import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const root = fileURLToPath(new URL("../out/", import.meta.url));
const changelogSource = fs.readFileSync(new URL("../../CHANGELOG.md", import.meta.url), "utf8");
const guidePages = ["models", "pricing", "changelog"];
for (const [route, lang] of [
  ["index.html", "zh-Hant"],
  ["en/index.html", "en"],
  ["models/index.html", "zh-Hant"],
  ["en/models/index.html", "en"],
  ["pricing/index.html", "zh-Hant"],
  ["en/pricing/index.html", "en"],
  ["changelog/index.html", "zh-Hant"],
  ["en/changelog/index.html", "en"],
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
  assert(
    html.includes("data-enter") && html.includes("m-enter"),
    "The hero entrance must be gated by the m-enter head script",
  );
  const page = route.split("/").at(-2);
  const guide = guidePages.includes(page);
  const localRoot = lang === "en" ? "/en/" : "/";
  const otherRoot = lang === "en" ? "/" : "/en/";
  for (const name of guidePages)
    assert(html.includes(`href="${localRoot}${name}/"`), `${route}: missing ${name} navigation`);
  assert(
    html.includes(`href="${otherRoot}${guide ? page + "/" : ""}"`),
    `${route}: missing language switch`,
  );
  if (!guide) {
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
