"use client";
import { useRef, useState } from "react";
import Image from "next/image";
import { motion, useScroll, useMotionValueEvent } from "motion/react";
import { useMotionScene } from "@/hooks/use-motion-scene";
import { useCopy } from "@/components/i18n";
import { cn } from "@/lib/utils";
import { container, heading, sectionPadding } from "./shared";
const chapters = [
  {
    title: "會議開始，輕按一下。",
    text: "偵測到會議時，選單列的小膠囊會詢問是否錄音。直接擷取 Mac 音訊，不需要 Bot 加入。",
    image: "recording.webp",
    alt: "mm2t 偵測到 Zoom 會議，顯示錄音膠囊",
  },
  {
    title: "叫得出名字的逐字稿。",
    text: "麥克風與遠端聲音分軌錄製，再於 Mac 上辨識說話者。命名一次，下次自動套用聲紋。",
    image: "speakers.webp",
    alt: "mm2t 逐字稿中的說話者姓名與時間戳記",
  },
  {
    title: "會議結束，接著整理。",
    text: "討論重點、決議與待辦整理成摘要，附上時間點，方便回到當時的對話。",
    image: "summary.webp",
    alt: "mm2t 自動整理的會議摘要",
  },
];
export function Experience() {
  const { t, media } = useCopy();
  const section = useRef<HTMLElement>(null);
  const enabled = useMotionScene(1024, 720);
  const [active, setActive] = useState(0);
  // 4.6H total - 1H sticky viewport = 3.6H of travel = 1.2H per chapter.
  const { scrollYProgress } = useScroll({
    target: section,
    offset: ["start start", "end end"],
  });
  useMotionValueEvent(scrollYProgress, "change", (p) =>
    setActive(Math.min(2, Math.floor(Math.max(0, p) * 3))),
  );
  return (
    <section
      ref={section}
      id="experience"
      data-scroll-chapters=""
      aria-labelledby="experience-title"
      className={cn("bg-secondary", enabled ? "h-[460svh]" : sectionPadding)}
    >
      <div
        className={cn(
          container,
          enabled
            ? "sticky top-0 grid h-svh grid-cols-2 items-center gap-14 pt-24"
            : "grid gap-12",
        )}
      >
        <div>
          <h2 id="experience-title" className={heading}>
            {t("會議在進行。")}
            <br />
            <span className="text-muted-foreground">
              {t("紀錄，也跟得上。")}
            </span>
          </h2>
          <ol className={cn("mt-12 grid", enabled ? "gap-7" : "gap-12")}>
            {chapters.map((chapter, i) => (
              <li
                key={chapter.image}
                className={cn(
                  !enabled &&
                    "grid items-center gap-5 md:grid-cols-2 md:gap-x-12",
                )}
              >
                <div>
                  <h3
                    className={cn(
                      "flex items-center gap-4 text-lg leading-8 font-medium transition-colors duration-500",
                      enabled && active !== i && "text-muted-foreground",
                    )}
                  >
                    <span
                      className={cn(
                        "text-xs",
                        active === i ? "text-primary" : "text-muted-foreground",
                      )}
                    >
                      0{i + 1}
                    </span>
                    {t(chapter.title)}
                  </h3>
                  <motion.div
                    initial={false}
                    animate={{
                      height: !enabled || active === i ? "auto" : 0,
                      opacity: !enabled || active === i ? 1 : 0,
                    }}
                    transition={{ duration: 0.45, ease: [0.22, 1, 0.36, 1] }}
                    className="overflow-hidden"
                  >
                    <p className="mt-3 max-w-[38ch] text-sm leading-8 text-muted-foreground lg:ml-9">
                      {t(chapter.text)}
                    </p>
                  </motion.div>
                </div>
                {!enabled && (
                  <Image
                    src={media(chapter.image)}
                    alt={t(chapter.alt)}
                    width={1400}
                    height={900}
                    className="h-auto w-full rounded-2xl"
                    sizes="(max-width: 767px) 90vw, 50vw"
                  />
                )}
              </li>
            ))}
          </ol>
        </div>
        {enabled && (
          <div className="relative aspect-[1.1] max-h-[70svh] overflow-hidden rounded-3xl bg-background">
            {chapters.map((chapter, i) => (
              <motion.div
                key={chapter.image}
                initial={false}
                animate={{
                  opacity: active === i ? 1 : 0,
                  scale: active === i ? 1 : 1.025,
                }}
                transition={{ duration: 0.65, ease: [0.22, 1, 0.36, 1] }}
                className="absolute inset-0"
                aria-hidden={active !== i}
              >
                <Image
                  src={media(chapter.image)}
                  alt={t(chapter.alt)}
                  width={1400}
                  height={900}
                  className="size-full object-contain"
                  sizes="50vw"
                />
              </motion.div>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}
