"use client";
import Image from "next/image";
import { Icon } from "@/components/icon";
import { useCopy } from "@/components/i18n";
import { cn } from "@/lib/utils";

export const REPO = "https://github.com/yuzen9622/mm2t";
export const DOWNLOAD = `${REPO}/releases/latest`;
/** One content edge for the header, every section and the footer: 80px gutters at 1440. */
export const wrap =
  "wrap relative z-1 mx-auto w-[min(100%_-_48px,1280px)] md:w-[min(100%_-_96px,1280px)] xl:w-[min(100%_-_160px,1280px)]";
/** One or two screens a section, the h2 120px under the section top (96 on a phone). */
export const screen =
  "relative min-h-svh pt-24 pb-12 lg:h-svh lg:min-h-0 lg:pt-[120px] lg:pb-[72px]";
export const h2 =
  "text-[30px] leading-[1.2] font-medium tracking-[-0.02em] lg:text-[48px] lg:leading-[1.12]";
export const lead = "text-base leading-[1.65] text-muted-foreground lg:text-lg";

export function Brand({ tone = "ink" }: { tone?: "ink" | "stage" }) {
  const { t } = useCopy();
  return (
    <a
      className={cn(
        "inline-flex min-h-11 items-center gap-2.5 text-[20px] font-semibold tracking-[-0.03em]",
        tone === "stage" ? "text-stage-ink" : "text-foreground",
      )}
      href="#top"
      aria-label={t("mm2t 首頁")}
    >
      <Image src="/media/icon.png" width={28} height={28} alt="" className="rounded-[7px]" />
      mm2t
    </a>
  );
}

export function DownloadButton({
  className,
  size = "md",
}: {
  className?: string;
  size?: "md" | "lg";
}) {
  const { t } = useCopy();
  return (
    <a
      href={DOWNLOAD}
      target="_blank"
      rel="noreferrer"
      className={cn(
        "btn inline-flex items-center justify-center gap-2 rounded-full bg-primary font-medium text-primary-foreground hover:bg-[#d9660e]",
        size === "lg" ? "min-h-12 px-6 text-base" : "min-h-11 px-5 text-sm",
        className,
      )}
    >
      <Icon name="download" size={size === "lg" ? 18 : 16} />
      {t("下載 mm2t")}
    </a>
  );
}
