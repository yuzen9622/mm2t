"use client";
import { useEffect, useState } from "react";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import {
  Sheet,
  SheetTrigger,
  SheetContent,
  SheetTitle,
  SheetDescription,
  SheetClose,
} from "@/components/ui/sheet";
import { guidePageKeys, guidePages, sitePath, type GuidePage } from "@/lib/guide";
import { cn } from "@/lib/utils";
import { Brand, DownloadButton, REPO, wrap } from "./shared";

const homeLinks = [
  { label: "使用流程", href: "#flow" },
  { label: "四種讀法", href: "#views" },
  { label: "隱私", href: "#privacy" },
  { label: "常見問題", href: "#faq" },
];

/** The header takes the ground of whatever section passes under it, so it never reads as a band. */
type Ground = "background" | "secondary" | "stage";
function useGroundUnderHeader() {
  const [ground, setGround] = useState<Ground>("background");
  useEffect(() => {
    let frame = 0;
    const read = () => {
      frame = 0;
      const y = 36;
      const hit = [...document.querySelectorAll<HTMLElement>("[data-ground]")].find((el) => {
        const r = el.getBoundingClientRect();
        return r.top <= y && r.bottom > y;
      });
      setGround((hit?.dataset.ground as Ground) ?? "background");
    };
    const queue = () => {
      if (!frame) frame = requestAnimationFrame(read);
    };
    read();
    addEventListener("scroll", queue, { passive: true });
    addEventListener("resize", queue);
    addEventListener("mm2t:ground", queue);
    return () => {
      cancelAnimationFrame(frame);
      removeEventListener("scroll", queue);
      removeEventListener("resize", queue);
      removeEventListener("mm2t:ground", queue);
    };
  }, []);
  return ground;
}

export function Header({ page }: { page?: GuidePage }) {
  const { t, locale } = useCopy();
  const links = [
    ...homeLinks.map(({ href, label }) => ({ label, href: (page ? sitePath(locale) : "") + href })),
    ...guidePageKeys.map((key) => ({
      label: guidePages[key].label,
      href: sitePath(locale, key),
    })),
  ];
  const [open, setOpen] = useState(false);
  const ground = useGroundUnderHeader();
  const stage = ground === "stage";
  const quiet = stage ? "text-stage-ink" : "text-foreground";
  return (
    <header
      className={cn(
        "nav fixed inset-x-0 top-0 z-70 transition-colors duration-200",
        { background: "bg-background", secondary: "bg-secondary", stage: "bg-stage" }[ground],
      )}
    >
      <div className={cn(wrap, "flex h-18 items-center gap-6")}>
        <a
          href="#main"
          className="absolute -top-30 left-0 z-10 rounded-xl bg-foreground px-6 py-3 text-background focus:top-3"
        >
          {t("跳至主要內容")}
        </a>
        <Brand tone={stage ? "stage" : "ink"} />
        <nav className="ml-6 hidden items-center gap-5 lg:flex" aria-label={t("主要導覽")}>
          {links.map((link) => (
            <a
              key={link.href}
              href={link.href}
              aria-current={page && link.href === sitePath(locale, page) ? "page" : undefined}
              className={cn("link-draw inline-flex min-h-11 items-center text-sm aria-[current=page]:font-semibold", quiet)}
            >
              {t(link.label)}
            </a>
          ))}
        </nav>
        <div className={cn("ml-auto flex items-center gap-1", quiet)}>
          <a
            className="btn grid size-11 place-items-center rounded-full text-[13px] font-medium"
            href={sitePath(locale === "en" ? "zh" : "en", page)}
            hrefLang={locale === "en" ? "zh-Hant" : "en"}
            lang={locale === "en" ? "zh-Hant" : "en"}
            aria-label={locale === "en" ? "切換為繁體中文" : "Switch to English"}
          >
            {locale === "en" ? "繁中" : "EN"}
          </a>
          <a
            className="btn hidden size-11 place-items-center rounded-full sm:grid"
            href={REPO}
            target="_blank"
            rel="noreferrer"
            aria-label={t("在 GitHub 查看 mm2t 原始碼")}
          >
            <Icon name="github" size={20} />
          </a>
          <DownloadButton className="ml-2 hidden md:inline-flex" />
          <Sheet open={open} onOpenChange={setOpen}>
            <SheetTrigger asChild>
              <button
                type="button"
                className="btn grid size-11 place-items-center rounded-full lg:hidden"
                aria-label={t("開啟導覽選單")}
              >
                <Icon name="menu" />
              </button>
            </SheetTrigger>
            <SheetContent>
              <SheetTitle className="sr-only">{t("網站導覽")}</SheetTitle>
              <SheetDescription className="sr-only">{t("選擇想查看的官網章節。")}</SheetDescription>
              <div className="flex items-center justify-between">
                <Brand />
                <SheetClose asChild>
                  <button
                    type="button"
                    className="btn grid size-11 place-items-center rounded-full"
                    aria-label={t("關閉導覽選單")}
                  >
                    <Icon name="close" />
                  </button>
                </SheetClose>
              </div>
              <nav className="mt-8" aria-label={t("手機版導覽")}>
                {links.map((link) => (
                  <a
                    key={link.href}
                    href={link.href}
                    aria-current={page && link.href === sitePath(locale, page) ? "page" : undefined}
                    onClick={() => setOpen(false)}
                    className="flex min-h-16 items-center text-2xl tracking-[-0.02em]"
                  >
                    {t(link.label)}
                  </a>
                ))}
              </nav>
              <div className="mt-auto pt-10">
                <DownloadButton size="lg" className="w-full" />
              </div>
            </SheetContent>
          </Sheet>
        </div>
      </div>
    </header>
  );
}
