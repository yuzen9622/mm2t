"use client";
import { MotionConfig } from "motion/react";
import type { Locale } from "@/lib/messages";
import { LanguageProvider } from "./i18n";
import { Header } from "./marketing/header";
import { Hero } from "./marketing/hero";
import { FlowScene } from "./marketing/flow-scene";
import { Views } from "./marketing/views";
import { Memory } from "./marketing/memory";
import { Privacy } from "./marketing/privacy";
import { FAQ } from "./marketing/faq";
import { Footer } from "./marketing/footer";

export function LandingPage({ locale = "zh" }: { locale?: Locale }) {
  return (
    <LanguageProvider locale={locale}>
      <MotionConfig reducedMotion="user">
        <Header />
        <main id="main">
          <Hero />
          <FlowScene />
          <Views />
          <Memory />
          <Privacy />
          <FAQ />
        </main>
        <Footer />
      </MotionConfig>
    </LanguageProvider>
  );
}
