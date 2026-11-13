"use client";
import { useState } from "react";
import { motion } from "motion/react";
import { useCopy } from "@/components/i18n";
import { useIntroReady } from "@/components/brand-intro";
import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";
import {
  Sheet,
  SheetTrigger,
  SheetContent,
  SheetTitle,
  SheetDescription,
  SheetClose,
} from "@/components/ui/sheet";
import { Brand, DownloadButton, REPO } from "./shared";
const links = [
  { label: "使用體驗", href: "#experience" },
  { label: "功能", href: "#features" },
  { label: "隱私", href: "#privacy" },
  { label: "常見問題", href: "#faq" },
];
export function Header() {
  const { t, locale } = useCopy();
  const ready = useIntroReady();
  const [open, setOpen] = useState(false);
  return (
    <motion.header
      data-intro-content=""
      initial={false}
      animate={{ opacity: ready ? 1 : 0 }}
      transition={{ duration: 0.5 }}
      className="pointer-events-none fixed inset-x-0 top-4 z-70 px-4 md:top-6 md:px-6"
    >
      <a
        href="#top"
        className="pointer-events-auto absolute -top-30 left-6 rounded-xl bg-foreground px-6 py-4 text-background focus:top-0"
      >
        {t("跳至主要內容")}
      </a>
      <div className="pointer-events-auto mx-auto flex min-h-16 max-w-[1100px] items-center justify-between gap-3 rounded-full bg-card/85 py-2 pr-2 pl-4 shadow-[0_5px_28px_#28201108] ring-1 ring-white/70 backdrop-blur-2xl md:gap-6">
        <Brand />
        <nav
          className="hidden items-center gap-7 lg:flex"
          aria-label={t("主要導覽")}
        >
          {links.map((link) => (
            <a
              key={link.href}
              href={link.href}
              className="inline-flex min-h-11 items-center text-sm decoration-primary underline-offset-8 hover:underline"
            >
              {t(link.label)}
            </a>
          ))}
        </nav>
        <div className="flex items-center gap-1 md:gap-2">
          <Button asChild size="icon" variant="ghost" className="text-xs">
            <a
              href={locale === "en" ? "/" : "/en/"}
              hrefLang={locale === "en" ? "zh-Hant" : "en"}
              lang={locale === "en" ? "zh-Hant" : "en"}
              aria-label={
                locale === "en" ? "切換為繁體中文" : "Switch to English"
              }
            >
              {locale === "en" ? "繁中" : "EN"}
            </a>
          </Button>
          <Button
            asChild
            size="icon"
            variant="ghost"
            className="hidden sm:inline-flex"
          >
            <a
              href={REPO}
              target="_blank"
              rel="noreferrer"
              aria-label={t("在 GitHub 查看 mm2t 原始碼")}
            >
              <Icon name="github" size={21} />
            </a>
          </Button>
          <DownloadButton className="hidden md:inline-flex" />
          <Sheet open={open} onOpenChange={setOpen}>
            <SheetTrigger asChild>
              <Button
                size="icon"
                variant="ghost"
                className="lg:hidden"
                aria-label={t("開啟導覽選單")}
              >
                <Icon name="menu" />
              </Button>
            </SheetTrigger>
            <SheetContent>
              <SheetTitle className="sr-only">{t("網站導覽")}</SheetTitle>
              <SheetDescription className="sr-only">
                {t("選擇想查看的官網章節。")}
              </SheetDescription>
              <div className="flex items-center justify-between">
                <Brand />
                <SheetClose asChild>
                  <Button
                    size="icon"
                    variant="ghost"
                    aria-label={t("關閉導覽選單")}
                  >
                    <Icon name="close" />
                  </Button>
                </SheetClose>
              </div>
              <nav className="mt-8" aria-label={t("手機版導覽")}>
                {links.map((link, i) => (
                  <a
                    key={link.href}
                    href={link.href}
                    onClick={() => setOpen(false)}
                    className="flex min-h-24 items-center gap-5 border-b border-border text-2xl tracking-tight"
                  >
                    <span className="text-xs text-muted-foreground">
                      0{i + 1}
                    </span>
                    {t(link.label)}
                    <Icon name="diagonal" className="ml-auto" />
                  </a>
                ))}
              </nav>
              <div className="mt-auto pt-10">
                <DownloadButton className="w-full" />
                <p className="mt-5 text-center text-xs text-muted-foreground">
                  {t("macOS 14.2 以上 · 免費開放原始碼")}
                </p>
              </div>
            </SheetContent>
          </Sheet>
        </div>
      </div>
    </motion.header>
  );
}
