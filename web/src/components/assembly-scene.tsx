"use client";
import { useRef, useState } from "react";
import Image from "next/image";
import { motion, useScroll, useTransform } from "motion/react";
import { useMotionScene } from "@/hooks/use-motion-scene";
import { useCopy } from "./i18n";
import { NativeWaveform } from "./native-waveform";
import { Icon } from "./icon";
import { Button } from "./ui/button";
import { cn } from "@/lib/utils";
import { frame, heading, label } from "./marketing/shared";
export function AssemblyScene() {
  const { t, media } = useCopy();
  const section = useRef<HTMLElement>(null);
  const enabled = useMotionScene();
  const [paused, setPaused] = useState(false);
  const { scrollYProgress: p } = useScroll({
    target: section,
    offset: ["start start", "end end"],
  });
  const waveScale = useTransform(p, [0, 0.35, 0.55], [1, 0.6, 0.15]);
  const waveOpacity = useTransform(p, [0.28, 0.48], [1, 0]);
  const imageOpacity = useTransform(p, [0.3, 0.55], [0, 1]);
  const imageY = useTransform(p, [0.3, 0.7], [180, 0]);
  const imageScale = useTransform(p, [0.3, 0.8], [0.7, 1]);
  const rotateX = useTransform(p, [0.3, 0.8], [18, 0]);
  return (
    <section
      ref={section}
      data-product-scene="signal-to-notes"
      aria-labelledby="signal-title"
      className={cn(
        "relative bg-[#1b1b1d] text-background",
        enabled && "h-[300svh]",
      )}
    >
      <div
        className={cn(
          "flex flex-col items-center justify-center gap-8 overflow-clip px-6 md:px-12",
          enabled ? "sticky top-0 h-svh pt-28 pb-7" : "py-24",
        )}
      >
        <div className="text-center">
          <span className={`${label} text-[#e7a06b]`}>
            {t("從第一句，到下一步")}
          </span>
          <h2 id="signal-title" className={heading}>
            {t("聲音，成為清楚的下一步。")}
          </h2>
        </div>
        <div
          className={cn(
            "w-full max-w-[1040px] perspective-[1400px]",
            enabled
              ? "grid min-h-0 flex-1 place-items-center"
              : "flex flex-col items-center gap-12",
          )}
        >
          <motion.div
            className={cn(
              "flex w-full flex-col items-center justify-center",
              enabled ? "col-start-1 row-start-1 gap-16" : "gap-6",
            )}
            style={
              enabled ? { scale: waveScale, opacity: waveOpacity } : undefined
            }
          >
            <NativeWaveform
              paused={paused}
              className={enabled ? "my-16 scale-600" : "my-6 scale-200"}
            />
            <p className="text-sm text-background/60">
              {t("每一句話，都有了位置。")}
            </p>
          </motion.div>
          <motion.div
            className={cn(
              frame,
              enabled
                ? "col-start-1 row-start-1 w-[min(100%,calc((100svh-290px)*1.7))]"
                : "w-full",
            )}
            style={
              enabled
                ? {
                    opacity: imageOpacity,
                    y: imageY,
                    scale: imageScale,
                    rotateX,
                  }
                : undefined
            }
          >
            <Image
              src={media("app/summary.webp")}
              alt={t("mm2t 自動整理的會議摘要")}
              width={1600}
              height={941}
              sizes="(max-width: 767px) 100vw, 80vw"
              className="h-auto w-full"
            />
          </motion.div>
        </div>
        <div className="flex w-full max-w-[1040px] items-center justify-between gap-4 text-background/60">
          <Button
            type="button"
            variant="link"
            size="sm"
            className="px-0 text-xs"
            onClick={() => setPaused((v) => !v)}
            aria-pressed={paused}
          >
            {t(paused ? "播放波形動畫" : "暫停波形動畫")}
            <Icon name={paused ? "play" : "pause"} size={16} />
          </Button>
          <Button asChild variant="link" size="sm" className="px-0 text-xs">
            <a href="#privacy">
              {t("繼續探索")}
              <Icon name="arrow" size={17} />
            </a>
          </Button>
        </div>
      </div>
    </section>
  );
}
