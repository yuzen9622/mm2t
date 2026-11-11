"""Synthetic 8-speaker recordings: two 4-speaker sessions back to back (nearmix_opus).

Usage: concat.py DATA_DIR
Speakers never interleave across the join, so this tests speaker capacity and counting only,
not 8-way turn-taking.
"""

import sys
from pathlib import Path

import numpy as np
import soundfile as sf

PAIRS = [("R8001_M8004", "R8003_M8001"), ("R8007_M8010", "R8007_M8011")]
CONDITION = "nearmix_opus"


def main() -> None:
    data = Path(sys.argv[1])
    out_wav = data / "wav" / "concat8"
    out_ref = data / "ref_concat8"
    out_wav.mkdir(parents=True, exist_ok=True)
    out_ref.mkdir(parents=True, exist_ok=True)
    for first, second in PAIRS:
        session = f"{first}+{second}"
        parts, lines, offset = [], [], 0.0
        for name in (first, second):
            audio, rate = sf.read(data / "wav" / CONDITION / f"{name}__{CONDITION}.wav", dtype="float32")
            uem_end = float((data / "ref" / f"{name}.uem").read_text().split()[3])
            audio = audio[: int(uem_end * rate)]
            parts.append(audio)
            for line in (data / "ref" / f"{name}.rttm").read_text().splitlines():
                f = line.split()
                lines.append(f"SPEAKER {session} 1 {float(f[3]) + offset:.3f} {f[4]} <NA> <NA> {f[7]} <NA> <NA>")
            offset += len(audio) / rate
        sf.write(out_wav / f"{session}__concat8.wav", np.concatenate(parts), rate, subtype="PCM_16")
        (out_ref / f"{session}.rttm").write_text("\n".join(lines) + "\n")
        (out_ref / f"{session}.uem").write_text(f"{session} 1 0.000 {offset:.3f}\n")
        print(session, f"{offset:.1f}s", len({l.split()[7] for l in lines}), "speakers")


if __name__ == "__main__":
    main()
