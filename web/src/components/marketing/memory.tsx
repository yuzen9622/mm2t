"use client";
import { useState } from "react";
import { useCopy } from "@/components/i18n";
import { AppWindow, PeopleList } from "@/components/app-ui";
import { VocabularyView } from "@/components/vocabulary-preview";
import { cn } from "@/lib/utils";
import { h2, lead, screen, wrap } from "./shared";

export function Memory() {
  const { t } = useCopy();
  const [selected, setSelected] = useState<"人物" | "詞彙">("人物");
  return (
    <section id="memory" data-ground="secondary" aria-labelledby="memory-title" className={cn(screen, "h-svh min-h-[640px] bg-secondary")}>
      <div className={cn(wrap, "flex h-full flex-col")}>
        <div className="grid gap-4 lg:grid-cols-12 lg:gap-6">
          <h2 id="memory-title" className={cn(h2, "lg:col-span-6")}>
            {t("記住常見的與會者和團隊用語")}
          </h2>
          <p className={cn(lead, "lg:col-span-6 lg:col-start-7 lg:self-end")}>
            {t("人物卡會標出聲紋來自現場或線上通話。儲存逐字稿修正後，mm2t 會學習你改過的人名與術語，也可以手動新增詞彙。")}
          </p>
        </div>
        <div role="group" aria-labelledby="memory-title" className="mt-5 flex w-fit gap-5 lg:hidden">
          {(["人物", "詞彙"] as const).map((item) => (
            <button key={item} type="button" aria-pressed={item === selected} onClick={() => setSelected(item)}
              className="min-h-11 min-w-11 border-b-2 border-transparent text-sm font-medium text-muted-foreground hover:text-foreground aria-pressed:border-primary aria-pressed:text-foreground">{t(item)}</button>
          ))}
        </div>
        <div className="mt-3 grid min-h-0 flex-1 grid-rows-[minmax(0,1fr)] gap-6 lg:mt-10 lg:grid-cols-12">
          <AppWindow active="人物" className={cn("lg:col-span-7", selected !== "人物" && "max-lg:hidden")}>
            <div className="min-h-0 flex-1 overflow-y-auto p-4 @sm:p-5">
              <h3 className="mb-4 text-[18px] font-semibold max-lg:sr-only @[560px]:sr-only">{t("人物")}</h3>
              <div className="@[560px]:pt-10"><PeopleList /></div>
            </div>
          </AppWindow>
          <AppWindow active="詞彙" className={cn("lg:col-span-5", selected !== "詞彙" && "max-lg:hidden")}>
            <div className="min-h-0 flex-1 overflow-y-auto p-4 @sm:p-5">
              <h3 className="mb-4 text-[18px] font-semibold max-lg:sr-only @[560px]:sr-only">{t("詞彙")}</h3>
              <VocabularyView />
            </div>
          </AppWindow>
        </div>
      </div>
    </section>
  );
}
