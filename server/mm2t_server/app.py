import hmac
import json
import logging
from typing import Optional

from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from faster_whisper.tokenizer import _LANGUAGE_CODES

from .engine import Engine, InvalidAudio, Transcript

log = logging.getLogger("mm2t_server")


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        self.status, self.code, self.message = status, code, message


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(
        status_code=status, content={"error": {"code": code, "message": message}}
    )


def _parse_language(raw: Optional[str]) -> Optional[str]:
    if raw is None or raw.strip() == "":
        return None
    # Whisper only knows the primary subtag: "zh-TW" and "zh-Hant" both mean "zh".
    code = raw.strip().replace("_", "-").split("-")[0].lower()
    if code not in _LANGUAGE_CODES:
        raise ApiError(400, "invalid_language", f"unsupported language: {raw}")
    return code


def _parse_vocabulary(raw: Optional[str]) -> list[str]:
    if raw is None or raw.strip() == "":
        return []
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        value = None
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise ApiError(
            400, "invalid_vocabulary", "vocabulary must be a JSON array of strings"
        )
    return [v.strip() for v in value if v.strip()]


def create_app(engine: Engine, token: Optional[str], max_upload_bytes: int) -> FastAPI:
    app = FastAPI(title="mm2t transcription server")
    too_large = f"upload exceeds {max_upload_bytes} bytes"

    @app.exception_handler(ApiError)
    async def api_error(_: Request, e: ApiError):
        return _error(e.status, e.code, e.message)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_: Request, e: RequestValidationError):
        fields = ", ".join(".".join(map(str, err["loc"][1:])) for err in e.errors())
        return _error(400, "invalid_request", f"missing or invalid fields: {fields}")

    # Middleware runs before the multipart body is read, so unauthenticated or
    # declared-oversized uploads are rejected without spooling them to disk.
    @app.middleware("http")
    async def guard(request: Request, call_next):
        if request.url.path.startswith("/v1/"):
            if token is not None:
                given = request.headers.get("authorization", "")
                if not hmac.compare_digest(given.encode(), f"Bearer {token}".encode()):
                    return _error(401, "unauthorized", "missing or invalid bearer token")
            length = request.headers.get("content-length")
            if length is not None and length.isdigit() and int(length) > max_upload_bytes:
                return _error(413, "payload_too_large", too_large)
        return await call_next(request)

    @app.get("/healthz")
    def healthz():
        return {"status": "ok", "model": engine.model_id, "device": engine.device}

    @app.post("/v1/transcriptions", response_model=Transcript)
    def transcriptions(
        file: UploadFile = File(...),
        language: Optional[str] = Form(None),
        vocabulary: Optional[str] = Form(None),
    ):
        if file.size is not None and file.size > max_upload_bytes:
            raise ApiError(413, "payload_too_large", too_large)
        lang = _parse_language(language)
        vocab = _parse_vocabulary(vocabulary)
        try:
            return engine.transcribe(file.file, lang, vocab)
        except InvalidAudio as e:
            raise ApiError(400, "invalid_audio", f"could not decode audio: {e}")
        except Exception as e:
            log.exception("transcription failed")
            raise ApiError(500, "engine_error", f"transcription failed: {e}")

    return app
