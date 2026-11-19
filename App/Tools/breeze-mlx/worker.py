"""Persistent offline Breeze recognizer. stdin carries JSON headers and little-endian float32 PCM."""
import multiprocessing

if __name__ == "__main__":
    multiprocessing.freeze_support()

import json
import os
import sys
import traceback

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"
import mlx.core as mx
import numpy as np
from mlx_whisper.transcribe import ModelHolder, transcribe


def reply(value):
    print(json.dumps(value, ensure_ascii=False, allow_nan=False), flush=True)


def main():
    model = sys.argv[1]
    # Variable utterance lengths create many buffer sizes. Bound the allocations
    # MLX keeps for reuse between requests; the live model weights stay resident.
    mx.set_cache_limit(256 * 1024 * 1024)
    ModelHolder.get_model(model, mx.float16)
    mx.synchronize()
    reply({"ready": True})
    source = sys.stdin.buffer
    while header := source.readline():
        request = json.loads(header)
        length = request["frames"]
        data = source.read(length * 4)
        if len(data) != length * 4:
            raise EOFError("Incomplete audio")
        try:
            result = transcribe(np.frombuffer(data, dtype="<f4").copy(), path_or_hf_repo=model,
                                language=request.get("language"), initial_prompt=request.get("prompt"),
                                word_timestamps=True, verbose=None, temperature=(0.0, 0.2, 0.4, 0.6))
            words = []
            for seg in result["segments"]:
                units = seg.get("words") or [dict(word=seg["text"], start=seg["start"], end=seg["end"])]
                for word in units:
                    text = word["word"].strip()
                    if text:
                        start = max(0, min(length / 16000, word["start"]))
                        end = max(start, min(length / 16000, word["end"]))
                        words.append(dict(text=text, start=start, end=end))
            reply({"words": words})
        except Exception:
            traceback.print_exc(file=sys.stderr)
            reply({"error": "decode"})


if __name__ == "__main__":
    main()
