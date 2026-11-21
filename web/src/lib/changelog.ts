import markdown from "../../../CHANGELOG.md";

export const categoryNames: Record<string, string> = {
  Added: "新增",
  Changed: "調整",
  Deprecated: "即將停用",
  Removed: "移除",
  Fixed: "修正",
  Security: "安全性",
};

export const changelogLabels = {
  zh: { index: "依版本瀏覽" },
  en: { index: "Browse by version" },
};

type Group = { title: string; body: string };
type Release = { version: string; date?: string; groups: Group[] };

// Keep the document's order, including releases published on the same date.
function readReleases(source: string) {
  const releases: Release[] = [];
  const definitions: string[] = [];
  let release: Release | undefined;
  let group: Group | undefined;
  for (const line of source.split(/\r?\n/)) {
    if (/^\[[^\]]+\]:\s/.test(line)) {
      definitions.push(line);
      continue;
    }
    const heading = /^## \[([^\]]+)\](?:\s+-\s+(\d{4}-\d{2}-\d{2}))?\s*$/.exec(line);
    if (heading) {
      release = { version: heading[1], date: heading[2], groups: [] };
      releases.push(release);
      group = undefined;
      continue;
    }
    if (!release) continue;
    if (line.startsWith("### ")) {
      group = { title: line.slice(4).trim(), body: "" };
      release.groups.push(group);
    } else if (line.trim() || group) {
      if (!group) {
        group = { title: "", body: "" };
        release.groups.push(group);
      }
      group.body += line + "\n";
    }
  }
  for (const entry of releases) {
    entry.groups = entry.groups.filter(({ body }) => body.trim());
  }
  return {
    releases: releases.filter(({ version, groups }) => version.toLowerCase() !== "unreleased" && groups.length),
    definitions: definitions.join("\n"),
  };
}

export const changelog = readReleases(markdown);
