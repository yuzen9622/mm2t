import io
from typing import BinaryIO, Optional

import pytest
from fastapi.testclient import TestClient

from mm2t_server.app import create_app
from mm2t_server.engine import InvalidAudio, Segment, Transcript, Word

AUDIO = ("clip.wav", b"RIFF....WAVEfmt fake audio bytes", "audio/wav")


class FakeEngine:
    model_id = "fake/breeze"
    device = "cpu"

    def __init__(self, error: Optional[Exception] = None):
        self.error = error
        self.calls: list[dict] = []

    def transcribe(
        self, audio: BinaryIO, language: Optional[str], vocabulary: list[str]
    ) -> Transcript:
        self.calls.append(
            {"audio": audio.read(), "language": language, "vocabulary": vocabulary}
        )
        if self.error:
            raise self.error
        return Transcript(
            model=self.model_id,
            language=language or "zh",
            duration=2.5,
            segments=[
                Segment(
                    start=0.0,
                    end=1.2,
                    text="王小明 好",
                    words=[
                        Word(word="王小明", start=0.0, end=0.8, probability=0.91),
                        Word(word="好", start=0.8, end=1.2, probability=0.88),
                    ],
                )
            ],
        )


def client(engine=None, token=None, max_upload_bytes=10_000):
    engine = engine or FakeEngine()
    return engine, TestClient(create_app(engine, token, max_upload_bytes))


def test_healthz_reports_model_and_device():
    _, c = client()
    r = c.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "model": "fake/breeze", "device": "cpu"}


def test_transcription_returns_contract_shape_with_word_timestamps():
    engine, c = client()
    r = c.post("/v1/transcriptions", files={"file": AUDIO})
    assert r.status_code == 200
    body = r.json()
    assert body == {
        "model": "fake/breeze",
        "language": "zh",
        "duration": 2.5,
        "segments": [
            {
                "start": 0.0,
                "end": 1.2,
                "text": "王小明 好",
                "words": [
                    {"word": "王小明", "start": 0.0, "end": 0.8, "probability": 0.91},
                    {"word": "好", "start": 0.8, "end": 1.2, "probability": 0.88},
                ],
            }
        ],
    }
    assert engine.calls[0]["audio"] == AUDIO[1]
    assert engine.calls[0]["language"] is None


def test_vocabulary_and_language_reach_engine():
    engine, c = client()
    r = c.post(
        "/v1/transcriptions",
        files={"file": AUDIO},
        data={"language": "zh-TW", "vocabulary": '["王小明", " Kubernetes ", ""]'},
    )
    assert r.status_code == 200
    assert engine.calls[0]["language"] == "zh"
    assert engine.calls[0]["vocabulary"] == ["王小明", "Kubernetes"]


@pytest.mark.parametrize(
    "data, code",
    [
        ({"vocabulary": "not json"}, "invalid_vocabulary"),
        ({"vocabulary": '{"a": 1}'}, "invalid_vocabulary"),
        ({"vocabulary": '["ok", 3]'}, "invalid_vocabulary"),
        ({"language": "xx"}, "invalid_language"),
    ],
)
def test_bad_fields_are_400(data, code):
    engine, c = client()
    r = c.post("/v1/transcriptions", files={"file": AUDIO}, data=data)
    assert r.status_code == 400
    assert r.json()["error"]["code"] == code
    assert engine.calls == []


def test_missing_file_is_400():
    _, c = client()
    r = c.post("/v1/transcriptions", data={"language": "zh"})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_request"


def test_undecodable_audio_is_400():
    _, c = client(FakeEngine(error=InvalidAudio("bad header")))
    r = c.post("/v1/transcriptions", files={"file": AUDIO})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_audio"


def test_engine_failure_is_500():
    _, c = client(FakeEngine(error=RuntimeError("CUBLAS_STATUS_NOT_SUPPORTED")))
    r = c.post("/v1/transcriptions", files={"file": AUDIO})
    assert r.status_code == 500
    assert r.json()["error"] == {
        "code": "engine_error",
        "message": "transcription failed: CUBLAS_STATUS_NOT_SUPPORTED",
    }


def test_oversized_upload_is_413_and_never_reaches_engine():
    engine, c = client(max_upload_bytes=1024)
    big = ("big.wav", io.BytesIO(b"\0" * 4096), "audio/wav")
    r = c.post("/v1/transcriptions", files={"file": big})
    assert r.status_code == 413
    assert r.json()["error"]["code"] == "payload_too_large"
    assert engine.calls == []


def test_oversized_chunked_upload_without_content_length_is_413():
    engine, c = client(max_upload_bytes=1024)
    body = (
        b"--b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"big.wav\"\r\n"
        b"Content-Type: audio/wav\r\n\r\n" + b"\0" * 4096 + b"\r\n--b--\r\n"
    )
    r = c.post(
        "/v1/transcriptions",
        content=iter([body]),
        headers={"Content-Type": "multipart/form-data; boundary=b"},
    )
    assert "content-length" not in r.request.headers
    assert r.status_code == 413
    assert engine.calls == []


def test_auth_off_when_no_token():
    _, c = client(token=None)
    assert c.post("/v1/transcriptions", files={"file": AUDIO}).status_code == 200


@pytest.mark.parametrize("header", [None, "Bearer wrong", "secret", "Basic secret"])
def test_auth_on_rejects_bad_credentials(header):
    engine, c = client(token="secret")
    headers = {"Authorization": header} if header else {}
    r = c.post("/v1/transcriptions", files={"file": AUDIO}, headers=headers)
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "unauthorized"
    assert engine.calls == []


def test_auth_on_accepts_token_and_leaves_healthz_open():
    _, c = client(token="secret")
    r = c.post(
        "/v1/transcriptions",
        files={"file": AUDIO},
        headers={"Authorization": "Bearer secret"},
    )
    assert r.status_code == 200
    assert c.get("/healthz").status_code == 200
