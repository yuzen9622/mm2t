"use client";

import { scroll } from "motion";
import { useEffect, useState } from "react";

type Chapter = { id: string; title: string };

export function PolicyContents({ label, chapters }: { label: string; chapters: Chapter[] }) {
  const [current, setCurrent] = useState<string | null>(null);

  useEffect(() => {
    const headings = chapters.flatMap(({ id }) => {
      const heading = document.getElementById(id);
      return heading ? [heading] : [];
    });
    const first = headings[0];
    if (!first) return;

    const update = () => {
      const top = parseFloat(getComputedStyle(first).scrollMarginTop) + 2;
      const atBottom = window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 2;
      const target = headings.find((heading) => `#${heading.id}` === window.location.hash);
      if (atBottom && target) {
        const targetTop = target.getBoundingClientRect().top;
        if (targetTop >= 72 && targetTop < window.innerHeight) {
          setCurrent(target.id);
          return;
        }
      }
      const visible = headings.findLast((heading) => heading.getBoundingClientRect().top <= top);
      setCurrent(visible?.id ?? first.id);
    };

    update();
    const stop = scroll(update);
    window.addEventListener("hashchange", update);
    return () => {
      stop();
      window.removeEventListener("hashchange", update);
    };
  }, [chapters]);

  const contents = (
    <nav aria-label={label}>
      <ol className="divide-y divide-border border-y border-border">
        {chapters.map(({ id, title }, index) => (
          <li key={id}>
            <a
              href={`#${id}`}
              aria-current={current === id ? "location" : undefined}
              className="flex min-h-11 items-center gap-3 px-1 py-2 text-sm leading-5 text-muted-foreground hover:text-foreground focus-visible:outline-2 focus-visible:-outline-offset-2 aria-[current=location]:font-medium aria-[current=location]:text-foreground"
            >
              <span aria-hidden="true" className="shrink-0 tabular-nums text-muted-foreground">
                {String(index + 1).padStart(2, "0")}
              </span>
              {title.replace(/^\d+\. /, "")}
            </a>
          </li>
        ))}
      </ol>
    </nav>
  );

  return (
    <>
      <div
        data-policy-contents="desktop"
        className="sticky top-24 col-start-1 row-start-2 row-end-4 hidden max-h-[calc(100dvh-7rem)] overflow-y-auto overscroll-contain pb-1 md:block xl:row-end-3"
      >
        {contents}
      </div>
      <details className="md:hidden">
        <summary className="min-h-11 cursor-pointer py-3 text-sm font-medium focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-ring">
          {label}
        </summary>
        {contents}
      </details>
    </>
  );
}
