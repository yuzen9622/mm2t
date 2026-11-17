"use client";
import type { CSSProperties, ReactNode } from "react";
import { useCopy } from "./i18n";
import { Icon, type IconName } from "./icon";
import { cn } from "@/lib/utils";
import {
  bySpeaker,
  meetingTitle,
  people,
  summary,
  transcript,
  vocabulary,
  voiceprints,
} from "@/lib/meeting";

/**
 * The mm2t App rebuilt as live HTML from App/MM2T/Design (Palette, Typo, Radius) so it stays crisp
 * at any size. Colors come from `.app-ui` in globals.css; `data-theme="dark"` swaps them.
 */
const nav: { icon: IconName; label: string }[] = [
  { icon: "home", label: "首頁" },
  { icon: "messages", label: "會議" },
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
  active?: string;
  sidebar?: boolean;
  theme?: "light" | "dark";
  className?: string;
  style?: CSSProperties;
  children: ReactNode;
}) {
  const { t } = useCopy();
  return (
    <div
      className={cn("app-ui app-frame @container flex overflow-hidden rounded-[14px]", className)}
      data-theme={theme}
      data-ui=""
      style={style}
    >
      <aside
        className={cn(
          "hidden w-[164px] shrink-0 flex-col bg-(--w-side) px-2.5 pt-3.5 pb-3",
          sidebar && "@[560px]:flex",
        )}
      >
        <div className="mb-6 flex gap-2 pl-1.5" aria-hidden="true">
          <i className="size-3 rounded-full bg-[#ff5f57]" />
          <i className="size-3 rounded-full bg-[#febc2e]" />
          <i className="size-3 rounded-full bg-[#28c840]" />
        </div>
        <ul className="grid gap-1">
          {nav.map((item) => (
            <li
              key={item.label}
              className={cn(
                "flex h-8 items-center gap-2.5 rounded-lg px-2.5 text-[13px]",
                active === item.label
                  ? "bg-(--w-orange-soft) font-medium text-(--w-orange)"
                  : "text-(--w-text)",
              )}
            >
              <Icon name={item.icon} size={15} />
              {t(item.label)}
            </li>
          ))}
        </ul>
        <div className="mt-auto flex h-8 items-center gap-2.5 px-2.5 text-[13px] text-(--w-text)">
          <Icon name="settings" size={15} />
          {t("設定")}
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
  const actions: IconName[] = ["play", "pencil", "copy", "upload"];
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
      <div className="mt-3">{tabs}</div>
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

function RowList({ rows }: { rows: readonly (readonly [string, string])[] }) {
  const { t } = useCopy();
  return (
    <ul className="grid gap-2">
      {rows.map(([text, at]) => (
        <li key={at} className="grid grid-cols-[1fr_auto] gap-6 text-[13px] leading-[1.6]">
          <span>{t(text)}</span>
          <time className="font-mono text-[11px] leading-[21px] text-(--w-secondary) tabular-nums">{at}</time>
        </li>
      ))}
    </ul>
  );
}

export function SummaryView() {
  const { t } = useCopy();
  return (
    <div className="grid gap-3">
      {summary.map((block) => (
        <section key={block.title} className="rounded-[14px] bg-(--w-card) px-4 py-3.5">
          <h4 className="mb-2 text-[12px] font-medium text-(--w-secondary)">{t(block.title)}</h4>
          <RowList rows={block.rows} />
        </section>
      ))}
    </div>
  );
}

export function BySpeakerView() {
  const { t } = useCopy();
  return (
    <div className="grid gap-3">
      {bySpeaker.map((rows, who) => (
        <section key={people[who].name} className="rounded-[14px] bg-(--w-card) px-4 py-3.5">
          <h4 className="mb-2.5 flex items-center gap-2 text-[14px] font-medium">
            <Avatar who={who} />
            {t(people[who].name)}
          </h4>
          <RowList rows={rows} />
        </section>
      ))}
    </div>
  );
}

export function PeopleList() {
  const { t } = useCopy();
  return (
    <ul className="grid gap-2.5">
      {voiceprints.map((row) => (
        <li key={row.who} className="flex items-center gap-3 rounded-[14px] bg-(--w-card) px-4 py-3">
          <Avatar who={row.who} size={36} />
          <div className="min-w-0">
            <p className="text-[14px] font-medium">{t(people[row.who].name)}</p>
            <p className="mt-1 flex flex-wrap items-center gap-1.5 text-[12px] text-(--w-secondary)">
              {t(`${row.count} 個聲紋`)}
              {row.tags.map((tag) => (
                <span key={tag} className="rounded-md bg-(--w-orange-soft) px-1.5 py-px font-medium text-(--w-orange)">
                  {t(tag)}
                </span>
              ))}
            </p>
          </div>
          <span className="ml-auto flex gap-4 text-(--w-text)">
            <Icon name="pencil" size={15} />
            <Icon name="trash" size={15} />
          </span>
        </li>
      ))}
    </ul>
  );
}

export function VocabularyView() {
  const { t } = useCopy();
  const auto = vocabulary.filter((word) => word.auto).length;
  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center gap-3">
        <h3 className="text-[18px] font-semibold">{t("詞彙")}</h3>
        <div className="ml-auto flex rounded-[10px] bg-(--w-tonal) p-0.5 text-[12px]">
          <span className="rounded-lg bg-(--w-card) px-2.5 py-1 font-medium shadow-[0_1px_2px_#0000000f]">
            {t("全部")} {vocabulary.length}
          </span>
          <span className="px-2.5 py-1 text-(--w-secondary)">
            {t("自動新增")} {auto}
          </span>
        </div>
      </div>
      <div className="flex items-center gap-2">
        <span className="flex h-9 min-w-0 flex-1 items-center rounded-[10px] bg-(--w-field) px-3 text-[13px]">
          {t("新品發表會")}
          <i className="ml-px h-4 w-px bg-[#2f6fe4]" aria-hidden="true" />
        </span>
        <span className="flex h-9 items-center gap-1.5 rounded-full bg-(--w-orange) px-3.5 text-[13px] font-medium text-white">
          <Icon name="plus" size={13} />
          {t("新增")}
        </span>
      </div>
      <ul className="flex flex-wrap gap-2">
        {vocabulary.map((word) => (
          <li
            key={word.term}
            className="flex h-8 items-center gap-1.5 rounded-full bg-(--w-card) px-3 text-[13px] ring-1 ring-(--w-hairline)"
          >
            {word.auto && <Icon name="sparkles" size={12} className="text-(--w-orange)" />}
            {t(word.term)}
            <Icon name="close" size={11} className="text-(--w-muted)" />
          </li>
        ))}
      </ul>
    </div>
  );
}
