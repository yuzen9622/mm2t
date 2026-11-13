"use client";
import { MotionConfig } from "motion/react";
import type { Locale } from "@/lib/messages";
import { LanguageProvider } from "./i18n";
import { BrandIntro } from "./brand-intro";
import { AssemblyScene } from "./assembly-scene";
import { Header } from "./marketing/header";
import { Hero } from "./marketing/hero";
import { Experience } from "./marketing/experience";
import { ProductTour, Details } from "./marketing/product-sections";
import { Privacy } from "./marketing/privacy";
import { FAQ } from "./marketing/faq";
import { Footer } from "./marketing/footer";
export function LandingPage({ locale = "zh" }: { locale?: Locale }) {
  return (
    <LanguageProvider locale={locale}>
      <MotionConfig reducedMotion="user">
        <BrandIntro>
          <Header />
          <main id="top">
            <Hero />
            <Experience />
            <ProductTour />
            <Details />
            <AssemblyScene />
            <Privacy />
            <FAQ />
          </main>
          <Footer />
        </BrandIntro>
      </MotionConfig>
    </LanguageProvider>
  );
}
