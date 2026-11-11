import logging
import os

import uvicorn

from .app import create_app
from .engine import FasterWhisperEngine

# Community CT2 conversion of MediaTek-Research/Breeze-ASR-25; pinned to a commit
# so a third party cannot silently swap the weights.
DEFAULT_MODEL = "SoybeanMilk/faster-whisper-Breeze-ASR-25"
DEFAULT_REVISION = "85be11de5f67aaa6a92e931622f1c2b55cc1dd3a"


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    model = os.environ.get("MM2T_MODEL") or DEFAULT_MODEL
    revision = os.environ.get("MM2T_MODEL_REVISION") or (
        DEFAULT_REVISION if model == DEFAULT_MODEL else None
    )
    engine = FasterWhisperEngine(
        model_id=model,
        device=os.environ.get("MM2T_DEVICE", "auto"),
        compute_type=os.environ.get("MM2T_COMPUTE_TYPE", "default"),
        revision=revision,
    )
    app = create_app(
        engine,
        token=os.environ.get("MM2T_SERVER_TOKEN") or None,
        max_upload_bytes=int(os.environ.get("MM2T_MAX_UPLOAD_MB", "500")) * 1024 * 1024,
    )
    uvicorn.run(
        app,
        host=os.environ.get("MM2T_HOST", "0.0.0.0"),
        port=int(os.environ.get("MM2T_PORT", "8000")),
    )


if __name__ == "__main__":
    main()
