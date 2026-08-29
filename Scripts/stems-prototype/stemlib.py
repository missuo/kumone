"""Shared helpers for the AutoMix S1 stem-separation feasibility prototype.

Offline only. Nothing here ships in the app — this exists to answer the S1
kill-gate question from docs/automix-stems-predev.md §8:

    Is a stem-based transition audibly better than the current whole-mix
    technique, and is the separation residue acceptable when exposed solo?

See README.md in this directory for how to run it.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfiltfilt

SR = 44100
HF_MODEL = "mlx-community/mel-roformer-zfturbo-vocals-v1-mlx"


# ---------------------------------------------------------------- audio I/O


def decode(path: str, start: float, duration: float, rate: float = 1.0) -> np.ndarray:
    """Decode [start, start+duration*rate) of `path`, tempo-scaled by `rate`.

    `rate > 1` speeds the source up (pitch preserved, like the engine's
    AVAudioUnitTimePitch). Returns float32 [N, 2] at 44.1 kHz, exactly
    round(duration * SR) frames long (zero-padded if the source runs out).
    """
    src_dur = duration * rate + 0.5
    af = ["-af", f"atempo={rate:.9f}"] if abs(rate - 1.0) > 1e-6 else []
    cmd = [
        "ffmpeg", "-v", "error",
        "-ss", f"{max(0.0, start):.6f}", "-t", f"{src_dur:.6f}",
        "-i", path, *af,
        "-ar", str(SR), "-ac", "2", "-f", "f32le", "-",
    ]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).copy()
    want = int(round(duration * SR))
    if len(x) < want:
        x = np.vstack([x, np.zeros((want - len(x), 2), np.float32)])
    return x[:want]


def write_wav(path: str, x: np.ndarray) -> None:
    import soundfile as sf

    Path(path).parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, np.clip(x, -1.0, 1.0), SR, subtype="PCM_24")


# ------------------------------------------------------- Kumone analysis JSON


@dataclass
class Analysis:
    path: str
    bpm: float
    bpm_confidence: float
    duration: float
    intro_end: float
    downbeats: list
    phrase_boundaries: list

    @staticmethod
    def load(audio_path: str) -> "Analysis":
        j = json.load(open(audio_path + ".analysis.json"))
        return Analysis(
            path=audio_path,
            bpm=j["bpm"],
            bpm_confidence=j.get("bpmConfidence", 0.0),
            duration=j["duration"],
            intro_end=j.get("introEnd", 0.0),
            downbeats=sorted(j.get("downbeats", [])),
            phrase_boundaries=sorted(j.get("phraseBoundaries", [])),
        )


def out_point_candidates(a: Analysis, overlap: float, pre: float, span: float = 50.0) -> list:
    lo = max(pre + 1.0, a.duration - span)
    hi = a.duration - overlap - 2.0
    c = [d for d in a.downbeats if lo <= d <= hi]
    return c or [max(lo, min(hi, a.duration - 35.0))]


def pick_out_point(a: Analysis, overlap: float, pre: float, vocal_env=None, env_hz: float = 1.0) -> float:
    """Approximate the outgoing cue: a downbeat late in the track, biased toward
    a phrase boundary.

    If `vocal_env` (a per-second RMS curve of the separated vocal over the whole
    track) is supplied, candidates whose overlap window carries no vocal are
    rejected first — the stem techniques are undefined on an instrumental outro,
    and a stem-aware planner would make the same choice (predev doc §7.5).
    """
    cands = out_point_candidates(a, overlap, pre)
    target = a.duration - 35.0
    phrases = [p for p in a.phrase_boundaries if cands[0] <= p <= cands[-1]]
    anchor = min(phrases, key=lambda p: abs(p - target)) if phrases else target

    if vocal_env is not None and len(vocal_env):
        def vocal_score(d):
            i0, i1 = int(d * env_hz), int((d + overlap) * env_hz)
            seg = vocal_env[i0:i1]
            return float(seg.mean()) if len(seg) else 0.0

        scored = [(vocal_score(d), d) for d in cands]
        best = max(s for s, _ in scored)
        if best > 0.0:
            keep = [d for s, d in scored if s >= 0.6 * best]
            return min(keep, key=lambda d: abs(d - anchor))
    return min(cands, key=lambda d: abs(d - anchor))


def rms_env(x: np.ndarray, hz: float = 1.0) -> np.ndarray:
    """Per-(1/hz)-second RMS curve, index i covering [i/hz, (i+1)/hz)."""
    w = int(SR / hz)
    n = max(1, len(x) // w)
    m = x[: n * w].reshape(n, -1)
    return np.sqrt(np.mean(np.square(m, dtype=np.float64), axis=1))


def pick_in_point(a: Analysis) -> float:
    """Approximate the incoming cue: first downbeat at/after introEnd."""
    after = [d for d in a.downbeats if d >= max(a.intro_end, 0.0) - 0.05]
    if after:
        return after[0]
    return a.downbeats[0] if a.downbeats else 0.0


def bars_overlap(bpm: float, target: float = 12.0, lo: float = 10.0, hi: float = 15.0) -> float:
    """Overlap length snapped to whole 4-beat bars, kept inside [lo, hi] s."""
    bar = 4.0 * 60.0 / bpm
    n = max(1, int(round(target / bar)))
    while n * bar > hi and n > 1:
        n -= 1
    while n * bar < lo:
        n += 1
    return n * bar


# ------------------------------------------------------------- separation


class VocalSeparator:
    """Mel-Band RoFormer (ZFTurbo vocals v1, MIT) via MLX.

    Chunked exactly as the checkpoint was trained (8 s chunks, 50 % overlap,
    Hann overlap-add) so the numbers below are representative of what an
    on-device Core ML port would have to reproduce.
    """

    def __init__(self, repo: str = HF_MODEL):
        import mlx.core as mx
        from mlx_audio.sts.models.mel_roformer import MelRoFormer

        self.mx = mx
        t0 = time.time()
        self.model = MelRoFormer.from_pretrained(repo)
        self.model.eval()
        self.load_seconds = time.time() - t0
        self.cfg = self.model.config
        self.stats: list[dict] = []

    def separate(self, x: np.ndarray, label: str = "") -> np.ndarray:
        """x: float32 [N, 2] -> vocals float32 [N, 2]. Instrumental is x - vocals."""
        mx = self.mx
        chunk = int(self.cfg.chunk_size)
        hop = chunk // int(self.cfg.num_overlap)
        n = len(x)
        pad = max(0, chunk - n)
        xp = np.vstack([x, np.zeros((pad, 2), np.float32)]) if pad else x

        win = np.hanning(chunk + 1)[:-1].astype(np.float32)
        acc = np.zeros((len(xp), 2), np.float32)
        wsum = np.zeros((len(xp), 1), np.float32)

        mx.reset_peak_memory()
        t0 = time.time()
        starts = list(range(0, max(1, len(xp) - chunk + 1), hop))
        if starts[-1] + chunk < len(xp):
            starts.append(len(xp) - chunk)
        for s in starts:
            seg = xp[s : s + chunk]
            out = self.model(mx.array(seg.T[None]))
            mx.eval(out)
            v = np.array(out, dtype=np.float32)[0].T
            acc[s : s + chunk] += v * win[:, None]
            wsum[s : s + chunk, 0] += win
        elapsed = time.time() - t0
        peak_gb = mx.get_peak_memory() / 1e9

        wsum[wsum < 1e-6] = 1e-6
        vocals = (acc / wsum)[:n]
        self.stats.append(
            {
                "label": label,
                "seconds_in": n / SR,
                "seconds_elapsed": elapsed,
                "realtime_factor": (n / SR) / elapsed,
                "chunks": len(starts),
                "mlx_peak_gb": peak_gb,
            }
        )
        return vocals.astype(np.float32)


# ------------------------------------------------------------- DSP helpers


def _split_lo_hi(x: np.ndarray, fc: float = 200.0) -> tuple:
    """Zero-phase 2nd-order split so low + high == x (approximately)."""
    sos = butter(2, fc / (SR / 2), btype="low", output="sos")
    lo = sosfiltfilt(sos, x, axis=0).astype(np.float32)
    return lo, (x - lo).astype(np.float32)


def highpass(x: np.ndarray, fc: float) -> np.ndarray:
    sos = butter(2, fc / (SR / 2), btype="high", output="sos")
    return sosfiltfilt(sos, x, axis=0).astype(np.float32)


def equal_power(n: int) -> tuple:
    """(fade_out, fade_in) equal-power curves of length n, as [n,1] columns."""
    t = np.linspace(0.0, 1.0, n, dtype=np.float32)
    return np.cos(t * np.pi / 2)[:, None], np.sin(t * np.pi / 2)[:, None]


def ramp(n: int, t0: float, t1: float, v0: float, v1: float) -> np.ndarray:
    """[n,1] gain that is v0 up to fraction t0, ramps (raised-cosine) to v1 by t1."""
    t = np.linspace(0.0, 1.0, n, dtype=np.float32)
    u = np.clip((t - t0) / max(t1 - t0, 1e-9), 0.0, 1.0)
    s = 0.5 - 0.5 * np.cos(np.pi * u)
    return (v0 + (v1 - v0) * s)[:, None].astype(np.float32)


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(x), dtype=np.float64)) + 1e-12)


def click_check(x: np.ndarray, splices: list | None = None) -> dict:
    """Glue-point sanity.

    A raw max-sample-jump is meaningless on dense program material, so we report
    the jump at each splice index relative to the 99.99th percentile jump of the
    whole file. Anything at or below 1.0 is indistinguishable from normal
    program transients.
    """
    d = np.abs(np.diff(x, axis=0)).max(axis=1)
    ref = float(np.percentile(d, 99.99)) if len(d) else 1.0
    out = {"peak": float(np.abs(x).max()), "jump_p99_99": round(ref, 5)}
    for i, k in enumerate(splices or []):
        k = int(min(max(k, 1), len(d)))
        out[f"splice{i}_jump_over_p99_99"] = round(float(d[k - 1]) / max(ref, 1e-9), 3)
    return out


def env_db(x: np.ndarray, win: float = 0.25) -> np.ndarray:
    """Coarse RMS envelope in dBFS, for report tables."""
    w = int(win * SR)
    n = len(x) // w
    m = x[: n * w].reshape(n, w, -1)
    r = np.sqrt(np.mean(np.square(m, dtype=np.float64), axis=(1, 2)))
    return 20 * np.log10(r + 1e-12)
