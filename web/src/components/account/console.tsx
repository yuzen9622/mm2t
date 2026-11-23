"use client";

import { useEffect, useSyncExternalStore, type MouseEvent, type ReactNode } from "react";
import { IconChartBar, IconCreditCard, IconLayoutDashboard, IconUserCircle } from "@tabler/icons-react";
import { LanguageProvider } from "@/components/i18n";
import { Brand, DownloadButton, wrap } from "@/components/marketing/shared";
import { cn } from "@/lib/utils";
import { copy, type AccountLocale } from "./copy";
import { Account, Billing, Overview, Usage } from "./sections";
import { accountSession, sectionFromHash, sections, type Section } from "./session";
import { Action, focus, Panel, settingsRow, textLink } from "./shared";

const icons = { overview: IconLayoutDashboard, usage: IconChartBar, billing: IconCreditCard, account: IconUserCircle };
const fullWrap = cn(wrap, "max-md:w-[calc(100%_-_32px)]");
const heading = "text-[28px] font-medium tracking-[-0.02em]";
const sectionEvent = "mm2t:account-section";

function subscribeSection(listener: () => void) {
  window.addEventListener(sectionEvent, listener);
  window.addEventListener("hashchange", listener);
  return () => {
    window.removeEventListener(sectionEvent, listener);
    window.removeEventListener("hashchange", listener);
  };
}
const getSection = () => sectionFromHash(location.hash);
const defaultSection = (): Section => "overview";

function select(section: Section, event?: MouseEvent<HTMLAnchorElement>) {
  if (event && (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)) return;
  event?.preventDefault();
  history.replaceState(history.state, "", `#${section}`);
  window.dispatchEvent(new Event(sectionEvent));
}

function Skeleton({ section }: { section: Section }) {
  const heights = section === "billing" ? ["h-24", "h-48"] : section === "usage" ? ["h-5", "h-48"] : ["h-24", "h-40"];
  return <div aria-hidden="true" className="space-y-4">
    {heights.map((height) => <div key={height} className={cn("animate-pulse rounded-lg bg-secondary motion-reduce:animate-none", height)} />)}
  </div>;
}

function Console({ locale }: { locale: AccountLocale }) {
  const t = copy[locale];
  const pricing = locale === "zh" ? "/pricing/" : "/en/pricing/";
  const snapshot = useSyncExternalStore(accountSession.subscribe, accountSession.getSnapshot, accountSession.getServerSnapshot);
  const section = useSyncExternalStore(subscribeSection, getSection, defaultSection);
  const profile = snapshot.kind === "ready" ? snapshot.profile : undefined;
  const user = profile?.user;

  useEffect(() => {
    accountSession.start();
    window.addEventListener("focus", accountSession.focus);
    return () => window.removeEventListener("focus", accountSession.focus);
  }, []);

  let content: ReactNode;
  if (snapshot.kind === "loading") content = <Skeleton section={section} />;
  if (snapshot.kind === "error") content = <Panel><div className={settingsRow}>
    <p role="alert">{t.fetchError}</p><Action onClick={accountSession.retry}>{t.retry}</Action>
  </div></Panel>;
  if (snapshot.kind === "ready") {
    const { profile, busy, billingError } = snapshot;
    const language = locale === "zh" ? "zh-Hant" : "en";
    const formats = {
      date: new Intl.DateTimeFormat(language, { year: "numeric", month: "long", day: "numeric" }),
      number: new Intl.NumberFormat(language, { maximumFractionDigits: 1 }),
    };
    switch (section) {
      case "overview": content = <Overview plan={profile.plan} t={t} formats={formats} pricing={pricing} select={select} />; break;
      case "usage": content = <Usage profile={profile} t={t} formats={formats} />; break;
      case "billing": content = <Billing plan={profile.plan} t={t} formats={formats} pricing={pricing} busy={busy} error={billingError} />; break;
      case "account": content = <Account user={profile.user} t={t} />; break;
    }
  }

  return <div className="min-h-svh bg-background text-foreground">
    <header className="h-16 border-b border-border">
      <div className={cn(fullWrap, "flex h-full items-center justify-between gap-2")}>
        <div className="shrink-0 [&_a]:rounded-sm [&_a:focus-visible]:ring-2 [&_a:focus-visible]:ring-ring"><Brand wordmark /></div>
        <div className="flex min-w-0 items-center gap-3 md:gap-6">
          <a href={pricing} className={cn(textLink, "whitespace-nowrap")}>{t.pricing}</a>
          <a href={locale === "zh" ? "/en/account/" : "/account/"} hrefLang={locale === "zh" ? "en" : "zh-Hant"}
            lang={locale === "zh" ? "en" : "zh-Hant"} className={cn(textLink, "whitespace-nowrap")}>{t.language}</a>
          {user && <span aria-hidden="true" className="grid size-8 shrink-0 place-items-center rounded-full bg-secondary text-sm font-medium">
            {Array.from(user.name.trim() || user.email)[0]?.toLocaleUpperCase()}
          </span>}
        </div>
      </div>
    </header>
    {snapshot.kind === "signedOut" ? <main className="mx-auto w-[calc(100%_-_32px)] max-w-md pt-[max(2rem,calc(30svh_-_4rem))] pb-10 text-center">
      <h1 className={heading}>{t.openFromApp}</h1>
      <p className="mt-3 text-sm text-muted-foreground">{t.openInstructions}</p>
      <div className="mt-6 flex flex-wrap justify-center gap-3">
        <DownloadButton className="focus-visible:ring-2 focus-visible:ring-ring" />
        <Action href={pricing}>{t.seePlans}</Action>
      </div>
    </main> : <div className={cn(fullWrap, "grid min-w-0 gap-6 pt-4 pb-12 md:grid-cols-[232px_1fr] md:gap-12 md:pt-10")}>
      <aside className="min-w-0 self-start md:sticky md:top-24">
        <nav aria-label={t.nav} className="flex gap-1 overflow-x-auto p-0.5 md:flex-col md:overflow-visible">
          {sections.map((item) => {
            const Icon = icons[item];
            return <a key={item} href={`#${item}`} onClick={(event) => select(item, event)} aria-current={section === item ? "page" : undefined}
              className={cn(focus, "inline-flex h-9 shrink-0 items-center gap-2 rounded-full px-3 text-sm whitespace-nowrap md:h-10 md:rounded-lg",
                section === item ? "bg-secondary font-medium text-foreground" : "text-muted-foreground hover:bg-secondary/60")}>
              <Icon size={18} stroke={1.75} aria-hidden="true" />{t[item]}
            </a>;
          })}
        </nav>
        {user && <div className="mt-6 hidden min-w-0 border-t border-border px-3 pt-4 md:block">
          <p className="truncate text-sm font-medium" title={user.name}>{user.name}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground" title={user.email}>{user.email}</p>
        </div>}
      </aside>
      <main className="min-w-0 max-w-[760px]" aria-busy={snapshot.kind === "loading"}>
        <h1 className={cn(heading, "mb-8")}>{t[section]}</h1>
        <div className="space-y-6">{content}</div>
      </main>
    </div>}
  </div>;
}

export function AccountConsole({ locale }: { locale: AccountLocale }) {
  return <LanguageProvider locale={locale}><Console locale={locale} /></LanguageProvider>;
}
