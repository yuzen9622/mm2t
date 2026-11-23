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

export const policyPages = {
  terms: {
    label: "服務條款",
    en: "Terms of Service",
    heading: { zh: "雲端服務條款", en: "Terms for Cloud Services" },
    description: "mm2t 雲端服務的條款，涵蓋帳號、訂閱、服務使用權、轉售限制、伺服器安全與法律救濟。",
    enDescription: "Terms for mm2t cloud services, covering accounts, subscriptions, authorized use, resale restrictions, server security, and remedies.",
  },
  privacy: {
    label: "隱私權政策",
    en: "Privacy Policy",
    heading: { zh: "雲端服務隱私權政策", en: "Privacy Policy for Cloud Services" },
    description: "了解 mm2t 雲端服務如何處理帳號、會議、付款及安全事件資料。",
    enDescription: "How mm2t cloud services handle account, meeting, payment, and security incident data.",
  },
  refunds: {
    label: "退款政策",
    en: "Refund Policy",
    heading: { zh: "雲端服務退款政策", en: "Refund Policy for Cloud Services" },
    description: "了解 mm2t 雲端服務付費方案的取消、退款申請與消費者權利。",
    enDescription: "Cancelling paid plans, requesting a refund, and exercising consumer rights for mm2t cloud services.",
  },
} as const;

export type GuidePage = keyof typeof guidePages;
export type PolicyPage = keyof typeof policyPages;
export type SitePage = GuidePage | PolicyPage;

export const policyPageKeys = ["terms", "privacy", "refunds"] as const satisfies readonly PolicyPage[];

export const guidePageKeys = Object.keys(guidePages) as GuidePage[];

export function sitePath(locale: Locale, page?: SitePage) {
  return (locale === "en" ? "/en/" : "/") + (page ? page + "/" : "");
}
