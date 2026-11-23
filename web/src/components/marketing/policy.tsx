import Markdown from "react-markdown";
import { LanguageProvider } from "@/components/i18n";
import { policyPages, type PolicyPage } from "@/lib/guide";
import type { Locale } from "@/lib/messages";
import { policyCopy, webPolicies } from "@/lib/policies";
import { cn, wrap } from "@/lib/utils";
import { CompactFooter } from "./footer-links";
import { Header } from "./header";
import { PolicyContents } from "./policy-contents";

export function Policy({ locale, page }: { locale: Locale; page: PolicyPage }) {
  const info = policyPages[page];
  const copy = policyCopy[locale];
  const document = webPolicies[page][locale];
  const revisionDate = new Intl.DateTimeFormat(locale === "zh" ? "zh-TW" : "en-US", {
    dateStyle: "long",
    timeZone: "UTC",
  }).format(new Date(document.date));

  return (
    <LanguageProvider locale={locale}>
      <div className="flex min-h-svh flex-col">
        <Header page={page} />
        <main id="main" className={cn(wrap, "flex-1 pt-24 pb-16 md:pt-30 md:pb-24")}>
          <article
            aria-labelledby="policy-title"
            className="mx-auto grid gap-y-6 md:grid-cols-[10rem_minmax(0,40rem)] md:items-start md:justify-center md:gap-x-8 xl:grid-cols-[12.5rem_minmax(0,40rem)_12.5rem] xl:gap-x-10"
          >
            <h1 id="policy-title" className="text-center text-[32px] leading-tight font-medium tracking-tight md:col-start-2 md:row-start-1 md:pb-5 md:text-[40px]">
              {info.heading[locale]}
            </h1>
            <dl className="divide-y divide-border border-y border-border text-sm leading-5 md:col-start-2 md:row-start-2 xl:col-start-3">
              <div className="py-2">
                <dt className="text-muted-foreground">{copy.statusLabel}</dt>
                <dd className="mt-1" data-policy-status="draft">{copy.status}</dd>
              </div>
              <div className="py-2">
                <dt className="text-muted-foreground">{copy.dateLabel}</dt>
                <dd className="mt-1"><time dateTime={document.date}>{revisionDate}</time></dd>
              </div>
              <div className="py-2">
                <dt className="text-muted-foreground">{copy.scopeLabel}</dt>
                <dd className="mt-1">{copy.scopes[page]}</dd>
              </div>
              <div className="py-2">
                <dt className="text-muted-foreground">{copy.languageLabel}</dt>
                <dd className="mt-1">{copy.language}</dd>
              </div>
            </dl>
            <PolicyContents
              label={copy.chapters}
              chapters={document.sections.map(({ id, title }) => ({ id, title }))}
            />
            <div className="min-w-0 space-y-10 text-base leading-7 wrap-anywhere md:col-start-2 md:row-start-3 xl:row-start-2">
              <div className="space-y-4"><PolicyMarkdown>{document.intro}</PolicyMarkdown></div>
              {document.sections.map(({ id, title, body }) => (
                <section key={id} className="space-y-4">
                  <h2 id={id} tabIndex={-1} className="scroll-mt-24 text-[22px] leading-snug font-medium">
                    {title}
                  </h2>
                  <PolicyMarkdown>{body}</PolicyMarkdown>
                </section>
              ))}
            </div>
          </article>
        </main>
        <CompactFooter />
      </div>
    </LanguageProvider>
  );
}

function PolicyMarkdown({ children }: { children: string }) {
  return (
    <Markdown
      skipHtml
      components={{
        a: ({ href, children }) => <a className="underline underline-offset-4" href={href}>{children}</a>,
        h3: ({ children }) => <h3 className="mt-7 text-lg leading-snug font-medium">{children}</h3>,
        ul: ({ children }) => <ul className="list-disc space-y-2 pl-6">{children}</ul>,
      }}
    >
      {children}
    </Markdown>
  );
}
