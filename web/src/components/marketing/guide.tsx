"use client";
import { LanguageProvider, useCopy } from "@/components/i18n";
import { guidePages, sitePath, type GuidePage } from "@/lib/guide";
import type { Locale } from "@/lib/messages";
import { cn } from "@/lib/utils";
import { Header } from "./header";
import { Brand, wrap } from "./shared";
import { ModelGuide } from "./models";
import { Pricing } from "./pricing";

export function Guide({ locale, page }: { locale: Locale; page: GuidePage }) {
  return (
    <LanguageProvider locale={locale}>
      <Header page={page} />
      <main id="main">
        <GuideIntro page={page} />
        {page === "pricing" ? <Pricing /> : <ModelGuide />}
      </main>
      <footer className={cn(wrap, "flex items-center justify-between gap-4 border-t border-border py-6")}>
        <Brand />
        <span className="text-xs text-muted-foreground">mm2t · AGPL-3.0</span>
      </footer>
    </LanguageProvider>
  );
}

function GuideIntro({ page }: { page: GuidePage }) {
  const { t, locale } = useCopy();
  return (
    <div data-enter="" className={cn(wrap, "pt-24 pb-8 md:pt-30 md:pb-11")}>
      <nav aria-label={t("產品資訊")} className="inline-flex rounded-full border border-border bg-secondary p-1">
        {(["models", "pricing"] as const).map((item) => (
          <a key={item} href={sitePath(locale, item)} aria-current={item === page ? "page" : undefined}
            className="btn inline-flex min-h-10 items-center rounded-full px-5 text-sm aria-[current=page]:bg-foreground aria-[current=page]:text-background">
            {t(guidePages[item].label)}
          </a>
        ))}
      </nav>
      <div className="mt-8 grid items-end gap-x-12 gap-y-4 md:grid-cols-2">
        <h1 className="enter text-[clamp(2.6rem,5.4vw,5rem)] leading-[1.06] font-medium tracking-[-0.05em]">
          {t(guidePages[page].label)}
        </h1>
        <p className="max-w-[38em] text-base leading-relaxed text-muted-foreground md:justify-self-end">
          {page === "pricing"
            ? t("方案預覽。每月雲端會議額度依方案而定。Standard 與 Pro 的 AI 提問與改寫次數無限。")
            : t("依會議中使用的語言，選擇跟得上對話的字幕、讀得懂的翻譯，以及適合會後整理的模型。")}
        </p>
      </div>
    </div>
  );
}
