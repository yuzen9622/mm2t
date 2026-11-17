"use client";
import Image from "next/image";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from "@/components/ui/accordion";
import { cn } from "@/lib/utils";
import { getFaqs } from "./faq-data";
import { REPO, h2, lead, screen, wrap } from "./shared";

export function FAQ() {
  const { t, locale } = useCopy();
  return (
    <section id="faq" data-ground="secondary" aria-labelledby="faq-title" className={cn(screen, "bg-secondary")}>
      <div className={cn(wrap, "grid gap-10 lg:h-full lg:grid-cols-12 lg:gap-6")}>
        <div className="flex flex-col lg:col-span-5">
          <h2 id="faq-title" className={h2}>
            {t("常見問題")}
          </h2>
          <p className={cn(lead, "mt-5 max-w-[24em]")}>
            {t("安裝步驟、支援的服務與每項設定，都寫在 GitHub 的使用文件。")}
          </p>
          <a
            className="link-draw mt-4 inline-flex min-h-11 items-center gap-2 text-[15px] font-medium"
            href={`${REPO}/blob/main/${locale === "en" ? "README.md" : "README.zh-TW.md"}`}
            target="_blank"
            rel="noreferrer"
          >
            {t("閱讀使用文件")}
            <Icon name="diagonal" size={15} />
          </a>
          <Image
            src="/media/icon.png"
            width={96}
            height={96}
            alt={t("mm2t 應用程式圖示")}
            className="mt-10 rounded-[22px] lg:mt-auto"
          />
        </div>
        <Accordion
          type="single"
          collapsible
          defaultValue="question-0"
          className="lg:col-span-6 lg:col-start-7"
        >
          {getFaqs(t).map((item, i) => (
            <AccordionItem key={item.question} value={`question-${i}`}>
              <AccordionTrigger>{t(item.question)}</AccordionTrigger>
              <AccordionContent>{item.answer}</AccordionContent>
            </AccordionItem>
          ))}
        </Accordion>
      </div>
    </section>
  );
}
