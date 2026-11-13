"use client";
import type { ReactNode } from "react";
import Image from "next/image";
import { motion, useReducedMotion } from "motion/react";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/icon";
import { useCopy } from "@/components/i18n";
import { cn } from "@/lib/utils";

export const REPO = "https://github.com/yuzen9622/mm2t";
export const DOWNLOAD = `${REPO}/releases/latest`;
export const container =
  "mx-auto w-[calc(100%-3rem)] max-w-7xl md:w-[calc(100%-6rem)] xl:w-[calc(100%-8rem)]";
export const sectionPadding = "py-20 md:py-28 xl:py-32";
export const heading =
  "text-[clamp(2.1rem,3.5vw,3.2rem)] leading-[1.3] font-medium tracking-[-.055em]";
export const label =
  "mb-6 block text-xs font-medium tracking-[.09em] text-[#925021]";
export const frame =
  "overflow-hidden rounded-xl bg-background shadow-[0_24px_65px_-28px_#30282038] ring-1 ring-foreground/5 md:rounded-2xl";
export const textLink =
  "inline-flex min-h-11 items-center gap-4 text-sm font-medium decoration-1 underline-offset-8 transition-colors hover:text-primary hover:underline";

export function Reveal({
  children,
  className,
  delay = 0,
}: {
  children: ReactNode;
  className?: string;
  delay?: number;
}) {
  const reduced = useReducedMotion();
  return (
    <motion.div
      data-reveal=""
      className={className}
      initial={reduced ? false : { opacity: 0, y: 24 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.12 }}
      transition={{
        duration: reduced ? 0 : 0.8,
        ease: [0.22, 1, 0.36, 1],
        delay,
      }}
    >
      {children}
    </motion.div>
  );
}
export function Brand() {
  const { t } = useCopy();
  return (
    <a
      className="inline-flex min-h-11 items-center gap-2"
      href="#top"
      aria-label={t("mm2t 首頁")}
    >
      <Image
        src="/media/icon.png"
        width={38}
        height={38}
        alt=""
        className="rounded-xl"
      />
      <span className="text-[26px] font-semibold tracking-[-.06em]">
        mm2t<span className="text-primary">.</span>
      </span>
    </a>
  );
}
export function DownloadButton({ className }: { className?: string }) {
  const { t } = useCopy();
  return (
    <Button asChild className={cn("gap-5 py-2 pr-2 pl-6", className)}>
      <a href={DOWNLOAD} target="_blank" rel="noreferrer">
        {t("下載 mm2t")}
        <span className="grid size-9 place-items-center rounded-full bg-black/10">
          <Icon name="diagonal" size={17} />
        </span>
      </a>
    </Button>
  );
}
