"use client";
import { useRef, useState } from "react";
import Image from "next/image";
import { motion, useReducedMotion, useScroll, useTransform } from "motion/react";
import { useCopy } from "./i18n";
import { NativeWaveform } from "./native-waveform";
import { Icon } from "./icon";

/** Animate the complete captured app window; never rearrange or invent its panels. */
export function AssemblyScene() {
  const { t, media } = useCopy();
  const section = useRef<HTMLElement>(null);
  const reduced = useReducedMotion();
  const [paused, setPaused] = useState(false);
  const { scrollYProgress: p } = useScroll({ target: section, offset: ["start start", "end end"] });
  const waveScale = useTransform(p, [0, .35, .55], [1, .6, .15]);
  const waveOpacity = useTransform(p, [.28, .48], [1, 0]);
  const imageOpacity = useTransform(p, [.3, .55], [0, 1]);
  const imageY = useTransform(p, [.3, .7], [180, 0]);
  const imageScale = useTransform(p, [.3, .8], [.7, 1]);
  const rotateX = useTransform(p, [.3, .8], [18, 0]);
  return <section ref={section} className="signal-scene" data-product-scene="signal-to-notes" aria-labelledby="signal-title">
    <div className="signal-stage"><div className="signal-heading"><span className="section-label">{t("從第一句，到下一步")}</span><h2 id="signal-title">{t("聲音，成為清楚的下一步。")}</h2></div>
      <div className="signal-composition"><motion.div className="signal-live" style={reduced ? undefined : { scale: waveScale, opacity: waveOpacity }}><NativeWaveform paused={paused} className="signal-wave" /><p>{t("每一句話，都有了位置。")}</p></motion.div>
        <motion.div className="signal-capture actual-app-frame" style={reduced ? undefined : { opacity: imageOpacity, y: imageY, scale: imageScale, rotateX }}><Image src={media("app/summary.webp")} alt={t("mm2t 自動整理的會議摘要")} width={1600} height={941} sizes="(max-width: 767px) 100vw, 80vw" /></motion.div>
      </div>
    </div>
  </section>;
}
