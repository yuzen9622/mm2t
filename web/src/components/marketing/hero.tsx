"use client";
import { useRef } from "react";
import Image from "next/image";
import { motion, useScroll, useSpring, useTransform } from "motion/react";
import { useMotionScene } from "@/hooks/use-motion-scene";
import { useCopy } from "@/components/i18n";
import { HeroWordmark, useIntroReady } from "@/components/brand-intro";
import { RecordingDemo } from "@/components/native-waveform";
import { Icon } from "@/components/icon";
import { DownloadButton, container, frame } from "./shared";
import { VideoButton } from "./video-dialog";
export function Hero() {
  const { t, locale, media } = useCopy();
  const ready = useIntroReady();
  const enabled = useMotionScene();
  const hero = useRef<HTMLElement>(null);
  const { scrollYProgress } = useScroll({
    target: hero,
    offset: ["start start", "end start"],
  });
  const progress = useSpring(scrollYProgress, { stiffness: 110, damping: 28 });
  const y = useTransform(progress, [0, 1], [0, 150]);
  const rotateX = useTransform(progress, [0, 1], [0, 16]);
  const rotateZ = useTransform(progress, [0, 1], [0, -7]);
  const scale = useTransform(progress, [0, 1], [1, 0.86]);
  return (
    <section
      ref={hero}
      className="relative z-55 flex min-h-svh flex-col overflow-clip pt-32 pb-8 md:pt-40 xl:min-h-[800px]"
      aria-labelledby="hero-title"
    >
      <div
        className={`${container} grid flex-1 items-center gap-12 pb-14 perspective-[1400px] lg:grid-cols-[.8fr_1.2fr] lg:gap-10`}
      >
        <div className="relative z-1">
          <HeroWordmark />
          <motion.div
            data-intro-content=""
            initial={false}
            animate={{ opacity: ready ? 1 : 0, y: ready ? 0 : 22 }}
            transition={{ delay: 0.3, duration: 0.8, ease: [0.22, 1, 0.36, 1] }}
          >
            <div className="mb-6 flex items-center gap-3 text-[10px] tracking-wider text-muted-foreground md:text-xs">
              <span className="size-1.5 rounded-full bg-primary ring-4 ring-primary/10" />
              {t("為 macOS 而生的開源工具")}
            </div>
            <h1
              id="hero-title"
              className="text-[clamp(43px,5.1vw,78px)] leading-[1.15] font-medium tracking-[-.065em]"
            >
              {locale === "en" ? (
                <>
                  Meeting notes.
                  <br />
                  Made for Mac<span className="text-primary">.</span>
                </>
              ) : (
                <>
                  {t("Mac 上的")}
                  <br className="hidden md:block" />
                  {t("會議記錄，")}
                  <br />
                  <span className="whitespace-nowrap">
                    {t("交給")} mm2t<span className="text-primary">。</span>
                  </span>
                </>
              )}
            </h1>
            <p className="my-7 max-w-md text-base leading-8 text-muted-foreground md:text-lg">
              {t("開會時專心說話。")}
              <br />
              {t("從錄音、辨識說話者，到逐字稿與摘要，")}
              {t("mm2t 替你接著整理。")}
            </p>
            <div className="flex flex-wrap items-center gap-2">
              <DownloadButton />
              <VideoButton />
            </div>
            <p className="mt-5 flex items-center gap-3 text-xs text-muted-foreground">
              {t("免費開放原始碼")}
              <span>·</span>
              {t("macOS 14.2 以上")}
            </p>
          </motion.div>
        </div>
        <motion.div
          data-intro-content=""
          initial={false}
          animate={{ opacity: ready ? 1 : 0 }}
          transition={{ delay: 0.45, duration: 0.8 }}
          className="mx-auto w-full max-w-[850px] min-w-0 origin-[center_35%]"
          style={enabled ? { y, rotateX, rotateZ, scale } : undefined}
        >
          <RecordingDemo />
          <div className={frame}>
            <Image
              src={media("app/transcript.webp")}
              width={1600}
              height={941}
              alt={t("mm2t 會議逐字稿介面預覽，顯示不同說話者與時間戳記")}
              sizes="(max-width: 1023px) 90vw, 60vw"
              priority
              className="h-auto w-full"
            />
          </div>
        </motion.div>
      </div>
      <div
        className={`${container} flex flex-wrap items-center gap-5 text-xs text-muted-foreground md:gap-8`}
      >
        <span>{t("融入你習慣的會議")}</span>
        <div className="flex w-full justify-between gap-3 font-medium md:w-auto md:gap-7">
          <span>Google Meet</span>
          <span>Microsoft Teams</span>
          <span>Zoom</span>
          <span>Webex</span>
        </div>
        <a
          href="#experience"
          className="ml-auto hidden min-h-11 items-center gap-3 lg:flex"
          aria-label={t("向下查看使用體驗")}
        >
          {t("往下看看")}
          <Icon name="arrow" size={17} />
        </a>
      </div>
    </section>
  );
}
