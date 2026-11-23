import type { ReactNode } from "react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import type { AccountCopy } from "./copy";

export const focus = "rounded-sm focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none";
export const textLink = cn(focus, "text-sm font-medium underline-offset-4 hover:underline");
export const row = "min-w-0 px-5 py-4 md:px-6";
export const settingsRow = cn(row, "flex items-center justify-between gap-3 text-sm");

export function Action({ primary = false, href, children, disabled, onClick }: {
  primary?: boolean; href?: string; children: ReactNode; disabled?: boolean; onClick?: () => void;
}) {
  const style = { size: "sm" as const, variant: primary ? "default" as const : "secondary" as const, className: "hover:shadow-none" };
  return href ? <Button {...style} asChild><a href={href}>{children}</a></Button>
    : <Button {...style} type="button" disabled={disabled} onClick={onClick}>{children}</Button>;
}

export function Panel({ title, children }: { title?: string; children: ReactNode }) {
  return <div className="min-w-0">
    {title && <h2 className="mb-3 text-sm font-medium text-muted-foreground">{title}</h2>}
    <div className="divide-y divide-border rounded-2xl border border-border bg-card">{children}</div>
  </div>;
}

export function Meter({ label, used, limit, unit, t, number, hours = false }: {
  label: string; used: number; limit: number | null; unit: string; t: AccountCopy;
  number: Intl.NumberFormat; hours?: boolean;
}) {
  const format = (value: number) => number.format(value);
  if (limit === null) return <div className={cn(settingsRow, "flex-wrap")}>
    <span>{label}</span>
    <span className="flex flex-wrap items-baseline justify-end gap-x-2 tabular-nums">
      <span>{t.used(format(used))}</span><span className="text-muted-foreground">{t.unlimited}</span>
    </span>
  </div>;
  const fraction = limit > 0 ? Math.min(used / limit, 1) : 0;
  const exact = `${format(used)} / ${format(limit)} ${unit}`;
  const value = hours ? `${format(used / 60)} / ${format(limit / 60)} ${t.hour}` : exact;
  return <div className={row}>
    <div className="mb-2 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1 text-sm">
      <span>{label}</span>
      <span className="tabular-nums">{value}{hours && <span className="ml-2 text-xs text-muted-foreground">({exact})</span>}</span>
    </div>
    <div role="meter" aria-label={label} aria-valuemin={0} aria-valuemax={limit} aria-valuenow={Math.min(used, limit)} aria-valuetext={exact}
      className="h-1.5 overflow-hidden rounded-full bg-secondary">
      <div className={cn("h-full rounded-full", fraction >= .9 ? "bg-[#c2410c]" : "bg-primary")} style={{ width: `${fraction * 100}%` }} />
    </div>
  </div>;
}
