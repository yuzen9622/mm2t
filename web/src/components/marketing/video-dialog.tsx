"use client";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogTrigger,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogClose,
} from "@/components/ui/dialog";
export function VideoButton() {
  const { t, locale, media } = useCopy();
  return (
    <Dialog>
      <DialogTrigger asChild>
        <button
          type="button"
          className="btn inline-flex min-h-12 items-center gap-2.5 rounded-full px-5 text-base font-medium hover:bg-foreground/[.06] max-sm:w-full max-sm:justify-center"
        >
          <Icon name="playFilled" size={14} />
          {t("觀看示範")}
          <span className="font-mono text-sm text-muted-foreground tabular-nums">0:44</span>
        </button>
      </DialogTrigger>
      <DialogContent className="max-w-5xl gap-2 p-2 md:p-3">
        <DialogHeader className="pl-3">
          <DialogTitle>{t("一分鐘看懂 mm2t")}</DialogTitle>
          <DialogClose asChild>
            <Button variant="ghost" size="icon" aria-label={t("關閉示範影片")}>
              <Icon name="close" />
            </Button>
          </DialogClose>
        </DialogHeader>
        <DialogDescription className="sr-only">
          {t(
            "mm2t 的實際操作示範：錄音、命名說話者與查看摘要。影片以畫面文字說明，沒有口述。",
          )}
        </DialogDescription>
        <video
          className="aspect-video max-h-[75dvh] w-full rounded-2xl bg-foreground"
          controls
          autoPlay
          playsInline
          preload="none"
          poster={media("poster.webp")}
          aria-label={t("mm2t 操作示範")}
        >
          <source
            src={media(locale === "en" ? "mm2t-en.mp4" : "mm2t-zh.mp4")}
            type="video/mp4"
          />
          <track
            kind="captions"
            src={media(locale === "en" ? "demo-en.vtt" : "demo-zh.vtt")}
            srcLang={locale === "en" ? "en" : "zh-Hant"}
            label={t("繁體中文")}
          />
          {t("你的瀏覽器無法播放影片，請")}
          <a href={media(locale === "en" ? "mm2t-en.mp4" : "mm2t-zh.mp4")}>
            {t("下載示範影片")}
          </a>
        </video>
        {locale === "en" && (
          <a
            className="px-4 py-2 text-center text-xs text-muted-foreground underline underline-offset-4"
            href="/media/en/ATTRIBUTION.md"
            target="_blank"
            rel="noreferrer"
          >
            Demo transcript adapted from the AMI Meeting Corpus · CC BY 4.0
          </a>
        )}
      </DialogContent>
    </Dialog>
  );
}
