import type { Metadata } from "next";
import type { Locale } from "./messages";
export function siteMetadata(locale: Locale): Metadata {
  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL;
  const en = locale === "en";
  const title = en
    ? "mm2t — Meeting notes. Made for Mac."
    : "mm2t — Mac 上的會議記錄工具";
  const description = en
    ? "Stay in the conversation. mm2t records meetings without a bot, recognizes speakers, and creates transcripts and summaries. Free and open source for macOS."
    : "開會時專心說話，紀錄交給 mm2t。免費開源的 macOS 會議記錄工具，免 Bot 錄音、辨識說話者，整理逐字稿與摘要。";
  return {
    title,
    description,
    ...(siteUrl
      ? {
          metadataBase: new URL(siteUrl),
          alternates: {
            canonical: en ? "/en/" : "/",
            languages: { "zh-Hant": "/", en: "/en/", "x-default": "/" },
          },
        }
      : {}),
    openGraph: {
      title,
      description,
      type: "website",
      locale: en ? "en_US" : "zh_TW",
      alternateLocale: en ? "zh_TW" : "en_US",
      images: [
        {
          url: siteUrl
            ? `/media/${en ? "en/" : ""}poster.webp`
            : `https://raw.githubusercontent.com/yuzen9622/mm2t/main/docs/assets/${en ? "en/" : ""}poster.png`,
          width: 1920,
          height: 1080,
          alt: title,
        },
      ],
    },
    twitter: { card: "summary_large_image" },
    other: { "page-type": "software", "site-kind": "software" },
  };
}
