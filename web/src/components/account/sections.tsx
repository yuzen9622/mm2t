import type { MouseEvent } from "react";
import { cn } from "@/lib/utils";
import type { PaidPlan, Plan, Profile } from "./api";
import { planNames, type AccountCopy } from "./copy";
import { accountSession, type Section } from "./session";
import { Action, Meter, Panel, row, settingsRow, textLink } from "./shared";

type Formatting = { date: Intl.DateTimeFormat; number: Intl.NumberFormat };
const paidHours = { standard: 15, pro: 40 } as const;
const paidPlans = ["standard", "pro"] as const;

function PlanDescription({ plan, t, date }: { plan: Plan; t: AccountCopy; date: Intl.DateTimeFormat }) {
  const end = date.format(new Date(plan.period.end));
  const change = plan.scheduledChange;
  const status = plan.status === "past_due" ? t.pastDue
    : change ? t.scheduled(date.format(new Date(change.at)), planNames[change.plan])
    : plan.status === "canceling" ? t.ends(end) : t.resets(end);
  return <div className="min-w-0">
    <p className="text-2xl font-medium">{planNames[plan.name]}</p>
    <p className={cn("mt-1 text-sm", plan.status === "past_due" ? "text-[#c2410c]" : "text-muted-foreground")}>{status}</p>
  </div>;
}

function CloudMeters({ plan, t, number, hours }: { plan: Plan; t: AccountCopy; number: Intl.NumberFormat; hours?: boolean }) {
  return <>
    <Meter t={t} number={number} label={t.transcription} used={Math.floor(plan.minutes.usedSeconds / 60)}
      limit={plan.minutes.limit} unit={t.minute} hours={hours && plan.minutes.limit >= 60} />
    <Meter t={t} number={number} label={t.ai} used={plan.ai.asksUsed} limit={plan.ai.asksLimit} unit={t.ask} />
  </>;
}

export function Overview({ plan, t, formats, pricing, select }: {
  plan: Plan; t: AccountCopy; formats: Formatting; pricing: string;
  select: (section: Section, event?: MouseEvent<HTMLAnchorElement>) => void;
}) {
  return <>
    <Panel>
      <div className={settingsRow}>
        <PlanDescription plan={plan} t={t} date={formats.date} />
        {plan.name === "free" ? <Action href={pricing} primary>{t.upgrade}</Action>
          : <Action onClick={() => select("billing")}>{t.managePlan}</Action>}
      </div>
    </Panel>
    <Panel>
      <CloudMeters plan={plan} t={t} number={formats.number} />
      <div className={row}><a className={textLink} href="#usage" onClick={(event) => select("usage", event)}>{t.viewUsage}</a></div>
    </Panel>
  </>;
}

export function Usage({ profile, t, formats }: { profile: Profile; t: AccountCopy; formats: Formatting }) {
  const { plan, quota } = profile;
  const { date, number } = formats;
  return <>
    <p className="text-sm text-muted-foreground">{date.format(new Date(plan.period.start))} – {date.format(new Date(plan.period.end))}</p>
    <Panel title={t.allowance}>
      <CloudMeters plan={plan} t={t} number={number} hours />
      <Meter t={t} number={number} label={t.rooms} used={quota.used} limit={quota.limit} unit={t.room} />
    </Panel>
    {plan.storedMeetings.limit > 0 && <Panel title={t.storage}>
      <div className={settingsRow}>
        <span>{t.meetingsKept}</span><span className="shrink-0 tabular-nums">{number.format(plan.storedMeetings.limit)} {t.meeting}</span>
      </div>
    </Panel>}
  </>;
}

export function Billing({ plan, t, formats, pricing, busy, error }: {
  plan: Plan; t: AccountCopy; formats: Formatting; pricing: string;
  busy?: PaidPlan | "portal"; error?: { action: PaidPlan | "portal"; code?: string };
}) {
  const free = plan.name === "free";
  const messages = t.errors;
  const message = error?.code && Object.hasOwn(messages, error.code) ? messages[error.code as keyof typeof messages] : messages.other;
  return <>
    <Panel title={t.currentPlan}><div className={row}><PlanDescription plan={plan} t={t} date={formats.date} /></div></Panel>
    <div>
      <Panel title={t.changePlan}>
        <div className={row}>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            {paidPlans.map((name) => {
              const current = name === plan.name;
              return <div key={name} className={cn("min-w-0 rounded-xl border p-5", current ? "border-foreground" : "border-border")}>
                <p className="text-lg font-medium">{planNames[name]}</p>
                <ul className="mt-2 mb-4 space-y-1 text-sm text-muted-foreground">
                  <li>{t.includedTranscription(paidHours[name])}</li><li>{t.includedAI}</li>
                </ul>
                <Action primary={free} disabled={current || !!busy} onClick={() => void accountSession.bill(name)}>
                  {busy === name ? t.working : current ? t.currentPlan : free ? t.choose : t.switchPlan}
                </Action>
              </div>;
            })}
          </div>
          <a className={cn(textLink, "mt-4 inline-block")} href={pricing}>{t.compare}</a>
        </div>
      </Panel>
      {error && error.action !== "portal" && <p className="mt-3 text-sm text-[#c2410c]" role="alert">{message}</p>}
    </div>
    {!free && <div>
      <Panel title={t.invoices}>
        <div className={settingsRow}>
          <span>{t.paymentMethod}</span>
          <Action disabled={!!busy} onClick={() => void accountSession.bill("portal")}>{busy === "portal" ? t.working : t.manage}</Action>
        </div>
      </Panel>
      {error?.action === "portal" && <p className="mt-3 text-sm text-[#c2410c]" role="alert">{message}</p>}
    </div>}
  </>;
}

export function Account({ user, t }: { user: Profile["user"]; t: AccountCopy }) {
  return <>
    <Panel>
      {(["name", "email"] as const).map((key) => <div className={settingsRow} key={key}>
        <span className="shrink-0">{t[key]}</span><span className="truncate text-right" title={user[key]}>{user[key]}</span>
      </div>)}
    </Panel>
    <Panel>
      <div className={settingsRow}><span>{t.signOutRow}</span><Action onClick={accountSession.signOut}>{t.signOut}</Action></div>
    </Panel>
  </>;
}
