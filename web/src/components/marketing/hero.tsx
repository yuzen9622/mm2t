"use client";
import type { CSSProperties } from "react";
import { useCopy } from "@/components/i18n";
import { RecordingDemo } from "@/components/native-waveform";
import { AppWindow, MeetingHeader, SpeakerPanel, StaticTabs, TranscriptRows } from "@/components/app-ui";
import { DownloadButton, wrap } from "./shared";
import { VideoButton } from "./video-dialog";

const d = (n: number) => ({ "--d": n }) as CSSProperties;

export function Hero() {
  const { t, locale } = useCopy();
  return (
    <section
      id="top"
      data-enter=""
      aria-labelledby="hero-title"
      className="hero relative h-svh overflow-hidden pt-24 pb-6 lg:pt-[120px] lg:pb-16"
    >
      <div className={`${wrap} h-full`}>
       <div className="hero-text grid h-full grid-rows-[auto_1fr] gap-8 lg:grid-cols-12 lg:grid-rows-1 lg:gap-6">
        <div className="flex flex-col lg:col-span-5">
          <h1
            id="hero-title"
            className="text-[38px] leading-[1.08] font-medium tracking-[-0.02em] md:text-[52px] lg:text-[64px] lg:leading-[1.04]"
          >
            {locale === "en" ? (
              <>
                <span className="enter block" style={d(0)}>Meeting notes</span>
                <span className="enter block" style={d(1)}>for Mac that</span>
                <span className="enter block" style={d(1)}>know who spoke</span>
              </>
            ) : (
              <>
                <span className="enter block" style={d(0)}>Mac 會議記錄，</span>
                <span className="enter block" style={d(1)}>認得每位說話者</span>
              </>
            )}
          </h1>
          <p
            className="enter mt-5 max-w-[30em] text-base leading-[1.6] text-muted-foreground lg:mt-6 lg:text-xl lg:leading-[1.5]"
            style={d(2)}
          >
            {t("直接錄下麥克風與會議 App 的聲音，不需要機器人進會議。會後在 Mac 上分出說話者，整理成逐字稿與摘要。")}
          </p>
          <div className="enter mt-6 flex flex-wrap items-center gap-2 lg:mt-8" style={d(3)}>
            <DownloadButton size="lg" className="max-sm:w-full" />
            <VideoButton />
          </div>
          <p className="enter mt-5 text-sm text-muted-foreground lg:mt-6" style={d(4)}>
            {t("免費開源 · macOS 14.2 以上")}
          </p>
          <div className="enter mt-auto hidden pt-10 lg:block" style={d(5)}>
            <p className="text-sm text-muted-foreground">{t("錄得到這些會議 App")}</p>
            <ul className="mt-3 flex flex-wrap gap-x-6 gap-y-2 text-[17px] font-medium">
              {["Google Meet", "Microsoft Teams", "Zoom", "Webex"].map((app) => (
                <li key={app}>{app}</li>
              ))}
            </ul>
          </div>
        </div>
        <div
          className="enter-art relative min-h-[220px] overflow-hidden rounded-[20px] bg-[#e9e2d6] lg:col-span-6 lg:col-start-7"
          data-visual=""
        >
          {/* One soft light from the upper left, inside the sand ground. */}
          <div
            aria-hidden="true"
            className="absolute inset-0 bg-[radial-gradient(90%_70%_at_18%_8%,#f4efe7_0%,#f4efe700_70%)]"
          />
          <AppWindow
            sidebar={false}
            className="absolute inset-x-4 top-4 h-[640px] [mask-image:linear-gradient(#000_55%,transparent_92%)] sm:inset-x-auto sm:left-10 sm:w-[calc(100%_-_40px_+_28px)] md:top-10 lg:top-16 lg:left-16 lg:h-[calc(100%_-_64px_+_28px)] lg:w-[calc(100%_-_64px_+_28px)] lg:[mask-image:none]"
          >
            <MeetingHeader tabs={<StaticTabs active="整理版逐字稿" />} />
            <div className="flex gap-4 px-5 pt-5 pr-12">
              <div className="min-w-0 flex-1">
                <TranscriptRows mode="clean" />
              </div>
              <SpeakerPanel />
            </div>
          </AppWindow>
          <RecordingDemo className="absolute bottom-8 left-10 hidden sm:flex lg:left-16" />
        </div>
       </div>
      </div>
    </section>
  );
}
