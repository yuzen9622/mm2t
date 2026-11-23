const apiURL = process.env.NEXT_PUBLIC_API_URL;

export type PaidPlan = "standard" | "pro";
export type PlanName = "free" | PaidPlan;
export type Plan = {
  name: PlanName;
  status: "active" | "past_due" | "canceling";
  period: { start: string; end: string };
  minutes: { limit: number; usedSeconds: number };
  ai: { asksLimit: number | null; asksUsed: number };
  storedMeetings: { limit: number };
  scheduledChange: { plan: PlanName; at: string } | null;
};
export type Profile = {
  user: { id: string; email: string; name: string };
  quota: { used: number; limit: number; period: string };
  plan: Plan;
};
export type Session = { token: string; expiresAt: string };

function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}
function text(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}
function date(value: unknown): value is string {
  return text(value) && Number.isFinite(Date.parse(value));
}
function count(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}
function planName(value: unknown): value is PlanName {
  return value === "free" || value === "standard" || value === "pro";
}

export function parseSession(value: unknown): Session | undefined {
  const data = record(value);
  if (text(data?.token) && date(data.expiresAt)) return { token: data.token, expiresAt: data.expiresAt };
}

function parsePlan(value: unknown): Plan | undefined {
  const plan = record(value);
  if (!plan || !planName(plan.name)) return;
  const { name, status } = plan;
  if (status !== "active" && status !== "past_due" && status !== "canceling") return;
  const period = record(plan.period);
  const minutes = record(plan.minutes);
  const ai = record(plan.ai);
  const storedMeetings = record(plan.storedMeetings);
  if (!date(period?.start) || !date(period.end) || !count(minutes?.limit) || !count(minutes.usedSeconds) ||
      !count(ai?.asksUsed) || !(ai.asksLimit === null || count(ai.asksLimit)) || !count(storedMeetings?.limit)) return;
  let scheduledChange: Plan["scheduledChange"] = null;
  if (plan.scheduledChange !== null) {
    const change = record(plan.scheduledChange);
    if (!planName(change?.plan) || !date(change.at)) return;
    scheduledChange = { plan: change.plan, at: change.at };
  }
  return {
    name, status, scheduledChange,
    period: { start: period.start, end: period.end },
    minutes: { limit: minutes.limit, usedSeconds: minutes.usedSeconds },
    ai: { asksLimit: ai.asksLimit, asksUsed: ai.asksUsed },
    storedMeetings: { limit: storedMeetings.limit },
  };
}

function parseProfile(value: unknown): Profile | undefined {
  const data = record(value);
  const user = record(data?.user);
  const quota = record(data?.quota);
  const plan = parsePlan(data?.plan);
  if (plan && text(user?.id) && text(user.email) && text(user.name) && count(quota?.used) && count(quota.limit) && text(quota.period)) {
    return { user: { id: user.id, name: user.name, email: user.email }, quota: { used: quota.used, limit: quota.limit, period: quota.period }, plan };
  }
}

export class AccountAPIError extends Error {
  constructor(readonly status: number, readonly code?: string) { super(code ?? String(status)); }
}

async function request<T>(path: string, parse: (value: unknown) => T | undefined, options: {
  token?: string; method?: "GET" | "POST"; body?: object;
} = {}): Promise<T> {
  if (!apiURL) throw new Error("Missing account API URL");
  const { token, method = "GET", body } = options;
  const response = await fetch(`${apiURL.replace(/\/+$/, "")}${path}`, {
    method, cache: "no-store", credentials: "omit", redirect: "error",
    headers: { ...(token && { Authorization: `Bearer ${token}` }), ...(body && { "Content-Type": "application/json" }) },
    body: body && JSON.stringify(body),
  });
  const value: unknown = await response.json().catch(() => undefined);
  if (!response.ok) {
    const code = record(value)?.error;
    throw new AccountAPIError(response.status, text(code) ? code : undefined);
  }
  const parsed = parse(value);
  if (parsed === undefined) throw new Error("Invalid account API response");
  return parsed;
}

const post = (token?: string, body?: object) => ({ method: "POST" as const, token, body });
const stringField = (key: string) => (value: unknown) => {
  const field = record(value)?.[key];
  return text(field) ? field : undefined;
};

export const accountAPI = {
  redeem: (code: string) => request("/v1/billing/handoff/redeem", (value) => {
    const data = record(value);
    return parseSession({ token: data?.accessToken, expiresAt: data?.expiresAt });
  }, post(undefined, { code })),
  me: (token: string) => request("/v1/me", parseProfile, { token }),
  checkout: (token: string, plan: PaidPlan) => request("/v1/billing/checkout", stringField("transactionId"), post(token, { plan })),
  change: (token: string, plan: PaidPlan) => request("/v1/billing/change", (value) => parsePlan(record(value)?.plan), post(token, { plan })),
  portal: (token: string) => request("/v1/billing/portal", stringField("url"), post(token)),
};
