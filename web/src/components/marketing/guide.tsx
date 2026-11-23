"use client";
import type { ReactNode } from "react";
import { LanguageProvider, useCopy } from "@/components/i18n";
import { guidePages, type GuidePage } from "@/lib/guide";
import type { Locale } from "@/lib/messages";
import { cn } from "@/lib/utils";
import { Header } from "./header";
import { CompactFooter } from "./footer-links";
import { wrap } from "./shared";

export function Guide({ locale, page, children }: { locale: Locale; page: GuidePage; children: ReactNode }) {
  return (
    <LanguageProvider locale={locale}>
      <Header page={page} />
      <main id="main">
        <GuideIntro page={page} />
        {children}
      </main>
      <CompactFooter />
    </LanguageProvider>
  );
}

function GuideIntro({ page }: { page: GuidePage }) {
  const { t } = useCopy();
  return (
    <div data-enter="" className={cn(wrap, "grid items-end gap-x-12 gap-y-4 pt-24 pb-8 md:pt-30 md:pb-11", page === "pricing" && "md:grid-cols-2")}>
      <h1 className="enter text-[clamp(2.6rem,5.4vw,5rem)] leading-[1.06] font-medium tracking-[-0.05em]">
        {t(guidePages[page].label)}
      </h1>
      {page === "pricing" && (
        <p className="max-w-[38em] text-base leading-relaxed text-muted-foreground md:justify-self-end">
          {t("Free 幫你在會後查回誰說了什麼。Standard 和 Pro 讓你開會時就能看字幕與翻譯，會後也能不限次數用 AI 提問或改寫。")}
        </p>
      )}
    </div>
  );
}
