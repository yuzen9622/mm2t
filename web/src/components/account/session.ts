import { accountAPI, AccountAPIError, parseSession, type PaidPlan, type Profile, type Session } from "./api";
import { loadPaddle, openCheckout } from "./paddle";

const storageKey = "mm2t.account";
const focusInterval = 30_000;
export const sections = ["overview", "usage", "billing", "account"] as const;
export type Section = (typeof sections)[number];
type BillingAction = PaidPlan | "portal";
type BillingError = { action: BillingAction; code?: string };
type Snapshot = { kind: "loading" | "signedOut" | "error" }
  | { kind: "ready"; profile: Profile; busy?: BillingAction; billingError?: BillingError };

export function sectionFromHash(hash: string): Section {
  return sections.find((section) => hash === `#${section}`) ?? "overview";
}

function storeSession(session?: Session) {
  try {
    if (session) sessionStorage.setItem(storageKey, JSON.stringify(session));
    else sessionStorage.removeItem(storageKey);
  } catch {}
}

function savedSession() {
  try { return parseSession(JSON.parse(sessionStorage.getItem(storageKey) ?? "null")); }
  catch { return undefined; }
}

function expiresIn(session: Session) { return Date.parse(session.expiresAt) - Date.now(); }
function unauthorized(error: unknown) { return error instanceof AccountAPIError && error.status === 401; }

const initial: Snapshot = { kind: "loading" };
let snapshot: Snapshot = initial;
let started = false;
let session: Session | undefined;
let handoff: string | undefined;
let expiry: ReturnType<typeof setTimeout> | undefined;
let pending: Promise<void> | undefined;
let lastFetch = -Infinity;
let planVersion = 0;
const pollTimers = new Set<ReturnType<typeof setTimeout>>();
const listeners = new Set<() => void>();

function publish(value: Snapshot) {
  snapshot = value;
  for (const listener of listeners) listener();
}

function signOut() {
  clearTimeout(expiry);
  for (const timer of pollTimers) clearTimeout(timer);
  pollTimers.clear();
  session = handoff = undefined;
  storeSession();
  publish({ kind: "signedOut" });
}

function installSession(value?: Session) {
  if (!value || expiresIn(value) <= 0) { signOut(); return; }
  session = value;
  storeSession(value);
  expiry = setTimeout(signOut, expiresIn(value));
}

async function readProfile() {
  const code = handoff;
  if (code) {
    try {
      const redeemed = await accountAPI.redeem(code);
      if (handoff !== code) return;
      handoff = undefined;
      installSession(redeemed);
    } catch (error) {
      if (handoff === code) {
        if (unauthorized(error)) signOut();
        else publish({ kind: "error" });
      }
      return;
    }
  }
  const active = session;
  if (!active) return;
  if (expiresIn(active) <= 0) { signOut(); return; }
  const version = planVersion;
  try {
    lastFetch = Date.now();
    const profile = await accountAPI.me(active.token);
    if (session === active && version === planVersion) {
      publish(snapshot.kind === "ready" ? { ...snapshot, profile } : { kind: "ready", profile });
    }
  } catch (error) {
    if (session !== active) return;
    if (unauthorized(error)) signOut();
    else if (version === planVersion) publish({ kind: "error" });
  }
}

function refresh() {
  pending ??= readProfile().finally(() => { pending = undefined; });
  return pending;
}

function start() {
  if (started) return;
  started = true;
  const fragment = new URLSearchParams(location.hash.slice(1));
  if (fragment.has("handoff")) {
    history.replaceState(history.state, "", location.pathname + location.search);
    storeSession();
    handoff = fragment.get("handoff") || undefined;
    if (!handoff) { signOut(); return; }
  } else {
    installSession(savedSession());
  }
  void refresh();
}

function focus() {
  if (!session) return;
  if (expiresIn(session) <= 0) signOut();
  else if (Date.now() - lastFetch >= focusInterval) void refresh();
}

function retry() {
  publish(initial);
  void refresh();
}

function scheduleCheckoutRefresh(active: Session) {
  if (session !== active) return;
  for (const delay of [2_000, 5_000, 10_000]) {
    const timer = setTimeout(() => {
      pollTimers.delete(timer);
      if (session === active) void refresh();
    }, delay);
    pollTimers.add(timer);
  }
}

async function bill(action: BillingAction) {
  if (!session || snapshot.kind !== "ready" || snapshot.busy) return;
  if (expiresIn(session) <= 0) { signOut(); return; }
  const active = session;
  const currentPlan = snapshot.profile.plan.name;
  publish({ ...snapshot, busy: action, billingError: undefined });
  try {
    if (action === "portal") {
      const url = new URL(await accountAPI.portal(active.token));
      if (url.protocol !== "https:" || url.username || url.password) throw new Error("Invalid billing portal URL");
      if (session === active) location.assign(url.href);
    } else if (currentPlan === "free") {
      if (!process.env.NEXT_PUBLIC_PADDLE_CLIENT_TOKEN) throw new AccountAPIError(503, "billing_unavailable");
      const transaction = await accountAPI.checkout(active.token, action);
      if (session !== active) return;
      const paddle = await loadPaddle();
      if (session === active) openCheckout(paddle, transaction, () => scheduleCheckoutRefresh(active));
    } else {
      const plan = await accountAPI.change(active.token, action);
      if (session === active) {
        planVersion++;
        if (snapshot.kind === "ready") publish({ ...snapshot, profile: { ...snapshot.profile, plan } });
        else { await pending; if (session === active) void refresh(); }
      }
    }
  } catch (error) {
    if (session !== active) return;
    if (unauthorized(error)) signOut();
    else if (snapshot.kind === "ready") {
      publish({ ...snapshot, billingError: { action, code: error instanceof AccountAPIError ? error.code : undefined } });
    }
  } finally {
    if (session === active && snapshot.kind === "ready") publish({ ...snapshot, busy: undefined });
  }
}

export const accountSession = {
  start, focus, retry, signOut, bill,
  getSnapshot: () => snapshot,
  getServerSnapshot: () => initial,
  subscribe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener); }; },
};
