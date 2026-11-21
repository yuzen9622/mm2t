"use client";
import type { ReactNode } from "react";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import { cn } from "@/lib/utils";
import { wrap } from "./shared";

const plans = [
  { name: "Free", fee: 0, firstMonthFee: null, minutes: 120, ai: 30,
    headline: "偶爾開會，會後整理重點",
    features: ["基礎模型轉錄，逐字稿標示每位說話者", "回放原音核對細節", "從會議摘要找回決議"],
  },
  { name: "Standard", fee: 299, firstMonthFee: 199, minutes: 900, ai: "unlimited",
    headline: "每週例會，開會當下就跟上討論",
    features: ["進階模型提供更好的轉錄品質", "邊聽邊看即時字幕", "用即時翻譯跟上外語發言", "會後不限次數向 AI 追問"],
  },
  { name: "Pro", fee: 499, firstMonthFee: 449, minutes: 2400, ai: "unlimited",
    headline: "長時間訪談，留足整月的處理時數",
    features: ["使用與 Standard 相同的進階轉錄模型", "包含 Standard 的所有即時功能", "會後不限次數改寫訪談紀錄"],
  },
] as const;
type Plan = (typeof plans)[number];

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

  const sharedAi = (plan: Plan) => (
    <>{aiQuota(plan)}{plan.ai !== "unlimited" && <small className="mt-1 block text-stage-muted">{t("每月共用")}</small>}</>
  );
  return (
    <div data-ground="stage" className="bg-stage py-8 text-stage-ink md:py-14">
      <div className={wrap}>
        <section aria-label={t("方案概覽")} className="grid border-t border-l border-white/20 md:grid-cols-3">
          {plans.map(plan => (
            <article key={plan.name} className="grid grid-rows-[auto_1fr] border-r border-b border-white/20">
              <h2 className={cn("border-b border-white/20 px-5 py-4 text-xl font-medium md:px-7",
                plan.name === "Pro" && "bg-secondary text-foreground")}>{plan.name}</h2>
              <div className="flex flex-col px-5 pt-5 pb-6 md:px-7">
                {plan.firstMonthFee !== null ? (
                  <>
                    <p className="mb-2 text-base font-semibold text-primary">{t("首次訂購・首月優惠")}</p>
                    <p className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                      <strong className="text-5xl leading-none font-semibold tracking-[-0.05em] xl:text-6xl">NT${plan.firstMonthFee}</strong>
                      <span className="text-lg text-stage-muted">
                        <span className="sr-only">{t("原價")} </span><s>NT${plan.fee}</s>
                      </span>
                    </p>
                    <p className="mt-3 text-sm leading-relaxed text-stage-muted">
                      {t("次月起每人每月")} NT${plan.fee}{t("（含稅）")}
                    </p>
                  </>
                ) : (
                  <>
                    <p className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                      <strong className="text-4xl font-medium tracking-[-0.05em] xl:text-5xl">NT${plan.fee}</strong>
                      <span className="text-sm text-stage-muted">{t("每人每月・含稅")}</span>
                    </p>
                    {plan.name === "Free" && <p className="mt-2 text-sm leading-relaxed text-stage-muted">{t("免費額度每月重置")}</p>}
                  </>
                )}
                <h3 className="mt-6 border-t border-white/20 pt-5 text-lg font-medium">{t(plan.headline)}</h3>
                <ul className="mt-3 mb-5 grid gap-2">
                  {plan.features.map(feature => (
                    <li key={feature} className="flex items-start gap-2 text-sm leading-relaxed">
                      <Icon name="check" size={16} className="mt-1" />{t(feature)}
                    </li>
                  ))}
                </ul>
                <dl className="mt-auto grid gap-3 border-t border-white/20 pt-5 text-sm">
                  <div><dt className="text-stage-muted">{t("雲端會議處理")}</dt>
                    <dd className="mt-1"><span className="text-xl font-medium">{plan.minutes / 60} {t("小時")}</span> ({minutes(plan)})</dd></div>
                  <div><dt className="text-stage-muted">{t("AI 使用額度")}</dt>
                    <dd className="mt-1">{aiQuota(plan)}</dd></div>
                </dl>
              </div>
            </article>
          ))}
        </section>
        <section className="mt-12 md:mt-16" aria-labelledby="features">
          <h2 id="features" className="mb-5 text-2xl font-medium tracking-tight md:text-3xl">{t("各方案功能對照")}</h2>
          <p className="mb-5 text-sm text-stage-muted">{t("Free 的單場 AI 助理與跨場會議整理合計每月可用 30 次。")}{" "}
            <a className="underline underline-offset-4 hover:text-stage-ink" href="#own-key">{t("自備金鑰可使用全部功能")}</a>
          </p>
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
              <FeatureRow label="AI 使用額度" value={aiQuota} />
            </tbody>
            <tbody>
              <GroupTitle>{t("轉錄品質與即時功能")}</GroupTitle>
              <FeatureRow label="轉錄模型" value={plan => t(plan.name === "Free" ? "基礎模型" : "進階模型")} />
              {["即時字幕", "即時轉錄", "即時翻譯"].map(label => <FeatureRow key={label} label={label} value={plan => plan.name !== "Free"} />)}
            </tbody>
            <tbody>
              <GroupTitle>{t("跨場會議整理")}</GroupTitle>
              <FeatureRow label="向 AI 查詢多場會議的決議" value={sharedAi} />
              <FeatureRow label="由 AI 建議會議資料夾分類" value={sharedAi} />
            </tbody>
            <tbody>
              <GroupTitle>{t("錄音與會後整理")}</GroupTitle>
              {["錄音", "會後逐字稿", "說話者辨識", "摘要", "待辦事項", "回放", "匯出"].map(label => <FeatureRow key={label} label={label} value={() => true} />)}
            </tbody>
            <tbody>
              <GroupTitle>{t("單場會議 AI 助理")}</GroupTitle>
              <FeatureRow label="AI 提問" value={sharedAi} />
              <FeatureRow label="AI 改寫" value={sharedAi} />
            </tbody>
          </table>
        </section>
        <aside id="own-key" className="scroll-mt-24 mt-6 flex items-start gap-4 py-2">
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
