"use client";
import { useLayoutEffect, useRef, useState } from "react";
import {
  motion,
  useMotionValueEvent,
  useScroll,
  useTransform,
  type MotionValue,
} from "motion/react";
import { useMotionScene } from "@/hooks/use-motion-scene";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import { NativeWaveform } from "@/components/native-waveform";
import { AppWindow, MeetingHeader, SpeakerPanel, StaticTabs, TranscriptRows } from "@/components/app-ui";
import { transcript } from "@/lib/meeting";
import { cn } from "@/lib/utils";
import { h2, wrap } from "./shared";

const steps = [
  {
    at: "00:00:00",
    title: "偵測到會議，一按就錄",
    text: "Google Meet、Teams、Zoom 或 Webex 開始時，選單列的膠囊會問你要不要錄音。",
  },
  {
    at: "00:00:07",
    title: "分出每位說話者",
    text: "麥克風與遠端聲音分兩軌錄，在 Mac 上辨識說話者。命名一次，下次自動套用聲紋。",
  },
  {
    at: "00:20:00",
    title: "整理成逐字稿",
    text: "每句話附上說話者與時間，點一下就從那裡重播。",
  },
];

/*
 * The scroll story (4 screens live, 1 at rest), in three beats on one held stage:
 *   0.00-0.20  the recording capsule grows until it is the whole dark stage
 *   0.28-0.68  the transcript, seen at 2x, is read out in the App's karaoke and its speakers named
 *   0.72-0.92  the camera pulls back: the text was inside the mm2t window all along
 */
const FLOOD = [0, 0.2] as const;
const READ = [0.28, 0.68] as const;
const PULL = [0.72, 0.92] as const;
const ZOOM = 2;

const ease = (x: number) => 1 - Math.pow(1 - Math.min(1, Math.max(0, x)), 3);
const span = (p: number, [a, b]: readonly [number, number]) => ease((p - a) / (b - a));

type Box = { left: number; top: number; width: number; height: number; stageW: number; stageH: number };

export function FlowScene() {
  const live = useMotionScene(1024, 700);
  const section = useRef<HTMLElement>(null);
  const { scrollYProgress: p } = useScroll({ target: section, offset: ["start start", "end end"] });
  return (
    <section
      ref={section}
      id="flow"
      data-big-scene="powers-of-ten-pullback"
      data-big-scene-opts='{"hold": 3}'
      data-product-scene="signal-to-notes"
      data-ground={live ? undefined : "stage"}
      aria-labelledby="flow-title"
      className={cn(live ? "relative h-[400svh] bg-background" : "relative bg-stage text-stage-ink")}
    >
      {live ? (
        <Stage p={p} />
      ) : (
        <div className={cn(wrap, "grid gap-10 pt-24 pb-12 lg:h-svh lg:grid-cols-12 lg:gap-6 lg:pt-[120px] lg:pb-[72px]")}>
          <Rail active={-1} />
          <div className="min-h-0 lg:col-span-8 lg:col-start-5">
            <AppWindow theme="dark" className="h-[520px] lg:h-full">
              <MeetingHeader tabs={<StaticTabs active="整理版逐字稿" />} />
              <div className="flex gap-4 px-5 pt-5">
                <div className="kc-done min-w-0 flex-1">
                  <TranscriptRows mode="clean" karaoke />
                </div>
                <SpeakerPanel />
              </div>
            </AppWindow>
          </div>
        </div>
      )}
    </section>
  );
}

function Rail({ active }: { active: number }) {
  const { t } = useCopy();
  return (
    <div className="lg:col-span-4">
      <h2 id="flow-title" className={h2}>
        {t("錄下會議，")}
        <br />
        {t("標出每位說話者")}
      </h2>
      <ol className="mt-10 grid gap-7 lg:mt-12">
        {steps.map((step, i) => (
          <li
            key={step.at}
            className="text-stage-ink"
          >
            <p className="flex items-center gap-2 font-mono text-[13px] text-stage-muted tabular-nums">
              <span
                aria-hidden="true"
                className={cn(
                  "size-1.5 rounded-full",
                  active === i || active < 0 ? "bg-primary" : "bg-stage-muted",
                )}
              />
              {step.at}
            </p>
            <h3 className="mt-2 text-xl leading-[1.4] font-medium">{t(step.title)}</h3>
            <p className="mt-1.5 max-w-[34ch] text-[15px] leading-[1.65] text-stage-muted">{t(step.text)}</p>
          </li>
        ))}
      </ol>
    </div>
  );
}

function Stage({ p }: { p: MotionValue<number> }) {
  const { locale, t } = useCopy();
  const stage = useRef<HTMLDivElement>(null);
  const target = useRef<HTMLDivElement>(null);
  const rows = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState<Box | null>(null);
  const [active, setActive] = useState(0);
  const [named, setNamed] = useState([false, false, false, false]);

  // The window's resting rect, measured from a ghost on the grid, drives every px value below.
  useLayoutEffect(() => {
    const measure = () => {
      const s = stage.current?.getBoundingClientRect();
      const r = target.current?.getBoundingClientRect();
      if (!s || !r) return;
      setBox({ left: r.left - s.left, top: r.top - s.top, width: r.width, height: r.height, stageW: s.width, stageH: s.height });
    };
    measure();
    const observer = new ResizeObserver(measure);
    if (stage.current) observer.observe(stage.current);
    return () => observer.disconnect();
  }, []);

  // Where each spoken line starts, counted in karaoke units (characters, or words in English).
  const starts: number[] = [];
  let total = 0;
  for (const line of transcript.slice(0, 3)) {
    starts.push(total);
    const text = t(line.clean);
    total += locale === "en" ? text.split(/\s+/).filter(Boolean).length : Array.from(text).length;
  }

  useMotionValueEvent(p, "change", (v) => {
    const k = span(v, READ) * total;
    rows.current?.style.setProperty("--k", k.toFixed(2));
    const step = v < READ[0] ? 0 : v < PULL[0] ? 1 : 2;
    setActive((prev) => (prev === step ? prev : step));
    setNamed((prev) => {
      const next = [0, 1, 2, 3].map((i) => i < 3 && k > starts[i] + 0.5);
      return next.every((x, i) => x === prev[i]) ? prev : next;
    });
    const dark = span(v, FLOOD) > 0.6;
    const el = stage.current?.parentElement;
    if (el && el.hasAttribute("data-ground") !== dark) {
      if (dark) el.setAttribute("data-ground", "stage");
      else el.removeAttribute("data-ground");
      dispatchEvent(new Event("mm2t:ground"));
    }
  });

  const flood = useTransform(p, (v) => span(v, FLOOD));
  const floodClip = useTransform(flood, (f) => {
    const r = 1 - f;
    return `inset(calc((50% - 44px) * ${r}) calc((50% - 190px) * ${r}) round ${44 * r}px)`;
  });
  const capsuleScale = useTransform(flood, [0, 1], [1, 2.4]);
  const capsuleOpacity = useTransform(p, [0.17, 0.25], [1, 0]);
  const capsuleY = useTransform(p, [0.17, 0.27], [0, -40]);
  const headingColor = useTransform(flood, [0.55, 0.85], ["#1c1c1e", "#f5f5f7"]);
  const railOpacity = useTransform(p, [0.18, 0.26], [0, 1]);
  const windowOpacity = useTransform(p, [0.2, 0.28], [0, 1]);
  const seconds = useTransform(p, [0, 0.2], [0, 7]);
  const clock = useTransform(seconds, (s) => `00:${String(Math.floor(s)).padStart(2, "0")}`);

  const pull = useTransform(p, (v) => span(v, PULL));
  // Zoom origin chosen so the left edge of the visible region lands just right of the sidebar.
  const originX = box ? (ZOOM * 176) / (ZOOM - 1) : 0;
  const originY = 150;
  const scale = useTransform(pull, (f) => ZOOM + (1 - ZOOM) * f);
  const windowClip = useTransform(pull, (f) => {
    if (!box) return "none";
    const top = box.top * f;
    const bottom = (box.stageH - box.top - box.height) * f;
    const right = (box.stageW - box.left - box.width) * f;
    return `inset(${top}px ${right}px ${bottom}px ${box.left}px round ${14 * f}px)`;
  });

  return (
    <div ref={stage} className="sticky top-0 h-svh overflow-hidden">
      <motion.div aria-hidden="true" className="absolute inset-0 bg-stage" style={{ clipPath: floodClip }} />
      <motion.div
        aria-hidden="true"
        className="absolute top-1/2 left-1/2 flex h-[88px] w-[380px] -translate-x-1/2 -translate-y-1/2 items-center gap-5 px-5 text-white"
        style={{ scale: capsuleScale, opacity: capsuleOpacity, y: capsuleY }}
      >
        <span className="grid size-12 place-items-center rounded-full bg-white/15">
          <Icon name="mic" size={20} />
        </span>
        <NativeWaveform className="scale-150" />
        <motion.span className="ml-4 font-mono text-xl tabular-nums">{clock}</motion.span>
        <Icon name="star" size={22} className="ml-auto" />
      </motion.div>

      <div className={cn(wrap, "grid h-full grid-cols-12 gap-6 pt-[120px] pb-[72px]")}>
        <div className="col-span-4 text-stage-ink">
          <RailLive active={active} headingColor={headingColor} railOpacity={railOpacity} />
        </div>
        <div ref={target} className="col-span-8 col-start-5" aria-hidden="true" />
      </div>

      {box && (
        <motion.div
          className="absolute inset-0"
          style={{ clipPath: windowClip, opacity: windowOpacity }}
          aria-hidden="true"
        >
          <motion.div
            className="absolute"
            style={{
              left: box.left,
              top: box.top,
              width: box.width,
              height: box.height,
              scale,
              transformOrigin: `${originX}px ${originY}px`,
            }}
          >
            <AppWindow theme="dark" className="h-full w-full shadow-none!">
              <MeetingHeader tabs={<StaticTabs active="整理版逐字稿" />} />
              <div className="flex gap-4 px-5 pt-5">
                <div ref={rows} className="min-w-0 flex-1">
                  <TranscriptRows mode="clean" karaoke named={named} />
                </div>
                <SpeakerPanel named={named} />
              </div>
            </AppWindow>
          </motion.div>
        </motion.div>
      )}
    </div>
  );
}

function RailLive({
  active,
  headingColor,
  railOpacity,
}: {
  active: number;
  headingColor: MotionValue<string>;
  railOpacity: MotionValue<number>;
}) {
  const { t } = useCopy();
  return (
    <div>
      <motion.h2 id="flow-title" className={h2} style={{ color: headingColor }}>
        {t("錄下會議，")}
        <br />
        {t("標出每位說話者")}
      </motion.h2>
      <motion.ol className="mt-12 grid gap-7" style={{ opacity: railOpacity }}>
        {steps.map((step, i) => (
          <li
            key={step.at}
            className={active === i ? "text-stage-ink" : "text-stage-muted"}
          >
            <p className="flex items-center gap-2 font-mono text-[13px] text-stage-muted tabular-nums">
              <span
                aria-hidden="true"
                className={cn("size-1.5 rounded-full", active === i ? "bg-primary" : "bg-stage-muted")}
              />
              {step.at}
            </p>
            <h3 className="mt-2 text-xl leading-[1.4] font-medium">{t(step.title)}</h3>
            <p className="mt-1.5 max-w-[34ch] text-[15px] leading-[1.65] text-stage-muted">{t(step.text)}</p>
          </li>
        ))}
      </motion.ol>
    </div>
  );
}
