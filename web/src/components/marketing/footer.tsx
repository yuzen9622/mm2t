"use client";
import Image from "next/image";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import {
  Reveal,
  Brand,
  DownloadButton,
  REPO,
  container,
  heading,
  textLink,
} from "./shared";
export function Footer() {
  const { t } = useCopy();
  return (
    <footer id="download" className="bg-secondary pt-24 pb-8 md:pt-32">
      <div className={container}>
        <Reveal className="flex flex-col items-center pb-24 text-center">
          <Image
            src="/media/icon.png"
            width={88}
            height={88}
            alt={t("mm2t 應用程式圖示")}
            className="mb-9 rounded-3xl"
          />
          <h2 className={`${heading} max-w-4xl`}>{t("把注意力留給對話。")}</h2>
          <p className="mt-5 mb-8 text-sm leading-7 text-muted-foreground">
            {t("打開 mm2t，開始你的第一份會議記錄。")}
          </p>
          <DownloadButton />
          <span className="mt-5 text-xs text-muted-foreground">
            {t("macOS 14.2 以上 · 免費開放原始碼")}
          </span>
        </Reveal>
        <div className="flex flex-wrap items-center justify-between gap-5 border-b border-border pb-7">
          <Brand />
          <p className="hidden text-sm text-muted-foreground md:block">
            {t("為每一場值得記下的對話。")}
          </p>
          <a href={REPO} className={textLink} target="_blank" rel="noreferrer">
            <Icon name="github" size={18} />
            {t("在 GitHub 給顆星")}
            <Icon name="diagonal" size={15} />
          </a>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-4 pt-6 text-xs text-muted-foreground">
          <span>© {new Date().getFullYear()} mm2t · AGPL-3.0</span>
          <div className="flex flex-wrap gap-5">
            <a
              href={`${REPO}/blob/main/PRIVACY.md`}
              target="_blank"
              rel="noreferrer"
              className="hover:underline"
            >
              {t("隱私權政策")}
            </a>
            <a
              href={`${REPO}/blob/main/TERMS.md`}
              target="_blank"
              rel="noreferrer"
              className="hover:underline"
            >
              {t("使用條款")}
            </a>
            <a
              href={`${REPO}/releases`}
              target="_blank"
              rel="noreferrer"
              className="hover:underline"
            >
              {t("版本紀錄")}
            </a>
          </div>
          <span>Made for macOS.</span>
        </div>
      </div>
    </footer>
  );
}
