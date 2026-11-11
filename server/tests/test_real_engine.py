import os
import urllib.request

import pytest
from fastapi.testclient import TestClient

from mm2t_server.app import create_app

pytestmark = pytest.mark.skipif(
    os.environ.get("MM2T_REAL_ENGINE_TEST") != "1",
    reason="downloads the faster-whisper tiny model and a clip; set MM2T_REAL_ENGINE_TEST=1",
)

JFK_URL = "https://raw.githubusercontent.com/SYSTRAN/faster-whisper/v1.2.1/tests/data/jfk.flac"


@pytest.fixture(scope="module")
def real_client():
    from mm2t_server.engine import FasterWhisperEngine

    engine = FasterWhisperEngine("tiny", device="cpu", compute_type="int8")
    real = engine._model.transcribe
    engine.seen_kwargs = []

    def spy(audio, **kwargs):
        engine.seen_kwargs.append(kwargs)
        return real(audio, **kwargs)

    engine._model.transcribe = spy
    c = TestClient(create_app(engine, token=None, max_upload_bytes=50 * 1024 * 1024))
    c.engine = engine
    return c


@pytest.fixture(scope="module")
def jfk(tmp_path_factory):
    path = tmp_path_factory.mktemp("audio") / "jfk.flac"
    urllib.request.urlretrieve(JFK_URL, path)
    return path.read_bytes()


def test_real_engine_returns_words_with_timestamps(real_client, jfk):
    r = real_client.post(
        "/v1/transcriptions",
        files={"file": ("jfk.flac", jfk, "audio/flac")},
        data={"language": "en", "vocabulary": '["Americans", "Kennedy"]'},
    )
    assert r.status_code == 200, r.text
    assert real_client.engine.seen_kwargs[-1]["hotwords"] == "Americans, Kennedy"
    body = r.json()
    assert body["model"] == "tiny"
    assert body["language"] == "en"
    assert 10.5 < body["duration"] < 11.5
    text = " ".join(s["text"] for s in body["segments"]).lower()
    assert "your country" in text
    words = [w for s in body["segments"] for w in s["words"]]
    assert len(words) > 15
    starts = [w["start"] for w in words]
    assert starts == sorted(starts)
    assert all(0 <= w["start"] <= w["end"] <= body["duration"] + 0.5 for w in words)


def test_real_engine_rejects_garbage_audio(real_client):
    r = real_client.post(
        "/v1/transcriptions", files={"file": ("x.wav", b"not audio at all", "audio/wav")}
    )
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_audio"
