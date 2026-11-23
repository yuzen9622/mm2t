import type { Metadata } from "next";
import type { Locale } from "./messages";
import { guidePages, policyPages, sitePath, type SitePage } from "./guide";

export function siteMetadata(locale: Locale, page?: SitePage): Metadata {
  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL;
  const en = locale === "en";
  const pages = { ...guidePages, ...policyPages };
  const details = page && pages[page];
  const title = details ? ("heading" in details ? details.heading[locale] : en ? details.en : details.label) + " · mm2t" : en
    ? "mm2t — Meeting notes for Mac that know who spoke"
    : "mm2t — Mac 會議記錄，認得每位說話者";
  const description = details ? (en ? details.enDescription : details.description) : en
    ? "mm2t records your microphone and meeting audio with no bot in the call, tells the speakers apart on your Mac, and writes the transcript and summary. Free and open source for macOS 14.2 or later."
    : "mm2t 直接錄下麥克風與會議 App 的聲音，不需要機器人進會議，在 Mac 上分出說話者，整理成逐字稿與摘要。免費開源，支援 macOS 14.2 以上。";
  return {
    title,
    description,
    ...(page && Object.hasOwn(policyPages, page) ? { robots: { index: false } } : {}),
    ...(siteUrl
      ? {
          metadataBase: new URL(siteUrl),
          alternates: {
            canonical: sitePath(locale, page),
            languages: { "zh-Hant": sitePath("zh", page), en: sitePath("en", page), "x-default": sitePath("zh", page) },
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
