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
        <Button variant="ghost" className="gap-3 px-3">
          <span className="grid size-7 place-items-center rounded-full border border-foreground/25">
            <Icon name="play" size={14} />
          </span>
          {t("觀看示範")}
          <span className="hidden text-xs text-muted-foreground sm:inline">
            00:44
          </span>
        </Button>
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
