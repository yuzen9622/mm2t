"""Run `diareval embed` one wav at a time (retrying), so one Core ML allocation failure loses one file.

  embed_chunked.py ENGINE SPANS.json OUT.json   (ENGINE: wespeaker | campplus)
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

engine, spans, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
root = Path(__file__).resolve().parents[1]
binary = root / "build/swift/release/diareval"
results = []
for i, request in enumerate(json.loads(spans.read_text())):
    with tempfile.TemporaryDirectory() as tmp:
        part, piece = Path(tmp) / "in.json", Path(tmp) / "out.json"
        part.write_text(json.dumps([request]))
        for attempt in range(5):
            r = subprocess.run([binary, "embed", "--engine", engine, "--models", root / "models",
                                "--spans", part, "--out", piece], capture_output=True, cwd=root)
            if r.returncode == 0 and piece.exists():
                results.extend(json.loads(piece.read_text()))
                break
            print(f"retry {i} attempt {attempt}", flush=True)
        else:
            sys.exit(f"failed {request['wav']}")
    print(f"{i + 1} done", flush=True)
out.write_text(json.dumps(results))
