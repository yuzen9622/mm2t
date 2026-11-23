"use client";

import { useCopy } from "@/components/i18n";
import { guidePages, policyPageKeys, policyPages, sitePath } from "@/lib/guide";
import { cn } from "@/lib/utils";
import { Brand, REPO, wrap } from "./shared";

export function FooterLinks({ tone = "ink" }: { tone?: "ink" | "stage" }) {
  const { locale, t } = useCopy();
  const onStage = tone === "stage";
  const linkClass = cn(
    "link-draw inline-flex min-h-11 items-center text-sm focus-visible:outline-2 focus-visible:outline-offset-2",
    onStage
      ? "text-stage-muted hover:text-stage-ink focus-visible:text-stage-ink"
      : "text-muted-foreground hover:text-foreground focus-visible:text-foreground",
  );

  return (
    <nav aria-label={t("頁尾連結")} className={cn("flex min-w-0 flex-wrap gap-x-5 gap-y-1", onStage && "lg:ml-6")}>
      {policyPageKeys.map((page) => (
        <a key={page} href={sitePath(locale, page)} className={linkClass}>
          {locale === "en" ? policyPages[page].en : policyPages[page].label}
        </a>
      ))}
      {onStage && (
        <>
          <a href={sitePath(locale, "changelog")} className={linkClass}>
            {t(guidePages.changelog.label)}
          </a>
          <a href={REPO} target="_blank" rel="noreferrer" className={linkClass}>
            {t("原始碼")}
          </a>
        </>
      )}
    </nav>
  );
}

export function CompactFooter() {
  return (
    <footer className={cn(wrap, "flex flex-wrap items-center gap-x-8 gap-y-2 border-t border-border py-6")}>
      <Brand />
      <FooterLinks />
      <span className="ml-auto text-xs text-muted-foreground">mm2t · AGPL-3.0</span>
    </footer>
  );
}
