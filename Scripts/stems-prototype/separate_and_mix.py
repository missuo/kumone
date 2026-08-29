#!/usr/bin/env python3
"""AutoMix S1 — offline stem-transition feasibility prototype (kill gate).

Builds, for each transition pair, one baseline rendering that approximates what
Kumone's engine does today (equal-power crossfade + bass swap at the midpoint)
and three stem-based renderings that today's engine cannot do. All variants of a
pair share the same cue points, the same overlap length, the same beat-matching
and the same output gain, so the only difference you hear is the technique.

    python3 separate_and_mix.py probe   --material DIR
    python3 separate_and_mix.py render  --material DIR --out DIR [--pairs pairs.json]

See README.md. Nothing here is product code.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stemlib import (  # noqa: E402
    SR,
    Analysis,
    VocalSeparator,
    _split_lo_hi,
    bars_overlap,
    click_check,
    decode,
    equal_power,
    highpass,
    pick_in_point,
    pick_out_point,
    ramp,
    rms,
    rms_env,
    write_wav,
)

PRE = 20.0   # seconds of outgoing track before the transition
POST = 20.0  # seconds of incoming track after the transition
DUCK_DB = -9.0

# Default pairs: (outgoing, incoming, note). BPMs are within ~2 % so a single
# constant tempo scale on the incoming track keeps downbeats locked.
DEFAULT_PAIRS = [
    ("20963188-exhigh-netease.mp3", "526439257-exhigh-netease.mp3",
     "slow 87->88, mp3/mp3, vocal outgoing over a sparse incoming"),
    ("2648334276-exhigh-netease.mp3", "1308782023-exhigh-netease.mp3",
     "mid 115->116, mp3/mp3, moderate vocal density both sides"),
    ("1960619635-exhigh-netease.mp3", "1322132356-exhigh-netease.mp3",
     "mid 120->120, mp3/mp3, dense vocal outgoing -> sparse incoming (best case for acapella)"),
    ("2675127419-exhigh-netease.mp3", "20943184-lossless-netease.flac",
     "mid 110->112, mp3/flac, sparse outgoing -> dense vocal incoming"),
    ("1824918479-lossless-netease.flac", "1997293311-lossless-netease.flac",
     "driving 132->130, flac/flac, strong vocal outro"),
    ("553543175-exhigh-netease.mp3", "1816189151-exhigh-netease.mp3",
     "fast 168->168, mp3/mp3"),
]


# --------------------------------------------------------------- techniques


def _bass_swap(lo_out, hi_out, lo_in, hi_in, fo, fi):
    """Approximation of the engine's `bassSwapAt` + `stagedEQ`: the outgoing low
    end is gone by the midpoint, the incoming low end arrives there.
    """
    lo_out_g = fo * ramp(len(fo), 0.35, 0.5, 1.0, 0.0)
    lo_in_g = fi * ramp(len(fi), 0.45, 0.6, 0.0, 1.0)
    return lo_out * lo_out_g + hi_out * fo + lo_in * lo_in_g + hi_in * fi


def render_variants(out_mix, out_voc, in_mix, in_voc, n_ov):
    """All renderings share pre-roll and tail; only the overlap window differs."""
    pre_n = int(PRE * SR)
    o_pre, o_ov = out_mix[:pre_n], out_mix[pre_n : pre_n + n_ov]
    o_ov_voc = out_voc[pre_n : pre_n + n_ov]
    o_ov_inst = o_ov - o_ov_voc
    i_ov, i_tail = in_mix[:n_ov], in_mix[n_ov:]
    i_ov_voc = in_voc[:n_ov]

    fo, fi = equal_power(n_ov)
    lo_o, hi_o = _split_lo_hi(o_ov)
    lo_i, hi_i = _split_lo_hi(i_ov)

    v = {}

    # A — today's engine, approximated: equal-power crossfade + bass swap.
    v["A_baseline"] = _bass_swap(lo_o, hi_o, lo_i, hi_i, fo, fi)

    # B1 — acapella over the new bed: the outgoing instrumental drops out early,
    # its vocal floats over the incoming full mix, then retires before the cut.
    inst_out = o_ov_inst * (fo * ramp(n_ov, 0.0, 0.28, 1.0, 0.0))
    voc_out = highpass(o_ov_voc, 100.0) * ramp(n_ov, 0.72, 0.96, 1.0, 0.0)
    v["B_acapella"] = inst_out + voc_out + i_ov * ramp(n_ov, 0.0, 0.30, 0.0, 1.0)

    # B2 — instrumental outro: the outgoing vocal is removed at the top of the
    # overlap so the incoming vocal owns the window.
    o_inst_only = o_ov_inst + o_ov_voc * ramp(n_ov, 0.0, 0.12, 1.0, 0.0)
    lo_oi, hi_oi = _split_lo_hi(o_inst_only)
    v["B_instrumental_out"] = _bass_swap(lo_oi, hi_oi, lo_i, hi_i, fo, fi)

    # B3 — vocal duck: same crossfade as A, outgoing vocal held DUCK_DB down
    # so the two vocals stop fighting.
    o_ducked = o_ov_inst + o_ov_voc * (10 ** (DUCK_DB / 20.0))
    lo_od, hi_od = _split_lo_hi(o_ducked)
    v["B_vocalduck"] = _bass_swap(lo_od, hi_od, lo_i, hi_i, fo, fi)

    out = {k: np.vstack([o_pre, w.astype(np.float32), i_tail]) for k, w in v.items()}
    # Solo stems for residue inspection: the last 4 s before the cue plus the
    # whole overlap, unprocessed.
    s0 = pre_n - int(4 * SR)
    out["_solo_out_vocals"] = out_voc[s0 : pre_n + n_ov]
    out["_solo_in_vocals"] = np.vstack([np.zeros((int(4 * SR), 2), np.float32), i_ov_voc])
    return out


# ------------------------------------------------------------------ driver


def build_pair(sep, material, out_dir, idx, out_name, in_name, note):
    o_path, i_path = os.path.join(material, out_name), os.path.join(material, in_name)
    ao, ai = Analysis.load(o_path), Analysis.load(i_path)

    rate = ao.bpm / ai.bpm
    overlap = bars_overlap(ao.bpm)
    n_ov = int(round(overlap * SR))
    in_point = pick_in_point(ai)

    # Stage 1 — separate the outgoing tail once so the cue search can see where
    # the vocal actually is, then place the cue on a downbeat inside a vocal
    # phrase. Both A and B use the cue this produces, so it biases nothing.
    tail_start = max(0.0, ao.duration - (50.0 + PRE + 6.0))
    tail = decode(o_path, tail_start, ao.duration - tail_start)
    tail_voc = sep.separate(tail, f"pair{idx}-outgoing-tail")
    # Shift the tail-relative envelope into absolute track time so the cue
    # search can index it by seconds.
    env = np.concatenate([np.zeros(int(tail_start)), rms_env(tail_voc, hz=1.0)])
    out_point = pick_out_point(ao, overlap, PRE, vocal_env=env, env_hz=1.0)

    # Stage 2 — slice the transition windows out of the tail we already have.
    s0 = int(round((out_point - PRE - tail_start) * SR))
    want = int(round((PRE + overlap) * SR))
    if s0 >= 0 and s0 + want <= len(tail):
        out_mix, out_voc = tail[s0 : s0 + want], tail_voc[s0 : s0 + want]
    else:  # cue landed outside the separated tail — decode and separate directly
        out_mix = decode(o_path, out_point - PRE, PRE + overlap)
        out_voc = sep.separate(out_mix, f"pair{idx}-outgoing")

    in_mix = decode(i_path, in_point, overlap + POST, rate=rate)
    # Loudness match, like the engine does before a crossfade.
    g = rms(out_mix) / rms(in_mix)
    in_mix = (in_mix * np.clip(g, 0.25, 4.0)).astype(np.float32)

    t0 = time.time()
    in_voc = sep.separate(in_mix, f"pair{idx}-incoming")
    sep_seconds = time.time() - t0

    variants = render_variants(out_mix, out_voc, in_mix, in_voc, n_ov)

    peak = max(np.abs(w).max() for k, w in variants.items() if not k.startswith("_"))
    gain = min(1.0, 0.89 / max(peak, 1e-9))

    splices = [int(PRE * SR), int(PRE * SR) + n_ov]
    written = {}
    for name, w in variants.items():
        solo = name.startswith("_")
        fn = f"pair{idx}_{name[6:] if solo else name}.wav"
        y = (w * gain).astype(np.float32)
        write_wav(os.path.join(out_dir, fn), y)
        written[fn] = {"seconds": len(y) / SR, **click_check(y, None if solo else splices)}

    voc_ratio_out = rms(out_voc) / rms(out_mix)
    voc_ratio_in = rms(in_voc) / rms(in_mix)
    return {
        "pair": idx,
        "note": note,
        "outgoing": out_name,
        "incoming": in_name,
        "outgoing_bpm": round(ao.bpm, 2),
        "incoming_bpm": round(ai.bpm, 2),
        "tempo_scale_on_incoming": round(rate, 4),
        "out_point_s": round(out_point, 3),
        "in_point_s": round(in_point, 3),
        "overlap_s": round(overlap, 3),
        "bars": round(overlap / (4 * 60 / ao.bpm)),
        "incoming_gain": round(float(np.clip(g, 0.25, 4.0)), 3),
        "incoming_window_separation_seconds": round(sep_seconds, 2),
        "incoming_window_seconds": round(overlap + POST, 2),
        "vocal_energy_ratio_outgoing": round(voc_ratio_out, 3),
        "vocal_energy_ratio_incoming": round(voc_ratio_in, 3),
        "files": written,
    }


def cmd_render(args):
    sep = VocalSeparator()
    pairs = DEFAULT_PAIRS
    if args.pairs:
        pairs = [tuple(p) for p in json.load(open(args.pairs))]
    os.makedirs(args.out, exist_ok=True)
    report = {
        "model": "mlx-community/mel-roformer-zfturbo-vocals-v1-mlx (Mel-Band RoFormer, ZFTurbo vocals v1, MIT)",
        "backend": "MLX / Metal",
        "model_load_seconds": round(sep.load_seconds, 2),
        "pre_roll_s": PRE,
        "tail_s": POST,
        "duck_db": DUCK_DB,
        "pairs": [],
    }
    for i, (o, n, note) in enumerate(pairs, 1):
        print(f"[pair{i}] {o} -> {n} ({note})", flush=True)
        report["pairs"].append(build_pair(sep, args.material, args.out, i, o, n, note))
    report["separation_runs"] = sep.stats
    p = os.path.join(args.out, "render-report.json")
    json.dump(report, open(p, "w"), indent=2)
    print("wrote", p)


def cmd_probe(args):
    """Separate a 12 s mid-track window of every candidate to see which tracks
    actually carry vocals (the cache has no usable title/artist tags)."""
    sep = VocalSeparator()
    rows = []
    for p in sorted(glob.glob(os.path.join(args.material, "*.analysis.json"))):
        a_path = p[: -len(".analysis.json")]
        if not os.path.exists(a_path):
            continue
        a = Analysis.load(a_path)
        start = max(0.0, a.duration * 0.45)
        x = decode(a_path, start, 12.0)
        v = sep.separate(x, os.path.basename(a_path))
        rows.append((rms(v) / rms(x), a.bpm, a.duration, os.path.basename(a_path)))
    rows.sort(reverse=True)
    print(f"{'voc/mix':>8} {'bpm':>7} {'dur':>7}  file")
    for r in rows:
        print(f"{r[0]:8.3f} {r[1]:7.1f} {r[2]:7.1f}  {r[3]}")


def cmd_bench(args):
    """Cost of one 30 s window, cold and warm. Run in a fresh process for the
    cold number to mean anything — the first call also builds Metal kernels.
    """
    import resource

    sep = VocalSeparator()
    x = decode(args.audio, 60.0, 30.0)
    print(f"model load: {sep.load_seconds:.2f} s")
    for i in range(args.repeats):
        sep.separate(x, f"run{i}")
        s = sep.stats[-1]
        tag = "cold (incl. Metal kernel build)" if i == 0 else "warm"
        print(f"  run{i} {s['seconds_elapsed']:6.2f} s  rtf {s['realtime_factor']:.2f}x  "
              f"mlx peak {s['mlx_peak_gb']:.2f} GB  [{tag}]")
    print(f"process peak RSS: {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9:.2f} GB")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("probe", "render"):
        s = sub.add_parser(name)
        s.add_argument("--material", required=True, help="directory of audio + .analysis.json sidecars")
        if name == "render":
            s.add_argument("--out", required=True)
            s.add_argument("--pairs", help="optional JSON list of [outgoing, incoming, note]")
    b = sub.add_parser("bench")
    b.add_argument("--audio", required=True)
    b.add_argument("--repeats", type=int, default=3)
    args = ap.parse_args()
    {"probe": cmd_probe, "render": cmd_render, "bench": cmd_bench}[args.cmd](args)


if __name__ == "__main__":
    main()
