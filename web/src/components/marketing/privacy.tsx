"use client";
import { useRef } from "react";
import { useMotionValueEvent, useScroll } from "motion/react";
import { useCopy } from "@/components/i18n";
import { Icon, type IconName } from "@/components/icon";
import { karaokeText } from "@/components/app-ui";
import { cn } from "@/lib/utils";
import { REPO, screen, wrap } from "./shared";

const facts: { icon: IconName; text: string }[] = [
  { icon: "key", text: "API 金鑰存在 macOS 鑰匙圈" },
  { icon: "shield", text: "聲紋辨識在 Mac 本機完成" },
  { icon: "video", text: "不錄螢幕，視窗也不會出現在螢幕分享" },
];

/**
 * The dealt moment (word-highlight): the statement is read out in the App's karaoke as it crosses
 * the middle of the screen, and runs back on the way up. Reduced motion shows it all in ink.
 */
export function Privacy() {
  const { t, locale } = useCopy();
  const text = useRef<HTMLHeadingElement>(null);
  const { scrollYProgress } = useScroll({ target: text, offset: ["start 0.85", "end 0.45"] });
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
      id="privacy"
      data-moment="word-highlight"
      data-moment-mounted=""
      aria-labelledby="privacy-title"
      className={screen}
    >
      <div className={cn(wrap, "flex h-full flex-col")}>
        <h2
          id="privacy-title"
          ref={text}
          className="max-w-[24em] text-[28px] leading-[1.35] font-medium tracking-[-0.02em] [--faint:0.5] lg:text-[48px] lg:leading-[1.25]"
        >
          {before.nodes}
          {locale === "en" ? " " : ""}
          <span className="kc-accent">{accent.nodes}</span>
          {after.nodes}
        </h2>
        <div className="mt-12 grid gap-6 lg:mt-16">
          <ul className="grid gap-4 sm:grid-cols-3">
            {facts.map((fact) => (
              <li key={fact.icon} className="flex items-start gap-3 text-[15px] leading-[1.5]">
                <Icon name={fact.icon} size={18} className="mt-0.5 text-muted-foreground" />
                {t(fact.text)}
              </li>
            ))}
          </ul>
          <a
            className="link-draw inline-flex min-h-11 items-center gap-2 justify-self-start text-[15px] font-medium"
            href={`${REPO}/blob/main/PRIVACY.md`}
            target="_blank"
            rel="noreferrer"
          >
            {t("閱讀隱私權政策")}
            <Icon name="diagonal" size={15} />
          </a>
        </div>
      </div>
    </section>
  );
}
