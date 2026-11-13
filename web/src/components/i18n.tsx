"use client";
import { createContext, useContext, type ReactNode } from "react";
import { english, type Locale } from "@/lib/messages";
const LanguageContext = createContext<Locale>("zh");
export function LanguageProvider({ locale, children }: { locale: Locale; children: ReactNode }) {
  return <LanguageContext.Provider value={locale}>{children}</LanguageContext.Provider>;
}
export function useCopy() {
  const locale = useContext(LanguageContext);
  return {
    locale,
    t: (text: string) => locale === "en" ? (english[text] ?? text) : text,
    media: (file: string) => `/media/${locale === "en" ? "en/" : ""}${file}`,
  };
}
