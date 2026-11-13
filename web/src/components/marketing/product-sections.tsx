"use client";
import { useState } from "react";
import Image from "next/image";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
} from "@/components/ui/card";
import {
  Reveal,
  container,
  sectionPadding,
  heading,
  label,
  frame,
} from "./shared";
const demos = [
  {
    label: "逐字稿",
    image: "transcript.webp",
    description: "逐句保留原話，依時間與說話者排列。",
  },
  {
    label: "依人彙整",
    image: "speakers.webp",
    description: "按說話者整理觀點，保留對應時間點。",
  },
  {
    label: "摘要",
    image: "summary.webp",
    description: "決議、討論重點與待辦事項，沿用 App 的原始排版。",
  },
];
export function ProductTour() {
  const { t, media, locale } = useCopy();
  const [tab, setTab] = useState("摘要");
  return (
    <section
      id="features"
      className={sectionPadding}
      aria-labelledby="features-title"
    >
      <div className={container}>
        <Reveal className="mb-12 flex flex-col justify-between gap-6 lg:flex-row lg:items-end">
          <div>
            <span className={label}>{t("你的會議，有不同讀法")}</span>
            <h2 id="features-title" className={heading}>
              {t("找回那句話。")}
              <br />
              <span className="text-muted-foreground">
                {t("或直接看重點。")}
              </span>
            </h2>
          </div>
          <p className="text-sm leading-8 text-muted-foreground">
            {t("逐字稿、整理版、依人彙整與摘要。")}
            <br />
            {t("切換下方頁籤，看看 mm2t 怎麼整理。")}
          </p>
        </Reveal>
        <Reveal>
          <Tabs value={tab} onValueChange={setTab}>
            <div className="flex flex-wrap items-center justify-between gap-4">
              <TabsList
                className="w-full sm:w-auto"
                aria-label={t("選擇會議紀錄格式")}
              >
                {demos.map((item) => (
                  <TabsTrigger key={item.label} value={item.label}>
                    {t(item.label)}
                  </TabsTrigger>
                ))}
              </TabsList>
              {locale === "en" && (
                <a
                  href="/media/en/ATTRIBUTION.md"
                  target="_blank"
                  rel="noreferrer"
                  className="text-xs text-muted-foreground underline underline-offset-4"
                >
                  Demo credits
                </a>
              )}
            </div>
            {demos.map((item) => (
              <TabsContent key={item.label} value={item.label}>
                <div
                  className={`${frame} overflow-x-auto`}
                  tabIndex={0}
                  role="region"
                  aria-label={t("App 畫面，可橫向捲動查看")}
                >
                  <Image
                    src={media(`app/${item.image}`)}
                    alt={t(item.description)}
                    width={1600}
                    height={941}
                    sizes="(max-width: 767px) 780px, 90vw"
                    className="h-auto w-full min-w-[780px]"
                  />
                </div>
                <p className="mt-6 text-sm text-muted-foreground">
                  {t(item.description)}
                </p>
              </TabsContent>
            ))}
          </Tabs>
        </Reveal>
      </div>
    </section>
  );
}
export function Details() {
  const { t, media } = useCopy();
  return (
    <section className={sectionPadding} aria-labelledby="details-title">
      <div className={container}>
        <Reveal className="mb-12 flex flex-col justify-between gap-6 lg:flex-row lg:items-end">
          <div>
            <span className={label}>{t("越用，越熟悉你的會議")}</span>
            <h2 id="details-title" className={heading}>
              {t("記住聲音，")}
              <br />
              <span className="text-muted-foreground">
                {t("也記住你的用語。")}
              </span>
            </h2>
          </div>
          <p className="text-sm leading-8 text-muted-foreground">
            {t("從常見的與會者，到團隊自己的專有名詞。")}
            <br />
            {t("每次整理，都有熟悉的依據。")}
          </p>
        </Reveal>
        <div className="grid gap-8 md:grid-cols-2">
          <Reveal>
            <Card>
              <CardHeader>
                <Icon name="users" size={25} className="mb-2" />
                <CardTitle>{t("一次命名，下次就認得。")}</CardTitle>
                <CardDescription>
                  {t("聲紋留在你的 Mac。現場與線上通話，")}
                  <br />
                  {t("分別記住同一個人的聲音。")}
                </CardDescription>
              </CardHeader>
              <CardContent>
                <div className={frame}>
                  <Image
                    src={media("app/people.webp")}
                    width={1600}
                    height={941}
                    alt={t("人物與聲紋的實際 App 畫面")}
                    sizes="(max-width: 767px) 90vw, 45vw"
                    className="h-auto w-full transition-transform duration-700 ease-out-expo hover:scale-[1.025]"
                  />
                </div>
              </CardContent>
            </Card>
          </Reveal>
          <Reveal delay={0.1}>
            <Card>
              <CardHeader>
                <Icon name="book" size={25} className="mb-2" />
                <CardTitle>{t("團隊的詞彙，說得準。")}</CardTitle>
                <CardDescription>
                  {t("將專有名詞加入個人詞彙庫，")}
                  <br />
                  {t("讓轉錄與整理時有參考依據。")}
                </CardDescription>
              </CardHeader>
              <CardContent>
                <div className={frame}>
                  <Image
                    src={media("app/vocabulary.webp")}
                    width={1600}
                    height={941}
                    alt={t("個人詞彙庫的實際 App 畫面")}
                    sizes="(max-width: 767px) 90vw, 45vw"
                    className="h-auto w-full transition-transform duration-700 ease-out-expo hover:scale-[1.025]"
                  />
                </div>
              </CardContent>
            </Card>
          </Reveal>
        </div>
      </div>
    </section>
  );
}
