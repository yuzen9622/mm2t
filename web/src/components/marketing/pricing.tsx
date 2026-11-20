"use client";
import type { ReactNode } from "react";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import { cn } from "@/lib/utils";
import { wrap } from "./shared";

const plans = [
  { name: "Free", fee: 0, minutes: 120, ai: 5, live: false, audience: "偶爾開會，先試一次完整的錄音與整理流程。" },
  { name: "Standard", fee: 199, minutes: 240, ai: "unlimited", live: true, audience: "每週都有例會，需要更多雲端轉錄時數。" },
  { name: "Pro", fee: 399, minutes: 540, ai: "unlimited", live: true, audience: "經常訪談或長時間開會，需要最多錄音時數。" },
] as const;
type Plan = (typeof plans)[number];

const featureGroups = [
  { name: "錄音與會後整理", features: ["錄音", "會後逐字稿", "說話者辨識", "摘要", "待辦事項", "搜尋", "回放", "匯出"], liveOnly: false },
  { name: "會議進行中", features: ["即時字幕", "即時轉錄", "即時翻譯"], liveOnly: true },
  { name: "AI 助理", features: ["AI 提問", "AI 改寫"], liveOnly: false },
] as const;

function FeatureRow({ label, value }: { label: string; value: (plan: Plan) => ReactNode }) {
  const { t } = useCopy();
  return (
    <tr>
      <th scope="row" className="border-x border-b border-white/15 px-2 py-4 text-left leading-relaxed font-normal sm:px-4">{t(label)}</th>
      {plans.map(plan => {
        const result = value(plan);
        return (
          <td key={plan.name} className="border-r border-b border-white/15 px-1 py-3 leading-snug tabular-nums">
            {typeof result === "boolean" ? (
              <>
                {result ? <Icon name="check" size={18} /> : <span aria-hidden="true" className="text-stage-muted">—</span>}
                <span className="sr-only">{t(result ? "已包含" : "未包含")}</span>
              </>
            ) : result}
          </td>
        );
      })}
    </tr>
  );
}

function GroupTitle({ children }: { children: ReactNode }) {
  return <tr><th scope="rowgroup" colSpan={4} className="border-x border-b border-white/20 bg-white/[0.06] px-2 py-3 text-left text-sm font-medium sm:px-4">{children}</th></tr>;
}

export function Pricing() {
  const { t } = useCopy();
  const minutes = (plan: Plan) => plan.minutes + " " + t("分鐘");
  const aiQuota = (plan: Plan) => plan.ai === "unlimited" ? t("無限") : plan.ai + " " + t("次");

  return (
    <div data-ground="stage" className="bg-stage py-8 text-stage-ink md:py-14">
      <div className={wrap}>
        <section aria-label={t("方案概覽")} className="grid border-t border-l border-white/20 md:grid-cols-3">
          {plans.map(plan => (
            <article key={plan.name} className="grid grid-rows-[auto_1fr] border-r border-b border-white/20">
              <h2 className={cn("border-b border-white/20 px-5 py-4 text-xl font-medium md:px-7",
                plan.name === "Pro" && "bg-secondary text-foreground")}>{plan.name}</h2>
              <div className="flex flex-col px-5 pt-5 pb-6 md:px-7">
                <p className="max-w-[24em] text-sm leading-relaxed text-stage-muted md:min-h-14">{t(plan.audience)}</p>
                <p className="mt-6 flex flex-wrap items-baseline gap-x-2 gap-y-1">
                  <strong className="text-4xl font-medium tracking-[-0.05em] xl:text-5xl">NT${plan.fee}</strong>
                  <span className="text-sm text-stage-muted">{t("每人每月・含稅")}</span>
                </p>
                <dl className="mt-6 grid gap-3 border-t border-white/20 pt-5 text-sm">
                  <div><dt className="text-stage-muted">{t("雲端會議處理")}</dt>
                    <dd className="mt-1">{minutes(plan)} ({plan.minutes / 60} {t("小時")})</dd></div>
                  <div><dt className="text-stage-muted">{t("額外 AI 共用額度")}</dt>
                    <dd className="mt-1">{aiQuota(plan)}</dd></div>
                </dl>
              </div>
            </article>
          ))}
        </section>
        <section className="mt-12 md:mt-16" aria-labelledby="features">
          <h2 id="features" className="mb-5 text-2xl font-medium tracking-tight md:text-3xl">{t("各方案功能對照")}</h2>
          <table className="w-full table-fixed border-separate border-spacing-0 text-center text-xs sm:text-sm">
            <caption className="sr-only">{t("各方案功能對照")}</caption>
            <colgroup><col className="w-[38%] md:w-[34%]" /><col /><col /><col /></colgroup>
            <thead className="sticky top-18 z-10">
              <tr>
                <th scope="col" className="border border-white/20 bg-stage px-2 py-4 text-left font-medium sm:px-4">{t("功能")}</th>
                {plans.map(plan => (
                  <th key={plan.name} scope="col" className={cn("border-y border-r border-white/20 bg-stage px-1 py-3 font-medium",
                    plan.name === "Pro" && "bg-secondary text-foreground")}>
                    {plan.name}<span className="mt-1 block text-xs font-normal">NT${plan.fee}{t("／月")}</span>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              <GroupTitle>{t("每月雲端額度")}</GroupTitle>
              <FeatureRow label="雲端會議處理" value={minutes} />
              <FeatureRow label="額外 AI 共用額度" value={aiQuota} />
            </tbody>
            {featureGroups.map(group => (
              <tbody key={group.name}>
                <GroupTitle>{t(group.name)}</GroupTitle>
                {group.features.map(feature => (
                  <FeatureRow key={feature} label={feature} value={plan => !group.liveOnly || plan.live} />
                ))}
              </tbody>
            ))}
          </table>
        </section>
        <aside className="mt-6 flex items-start gap-4 py-2">
          <Icon name="key" size={22} className="mt-1 text-primary" />
          <div>
            <h3 className="font-medium">{t("使用自己的 API 金鑰")}</h3>
            <p className="mt-1 max-w-3xl text-sm leading-relaxed text-stage-muted">{t("所有方案都能自備金鑰使用完整功能，包含會議中的即時功能。用量由你的服務商計費，保留 mm2t 的每月額度。")}</p>
          </div>
        </aside>
      </div>
    </div>
  );
}
