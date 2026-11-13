"use client";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from "@/components/ui/accordion";
import { getFaqs } from "./faq-data";
import {
  Reveal,
  REPO,
  container,
  sectionPadding,
  heading,
  label,
  textLink,
} from "./shared";
export function FAQ() {
  const { t, locale } = useCopy();
  return (
    <section id="faq" className={sectionPadding} aria-labelledby="faq-title">
      <div
        className={`${container} grid gap-12 lg:grid-cols-[.8fr_1.2fr] lg:gap-24`}
      >
        <Reveal>
          <span className={label}>{t("開始之前")}</span>
          <h2 id="faq-title" className={heading}>
            {t("關於 mm2t，")}
            <br />
            <span className="text-muted-foreground">{t("你可能想知道。")}</span>
          </h2>
          <p className="mt-7 text-sm leading-8 text-muted-foreground">
            {t("更多設定與使用方式，")}
            <br />
            {t("都整理在 GitHub 文件裡。")}
          </p>
          <a
            className={`${textLink} mt-4`}
            href={`${REPO}/blob/main/${locale === "en" ? "README.md" : "README.zh-TW.md"}`}
            target="_blank"
            rel="noreferrer"
          >
            {t("閱讀使用文件")}
            <Icon name="diagonal" size={17} />
          </a>
        </Reveal>
        <Reveal>
          <Accordion type="single" collapsible defaultValue="question-0">
            {getFaqs(t).map((item, i) => (
              <AccordionItem key={item.question} value={`question-${i}`}>
                <AccordionTrigger>{t(item.question)}</AccordionTrigger>
                <AccordionContent>{item.answer}</AccordionContent>
              </AccordionItem>
            ))}
          </Accordion>
        </Reveal>
      </div>
    </section>
  );
}
