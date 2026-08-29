#!/usr/bin/env python3
"""Objective sanity numbers for the S1 A/B set.

These do not replace listening — they are here so the written report can cite
something other than adjectives, and so a regression can be spotted without
re-listening to everything.

    python3 inspect_ab.py --dir /path/to/stems-ab

Reports, per pair:
  * vocal-stem duty cycle and residue floor (how loud the separation leftovers
    are between sung phrases, relative to that stem's own peak);
  * residue vs. the full mix in those same gaps — i.e. how much the incoming
    bed has to mask during an acapella-over;
  * how different each B rendering actually is from A inside the overlap.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys

import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stemlib import SR  # noqa: E402

FRAME = int(0.05 * SR)


def frames(x):
    n = len(x) // FRAME
    return np.sqrt(np.mean(np.square(x[: n * FRAME].reshape(n, -1), dtype=np.float64), axis=1))


def db(a, b):
    return 20 * np.log10(max(a, 1e-12) / max(b, 1e-12))


def band_split_pct(x, gap_frames):
    """Where the between-phrase residue sits: <200 Hz (bass/kick bleed),
    200 Hz-4 kHz (midrange smear), >8 kHz (cymbal wash).
    """
    n = min(len(gap_frames), len(x) // FRAME)
    m = x[: n * FRAME].reshape(n, FRAME, -1).mean(axis=2)[gap_frames[:n]]
    if not len(m):
        return (float("nan"),) * 3
    spec = np.abs(np.fft.rfft(m * np.hanning(FRAME)[None, :], axis=1)) ** 2
    f = np.fft.rfftfreq(FRAME, 1 / SR)
    tot = spec.sum() + 1e-20
    return (
        100 * spec[:, f < 200].sum() / tot,
        100 * spec[:, (f >= 200) & (f < 4000)].sum() / tot,
        100 * spec[:, f >= 8000].sum() / tot,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    args = ap.parse_args()
    report = json.load(open(os.path.join(args.dir, "render-report.json")))

    print(f"{'pair':>5} {'duty%':>6} {'residue vs stem peak':>21} {'residue vs mix':>15}   verdict")
    rows = []
    for p in report["pairs"]:
        i = p["pair"]
        voc, _ = sf.read(os.path.join(args.dir, f"pair{i}_out_vocals.wav"), dtype="float32", always_2d=True)
        base, _ = sf.read(os.path.join(args.dir, f"pair{i}_A_baseline.wav"), dtype="float32", always_2d=True)
        # the solo file is [cue-4 s, cue+overlap]; line the mix up with it
        pre = int(20.0 * SR)
        mix = base[pre - int(4 * SR) : pre - int(4 * SR) + len(voc)]

        fv, fm = frames(voc), frames(mix)
        n = min(len(fv), len(fm))
        fv, fm = fv[:n], fm[:n]
        peak = fv.max()
        active = fv > peak * 0.20
        gaps = ~active
        duty = 100.0 * active.mean()
        if gaps.sum() < 3:
            res_stem = res_mix = float("nan")
        else:
            res = np.median(fv[gaps])
            res_stem = db(res, peak)
            res_mix = db(res, np.median(fm[gaps]))
        verdict = "n/a" if np.isnan(res_stem) else (
            "clean" if res_stem < -30 else "audible when solo" if res_stem < -22 else "loud residue")
        bands = band_split_pct(voc, gaps)
        print(f"{i:>5} {duty:6.1f} {res_stem:21.1f} {res_mix:15.1f}   {verdict}"
              f"   residue energy <200Hz/200-4k/>8k: {bands[0]:.0f}/{bands[1]:.0f}/{bands[2]:.0f}%")
        rows.append({"pair": i, "duty_pct": round(duty, 1),
                     "residue_db_below_stem_peak": round(res_stem, 1),
                     "residue_db_vs_mix_in_gaps": round(res_mix, 1),
                     "residue_band_pct_low_mid_high": [round(b) for b in bands]})

    print(f"\n{'pair':>5}  difference from A inside the overlap window (dB RMS of A-B)")
    ov_by_pair = {p["pair"]: p["overlap_s"] for p in report["pairs"]}
    for i, ov in ov_by_pair.items():
        a, _ = sf.read(os.path.join(args.dir, f"pair{i}_A_baseline.wav"), dtype="float32", always_2d=True)
        s, e = int(20 * SR), int(20 * SR) + int(ov * SR)
        line = []
        for v in ("B_acapella", "B_instrumental_out", "B_vocalduck"):
            b, _ = sf.read(os.path.join(args.dir, f"pair{i}_{v}.wav"), dtype="float32", always_2d=True)
            d = np.sqrt(np.mean(np.square(a[s:e] - b[s:e], dtype=np.float64)))
            r = np.sqrt(np.mean(np.square(a[s:e], dtype=np.float64)))
            line.append(f"{v.replace('B_',''):>16}: {db(d, r):+6.1f}")
        print(f"{i:>5}  " + "  ".join(line))

    json.dump(rows, open(os.path.join(args.dir, "residue-report.json"), "w"), indent=2)


if __name__ == "__main__":
    main()
