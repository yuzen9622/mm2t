import type { CSSProperties } from "react";

// The same light Tabler stroke language used in App/MM2T/Icons.
const paths = {
  arrow: <><path d="M5 12h14M13 6l6 6-6 6" /></>,
  diagonal: <><path d="M6 18 18 6M6 6h12v12" /></>,
  play: <path d="m9 5 11 7-11 7z" />,
  download: <><path d="M12 3v12m-5-5 5 5 5-5M5 16v4h14v-4" /></>,
  mic: <><rect x="9" y="2" width="6" height="12" rx="3" /><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3m-4 0h8" /></>,
  file: <><path d="M14 3H6a1 1 0 0 0-1 1v16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8zM14 3v5h5M9 12h6m-6 4h6" /></>,
  users: <><circle cx="9" cy="7" r="3" /><path d="M3 21v-3a6 6 0 0 1 12 0v3M16 4a3 3 0 0 1 0 6m3 11v-3a6 6 0 0 0-3-5" /></>,
  home: <><path d="m3 10 9-7 9 7M5 9v12h5v-7h4v7h5V9" /></>,
  settings: <><path d="m10 3-1 3-3 1-2 3 2 3v3l3 2 3-1 3 1 3-2v-3l2-3-2-3-3-1-1-3z" /><circle cx="12" cy="11" r="3" /></>,
  book: <><path d="M5 3h14v18H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zM3 17h16M8 7h6" /></>,
  check: <path d="m5 12 4 4L19 6" />,
  chevron: <path d="m6 9 6 6 6-6" />,
  close: <path d="m6 6 12 12M6 18 18 6" />,
  shield: <><path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z" /><path d="m8 12 3 3 5-6" /></>,
  lock: <><rect x="5" y="10" width="14" height="11" rx="3" /><path d="M8 10V7a4 4 0 0 1 8 0v3m-4 5v2" /></>,
  laptop: <><rect x="4" y="3" width="16" height="13" rx="2" /><path d="m4 16-2 5h20l-2-5M9 18h6" /></>,
  cloud: <path d="M5 18a4 4 0 0 1-1-7 6 6 0 0 1 12-2 5 5 0 0 1 2 9z" />,
  sparkles: <><path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5zM20 2v4m-2-2h4" /></>,
  calendar: <><rect x="3" y="5" width="18" height="16" rx="3" /><path d="M7 3v4m10-4v4M3 11h18m-14 4h3m4 0h3" /></>,
  github: <><path d="M9 19c-4 1-4-2-6-2m12 5v-4c0-1-.3-2-1-2 4-.5 7-2 7-6 0-2-.5-3-2-4 .5-1 .5-3 0-4-2 0-3 1-4 2a13 13 0 0 0-6 0C8 3 7 2 5 2c-.5 1-.5 3 0 4-1.5 1-2 2-2 4 0 4 3 5.5 7 6-.7 0-1 1-1 2v4" /></>,
} satisfies Record<string, React.ReactNode>;

export function Icon({ name, size = 20, className, style }: { name: keyof typeof paths; size?: number; className?: string; style?: CSSProperties }) {
  return <svg className={className} style={style} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>;
}
