# AutoMix S1 — stem separation feasibility prototype

Offline research scripts for the **S1 kill gate** in
[`docs/automix-stems-predev.md`](../../docs/automix-stems-predev.md) §8. None of
this ships. It exists to answer two questions before anyone spends the 2–3 weeks
of Core ML work in S2:

1. Is a **stem-based** transition audibly better than the whole-mix technique the
   engine uses today?
2. Is the **separation residue** acceptable when the vocal is exposed solo?

The written verdict lives in
[`docs/automix-stems-s1-report.md`](../../docs/automix-stems-s1-report.md). The
decision is a blind-listening call, not a metric.

---

## What it produces

For each transition pair, four full renderings plus two solo stems:

| File | What it is |
|---|---|
| `pairN_A_baseline.wav` | **A side.** Offline approximation of today's engine: equal-power crossfade + bass swap at the midpoint. |
| `pairN_B_acapella.wav` | Outgoing instrumental drops out early; its vocal floats over the incoming full mix, then retires before the cut. |
| `pairN_B_instrumental_out.wav` | Outgoing vocal is removed at the top of the overlap; the incoming vocal owns the window. |
| `pairN_B_vocalduck.wav` | Same crossfade as A, but the outgoing vocal is held 9 dB down through the overlap. |
| `pairN_out_vocals.wav` | Outgoing separated vocal, solo, unprocessed — this is where you judge residue. |
| `pairN_in_vocals.wav` | Incoming separated vocal, solo. |

Each rendering is ~20 s of the outgoing track, the overlap, then ~20 s of the
incoming track: 44.1 kHz stereo, 24-bit. Every variant of a pair shares the same
cue points, overlap length, tempo scaling, loudness match and output gain, so the
**only** difference you hear is the technique.

## How to listen

Play `A_baseline` and one `B_*` back to back and pay attention to the ~12 s in the
middle. Then play `out_vocals` on its own — that is the residue, naked.

```sh
cd "$AB"           # wherever you rendered to
afplay pair3_A_baseline.wav
afplay pair3_B_acapella.wav
afplay pair3_out_vocals.wav
```

To keep it blind, have someone shuffle the filenames, or use the numbers in
`render-report.json` only after you've formed an opinion.

## How to run

Apple Silicon Mac, Command Line Tools only (no Xcode needed).

```sh
python3.13 -m venv /tmp/stems-venv
/tmp/stems-venv/bin/pip install mlx-audio sentencepiece soundfile scipy numpy
```

`ffmpeg` must be on `PATH` (decoding and tempo scaling).

```sh
MAT=/path/to/material          # audio + Kumone .analysis.json sidecars
AB=/path/to/output

# which tracks actually carry vocals (the cache has no usable title tags)
/tmp/stems-venv/bin/python separate_and_mix.py probe --material "$MAT"

# build the A/B set
/tmp/stems-venv/bin/python separate_and_mix.py render --material "$MAT" --out "$AB"

# objective sanity numbers (residue floor, how different B is from A)
/tmp/stems-venv/bin/python inspect_ab.py --dir "$AB"

# cost of one 30 s window, cold and warm
/tmp/stems-venv/bin/python separate_and_mix.py bench --audio "$MAT/some.mp3"
```

`--pairs pairs.json` overrides the built-in pair list with a JSON array of
`[outgoing_filename, incoming_filename, note]`.

## Material

The default pairs reference files from the app's own audio cache
(`~/Library/Caches/Kumone/Audio/`, `<trackID>-<quality>-netease.<ext>` with a
`.analysis.json` sidecar). **Neither the audio nor the renderings belong in the
repo** — keep both in a scratch directory.

The sidecars are what make the cue points realistic: they carry the analyzer's
`bpm`, `downbeats`, `phraseBoundaries` and `introEnd`.

## Model

[`mlx-community/mel-roformer-zfturbo-vocals-v1-mlx`](https://huggingface.co/mlx-community/mel-roformer-zfturbo-vocals-v1-mlx)
— Mel-Band RoFormer, ZFTurbo vocals v1, 67.4 MB fp16, MIT. This is the
licence-clean candidate from predev §2.2, converted for MLX. It is a **vocals-only**
model: it produces a vocal stem, and the instrumental is `mixture − vocals`.

That is why S1 only covers the vocal techniques. `stagedStemSwap` (drums first,
then bass) needs 4 stems and is out of scope here — see the report.

Downloaded on first run to `~/.cache/huggingface`. Inference runs on MLX/Metal,
chunked exactly as the checkpoint was trained (8 s chunks, 50 % overlap, Hann
overlap-add), so the timings are representative of the work a Core ML port would
have to reproduce.

## Fidelity to the real engine — what is approximated

This is a research rig, not a simulation of `PlaybackEngine`. Deliberate
approximations, all of which apply **equally to A and B**:

| Aspect | Real engine | Here |
|---|---|---|
| Cue selection | `TransitionPlanner.plan()` | A downbeat late in the outgoing track, biased toward a phrase boundary, and — because the stem techniques are undefined on an instrumental outro — required to sit inside a vocal phrase. Incoming: first downbeat at/after `introEnd`. |
| Overlap length | Planner-chosen per tier | Whole 4-beat bars at the outgoing tempo, clamped to 10–15 s. |
| Beat matching | `AVAudioUnitTimePitch` ramps | One constant `ffmpeg atempo` on the incoming track. Pairs are chosen within ~2 % BPM so this stays inaudible. |
| Loudness match | Engine's loudness matching | RMS match of the two excerpts. |
| Bass swap / staged EQ | 4-band EQ automation | Zero-phase 200 Hz split; outgoing lows gone by the midpoint, incoming lows arrive there. |
| Filter sweep / echo out | Real outro effects | Not modelled. The A side is the crossfade + bass swap case only. |

The A side is therefore a *fair but not literal* stand-in for today's output. If a
B rendering only barely beats it, treat that as a negative result — the real
engine's A side is somewhat better than this one.
