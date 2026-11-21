import type { Locale } from "./messages";

export const guidePages = {
  models: {
    label: "模型比較",
    en: "Model comparison",
    description: "依會議語言、字幕速度與翻譯品質，選擇適合的字幕、轉錄與摘要模型。",
    enDescription: "Choose models for live captions, translation, transcription and summaries based on meeting languages, speed and accuracy.",
  },
  pricing: {
    label: "定價",
    en: "Pricing",
    description: "比較Free、Standard 與 Pro的含稅月費、雲端會議額度和功能。",
    enDescription: "Compare tax-inclusive monthly prices, cloud meeting allowances and features for Free, Standard and Pro.",
  },
  changelog: {
    label: "版本紀錄",
    en: "Changelog",
    description: "mm2t 歷次正式發布的版本紀錄。",
    enDescription: "Published mm2t releases, with notes in Traditional Chinese.",
  },
} as const;

export type GuidePage = keyof typeof guidePages;

export const guidePageKeys = Object.keys(guidePages) as GuidePage[];

export function sitePath(locale: Locale, page?: GuidePage) {
  return (locale === "en" ? "/en/" : "/") + (page ? page + "/" : "");
}
