"use client";
import { useEffect, useRef, useState } from "react";
import { motion, useReducedMotion } from "motion/react";
import { useCopy } from "./i18n";
import { Icon } from "./icon";
import { Button } from "./ui/button";
import { useMicrophoneWaveform } from "@/hooks/use-microphone-waveform";

/** Same 11 bars, 2.5pt width/gap, six-sample mirrored history and taper as FloatingContent.swift. */
export function NativeWaveform({
  paused = false,
  className = "",
  samples,
}: {
  paused?: boolean;
  className?: string;
  samples?: number[];
}) {
  const root = useRef<HTMLDivElement>(null);
  const reduced = useReducedMotion();
  const [history, setHistory] = useState([0.9, 0.7, 0.95, 0.6, 0.8, 0.5]);
  useEffect(() => {
    const el = root.current;
    if (!el || reduced || paused || samples) return;
    let timer: ReturnType<typeof setInterval> | undefined;
    let tick = 0;
    let visible = false;
    function stop() {
      clearInterval(timer);
      timer = undefined;
    }
    function sync() {
      stop();
      if (!visible || document.hidden) return;
      timer = setInterval(() => {
        tick += 1;
        // Illustrative speech, no microphone access. New samples travel out from the center.
        const breath = Math.pow(Math.max(0, Math.sin(tick * 0.19)), 0.45);
        const syllable =
          0.25 + 0.75 * Math.abs(Math.sin(tick * 1.13) * Math.cos(tick * 0.37));
        setHistory((previous) => [
          0.08 + 0.92 * breath * syllable,
          ...previous.slice(0, 5),
        ]);
      }, 120);
    }
    const observer = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      sync();
    });
    observer.observe(el);
    document.addEventListener("visibilitychange", sync);
    return () => {
      observer.disconnect();
      stop();
      document.removeEventListener("visibilitychange", sync);
    };
  }, [paused, reduced, samples]);
  return (
    <div
      ref={root}
      className={`flex h-6 w-[52.5px] items-center justify-center gap-[2.5px] ${paused ? "opacity-45" : ""} ${className}`}
      aria-hidden="true"
    >
      {Array.from({ length: 11 }, (_, i) => {
        const d = Math.abs(i - 5);
        return (
          <motion.i
            key={i}
            initial={false}
            className="block shrink-0 basis-[2.5px] rounded-full bg-current"
            animate={{
              height: paused ? 3 : 3 + 21 * (samples ?? history)[d] * (1 - (d / 6) * 0.75),
            }}
            transition={{
              duration: reduced ? 0 : 0.12,
              ease: [0.22, 1, 0.36, 1],
            }}
          />
        );
      })}
    </div>
  );
}

export function RecordingDemo() {
  const { t } = useCopy();
  const mic = useMicrophoneWaveform();
  const listening = mic.status === "listening";
  const requesting = mic.status === "requesting";
  const action = requesting ? "取消麥克風請求" : listening ? "暫停麥克風" : "開啟麥克風試試";
  const time = `${String(Math.floor(mic.seconds / 60)).padStart(2, "0")}:${String(mic.seconds % 60).padStart(2, "0")}`;
  return (
    <div className="mb-6 flex flex-col items-center">
      <div
        className="flex items-center gap-3 rounded-full bg-black px-3 py-2 text-white shadow-lg shadow-black/5 md:px-4 md:py-3"
        role="group"
        aria-label={t("錄音膠囊互動示範")}
        aria-busy={requesting}
      >
        <Button
          type="button"
          size="icon"
          variant="ghost"
          className="size-11 bg-white/15 text-white hover:bg-white/25 hover:text-white"
          onClick={requesting ? mic.finish : listening ? mic.pause : mic.start}
          aria-label={t(action)}
          title={t(action)}
          aria-pressed={listening}
        >
          <Icon name={requesting ? "close" : listening ? "pause" : "mic"} size={16} />
        </Button>
        <NativeWaveform samples={mic.history} paused={!listening} />
        <time className="text-sm tabular-nums">{time}</time>
        <Icon name="star" size={20} />
        <Button
          type="button"
          size="icon"
          variant="ghost"
          className="size-9 bg-background text-foreground hover:bg-background/90"
          onClick={mic.finish}
          disabled={mic.status === "idle"}
          aria-label={t("結束麥克風體驗")}
          title={t("結束麥克風體驗")}
        >
          <Icon name="check" size={16} />
        </Button>
      </div>
      <p role="status" className={mic.error ? "mt-3 max-w-xs text-center text-xs text-muted-foreground" : "sr-only"}>
        {mic.error
          ? t(mic.error === "permission" ? "請允許麥克風權限，再點一下重試。" : "無法使用麥克風，請確認裝置與瀏覽器設定後重試。")
          : t(requesting ? "等待麥克風權限" : listening ? "麥克風已開啟，聲音僅在此裝置分析，不會儲存或上傳。" : "點擊麥克風，讓波形跟著你的聲音。")}
      </p>
    </div>
  );
}
