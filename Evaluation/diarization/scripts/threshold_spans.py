"""Fixed-length single-speaker reference pieces for calibrating the user (brief-vector) threshold.

  threshold_spans.py DATA_DIR OUT.json

For every session and condition, tiles each speaker's clean (no other reference speaker active)
stretches into non-overlapping pieces of each length in LENGTHS, then samples at most PER_SPEAKER
of them per speaker and length (seeded). Output has the same shape as `embeddings.py spans`, so
`diareval embed` accepts it with either engine.
"""

import json
import random
import sys
from pathlib import Path

from embeddings import read_rttm, subtract

LENGTHS = (0.5, 0.7, 1.0, 1.5, 2.0, 2.5)
PER_SPEAKER = 40
CONDITIONS = ("far", "nearmix", "nearmix_opus")


def tile(stretches, length):
    pieces = []
    for start, end in stretches:
        while end - start >= length - 1e-9:
            pieces.append((round(start, 3), round(start + length, 3)))
            start += length
    return pieces


def main(data: Path, out: Path) -> None:
    rng = random.Random(0)
    requests = []
    for ref in sorted((data / "ref").glob("*.rttm")):
        by_speaker = read_rttm(ref)
        chosen = []
        for speaker, intervals in sorted(by_speaker.items()):
            others = sorted(i for s, iv in by_speaker.items() if s != speaker for i in iv)
            stretches = subtract(sorted(intervals), others)
            for length in LENGTHS:
                pieces = tile(stretches, length)
                if len(pieces) > PER_SPEAKER:
                    pieces = rng.sample(pieces, PER_SPEAKER)
                chosen.extend(pieces)
        chosen.sort()
        for condition in CONDITIONS:
            wav = data / "wav" / condition / f"{ref.stem}__{condition}.wav"
            requests.append({"wav": str(wav.resolve()), "spans": [list(s) for s in chosen]})
    out.write_text(json.dumps(requests))
    print(f"{len(requests)} files, {sum(len(r['spans']) for r in requests)} spans")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
