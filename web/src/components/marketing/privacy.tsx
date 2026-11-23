"use client";
import { useRef } from "react";
import { motion, useMotionValueEvent, useReducedMotion, useScroll, useTransform } from "motion/react";
import { useCopy } from "@/components/i18n";
import { karaokeText } from "@/components/app-ui";
import { cn } from "@/lib/utils";
import { wrap } from "./shared";

/**
 * The dealt moment (word-highlight): the statement is read out in the App's karaoke as it crosses
 * the middle of the screen, and runs back on the way up. Track the section so the text's scale
 * never changes the scroll range. Reduced motion shows it all in ink at its final size.
 */
export function Privacy() {
  const { t, locale } = useCopy();
  const section = useRef<HTMLElement>(null);
  const text = useRef<HTMLHeadingElement>(null);
  const reducedMotion = useReducedMotion();
  const { scrollYProgress } = useScroll({ target: section, offset: ["start 0.9", "start 0.12"] });
  const scale = useTransform(scrollYProgress, [0, 0.85, 1], [0.94, 1, 1]);
  const before = karaokeText(t("錄音、聲紋和會議紀錄都存在"), 0, locale);
  const accent = karaokeText(t("這台 Mac"), before.end, locale);
  const after = karaokeText(
    t("。選用雲端轉錄時，音訊會送到服務商；選用雲端摘要時，則會送出逐字稿。"),
    accent.end,
    locale,
  );
  useMotionValueEvent(scrollYProgress, "change", (v) => {
    text.current?.style.setProperty("--k", (v * (after.end + 1)).toFixed(2));
  });
  return (
    <section
      ref={section}
      id="privacy"
      data-moment="word-highlight"
      data-moment-mounted=""
      aria-labelledby="privacy-title"
      className="relative flex min-h-svh items-center py-24"
    >
      <div className={cn(wrap, "flex flex-col items-center")}>
        <motion.h2
          id="privacy-title"
          ref={text}
          style={{ scale: reducedMotion ? 1 : scale }}
          className="max-w-[24em] text-center text-[28px] leading-[1.35] font-medium tracking-[-0.02em] [--faint:0.5] md:text-[40px] lg:text-[48px] xl:text-[56px] lg:leading-[1.25]"
        >
          {before.nodes}
          {locale === "en" ? " " : ""}
          <span className="kc-accent">{accent.nodes}</span>
          {after.nodes}
        </motion.h2>
      </div>
    </section>
  );
}
