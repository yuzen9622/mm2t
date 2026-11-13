"use client";
import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import {
  AnimatePresence,
  LayoutGroup,
  motion,
  useReducedMotion,
} from "motion/react";
const IntroContext = createContext(true);
const flight = {
  type: "spring",
  stiffness: 105,
  damping: 24,
  mass: 1.1,
} as const;
const word =
  "inline-block whitespace-nowrap font-semibold leading-[.95] tracking-[-.075em]";
export const useIntroReady = () => useContext(IntroContext);
export function BrandIntro({ children }: { children: ReactNode }) {
  const reduced = useReducedMotion();
  const [landed, setLanded] = useState(false);
  const ready = Boolean(landed || reduced);
  useEffect(() => {
    const finish = () => setLanded(true);
    const timer = window.setTimeout(finish, 650);
    window.addEventListener("wheel", finish, { once: true, passive: true });
    window.addEventListener("touchstart", finish, {
      once: true,
      passive: true,
    });
    window.addEventListener("keydown", finish, { once: true });
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener("wheel", finish);
      window.removeEventListener("touchstart", finish);
      window.removeEventListener("keydown", finish);
    };
  }, []);
  return (
    <LayoutGroup id="brand-intro">
      <IntroContext.Provider value={ready}>
        {children}
        <AnimatePresence>
          {!ready && (
            <motion.div
              data-intro-overlay=""
              className="pointer-events-none fixed inset-0 z-50 bg-background motion-reduce:hidden"
              aria-hidden="true"
              initial={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.65, delay: 0.15 }}
            />
          )}
        </AnimatePresence>
        {!ready && (
          <div
            data-intro-overlay=""
            className="pointer-events-none fixed inset-0 z-60 grid place-items-center motion-reduce:hidden"
            aria-hidden="true"
          >
            <motion.span
              className={`${word} text-[clamp(120px,23vw,330px)]`}
              layoutId="wordmark"
              transition={flight}
            >
              mm2t<span className="text-primary">.</span>
            </motion.span>
          </div>
        )}
      </IntroContext.Provider>
    </LayoutGroup>
  );
}
export function HeroWordmark() {
  const ready = useIntroReady();
  return (
    <div className="relative z-60 mb-6 h-12" aria-label="mm2t">
      {ready && (
        <motion.span
          className={`${word} text-[42px]`}
          layoutId="wordmark"
          transition={flight}
        >
          mm2t<span className="text-primary">.</span>
        </motion.span>
      )}
      <noscript>
        <span className={`${word} text-[42px]`}>
          mm2t<span className="text-primary">.</span>
        </span>
      </noscript>
    </div>
  );
}
