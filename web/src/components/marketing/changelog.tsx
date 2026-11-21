import Markdown from "react-markdown";
import { categoryNames, changelog, changelogLabels } from "@/lib/changelog";
import type { Locale } from "@/lib/messages";
import { ReleaseTimeline } from "./release-timeline";
import { Guide } from "./guide";

export function Changelog({ locale }: { locale: Locale }) {
  const labels = changelogLabels[locale];
  const versions = changelog.releases.map(release => ({
    ...release,
    id: "release-" + release.version.toLowerCase(),
    label: "v" + release.version,
  }));
  return (
    <Guide locale={locale} page="changelog">
      <ReleaseTimeline indexLabel={labels.index} versions={versions.map(({ id, label }) => ({ id, label }))}>
        {versions.map(({ id, label, date, groups }) => (
          <li key={id} className="relative ml-1 border-l border-foreground/20 pb-14 pl-6 last:border-transparent last:pb-0 md:pl-10">
            <article id={id} aria-labelledby={id + "-title"} className="max-w-[48rem] scroll-mt-18">
              <header className="release-heading relative mb-5 flex flex-wrap items-baseline gap-x-4 gap-y-1 bg-background pt-2 pb-3">
                <span aria-hidden="true" className="release-dot absolute top-6 -left-[calc(1.5rem+5.5px)] size-2.5 rounded-full bg-foreground ring-4 ring-background md:-left-[calc(2.5rem+5.5px)]" />
                <h2 id={id + "-title"} className="text-4xl leading-tight font-medium tracking-tight md:text-5xl">{label}</h2>
                {date && <time dateTime={date} className="font-mono text-sm tabular-nums text-muted-foreground">{date}</time>}
                <span aria-hidden="true" className="release-progress absolute inset-x-0 bottom-0 h-0.5 bg-border" />
              </header>
              <div className="space-y-6">
                {groups.map(({ title, body }, index) => (
                  <div key={index}>
                    {title && <h3 className="mb-2 text-base font-semibold">{locale === "zh" ? categoryNames[title] ?? title : title}</h3>}
                    <div lang="zh-Hant" data-release-notes="" className="space-y-2 text-[15px] leading-7 text-foreground/85 wrap-anywhere [&_a]:underline [&_code]:rounded [&_code]:bg-secondary [&_code]:px-1 [&_li+li]:mt-2 [&_ol]:list-decimal [&_ol]:pl-5 [&_ul]:list-disc [&_ul]:pl-5">
                      <Markdown skipHtml>{body + "\n" + changelog.definitions}</Markdown>
                    </div>
                  </div>
                ))}
              </div>
            </article>
          </li>
        ))}
      </ReleaseTimeline>
    </Guide>
  );
}
