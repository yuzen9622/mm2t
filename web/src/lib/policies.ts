import type { PolicyPage } from "./guide";
import termsZh from "./policies/TERMS.zh.md";
import termsEn from "./policies/TERMS.en.md";
import privacyZh from "./policies/PRIVACY.zh.md";
import privacyEn from "./policies/PRIVACY.en.md";
import refundsZh from "./policies/REFUNDS.zh.md";
import refundsEn from "./policies/REFUNDS.en.md";

function readPolicy(source: string) {
  const [title, revision, ...blocks] = source.trim().split(/\r?\n\r?\n/);
  const date = /^(?:修訂日期：|Revision date: )(\d{4}-\d{2}-\d{2})$/.exec(revision)?.[1];
  if (!title.startsWith("# ") || !date || blocks.length === 0) {
    throw new Error("Expected a policy heading, revision date, and body");
  }

  const [intro, ...sections] = blocks.join("\n\n").split(/^## /m);
  if (!intro.trim() || sections.length === 0) throw new Error("Expected an introduction and policy chapters");

  const chapters = sections.map((section) => {
    const lineEnd = section.indexOf("\n");
    const heading = /^(.+) \{#([a-z0-9]+(?:-[a-z0-9]+)*)\}$/.exec(section.slice(0, lineEnd).trim());
    const body = section.slice(lineEnd + 1).trim();
    if (!heading || !body || lineEnd < 0) throw new Error(`Expected an anchored policy chapter: ${section}`);

    return { title: heading[1], id: heading[2], body };
  });
  if (new Set(chapters.map(({ id }) => id)).size !== chapters.length) {
    throw new Error("Duplicate policy chapter anchor");
  }

  return { date, intro: intro.trim(), sections: chapters };
}

function localizedPolicy(zhSource: string, enSource: string) {
  const zh = readPolicy(zhSource);
  const en = readPolicy(enSource);
  if (
    zh.date !== en.date ||
    zh.sections.length !== en.sections.length ||
    zh.sections.some(({ id }, index) => id !== en.sections[index].id)
  ) {
    throw new Error("Policy translations must share the same revision and chapter order");
  }
  return { zh, en };
}

export const webPolicies = {
  terms: localizedPolicy(termsZh, termsEn),
  privacy: localizedPolicy(privacyZh, privacyEn),
  refunds: localizedPolicy(refundsZh, refundsEn),
} satisfies Record<PolicyPage, ReturnType<typeof localizedPolicy>>;

export const policyCopy = {
  zh: {
    dateLabel: "修訂日期",
    statusLabel: "文件狀態",
    status: "草稿",
    scopeLabel: "適用範圍",
    scopes: {
      terms: "mm2t 雲端服務、帳號、方案與訂閱",
      privacy: "mm2t 雲端服務",
      refunds: "mm2t 雲端服務",
    },
    languageLabel: "語言",
    language: "繁體中文",
    chapters: "章節目錄",
  },
  en: {
    dateLabel: "Revision date",
    statusLabel: "Document status",
    status: "Draft",
    scopeLabel: "Scope",
    scopes: {
      terms: "mm2t cloud services, accounts, plans, and subscriptions",
      privacy: "mm2t cloud services",
      refunds: "mm2t cloud services",
    },
    languageLabel: "Language",
    language: "English",
    chapters: "Contents",
  },
};
