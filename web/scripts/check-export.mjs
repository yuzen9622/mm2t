import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const root = fileURLToPath(new URL("../out/", import.meta.url));
const changelogSource = fs.readFileSync(new URL("../../CHANGELOG.md", import.meta.url), "utf8");
const guidePages = ["models", "pricing", "changelog"];
const policyPages = {
  terms: { "zh-Hant": "雲端服務條款", en: "Terms for Cloud Services", sections: 16, required: ["app", "account", "cloud-access", "resale-and-redistribution", "acceptable-use", "enforcement-and-remedies", "plans", "subscriptions-and-payment", "cancellation-and-refunds", "liability"] },
  privacy: { "zh-Hant": "雲端服務隱私權政策", en: "Privacy Policy for Cloud Services", sections: 12, required: ["account-and-billing", "cloud-processing", "sharing", "deleting-data", "rights", "security", "contact"] },
  refunds: { "zh-Hant": "雲端服務退款政策", en: "Refund Policy for Cloud Services", sections: 7, required: ["transactions", "cancellation", "requesting-a-refund", "refund-processing", "consumer-rights"] },
};
const policyPaths = Object.keys(policyPages);
const chapterIdsByPage = new Map();
const revisionByPage = new Map();
const policyLink = /^(?:\/en)?\/(?:terms|privacy|refunds)\/$/;
const linksIn = (html) => [...html.matchAll(/<a\b[^>]*\bhref="([^"]+)"[^>]*>/g)];
for (const [route, lang] of [
  ["index.html", "zh-Hant"],
  ["en/index.html", "en"],
  ["models/index.html", "zh-Hant"],
  ["en/models/index.html", "en"],
  ["pricing/index.html", "zh-Hant"],
  ["en/pricing/index.html", "en"],
  ["changelog/index.html", "zh-Hant"],
  ["en/changelog/index.html", "en"],
  ...policyPaths.flatMap(page => [[`${page}/index.html`, "zh-Hant"], [`en/${page}/index.html`, "en"]]),
]) {
  const html = fs.readFileSync(path.join(root, route), "utf8");
  assert.match(html, /<svg\b[^>]*\btabler-icon\b/, `${route}: missing Tabler React icons`);
  assert(!html.includes("/icons/tabler/"), `${route}: references a legacy icon file`);
  const ids = new Set(
    [...html.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]),
  );
  const assets = new Set(
    [...html.matchAll(/(?:src|href)="(\/[^"?#]*)/g)].map((match) => match[1]),
  );
  for (const [, id] of html.matchAll(/href="#([^"]+)"/g))
    assert(ids.has(id), `${route}: missing anchor #${id}`);
  for (const asset of assets)
    assert(
      fs.existsSync(path.join(root, asset)),
      `${route}: missing asset ${asset}`,
    );
  assert.equal(
    [...html.matchAll(/<h1\b/g)].length,
    1,
    `${route}: expected one primary heading`,
  );
  assert(
    html.includes(`lang="${lang}"`),
    `${route}: incorrect document language`,
  );
  assert(
    !/https?:\/\/localhost[^"<]*\/(?:media|icon)/.test(html),
    `${route}: localhost social image`,
  );
  assert(
    html.includes("https://github.com/yuzen9622/mm2t/releases/latest"),
    "Download must reach the official release",
  );
  const page = route.split("/").at(-2);
  const guide = guidePages.includes(page);
  const policy = policyPages[page];
  if (!policy) {
    assert(
      html.includes("data-enter") && html.includes("m-enter"),
      "The hero entrance must be gated by the m-enter head script",
    );
  }
  const localRoot = lang === "en" ? "/en/" : "/";
  const otherRoot = lang === "en" ? "/" : "/en/";
  for (const name of guidePages)
    assert(html.includes(`href="${localRoot}${name}/"`), `${route}: missing ${name} navigation`);
  const header = html.match(/<header\b[^>]*>[\s\S]*?<\/header>/)?.[0] ?? "";
  const switchHref = `${otherRoot}${guide || policy ? page + "/" : ""}`;
  assert(
    linksIn(header).some(([tag, href]) => href === switchHref && /\bhrefLang=/i.test(tag)),
    `${route}: missing language switch`,
  );

  const footer = html.match(/<footer\b[^>]*>[\s\S]*?<\/footer>/)?.[0] ?? "";
  const footerPolicies = linksIn(footer).filter(([, href]) => policyLink.test(href));
  assert.deepEqual(
    footerPolicies.map(([, href]) => href),
    policyPaths.map(name => `${localRoot}${name}/`),
    `${route}: expected three local policy links in footer order`,
  );
  assert(footerPolicies.every(([tag]) => !/\btarget=/.test(tag)), `${route}: policy links must open in the same tab`);
  const outsideFooter = linksIn(html.replace(footer, "")).filter(([, href]) => policyLink.test(href));
  assert.deepEqual(
    outsideFooter.map(([, href]) => href),
    policy ? [switchHref] : [],
    `${route}: policy navigation must stay in the footer except for the same-document language switch`,
  );
  assert(
    linksIn(html).every(([, href]) => !/(?:TERMS|PRIVACY)\.md(?:$|[?#])/.test(href)),
    `${route}: old policy document link`,
  );

  if (policy) {
    assert(html.includes(`<title>${policy[lang]} · mm2t</title>`), `${route}: incorrect policy title`);
    assert(html.includes(`>${policy[lang]}</h1>`), `${route}: incorrect policy heading`);
    const description = html.match(/<meta name="description" content="([^"]+)"/)?.[1];
    assert(description, `${route}: missing policy description`);
    assert.match(html, /<meta name="robots" content="noindex"/, `${route}: draft must not be indexed`);
    const main = html.match(/<main\b[^>]*>[\s\S]*?<\/main>/)?.[0] ?? "";
    assert.equal([...main.matchAll(/data-policy-status="draft"/g)].length, 1, `${route}: expected one draft status`);
    assert(main.includes(lang === "en" ? ">Draft</dd>" : ">草稿</dd>"), `${route}: missing localized draft status`);
    const date = main.match(/<time dateTime="(\d{4}-\d{2}-\d{2})"/)?.[1];
    assert(date && main.includes(lang === "en" ? ">Revision date</dt>" : ">修訂日期</dt>"), `${route}: missing revision date`);
    if (revisionByPage.has(page)) assert.equal(date, revisionByPage.get(page), `${route}: inconsistent revision date`);
    revisionByPage.set(page, date);

    const copy = main.replace(/<[^>]+>/g, " ");
    const cloudServices = lang === "en" ? /cloud services/i : /雲端服務/;
    assert.match(copy, cloudServices, `${route}: missing cloud services scope`);
    assert.match(description, cloudServices, `${route}: missing cloud services description`);
    assert.doesNotMatch(copy + description, /託管|自架|本機|自備金鑰|聲紋|網站|\b(?:hosted|byok|on-device|open.source|agpl|sparkle|github|website|voiceprints?)\b|macOS/i, `${route}: policy includes material outside cloud services`);
    const contactLinks = linksIn(main).filter(([, href]) => href.startsWith("mailto:"));
    assert.deepEqual(contactLinks.map(([, href]) => href), ["mailto:oscar48079@gmail.com"], `${route}: missing approved support email`);
    assert.doesNotMatch(copy, /但書|除非|尚待|待確認|未經確認|未涵蓋|沒有自己的伺服器|沒有帳號系統|原始碼|\b(?:unless|however|except|pending confirmation|source code|endpoint)\b|no servers of its own|no account system|paid cloud services fall outside/i, `${route}: exception, implementation detail, or superseded policy text`);

    const chapters = [...html.matchAll(/<h2 id="([^"]+)"/g)].map(([, id]) => id);
    assert.equal(chapters.length, policy.sections, `${route}: incorrect chapter count`);
    for (const id of policy.required) assert(chapters.includes(id), `${route}: missing required chapter #${id}`);
    assert.equal(new Set(chapters).size, chapters.length, `${route}: duplicate chapter anchors`);
    if (chapterIdsByPage.has(page)) {
      assert.deepEqual(chapters, chapterIdsByPage.get(page), `${route}: chapter anchors changed between languages`);
    }
    chapterIdsByPage.set(page, chapters);

    const contentsLinks = linksIn(main).map(([, href]) => href).filter(href => chapters.includes(href.slice(1)));
    const chapterLinks = chapters.map(id => `#${id}`);
    assert.deepEqual(contentsLinks, [...chapterLinks, ...chapterLinks], `${route}: missing desktop or mobile contents links`);

    const siteUrl = process.env.NEXT_PUBLIC_SITE_URL;
    if (siteUrl) {
      assert(html.includes(`rel="canonical" href="${new URL(`${localRoot}${page}/`, siteUrl)}"`), `${route}: incorrect canonical`);
      for (const [language, prefix] of [["zh-Hant", "/"], ["en", "/en/"], ["x-default", "/"]]) {
        const href = new URL(`${prefix}${page}/`, siteUrl);
        assert(html.includes(`rel="alternate" hrefLang="${language}" href="${href}"`), `${route}: incorrect ${language} alternate`);
      }
    }
  } else if (!guide) {
    assert.equal([...html.matchAll(/data-product-scene="/g)].length, 1, "Expected one product scene");
  } else if (page === "pricing") {
    const pricing = html.replaceAll("<!-- -->", "");
    assert(pricing.includes("<table"), `${route}: missing plan comparison`);
    const english = lang === "en";
    const currency = english ? "USD" : "TWD";
    const expected = english
      ? [["Free", "0"], ["Standard", "9", "7.5"], ["Pro", "21", "18"]]
      : [["Free", "0"], ["Standard", "299", "249"], ["Pro", "699", "599"]];
    const cards = [...pricing.matchAll(/<article\b[^>]*>[\s\S]*?<\/article>/g)];
    const table = pricing.match(/<table\b[^>]*>[\s\S]*?<\/table>/)?.[0] ?? "";
    for (const [name, regular, intro] of expected) {
      const card = cards.find(([content]) => content.includes(`>${name}</h2>`))?.[0] ?? "";
      const headline = card.match(/<strong\b[^>]*>([^<]*)<\/strong>/)?.[1];
      assert.equal(headline, `${currency} ${intro ?? regular}`, `${route}: incorrect ${name} headline price`);
      assert(table.includes(`${currency} ${regular}`), `${route}: missing ${name} comparison price`);
      if (intro) {
        assert(card.includes(`<s>${currency} ${regular}</s>`), `${route}: incorrect ${name} regular price`);
      }
      if (name === "Pro") assert(card.includes(english ? "40 hours" : "40 小時"), `${route}: incorrect Pro allowance`);
    }
  } else if (page === "changelog") {
    const articles = [...html.matchAll(/<article id="release-([^"]+)"[^>]*>([\s\S]*?)<\/article>/g)];
    const sections = changelogSource.split(/^## (?=\[)/m).slice(1);
    const versions = [];
    for (const section of sections) {
      const [, version, date] = /^\[([^\]]+)\](?: - ([\d-]+))?/.exec(section);
      const entries = [...section.matchAll(/^- /gm)].length;
      if (version.toLowerCase() === "unreleased" || !entries) continue;
      versions.push(version.toLowerCase());
      const article = articles.find(([, id]) => id === version.toLowerCase())?.[2] ?? "";
      assert(article, `${route}: missing version ${version}`);
      assert([...article.matchAll(/<li>/g)].length >= entries, `${route}: incomplete notes for ${version}`);
      if (date) assert(article.includes(`dateTime="${date}"`), `${route}: incorrect date for ${version}`);
    }
    assert.deepEqual(articles.map(([, id]) => id), versions, `${route}: incorrect timeline order`);
  } else {
    for (const section of ["live", "translation", "transcription", "llm"])
      assert(ids.has(section), `${route}: missing model category ${section}`);
  }
  if (lang === "en") {
    // The release document is authored in Traditional Chinese in both locales.
    const localizedHtml = page === "changelog"
      ? html.replace(/<div lang="zh-Hant" data-release-notes=""[^>]*>[\s\S]*?<\/div>/g, "")
      : html;
    const visible = localizedHtml
      .replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/g, "")
      .replace(/<[^>]+>/g, "")
      .replaceAll("繁中", "");
    assert(
      !/\p{Script=Han}/u.test(visible),
      "English page contains untranslated visible copy",
    );
  }
  console.log(
    `${route}: ${assets.size} assets, anchors, language and navigation passed.`,
  );
}
for (const asset of [
  "media/mm2t-zh.mp4",
  "media/demo-zh.vtt",
  "media/en/mm2t-en.mp4",
  "media/en/demo-en.vtt",
  "media/en/ATTRIBUTION.md",
  "fonts/geist-latin.woff2",
  "fonts/OFL.txt",
]) {
  assert(
    fs.existsSync(path.join(root, asset)),
    `Missing dynamically loaded asset: ${asset}`,
  );
}
// Also cover translated dialogs, inactive tabs, and closed FAQ content that SSR doesn't show.
const sourceRoot = fileURLToPath(new URL("../src/", import.meta.url));
const messages = fs.readFileSync(
  path.join(sourceRoot, "lib/messages.ts"),
  "utf8",
);
const js = ts.transpileModule(messages, {
  compilerOptions: {
    module: ts.ModuleKind.ESNext,
    target: ts.ScriptTarget.ES2022,
  },
}).outputText;
const { english } = await import(
  `data:text/javascript,${encodeURIComponent(js)}`
);
const intentional = new Set(["繁中", "切換為繁體中文"]);
const componentFiles = fs
  .readdirSync(path.join(sourceRoot, "components"), { recursive: true })
  .filter((file) => file.endsWith(".tsx"));
for (const relative of componentFiles) {
  const file = `components/${relative}`;
  const ast = ts.createSourceFile(
    file,
    fs.readFileSync(path.join(sourceRoot, file), "utf8"),
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX,
  );
  function visit(node) {
    if (
      ts.isStringLiteral(node) &&
      /\p{Script=Han}/u.test(node.text) &&
      !intentional.has(node.text)
    )
      assert(english[node.text], `Missing English copy: ${node.text}`);
    ts.forEachChild(node, visit);
  }
  visit(ast);
}
for (const prefix of ["media/app", "media/en/app"]) {
  for (const asset of [
    "transcript",
    "speakers",
    "summary",
    "people",
    "vocabulary",
  ]) {
    assert(
      fs.existsSync(path.join(root, `${prefix}/${asset}.webp`)),
      `Missing real App capture: ${prefix}/${asset}`,
    );
  }
}
assert(
  !fs.existsSync(path.join(root, "assets/moments")),
  "Legacy browser animation scripts remain in the export",
);
assert(
  !fs.existsSync(path.join(root, "assets/scenes")),
  "Legacy scene scripts remain in the export",
);
console.log(
  "Translation coverage, real App captures, Tabler React icons, and React-only animations passed.",
);
