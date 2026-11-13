"use client";
import { useEffect, useRef, useState } from "react";
import { motion, useReducedMotion } from "motion/react";
import { useCopy } from "./i18n";
import { Icon } from "./icon";
import { Button } from "./ui/button";

/** Same 11 bars, 2.5pt width/gap, six-sample mirrored history and taper as FloatingContent.swift. */
export function NativeWaveform({
  paused = false,
  className = "",
}: {
  paused?: boolean;
  className?: string;
}) {
  const root = useRef<HTMLDivElement>(null);
  const reduced = useReducedMotion();
  const [history, setHistory] = useState([0.9, 0.7, 0.95, 0.6, 0.8, 0.5]);
  useEffect(() => {
    const el = root.current;
    if (!el || reduced || paused) return;
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
  }, [paused, reduced]);
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
              height: paused ? 3 : 3 + 21 * history[d] * (1 - (d / 6) * 0.75),
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
  const [paused, setPaused] = useState(false);
  return (
    <div className="mb-6 flex flex-col items-center">
      <div
        className="flex items-center gap-3 rounded-full bg-black px-3 py-2 text-white shadow-lg shadow-black/5 md:px-4 md:py-3"
        aria-label={t("錄音膠囊互動示範")}
      >
        <Button
          type="button"
          size="icon"
          variant="ghost"
          className="size-11 bg-white/15 text-white hover:bg-white/25 hover:text-white"
          onClick={() => setPaused((v) => !v)}
          aria-label={t(paused ? "播放波形動畫" : "暫停波形動畫")}
          aria-pressed={paused}
        >
          <Icon name={paused ? "play" : "pause"} size={16} />
        </Button>
        <NativeWaveform paused={paused} />
        <time className="text-sm tabular-nums">12:48</time>
        <Icon name="star" size={20} />
        <span
          className="grid size-8 place-items-center rounded-full bg-background text-foreground"
          aria-hidden="true"
        >
          <Icon name="check" size={16} />
        </span>
      </div>
      <span className="mt-3 text-[10px] text-muted-foreground">
        {t("錄音膠囊 · 互動示範")}
      </span>
    </div>
  );
}
