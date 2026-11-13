import type { CSSProperties } from "react";
import { cn } from "@/lib/utils";

/** These are the exact Tabler SVG files bundled by the macOS app, not redrawn paths. */
const icons = {
  arrow: "chevron-right",
  diagonal: "external-link",
  play: "player-play",
  pause: "player-pause-filled",
  download: "download",
  mic: "microphone",
  file: "file-text",
  users: "users",
  home: "home",
  settings: "settings",
  book: "book-2",
  check: "check",
  chevron: "chevron-right",
  close: "x",
  shield: "shield-check",
  lock: "key",
  laptop: "settings",
  cloud: "upload",
  sparkles: "sparkles",
  calendar: "calendar-event",
  github: "brand-github",
  star: "star",
  menu: "adjustments-horizontal",
} as const;
export function Icon({
  name,
  size = 20,
  className,
  style,
}: {
  name: keyof typeof icons;
  size?: number;
  className?: string;
  style?: CSSProperties;
}) {
  const url = `url('/icons/tabler/${icons[name]}.svg')`;
  return (
    <span
      aria-hidden="true"
      data-icon={icons[name]}
      className={cn("inline-block shrink-0 bg-current", className)}
      style={{
        width: size,
        height: size,
        maskImage: url,
        WebkitMaskImage: url,
        maskSize: "contain",
        maskRepeat: "no-repeat",
        maskPosition: "center",
        ...style,
      }}
    />
  );
}
