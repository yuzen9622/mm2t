"use client";

import { useRef, useState } from "react";
import { vocabulary } from "@/lib/meeting";
import { cn } from "@/lib/utils";
import { useCopy } from "./i18n";
import { Icon } from "./icon";
import { Dialog, DialogContent, DialogTitle } from "./ui/dialog";

const sources = ["全部", "從修正學習", "手動新增"] as const;
type Source = (typeof sources)[number];
type Editor = { kind: "add" } | { kind: "edit"; term: string } | { kind: "delete" };
const pill = "inline-flex min-h-9 items-center justify-center gap-1 rounded-full px-3 text-[13px] font-medium";

export function VocabularyView() {
  const { locale, t } = useCopy();
  const [words, setWords] = useState(() => vocabulary.map(({ term, auto }) => ({ term: t(term), learned: auto })));
  const [source, setSource] = useState<Source>("全部");
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [editor, setEditor] = useState<Editor | null>(null);
  const [draft, setDraft] = useState("");
  const opener = useRef<HTMLElement | null>(null);
  const searchField = useRef<HTMLInputElement>(null);

  const learned = words.filter((word) => word.learned).length;
  const counts = { 全部: words.length, 從修正學習: learned, 手動新增: words.length - learned };
  const visible = words.filter((word) =>
    (source === "全部" || word.learned === (source === "從修正學習")) &&
    word.term.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()),
  );
  const allSelected = visible.length > 0 && selected.length === visible.length;
  const setFilter = (value: Source) => { setSource(value); setSelected([]); };
  function start(next: Editor) {
    opener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setDraft(next.kind === "edit" ? next.term : "");
    setEditor(next);
  }
  const terms = [...new Set(draft.split(/[,，\n]/).map((term) => term.trim()).filter(Boolean))];
  const additions = terms.filter((term) => !words.some((word) => word.term === term));
  const canSave = editor?.kind === "edit"
    ? terms.length === 1 && terms[0] === draft.trim() && (terms[0] === editor.term || additions.length === 1)
    : additions.length > 0;

  function apply() {
    if (!editor) return;
    if (editor.kind === "delete") {
      setWords(words.filter((word) => !selected.includes(word.term)));
    } else if (!canSave) {
      return;
    } else if (editor.kind === "edit") {
      setWords(words.map((word) => word.term === editor.term ? { ...word, term: terms[0] } : word));
    } else {
      setWords([...additions.map((term) => ({ term, learned: false })), ...words]);
    }
    setSelected([]);
    setEditor(null);
  }

  return (
    <div className="@container">
      <div className="flex items-center justify-end gap-2">
        <label className="flex h-9 min-w-0 max-w-60 flex-1 items-center gap-2 rounded-[10px] bg-(--w-field) px-3">
          <Icon name="search" size={15} className="text-(--w-secondary)" />
          <input ref={searchField} type="search" aria-label={t("搜尋")} placeholder={t("搜尋")} value={query}
            onChange={(event) => { setQuery(event.target.value); setSelected([]); }}
            className="min-w-0 flex-1 bg-transparent text-sm placeholder:text-(--w-secondary)" />
        </label>
        <button type="button" onClick={() => start({ kind: "add" })} className={cn(pill, "bg-(--w-orange) text-white")}>
          <Icon name="plus" size={14} />{t("新增詞彙")}
        </button>
      </div>
      <div className="mt-4 flex items-center justify-between gap-2">
        <select aria-label={t("來源")} value={source} onChange={(event) => setFilter(event.target.value as Source)}
          className="min-h-9 max-w-full rounded-lg bg-(--w-tonal) px-2 text-[13px] @[420px]:hidden">
          {sources.map((item) => <option key={item} value={item}>{t(item)} {counts[item]}</option>)}
        </select>
        <div role="group" aria-label={t("來源")} className="hidden rounded-[10px] bg-(--w-tonal) p-0.5 @[420px]:flex">
          {sources.map((item) => (
            <button type="button" key={item} aria-pressed={item === source} onClick={() => setFilter(item)}
              className="min-h-8 rounded-lg px-2 text-[12px] text-(--w-secondary) aria-pressed:bg-(--w-card) aria-pressed:font-medium aria-pressed:text-(--w-text)">
              {t(item)} {counts[item]}
            </button>
          ))}
        </div>
        <span title={t("儲存逐字稿修正後，mm2t 會將修正的人名和術語加入詞彙庫。")}><Icon name="info" size={15} className="text-(--w-secondary)" /></span>
      </div>
      <div className="my-1 flex min-h-[38px] flex-wrap items-center gap-2 text-xs text-(--w-secondary)">
        <label className="inline-flex min-h-9 items-center gap-2">
          <input type="checkbox" aria-label={t("全選搜尋結果")} checked={allSelected} disabled={!visible.length}
            ref={(node) => { if (node) node.indeterminate = selected.length > 0 && !allSelected; }}
            onChange={() => setSelected(allSelected ? [] : visible.map((word) => word.term))}
            className="size-4 accent-(--w-orange)" />
          {selected.length
            ? (locale === "en" ? `${selected.length} selected` : `已選取 ${selected.length} 個`)
            : (locale === "en" ? `${visible.length} ${visible.length === 1 ? "term" : "terms"}` : `${visible.length} 個詞彙`)}
        </label>
        {selected.length > 0 && <>
          <button type="button" className="ml-auto min-h-9" onClick={() => setSelected([])}>{t("取消選取")}</button>
          <button type="button" className="min-h-9 text-red-700" onClick={() => start({ kind: "delete" })}>{t("刪除")}</button>
        </>}
      </div>
      <ul className="grid grid-cols-[repeat(auto-fit,minmax(min(100%,200px),1fr))] gap-2">
        {visible.map(({ term, learned }) => (
          <li key={term} className="flex min-h-12 items-center gap-2 rounded-[10px] bg-(--w-tonal) pl-3 pr-1 has-checked:bg-(--w-orange-soft)">
            <label className="flex min-h-12 min-w-0 flex-1 cursor-pointer items-center gap-2 text-sm font-medium">
              <input type="checkbox" checked={selected.includes(term)} className="size-4 shrink-0 accent-(--w-orange)"
                onChange={(event) => setSelected(event.target.checked ? [...selected, term] : selected.filter((item) => item !== term))} />
              <span className="break-words [overflow-wrap:anywhere]">{term}</span>
            </label>
            <span title={t(learned ? "從修正學習" : "手動新增")} className="flex text-(--w-secondary)">
              {learned ? <Icon name="sparkles" size={13} className="text-(--w-orange)" /> : <span aria-hidden="true" className="font-serif text-sm">Ⅰ</span>}
            </span>
            <button type="button" aria-label={`${t("編輯詞彙")} · ${term}`} onClick={() => start({ kind: "edit", term })}
              className="grid size-9 shrink-0 place-items-center rounded-lg text-(--w-secondary) hover:bg-(--w-selected)">
              <Icon name="pencil" size={14} />
            </button>
          </li>
        ))}
      </ul>
      {!visible.length && <p className="py-6 text-center text-sm text-(--w-secondary)">{t("沒有符合的結果")}</p>}
      <Dialog open={editor !== null} onOpenChange={(open) => { if (!open) setEditor(null); }}>
        <DialogContent aria-describedby={undefined} className="max-w-sm" onCloseAutoFocus={(event) => {
          event.preventDefault();
          (opener.current?.isConnected ? opener.current : searchField.current)?.focus();
        }}>
          <DialogTitle>{t(editor?.kind === "edit" ? "編輯詞彙" : editor?.kind === "delete" ? "刪除選取的詞彙？" : "新增詞彙")}</DialogTitle>
          {editor?.kind !== "delete" &&
            <label className="grid gap-2 text-sm">
              {editor?.kind === "edit" ? t("詞彙") : t("以逗號或換行分隔，一次新增多個詞彙。")}
              <textarea value={draft} onChange={(event) => setDraft(event.target.value)} rows={editor?.kind === "edit" ? 1 : 3} className="resize-none rounded-lg bg-secondary p-3" />
            </label>}
          <div className="flex justify-end gap-2">
            <button type="button" onClick={() => setEditor(null)} className={cn(pill, "bg-secondary")}>{t("取消")}</button>
            <button type="button" disabled={editor?.kind !== "delete" && !canSave} onClick={apply}
              className={cn(pill, "bg-primary text-primary-foreground disabled:opacity-50")}>
              {t(editor?.kind === "delete" ? "刪除" : editor?.kind === "edit" ? "儲存" : "新增")}
            </button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
