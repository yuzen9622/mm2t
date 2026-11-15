from typing import BinaryIO, Optional, Protocol

from pydantic import BaseModel


class Word(BaseModel):
    word: str
    start: float
    end: float
    probability: float


class Segment(BaseModel):
    start: float
    end: float
    text: str
    words: list[Word]


class Transcript(BaseModel):
    model: str
    language: str
    duration: float
    segments: list[Segment]


class InvalidAudio(Exception):
    pass


class Engine(Protocol):
    model_id: str
    device: str

    def transcribe(
        self, audio: BinaryIO, language: Optional[str], vocabulary: list[str]
    ) -> Transcript: ...


class FasterWhisperEngine:
    def __init__(
        self,
        model_id: str,
        device: str,
        compute_type: str,
        revision: Optional[str] = None,
        batch_size: int = 16,
    ):
        import ctranslate2
        from faster_whisper import BatchedInferencePipeline, WhisperModel

        if device == "auto":
            device = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
        self.model_id = model_id
        self.device = device
        model = WhisperModel(
            model_id, device=device, compute_type=compute_type, revision=revision
        )
        # Batching decodes VAD-split chunks together instead of one 30 s window at a time:
        # on an RTX 5080 a 48-minute track went from 343 s to 21 s. batch_size 1 keeps the
        # sequential decoder.
        self._batch_size = batch_size
        self._model = BatchedInferencePipeline(model) if batch_size > 1 else model

    def transcribe(
        self, audio: BinaryIO, language: Optional[str], vocabulary: list[str]
    ) -> Transcript:
        import av
        from faster_whisper import decode_audio

        try:
            samples = decode_audio(audio)
        except av.error.FFmpegError as e:
            raise InvalidAudio(str(e)) from e
        if samples.size == 0:
            raise InvalidAudio("audio contains no samples")

        # hotwords is re-injected into every 30 s window; initial_prompt only primes the first.
        batching = {"batch_size": self._batch_size} if self._batch_size > 1 else {}
        segments, info = self._model.transcribe(
            samples,
            language=language,
            word_timestamps=True,
            hotwords=", ".join(vocabulary) or None,
            initial_prompt="以下是繁體中文的逐字稿，包含正確的標點符號，例如：逗號、句號、問號？以及驚嘆號！",
            **batching,
        )
        return Transcript(
            model=self.model_id,
            language=info.language,
            duration=info.duration,
            segments=[
                Segment(
                    start=s.start,
                    end=s.end,
                    text=s.text.strip(),
                    words=[
                        Word(
                            word=w.word,
                            start=w.start,
                            end=w.end,
                            probability=w.probability,
                        )
                        for w in s.words or []
                    ],
                )
                for s in segments
            ],
        )
