import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const root = fileURLToPath(new URL("../out/", import.meta.url));
for (const [route, lang] of [["index.html", "zh-Hant"], ["en/index.html", "en"]]) {
  const html = fs.readFileSync(path.join(root, route), "utf8");
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]));
  const assets = new Set([...html.matchAll(/(?:src|href)="(\/[^"?#]*)/g)].map(match => match[1]));
  for (const [, id] of html.matchAll(/href="#([^"]+)"/g)) assert(ids.has(id), `${route}: missing anchor #${id}`);
  for (const asset of assets) assert(fs.existsSync(path.join(root, asset)), `${route}: missing asset ${asset}`);
  assert.equal([...html.matchAll(/<h1\b/g)].length, 1, `${route}: expected one primary heading`);
  assert(html.includes(`lang="${lang}"`), `${route}: incorrect document language`);
  assert(!/https?:\/\/localhost[^"<]*\/(?:media|icon)/.test(html), `${route}: localhost social image`);
  assert(html.includes("https://github.com/yuzen9622/mm2t/releases/latest"), "Download must reach the official release");
  assert(html.includes("<noscript>"), "Reveals need a no-JavaScript fallback");
  assert.equal([...html.matchAll(/data-product-scene="/g)].length, 1, "Expected one product scene");
  assert(html.includes('href="/en/"') || html.includes('href="/"'), "Missing language switch");
  if (lang === "en") {
    const visible = html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/g, "").replace(/<[^>]+>/g, "").replaceAll("繁中", "");
    assert(!/\p{Script=Han}/u.test(visible), "English page contains untranslated visible copy");
    assert(html.includes('/media/en/speakers.webp'), "English screenshot missing");
  }
  console.log(`${route}: ${assets.size} assets, anchors, language, metadata, and scene passed.`);
}
for (const asset of ["media/mm2t-zh.mp4", "media/demo-zh.vtt", "media/en/mm2t-en.mp4", "media/en/demo-en.vtt", "media/en/ATTRIBUTION.md", "fonts/geist-latin.woff2", "fonts/OFL.txt", "assets/moments/lib.js", "assets/moments/pinned-chapters/moment.js", "assets/moments/pinned-chapters/moment.css", "assets/scenes/scenes.js", "assets/scenes/lib.js", "assets/scenes/scenes.css", "assets/scenes/parts-lock-into-the-whole/scene.js", "assets/scenes/parts-lock-into-the-whole/scene.css"]) {
  assert(fs.existsSync(path.join(root, asset)), `Missing dynamically loaded asset: ${asset}`);
}
// Also cover translated dialogs, inactive tabs, and closed FAQ content that SSR doesn't show.
const sourceRoot = fileURLToPath(new URL("../src/", import.meta.url));
const messages = fs.readFileSync(path.join(sourceRoot, "lib/messages.ts"), "utf8");
const js = ts.transpileModule(messages, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
const { english } = await import(`data:text/javascript,${encodeURIComponent(js)}`);
const intentional = new Set(["繁中", "切換為繁體中文"]);
for (const file of ["components/landing-page.tsx", "components/assembly-scene.tsx", "components/native-waveform.tsx"]) {
  const ast = ts.createSourceFile(file, fs.readFileSync(path.join(sourceRoot,file), "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  function visit(node) {
    if (ts.isStringLiteral(node) && /\p{Script=Han}/u.test(node.text) && !intentional.has(node.text)) assert(english[node.text], `Missing English copy: ${node.text}`);
    ts.forEachChild(node, visit);
  }
  visit(ast);
}
for (const prefix of ["media/app", "media/en/app"]) {
  for (const asset of ["transcript", "speakers", "summary", "people", "vocabulary"]) {
    assert(fs.existsSync(path.join(root, `${prefix}/${asset}.webp`)), `Missing real App capture: ${prefix}/${asset}`);
  }
}
console.log("Dialog/tab/FAQ translation coverage, real App captures, and dynamic assets passed.");
