import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/** One content edge for the header, every section and the footer: 80px gutters at 1440. */
export const wrap =
  "wrap relative z-1 mx-auto w-[min(100%_-_48px,1280px)] md:w-[min(100%_-_96px,1280px)] xl:w-[min(100%_-_160px,1280px)]";
