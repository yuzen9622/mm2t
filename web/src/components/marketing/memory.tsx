"use client";
import { useCopy } from "@/components/i18n";
import { AppWindow, PeopleList, VocabularyView } from "@/components/app-ui";
import { cn } from "@/lib/utils";
import { h2, lead, screen, wrap } from "./shared";

export function Memory() {
  const { t } = useCopy();
  return (
    <section id="memory" data-ground="secondary" aria-labelledby="memory-title" className={cn(screen, "bg-secondary")}>
      <div className={cn(wrap, "flex h-full flex-col")}>
        <div className="grid gap-4 lg:grid-cols-12 lg:gap-6">
          <h2 id="memory-title" className={cn(h2, "lg:col-span-6")}>
            {t("記住常見的與會者和團隊用語")}
          </h2>
          <p className={cn(lead, "lg:col-span-6 lg:col-start-7 lg:self-end")}>
            {t("同一個人在會議室和線上通話各存一份聲紋。會議中聽到的專有名詞，以及你改過的字，會自動加進詞彙庫。")}
          </p>
        </div>
        <div className="mt-8 grid min-h-0 flex-1 gap-6 lg:mt-10 lg:grid-cols-12">
          <AppWindow active="人物" className="min-h-[420px] lg:col-span-7">
            <div className="flex-1 p-5">
              <h3 className="mb-4 text-[18px] font-semibold">{t("人物")}</h3>
              <PeopleList />
            </div>
          </AppWindow>
          <AppWindow active="詞彙" className="min-h-[320px] lg:col-span-5">
            <div className="flex-1 p-5">
              <VocabularyView />
            </div>
          </AppWindow>
        </div>
      </div>
    </section>
  );
}
