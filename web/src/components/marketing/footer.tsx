"use client";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import { cn } from "@/lib/utils";
import { Brand, DownloadButton, REPO, wrap } from "./shared";

/** The close and the footer as one dark screen: the ask, then the links and the legal row. */
export function Footer() {
  const { t } = useCopy();
  const links = [
    { label: "隱私權政策", href: `${REPO}/blob/main/PRIVACY.md` },
    { label: "使用條款", href: `${REPO}/blob/main/TERMS.md` },
    { label: "版本紀錄", href: `${REPO}/releases` },
    { label: "原始碼", href: REPO },
  ];
  return (
    <footer
      id="download"
      data-ground="stage"
      className="closing relative min-h-svh bg-stage pt-24 pb-8 text-stage-ink lg:h-svh lg:min-h-0 lg:pt-[120px] lg:pb-[72px]"
    >
      <div className={cn(wrap, "flex h-full flex-col")}>
        <div>
          <h2 className="text-[38px] leading-[1.1] font-medium tracking-[-0.02em] lg:text-[96px] lg:leading-[1.02] lg:tracking-[-0.03em]">
            <span className="block">{t("下一場會議，")}</span>
            <span className="block">{t("交給 mm2t 記錄")}</span>
          </h2>
          <p className="mt-6 text-base text-stage-muted lg:text-lg">
            {t("免費開源 · macOS 14.2 以上")}
          </p>
          <div className="mt-8 flex flex-wrap items-center gap-2">
            <DownloadButton size="lg" className="max-sm:w-full" />
            <a
              href={REPO}
              target="_blank"
              rel="noreferrer"
              className="btn inline-flex min-h-12 items-center gap-2 rounded-full px-5 text-base font-medium text-stage-ink hover:bg-white/10 max-sm:w-full max-sm:justify-center"
            >
              <Icon name="github" size={18} />
              {t("在 GitHub 查看原始碼")}
            </a>
          </div>
        </div>
        <div className="mt-auto flex flex-wrap items-center gap-x-8 gap-y-2 pt-16">
          <Brand tone="stage" />
          <nav aria-label={t("頁尾連結")} className="flex flex-wrap gap-x-6 lg:ml-6">
            {links.map((link) => (
              <a
                key={link.label}
                href={link.href}
                target="_blank"
                rel="noreferrer"
                className="link-draw inline-flex min-h-11 items-center text-sm text-stage-muted hover:text-stage-ink"
              >
                {t(link.label)}
              </a>
            ))}
          </nav>
          <span className="text-sm text-stage-muted lg:ml-auto">
            © {new Date().getFullYear()} mm2t · AGPL-3.0
          </span>
        </div>
      </div>
    </footer>
  );
}
