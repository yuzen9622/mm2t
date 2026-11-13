"use client";
import { useCallback, useEffect, useRef, useState } from "react";

const silence = () => Array<number>(6).fill(0);
type Status = "idle" | "requesting" | "listening" | "paused";

export function useMicrophoneWaveform() {
  const [status, setStatus] = useState<Status>("idle");
  const [history, setHistory] = useState(silence);
  const [seconds, setSeconds] = useState(0);
  const [error, setError] = useState<"permission" | "unavailable" | null>(null);
  const generation = useRef(0);
  const elapsed = useRef(0);
  const started = useRef<number | null>(null);
  const resources = useRef<{
    stream?: MediaStream;
    context?: AudioContext;
    timer?: ReturnType<typeof setInterval>;
  }>({});

  const release = useCallback(() => {
    generation.current += 1;
    const { stream, context, timer } = resources.current;
    resources.current = {};
    clearInterval(timer);
    stream?.getTracks().forEach((track) => track.stop());
    if (context && context.state !== "closed") void context.close().catch(() => {});
    if (started.current !== null) {
      elapsed.current += performance.now() - started.current;
      started.current = null;
    }
  }, []);

  const pause = useCallback(() => {
    release();
    setStatus("paused");
    setHistory(silence());
    setSeconds(Math.floor(elapsed.current / 1000));
  }, [release]);

  const finish = useCallback(() => {
    release();
    elapsed.current = 0;
    setSeconds(0);
    setHistory(silence());
    setError(null);
    setStatus("idle");
  }, [release]);

  useEffect(() => {
    const hide = () => { if (document.hidden) pause(); };
    document.addEventListener("visibilitychange", hide);
    window.addEventListener("pagehide", pause);
    return () => {
      document.removeEventListener("visibilitychange", hide);
      window.removeEventListener("pagehide", pause);
      release();
    };
  }, [pause, release]);

  async function start() {
    release();
    const request = generation.current;
    setError(null);
    setStatus("requesting");
    try {
      if (!navigator.mediaDevices?.getUserMedia || !window.AudioContext) {
        throw new Error("unavailable");
      }
      // Resume within the click gesture for browsers that require user activation.
      const context = new AudioContext();
      resources.current.context = context;
      await context.resume();
      if (generation.current !== request) return;
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      if (generation.current !== request) {
        stream.getTracks().forEach((track) => track.stop());
        return;
      }
      resources.current.stream = stream;
      const analyser = context.createAnalyser();
      analyser.fftSize = 2048;
      context.createMediaStreamSource(stream).connect(analyser);
      // Deliberately do not connect to the speakers or record/upload audio.
      const samples = new Float32Array(analyser.fftSize);
      started.current = performance.now();
      setStatus("listening");
      stream.getAudioTracks().forEach((track) => {
        track.addEventListener("ended", () => {
          if (generation.current === request) {
            pause();
            setError("unavailable");
          }
        }, { once: true });
      });
      resources.current.timer = setInterval(() => {
        analyser.getFloatTimeDomainData(samples);
        const rms = Math.sqrt(samples.reduce((sum, value) => sum + value * value, 0) / samples.length);
        // Map -60..-12 dBFS to the capsule height; silence stays flat.
        const level = Math.max(0, Math.min(1, (20 * Math.log10(Math.max(rms, 0.000001)) + 60) / 48));
        setHistory((previous) => [level, ...previous.slice(0, 5)]);
        setSeconds(Math.floor((elapsed.current + performance.now() - started.current!) / 1000));
      }, 80);
    } catch (cause) {
      if (generation.current !== request) return;
      release();
      setStatus("paused");
      setHistory(silence());
      setError(cause instanceof DOMException && cause.name === "NotAllowedError" ? "permission" : "unavailable");
    }
  }

  return { status, history, seconds, error, start, pause, finish };
}
