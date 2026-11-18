"use client";
import { useState } from "react";
import * as Tabs from "@radix-ui/react-tabs";
import { useCopy } from "@/components/i18n";
import {
  AppWindow,
  BySpeakerView,
  MeetingHeader,
  SpeakerPanel,
  SummaryView,
  TranscriptRows,
  viewTabs,
} from "@/components/app-ui";
import { cn } from "@/lib/utils";
import { h2, lead, screen, wrap } from "./shared";

export function Views() {
  const { t } = useCopy();
  const [tab, setTab] = useState<string>("摘要");
  return (
    <section id="views" aria-labelledby="views-title" className={screen}>
      <div className={cn(wrap, "flex h-full flex-col")}>
        <div className="grid gap-4 lg:grid-cols-12 lg:gap-6">
          <h2 id="views-title" className={cn(h2, "lg:col-span-6")}>
            {t("同一場會議，四種讀法")}
          </h2>
          <p className={cn(lead, "lg:col-span-6 lg:col-start-7 lg:self-end")}>
            {t("要找原話時看逐字稿，只要結論時看摘要。點上方的分頁切換，這就是 App 裡的畫面。")}
          </p>
        </div>
        <Tabs.Root value={tab} onValueChange={setTab} className="mt-8 min-h-0 flex-1 lg:mt-10">
          <AppWindow className="lg:h-full">
            <MeetingHeader
              tabs={
                <Tabs.List
                  aria-label={t("選擇會議紀錄格式")}
                  className="inline-flex max-w-full gap-0.5 overflow-x-auto rounded-[10px] bg-(--w-tonal) p-0.5"
                >
                  {viewTabs.map((item) => (
                    <Tabs.Trigger
                      key={item}
                      value={item}
                      className="min-h-9 rounded-lg px-3.5 text-[13px] whitespace-nowrap text-(--w-secondary) transition-colors duration-150 hover:text-(--w-text) data-[state=active]:bg-(--w-card) data-[state=active]:font-medium data-[state=active]:text-(--w-text) data-[state=active]:shadow-[0_1px_2px_#0000000f]"
                    >
                      {t(item)}
                    </Tabs.Trigger>
                  ))}
                </Tabs.List>
              }
            />
            <div className="relative flex min-h-0 flex-1 gap-4 px-5 pt-5 pb-5 lg:overflow-hidden lg:pb-0">
              <div className="min-w-0 flex-1">
                <Tabs.Content value="逐字稿" className="outline-none">
                  <TranscriptRows mode="raw" />
                </Tabs.Content>
                <Tabs.Content value="整理版逐字稿" className="outline-none">
                  <TranscriptRows mode="clean" />
                </Tabs.Content>
                <Tabs.Content value="依人彙整" className="outline-none">
                  <BySpeakerView />
                </Tabs.Content>
                <Tabs.Content value="摘要" className="outline-none">
                  <SummaryView />
                </Tabs.Content>
              </div>
              <SpeakerPanel />
              {/* The window's own color fading out the last rows, as the App does at a scroll edge. */}
              <div
                aria-hidden="true"
                className="pointer-events-none absolute inset-x-0 bottom-0 hidden h-16 bg-linear-to-t from-(--w-bg) to-transparent lg:block"
              />
            </div>
          </AppWindow>
        </Tabs.Root>
      </div>
    </section>
  );
}
