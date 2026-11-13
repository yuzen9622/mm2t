"use client";
import { useEffect, useRef, useState } from "react";
import { useReducedMotion } from "motion/react";
import { useCopy } from "./i18n";
import { Icon } from "./icon";

/** Same 11 bars, 2.5pt width/gap, six-sample mirrored history and taper as FloatingContent.swift. */
export function NativeWaveform({ paused = false, className = "" }: { paused?: boolean; className?: string }) {
  const root = useRef<HTMLDivElement>(null);
  const reduced = useReducedMotion();
  useEffect(() => {
    const el = root.current;
    if (!el || reduced || paused) return;
    const bars = [...el.querySelectorAll<HTMLElement>("i")];
    const history = [.9, .7, .95, .6, .8, .5];
    let timer: ReturnType<typeof setInterval> | undefined;
    let tick = 0;
    let visible = false;
    function stop() { clearInterval(timer); timer = undefined; }
    function sync() {
      stop();
      if (!visible || document.hidden) return;
      timer = setInterval(() => {
        tick += 1;
        // Illustrative speech, no microphone access. New samples travel out from the center.
        const breath = Math.pow(Math.max(0, Math.sin(tick * .19)), .45);
        const syllable = .25 + .75 * Math.abs(Math.sin(tick * 1.13) * Math.cos(tick * .37));
        history.pop(); history.unshift(.08 + .92 * breath * syllable);
        bars.forEach((bar, index) => {
          const d = Math.abs(index - 5);
          bar.style.height = `${3 + 21 * history[d] * (1 - d / 6 * .75)}px`;
        });
      }, 120);
    }
    const observer = new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; sync(); });
    observer.observe(el);
    document.addEventListener("visibilitychange", sync);
    return () => { observer.disconnect(); stop(); document.removeEventListener("visibilitychange", sync); bars.forEach(bar => bar.style.removeProperty("height")); };
  }, [paused, reduced]);
  return <div ref={root} className={`native-waveform ${paused ? "is-paused" : ""} ${className}`} aria-hidden="true">{Array.from({ length: 11 }, (_, i) => {
    const d = Math.abs(i - 5);
    return <i key={i} style={{ height: paused ? 3 : 3 + 21 * [.9,.7,.95,.6,.8,.5][d] * (1 - d / 6 * .75) }} />;
  })}</div>;
}

export function RecordingDemo() {
  const { t } = useCopy();
  const [paused, setPaused] = useState(false);
  return <div className="native-recording-demo"><div className="native-capsule" aria-label={t("錄音膠囊互動示範")}>
    <NativeWaveform paused={paused} /><time>12:48</time><span className="capsule-star" aria-hidden="true">☆</span><span className="capsule-finish" aria-hidden="true"><Icon name="check" size={16} /></span>
  </div><span className="native-demo-caption">{t("錄音膠囊 · 互動示範")}</span></div>;
}
