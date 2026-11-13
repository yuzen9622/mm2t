"use client";
import { useCallback, useSyncExternalStore } from "react";

/** SSR stays readable; desktop scroll scenes opt in only when they fit and motion is allowed. */
export function useMotionScene(minWidth = 1024, minHeight = 720) {
  const query = `(min-width: ${minWidth}px) and (min-height: ${minHeight}px) and (prefers-reduced-motion: no-preference)`;
  const subscribe = useCallback(
    (notify: () => void) => {
      const media = window.matchMedia(query);
      media.addEventListener("change", notify);
      return () => media.removeEventListener("change", notify);
    },
    [query],
  );
  const snapshot = useCallback(() => window.matchMedia(query).matches, [query]);
  return useSyncExternalStore(subscribe, snapshot, () => false);
}
