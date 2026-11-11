"""Build references and the three single-channel audio conditions from AliMeeting Eval.

Usage: prepare.py RAW_EVAL_DIR OUT_DIR

Writes OUT_DIR/ref/<session>.rttm and .uem from the far-field TextGrid (all speakers, one tier
each), and 16 kHz mono PCM16 wavs to OUT_DIR/wav/<condition>/<session>__<condition>.wav:
  far          channel 0 of the 8-channel far-field array
  nearmix      sum of every participant's headset channel
  nearmix_opus nearmix through Opus 24 kbit/s VoIP mode and back
It also reports, per condition, the lag that best aligns the reference speech mask with the
audio energy, so a reference/audio offset shows up before any scoring.
"""

import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from praatio import textgrid

RATE = 16_000
FRAME = 0.01


def reference_segments(textgrid_path: Path) -> tuple[list[tuple[float, float, str]], float]:
    grid = textgrid.openTextgrid(str(textgrid_path), includeEmptyIntervals=False)
    segments = []
    for name in grid.tierNames:
        speaker = name.removeprefix("N_")
        for start, end, text in grid.getTier(name).entries:
            if text.strip() and end > start:
                segments.append((start, end, speaker))
    return sorted(segments), grid.maxTimestamp


def write_reference(session: str, segments, uem_end: float, ref_dir: Path) -> None:
    lines = [
        f"SPEAKER {session} 1 {start:.3f} {end - start:.3f} <NA> <NA> {speaker} <NA> <NA>"
        for start, end, speaker in segments
    ]
    (ref_dir / f"{session}.rttm").write_text("\n".join(lines) + "\n")
    (ref_dir / f"{session}.uem").write_text(f"{session} 1 0.000 {uem_end:.3f}\n")


def to_pcm16(samples: np.ndarray, path: Path) -> None:
    peak = np.max(np.abs(samples))
    scaled = samples * (0.9 / peak) if peak > 0 else samples
    sf.write(path, scaled.astype(np.float32), RATE, subtype="PCM_16")


def opus_roundtrip(src: Path, dst: Path) -> None:
    encoded = dst.with_suffix(".opus")
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(src), "-c:a", "libopus", "-b:a", "24k",
         "-application", "voip", str(encoded)],
        check=True,
    )
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(encoded), "-ar", str(RATE), "-ac", "1",
         "-sample_fmt", "s16", str(dst)],
        check=True,
    )
    encoded.unlink()


def best_lag(audio: np.ndarray, segments, max_lag_s: float = 5.0) -> tuple[float, float]:
    hop = int(RATE * FRAME)
    frames = len(audio) // hop
    energy = np.log1p(np.square(audio[: frames * hop].reshape(frames, hop)).mean(axis=1) * 1e6)
    energy = (energy - energy.mean()) / (energy.std() + 1e-9)
    mask = np.zeros(frames)
    for start, end, _ in segments:
        mask[int(start / FRAME) : int(end / FRAME)] = 1.0
    mask = (mask - mask.mean()) / (mask.std() + 1e-9)
    max_lag = int(max_lag_s / FRAME)
    scores = {}
    for lag in range(-max_lag, max_lag + 1):
        a = energy[max(lag, 0) : frames + min(lag, 0)]
        m = mask[max(-lag, 0) : frames - max(lag, 0)]
        n = min(len(a), len(m))
        scores[lag] = float(np.dot(a[:n], m[:n]) / n)
    lag = max(scores, key=scores.get)
    return lag * FRAME, scores[lag]


def main() -> None:
    raw, out = Path(sys.argv[1]), Path(sys.argv[2])
    far_dir, near_dir = raw / "Eval_Ali_far", raw / "Eval_Ali_near"
    ref_dir = out / "ref"
    ref_dir.mkdir(parents=True, exist_ok=True)
    report = {}
    for grid_path in sorted((far_dir / "textgrid_dir").glob("*.TextGrid")):
        session = grid_path.stem
        segments, grid_end = reference_segments(grid_path)
        far_wav = next((far_dir / "audio_dir").glob(f"{session}_MS*.wav"))
        near_wavs = sorted((near_dir / "audio_dir").glob(f"{session}_N_SPK*.wav"))
        speakers = sorted({s for _, _, s in segments})
        near_speakers = [p.stem.split("_N_")[1] for p in near_wavs]
        assert speakers == near_speakers, f"{session}: tiers {speakers} vs headsets {near_speakers}"

        far = sf.read(far_wav, dtype="float32")[0][:, 0]
        near = [sf.read(p, dtype="float32")[0] for p in near_wavs]
        length = min(len(x) for x in near)
        nearmix = np.sum([x[:length] for x in near], axis=0)

        conditions = {}
        for name, samples in (("far", far), ("nearmix", nearmix)):
            path = out / "wav" / name / f"{session}__{name}.wav"
            path.parent.mkdir(parents=True, exist_ok=True)
            to_pcm16(samples, path)
            conditions[name] = path
        opus_path = out / "wav" / "nearmix_opus" / f"{session}__nearmix_opus.wav"
        opus_path.parent.mkdir(parents=True, exist_ok=True)
        opus_roundtrip(conditions["nearmix"], opus_path)
        conditions["nearmix_opus"] = opus_path

        durations = {name: sf.info(path).duration for name, path in conditions.items()}
        uem_end = min([grid_end, *durations.values()])
        write_reference(session, segments, uem_end, ref_dir)

        lags = {}
        for name, path in conditions.items():
            audio = sf.read(path, dtype="float32")[0]
            lags[name] = best_lag(audio, segments)
        report[session] = {
            "speakers": speakers,
            "textgrid_end_s": grid_end,
            "uem_end_s": uem_end,
            "durations_s": durations,
            "last_reference_end_s": max(end for _, end, _ in segments),
            "best_lag_s_and_corr": lags,
            "far_source": far_wav.name,
        }
        print(session, json.dumps(report[session]["best_lag_s_and_corr"]), f"uem_end={uem_end:.1f}",
              {k: round(v, 1) for k, v in durations.items()})
    (out / "prepare_report.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
