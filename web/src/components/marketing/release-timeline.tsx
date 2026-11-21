"use client";

import { scroll } from "motion";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { cn, wrap } from "@/lib/utils";

type VersionLink = { id: string; label: string };

export function ReleaseTimeline({ versions, indexLabel, children }: {
  versions: VersionLink[];
  indexLabel: string;
  children: ReactNode;
}) {
  const list = useRef<HTMLOListElement>(null);
  const [current, setCurrent] = useState<number | null>(null);

  useEffect(() => {
    const timeline = list.current;
    if (!timeline) return;
    const articles = Array.from(timeline.querySelectorAll("article"));
    if (!articles.length) return;
    let active = -1;
    const reduced = matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => {
      const pin = parseFloat(getComputedStyle(articles[0]).scrollMarginTop);
      const rects = articles.map(article => article.getBoundingClientRect());
      const index = Math.max(0, rects.findLastIndex(rect => rect.top <= pin + 1));
      const article = articles[index];
      if (index !== active) {
        if (active >= 0) {
          articles[active].removeAttribute("data-reading");
          articles[active].style.removeProperty("--release-progress");
        }
        active = index;
        article.dataset.reading = "";
        setCurrent(index);
      }
      if (reduced.matches) return;
      const rect = rects[index];
      const read = Math.max(0, pin - rect.top);
      // The final note can be read before its heading reaches the top of the viewport.
      const remaining = Math.min(rect.bottom - pin, document.documentElement.scrollHeight - innerHeight - scrollY);
      const progress = remaining <= 0 ? 1 : read / (read + remaining);
      article.style.setProperty("--release-progress", String(progress));
    };
    update();
    const stop = scroll(update);
    const observer = new ResizeObserver(update);
    observer.observe(timeline);
    reduced.addEventListener("change", update);
    return () => {
      stop();
      observer.disconnect();
      reduced.removeEventListener("change", update);
    };
  }, []);

  return (
    <div className={cn(wrap, "grid gap-7 border-t border-border pt-6 pb-16 lg:grid-cols-[12rem_minmax(0,1fr)] lg:gap-10 lg:pt-10")}>
      <div className="min-w-0">
        <nav aria-label={indexLabel} className="release-minimap">
          <ul>
            {versions.map(({ id, label }, index) => (
              <li key={id}>
                <a href={"#" + id} aria-label={label} aria-current={current === index ? "location" : undefined}>
                  <span aria-hidden="true" className="minimap-tick" />
                  <span aria-hidden="true" className="minimap-label">{label}</span>
                </a>
              </li>
            ))}
          </ul>
        </nav>
      </div>
      <ol ref={list} className="changelog-timeline min-w-0">{children}</ol>
    </div>
  );
}
