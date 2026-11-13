"use client";
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { AnimatePresence, LayoutGroup, motion, useReducedMotion } from "motion/react";

const IntroContext = createContext(true);
const flight = { type: "spring", stiffness: 105, damping: 24, mass: 1.1 } as const;
export function BrandIntro({ children }: { children: ReactNode }) {
  const reduced = useReducedMotion();
  const [landed, setLanded] = useState(false);
  const ready = landed || reduced;
  useEffect(() => {
    const finish = () => setLanded(true);
    const timer = window.setTimeout(finish, 650);
    window.addEventListener("wheel", finish, { once: true, passive: true });
    window.addEventListener("touchstart", finish, { once: true, passive: true });
    window.addEventListener("keydown", finish, { once: true });
    return () => { window.clearTimeout(timer); window.removeEventListener("wheel", finish); window.removeEventListener("touchstart", finish); window.removeEventListener("keydown", finish); };
  }, []);
  return <LayoutGroup id="brand-intro"><IntroContext.Provider value={Boolean(ready)}>
    <div className={`site-intro ${ready ? "intro-landed" : "intro-waiting"}`}>{children}</div>
    <AnimatePresence>{!ready && <motion.div className="intro-curtain" aria-hidden="true" initial={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: .65, delay: .15 }} />}</AnimatePresence>
    {!ready && <div className="intro-source" aria-hidden="true"><motion.span className="intro-word" layoutId="wordmark" transition={flight}>mm2t<span>.</span></motion.span></div>}
  </IntroContext.Provider></LayoutGroup>;
}
export function HeroWordmark() {
  const ready = useContext(IntroContext);
  return <div className="hero-wordmark" aria-label="mm2t">{ready && <motion.span className="intro-word" layoutId="wordmark" transition={flight}>mm2t<span>.</span></motion.span>}<noscript><span className="intro-word">mm2t<span>.</span></span></noscript></div>;
}
