"use client";
import Image from "next/image";
import { useState, type CSSProperties, type ReactNode } from "react";
import { useCopy } from "./i18n";
import { Icon, type IconName } from "./icon";
import { cn } from "@/lib/utils";
import {
  bySpeaker,
  meetingTitle,
  people,
  summary,
  transcript,
  voiceprints,
} from "@/lib/meeting";

/**
 * The mm2t App rebuilt as live HTML from App/MM2T/Design (Palette, Typo, Radius) so it stays crisp
 * at any size. Colors come from `.app-ui` in globals.css; `data-theme="dark"` swaps them.
 */
const nav: { icon: IconName; label: string }[] = [
  { icon: "home", label: "首頁" },
  { icon: "users", label: "人物" },
  { icon: "book", label: "詞彙" },
];

export function AppWindow({
  active = "會議",
  sidebar = true,
  theme = "light",
  className,
  style,
  children,
}: {
  active?: "會議" | "人物" | "詞彙";
  sidebar?: boolean;
  theme?: "light" | "dark";
  className?: string;
  style?: CSSProperties;
  children: ReactNode;
}) {
  const { t } = useCopy();
  return (
    <div
      className={cn("app-ui app-frame @container flex overflow-hidden rounded-[14px] bg-(--w-bg) text-(--w-text)", className)}
      data-theme={theme}
      data-ui=""
      style={style}
    >
      <aside
        className={cn(
          "m-2 hidden w-[180px] @[900px]:w-[204px] shrink-0 flex-col overflow-hidden rounded-[18px] bg-(--w-panel) px-3 pt-2 pb-3 shadow-[0_2px_10px_#0000000a]",
          sidebar && "@[560px]:flex",
        )}
      >
        <div className="mb-5 flex gap-2 pl-1" aria-hidden="true">
          <i className="size-3 rounded-full bg-[#ff5f57]" />
          <i className="size-3 rounded-full bg-[#febc2e]" />
          <i className="size-3 rounded-full bg-[#28c840]" />
        </div>
        <div className="mb-4 flex items-center gap-2.5 px-1.5 text-[15px] font-semibold">
          <Image src="/media/icon.png" width={30} height={30} alt="" /> mm2t
        </div>
        <div className="mb-4 flex h-[38px] shrink-0 items-center gap-2 rounded-[11px] bg-(--w-orange) px-3 text-[14px] font-medium text-white">
          <Icon name="mic" size={16} />{t("開始記錄")}
        </div>
        <ul className="grid gap-0.5">
          {nav.map((item) => (
            <li
              key={item.label}
              className={cn(
                "flex h-9 items-center gap-2.5 rounded-[10px] px-2.5 text-[14px]",
                active === item.label
                  ? "bg-(--w-selected) font-medium text-(--w-text)"
                  : "text-(--w-secondary)",
              )}
            >
              <Icon name={item.icon} size={16} className={active === item.label ? "text-(--w-orange)" : undefined} />
              {t(item.label)}
            </li>
          ))}
        </ul>
        <div className="mt-3 min-h-0 flex-1 overflow-hidden text-(--w-secondary)">
          <div className="flex h-8 items-center gap-2 px-2 text-xs font-medium">
            <Icon name="chevron" size={11} className="rotate-90" />{t("我的資料夾")}
            <Icon name="plus" size={14} className="ml-auto" />
          </div>
          <div className={cn("flex h-[34px] items-center gap-2 rounded-[10px] px-2 text-sm", active === "會議" && "bg-(--w-selected) font-medium text-(--w-text)")}>
            <Icon name="chevron" size={10} className={active === "會議" ? "rotate-90" : undefined} />
            <Icon name="folder" size={16} className={active === "會議" ? "text-(--w-orange)" : undefined} />{t("未分類")}
          </div>
          {active === "會議" && (
            <div className="mt-0.5 ml-5 flex h-7 items-center gap-2 rounded-lg bg-(--w-selected) px-2 text-xs text-(--w-text)">
              <Icon name="file" size={13} className="text-(--w-orange)" /><span title={t(meetingTitle)} className="truncate">{t(meetingTitle)}</span>
            </div>
          )}
        </div>
        <div className="mt-3 flex gap-4 px-2 text-(--w-secondary)">
          <span title={t("設定")}><Icon name="settings" size={16} /></span>
          <span title={t("說明")}><Icon name="help" size={16} /></span>
        </div>
      </aside>
      <div className="flex min-w-0 flex-1 flex-col bg-(--w-bg) text-(--w-text)">
        <div className={cn("flex gap-2 px-5 pt-3.5", sidebar && "@[560px]:hidden")} aria-hidden="true">
          <i className="size-3 rounded-full bg-[#ff5f57]" />
          <i className="size-3 rounded-full bg-[#febc2e]" />
          <i className="size-3 rounded-full bg-[#28c840]" />
        </div>
        {children}
      </div>
    </div>
  );
}

export function Avatar({
  who,
  named = true,
  size = 22,
}: {
  who: number;
  named?: boolean;
  size?: number;
}) {
  const { t } = useCopy();
  const person = people[who];
  return (
    <span
      aria-hidden="true"
      className={cn(
        "grid shrink-0 place-items-center rounded-full font-medium transition-colors duration-300",
        named
          ? "bg-(--w-orange-soft) text-(--w-orange)"
          : "bg-(--w-field) text-(--w-secondary)",
      )}
      style={{ width: size, height: size, fontSize: size * 0.44 }}
    >
      {named ? t(person.initial) : person.code}
    </span>
  );
}

export function MeetingHeader({ tabs }: { tabs: ReactNode }) {
  const { t } = useCopy();
  const actions: IconName[] = ["pencil", "sparkles", "copy", "upload"];
  return (
    <div className="px-5 pt-3.5">
      <div className="flex h-8 items-center gap-3">
        <Icon name="back" size={15} className="text-(--w-secondary)" />
        <h3 className="min-w-0 truncate text-[16px] font-semibold">{t(meetingTitle)}</h3>
        <div className="ml-auto hidden items-center gap-3.5 text-(--w-text) @[640px]:flex">
          {actions.map((name) => (
            <Icon key={name} name={name} size={15} />
          ))}
          <span className="grid size-7 place-items-center rounded-full bg-(--w-orange-soft) text-(--w-orange)">
            <Icon name="users" size={14} />
          </span>
        </div>
      </div>
      <div className="@container/tabs mt-3">{tabs}</div>
    </div>
  );
}

export const viewTabs = ["逐字稿", "整理版逐字稿", "依人彙整", "摘要"] as const;

/** A static copy of the App's segmented control, for views that are not clickable. */
export function StaticTabs({ active }: { active: (typeof viewTabs)[number] }) {
  const { t } = useCopy();
  return (
    <div className="inline-flex max-w-full gap-0.5 overflow-hidden rounded-[10px] bg-(--w-tonal) p-0.5">
      {viewTabs.map((tab) => (
        <span
          key={tab}
          className={cn(
            "rounded-lg px-3 py-1 text-[12px] whitespace-nowrap",
            tab === active
              ? "bg-(--w-card) font-medium text-(--w-text) shadow-[0_1px_2px_#0000000f]"
              : "text-(--w-secondary)",
          )}
        >
          {t(tab)}
        </span>
      ))}
    </div>
  );
}

export function SpeakerPanel({ named = [true, true, true, true] }: { named?: boolean[] }) {
  const { t } = useCopy();
  return (
    <div className="hidden w-[168px] shrink-0 self-start rounded-[14px] bg-(--w-card) p-2 @[720px]:block">
      {people.map((person, i) => (
        <div key={person.name} className="flex h-9 items-center gap-2.5 px-2 text-[13px]">
          <Avatar who={i} named={named[i]} />
          <span className="truncate">
            {named[i] ? t(person.name) : `${t("說話者")} ${person.code}`}
          </span>
        </div>
      ))}
    </div>
  );
}

/** Characters (or English words) as spans indexed for the karaoke CSS in globals.css. */
export function karaokeText(text: string, start: number, locale: string) {
  const parts = locale === "en" ? text.split(/(\s+)/) : Array.from(text);
  let index = start;
  const nodes = parts.map((part, i) => {
    if (/^\s+$/.test(part)) return part;
    const style = { "--i": index++ } as CSSProperties;
    return (
      <span key={i} className="kc" style={style}>
        {part}
      </span>
    );
  });
  return { nodes, end: index };
}

export function TranscriptRows({
  mode,
  karaoke = false,
  named = [true, true, true, true],
  rows = transcript.length,
}: {
  mode: "raw" | "clean";
  karaoke?: boolean;
  named?: boolean[];
  rows?: number;
}) {
  const { t, locale } = useCopy();
  const lines = transcript.slice(0, rows);
  const spansByLine = lines.reduce<ReturnType<typeof karaokeText>[]>(
    (all, line) => [...all, karaokeText(t(line[mode]), all.at(-1)?.end ?? 0, locale)],
    [],
  );
  return (
    <ol className="grid gap-4">
      {lines.map((line, n) => {
        const text = t(line[mode]);
        const spans = karaoke ? spansByLine[n] : null;
        const isNamed = named[line.who];
        return (
          <li key={line.at} className="grid grid-cols-[22px_1fr] gap-x-2.5">
            <Avatar who={line.who} named={isNamed} />
            <div className="min-w-0">
              <div className="flex h-[22px] items-center gap-2 text-[12px]">
                <span className="font-medium">
                  {isNamed ? t(people[line.who].name) : `${t("說話者")} ${people[line.who].code}`}
                </span>
                <time className="font-mono text-[11px] text-(--w-muted) tabular-nums">{line.at}</time>
              </div>
              <p className="mt-1 text-[14px] leading-[1.7]">{spans ? spans.nodes : text}</p>
            </div>
          </li>
        );
      })}
    </ol>
  );
}

function MeetingDocument({ title, sections, completed = [], children }: {
  title: string;
  sections: readonly { title: string; rows: readonly string[] }[];
  completed?: readonly string[];
  children?: ReactNode;
}) {
  const { t } = useCopy();
  return (
    <article className="mx-auto max-w-[720px] space-y-5 px-2 pb-5 text-[16px] leading-[1.55]">
      <header>
        <h4 className="text-2xl font-semibold">{t(title)}</h4>
        <p className="mt-1">{t(meetingTitle)}</p>
      </header>
      {sections.map((block) => (
        <div key={block.title}>
          <h5 className="mb-1.5 text-xl font-semibold">{t(block.title)}</h5>
          <ul className="list-disc space-y-1 pl-6">
            {block.rows.map((row) => <li key={row}>{completed.includes(row) ? <s>✓ {t(row)}</s> : t(row)}</li>)}
          </ul>
        </div>
      ))}
      {children}
    </article>
  );
}

export function SummaryView() {
  const { t } = useCopy();
  const [completed, setCompleted] = useState<string[]>([]);
  return (
    <MeetingDocument title="摘要" sections={summary} completed={completed}>
      <details className="border-t border-(--w-hairline) pt-3 text-sm">
        <summary className="cursor-pointer py-2 font-medium">{t("管理待辦事項")}</summary>
        <ul className="space-y-2 pt-1">
          {summary.find((block) => block.title === "待辦事項")?.rows.map((task) => (
            <li key={task}><label className="flex items-start gap-2">
              <input type="checkbox" className="peer mt-1 accent-(--w-orange)" checked={completed.includes(task)}
                onChange={(event) => setCompleted(event.target.checked ? [...completed, task] : completed.filter((text) => text !== task))} />
              <span className="peer-checked:text-(--w-secondary) peer-checked:line-through">{t(task)}</span>
            </label></li>
          ))}
        </ul>
      </details>
    </MeetingDocument>
  );
}

export function BySpeakerView() {
  return <MeetingDocument title="依人彙整" sections={bySpeaker.map((rows, who) => ({ title: people[who].name, rows }))} />;
}

export function PeopleList() {
  const { t } = useCopy();
  return (
    <ul className="grid gap-2.5">
      {voiceprints.map((row) => (
        <li key={row.who} className="flex items-center gap-2 overflow-hidden rounded-[14px] bg-(--w-card) p-3 shadow-[0_2px_8px_#00000009] @sm:gap-3 @sm:p-4">
          <Image src={`/media/people/sigil-${row.who}.webp`} width={48} height={48} alt="" className="shrink-0" />
          <div className="min-w-0">
            <p className="text-sm font-medium">{t(people[row.who].name)}</p>
            <div className="mt-1 flex flex-wrap items-center gap-1.5 text-xs text-(--w-secondary)">
              <span>{t(`${row.count} 個聲紋`)}</span>
              {row.tags.map((tag) => (
                <span key={tag} className="rounded-full bg-(--w-orange-soft) px-2 py-px text-(--w-orange)">{t(tag)}</span>
              ))}
            </div>
          </div>
          <div className="@container relative flex-1 self-stretch" aria-hidden="true">
            <Image src={`/media/people/watermark-${row.who}.webp`} width={180} height={140} alt="" className="absolute top-1/2 right-0 hidden h-[140px] w-[180px] max-w-none -translate-y-1/2 @[160px]:block" />
          </div>
          <span className="flex shrink-0 items-center gap-3 text-(--w-secondary)">
            <Icon name="pencil" size={15} /><Icon name="trash" size={15} />
          </span>
        </li>
      ))}
    </ul>
  );
}
