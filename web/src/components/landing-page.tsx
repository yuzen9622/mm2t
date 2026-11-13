"use client";

import { useState, useRef, type ReactNode } from "react";
import Image from "next/image";
import Script from "next/script";
import * as Dialog from "@radix-ui/react-dialog";
import * as Tabs from "@radix-ui/react-tabs";
import * as Accordion from "@radix-ui/react-accordion";
import { motion, MotionConfig, useReducedMotion, useScroll, useSpring, useTransform } from "motion/react";
import { Icon } from "./icon";
import { LanguageProvider, useCopy } from "./i18n";
import type { Locale } from "@/lib/messages";
import { AssemblyScene } from "./assembly-scene";
import { BrandIntro, HeroWordmark } from "./brand-intro";
import { RecordingDemo } from "./native-waveform";

const REPO = "https://github.com/yuzen9622/mm2t";
const DOWNLOAD = `${REPO}/releases/latest`;
const navLinks = [{ label: "使用體驗", href: "#experience" }, { label: "功能", href: "#features" }, { label: "隱私", href: "#privacy" }, { label: "常見問題", href: "#faq" }];
const ease = [0.22, 1, 0.36, 1] as const;

function Reveal({ children, className = "", delay = 0 }: { children: ReactNode; className?: string; delay?: number }) {
  const reduced = useReducedMotion();
  return <motion.div className={`reveal ${className}`} initial={reduced ? false : { opacity: 0, y: 24 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true, amount: 0.12 }} transition={{ duration: reduced ? 0 : 0.8, ease, delay }}>{children}</motion.div>;
}

function Brand({ light = false }: { light?: boolean }) {
  const { t } = useCopy();
  return <a className={`brand ${light ? "brand-light" : ""}`} href="#top" aria-label={t("mm2t 首頁")}><Image src="/media/icon.png" width={38} height={38} alt="" /><span>mm2t<span className="brand-dot">.</span></span></a>;
}

function DownloadButton({ className = "" }: { className?: string }) {
  const { t } = useCopy();
  return <a className={`button button-primary ${className}`} href={DOWNLOAD} target="_blank" rel="noreferrer">{t("下載 mm2t")}<span className="button-orb"><Icon name="diagonal" size={17} /></span></a>;
}

function Header() {
  const { t, locale } = useCopy();
  const [open, setOpen] = useState(false);
  return <header className="header">
    <a className="skip-link" href="#top">{t("跳至主要內容")}</a>
    <div className="nav-island">
      <Brand />
      <nav className="desktop-nav" aria-label={t("主要導覽")}>{navLinks.map(link => <a key={link.href} href={link.href}>{t(link.label)}</a>)}</nav>
      <div className="nav-actions"><a className="language-switch" href={locale === "en" ? "/" : "/en/"} hrefLang={locale === "en" ? "zh-Hant" : "en"} lang={locale === "en" ? "zh-Hant" : "en"} aria-label={locale === "en" ? "切換為繁體中文" : "Switch to English"}>{locale === "en" ? "繁中" : "EN"}</a><a className="github-link" href={REPO} target="_blank" rel="noreferrer" aria-label={t("在 GitHub 查看 mm2t 原始碼")}><Icon name="github" size={21} /></a><DownloadButton />
        <Dialog.Root open={open} onOpenChange={setOpen}>
          <Dialog.Trigger className="menu-toggle" aria-label={t("開啟導覽選單")}><span /><span /></Dialog.Trigger>
          <Dialog.Portal><Dialog.Overlay className="menu-overlay" /><Dialog.Content className="mobile-menu">
            <Dialog.Title className="sr-only">{t("網站導覽")}</Dialog.Title><Dialog.Description className="sr-only">{t("選擇想查看的官網章節。")}</Dialog.Description>
            <div className="mobile-menu-top"><Brand /><Dialog.Close className="icon-button menu-close" aria-label={t("關閉導覽選單")}><span /><span /></Dialog.Close></div>
            <nav aria-label={t("手機版導覽")}>{navLinks.map((link, i) => <a key={link.href} href={link.href} onClick={() => setOpen(false)} style={{ animationDelay: `${i * 65}ms` }}><span className="menu-index">0{i + 1}</span>{t(link.label)}<Icon name="diagonal" size={26} /></a>)}</nav>
            <div className="menu-bottom"><DownloadButton /><p>{t("macOS 14.2 以上 · 免費開放原始碼")}</p></div>
          </Dialog.Content></Dialog.Portal>
        </Dialog.Root>
      </div>
    </div>
  </header>;
}

function VideoButton() {
  const { t, locale, media } = useCopy();
  return <Dialog.Root>
    <Dialog.Trigger className="button button-secondary"><span className="play-circle"><Icon name="play" size={15} /></span>{t("觀看示範")}<span className="video-time">00:44</span></Dialog.Trigger>
    <Dialog.Portal><Dialog.Overlay className="video-overlay" /><Dialog.Content className="video-dialog">
      <div className="video-heading"><Dialog.Title>{t("一分鐘看懂 mm2t")}</Dialog.Title><Dialog.Close className="icon-button" aria-label={t("關閉示範影片")}><Icon name="close" /></Dialog.Close></div>
      <Dialog.Description className="sr-only">{t("mm2t 的實際操作示範：錄音、命名說話者與查看摘要。影片以畫面文字說明，沒有口述。")}</Dialog.Description>
      <video controls autoPlay playsInline preload="none" poster={media("poster.webp")} aria-label={t("mm2t 操作示範")}><source src={media(locale === "en" ? "mm2t-en.mp4" : "mm2t-zh.mp4")} type="video/mp4" /><track kind="captions" src={media(locale === "en" ? "demo-en.vtt" : "demo-zh.vtt")} srcLang={locale === "en" ? "en" : "zh-Hant"} label={t("繁體中文")} />{t("你的瀏覽器無法播放影片，請")}<a href={media(locale === "en" ? "mm2t-en.mp4" : "mm2t-zh.mp4")}>{t("下載示範影片")}</a>{locale === "en" ? "." : "。"}</video>{locale === "en" && <a className="video-attribution" href="/media/en/ATTRIBUTION.md" target="_blank" rel="noreferrer">Demo transcript adapted from the AMI Meeting Corpus · CC BY 4.0</a>}
    </Dialog.Content></Dialog.Portal>
  </Dialog.Root>;
}

function HeroApp() {
  const { t, media } = useCopy();
  return <div className="hero-product actual-hero-product">
    <RecordingDemo />
    <div className="actual-app-frame"><Image src={media("app/transcript.webp")} width={1600} height={941} alt={t("mm2t 會議逐字稿介面預覽，顯示不同說話者與時間戳記")} sizes="(max-width: 767px) 100vw, 65vw" priority /></div>
    <p className="capture-caption">{t("實際 App 畫面")}</p>
  </div>;
}

function Hero() {
  const { t, locale } = useCopy();
  const hero = useRef<HTMLElement>(null);
  const reduced = useReducedMotion();
  const { scrollYProgress } = useScroll({ target: hero, offset: ["start start", "end start"] });
  const progress = useSpring(scrollYProgress, { stiffness: 110, damping: 28 });
  const y = useTransform(progress, [0, 1], [0, 150]);
  const rotateX = useTransform(progress, [0, 1], [0, 16]);
  const rotateZ = useTransform(progress, [0, 1], [0, -7]);
  const scale = useTransform(progress, [0, 1], [1, 0.86]);
  return <section ref={hero} className="hero hero--split" data-enter="" aria-labelledby="hero-title">
    <div className="wrap hero-grid"><div className="hero-copy">
      <HeroWordmark /><div className="eyebrow hero-eyebrow"><span className="status-dot" />{t("為 macOS 而生的開源工具")}</div>
      <h1 id="hero-title">{locale === "en" ? <>Meeting notes.<br />Made for <span className="hero-last">Mac<span className="orange-period">.</span></span></> : <>{t("Mac 上的")}<br />{t("會議記錄，")}<br /><span className="hero-last">{t("交給")}<span className="latin-name">mm2t</span><span className="orange-period">。</span></span></>}</h1>
      <p className="hero-lead">{t("開會時專心說話。")}<br />{t("從錄音、辨識說話者，到逐字稿與摘要，")}<br className="desktop-break" />{t("mm2t 替你接著整理。")}</p>
      <div className="button-row"><DownloadButton /><VideoButton /></div>
      <p className="hero-fineprint">{t("免費開放原始碼")}<span>·</span>{t("macOS 14.2 以上")}</p>
    </div><motion.div className="hero-product-motion" style={reduced ? undefined : { y, rotateX, rotateZ, scale }}><HeroApp /></motion.div></div>
    <div className="wrap hero-foot"><span className="hero-foot-label">{t("融入你習慣的會議")}</span><div className="meeting-apps"><span>Google Meet</span><span>Microsoft Teams</span><span>Zoom</span><span>Webex</span></div><a href="#experience" className="scroll-cue" aria-label={t("向下查看使用體驗")}><span>{t("往下看看")}</span><Icon name="arrow" size={17} /></a></div>
  </section>;
}

const chapters = [
  { title: "會議開始，輕按一下。", text: "偵測到會議時，選單列的小膠囊會詢問是否錄音。直接擷取 Mac 音訊，不需要 Bot 加入。", image: "recording.webp", alt: "mm2t 偵測到 Zoom 會議，顯示錄音膠囊" },
  { title: "叫得出名字的逐字稿。", text: "麥克風與遠端聲音分軌錄製，再於 Mac 上辨識說話者。命名一次，下次自動套用聲紋。", image: "speakers.webp", alt: "mm2t 逐字稿中的說話者姓名與時間戳記" },
  { title: "會議結束，接著整理。", text: "討論重點、決議與待辦整理成摘要，附上時間點，方便回到當時的對話。", image: "summary.webp", alt: "mm2t 自動整理的會議摘要" },
];

function Experience() {
  const { t, media } = useCopy();
  return <section id="experience" className="section experience" data-moment="pinned-chapters" aria-labelledby="experience-title">
    <div className="wrap mo-pc__grid"><div className="mo-pc__text"><div><span className="section-label">{t("從第一句，到下一步")}</span><h2 id="experience-title">{t("會議在進行。")}<br /><span className="muted">{t("紀錄，也跟得上。")}</span></h2></div>
      <ol className="mo-pc__steps">{chapters.map((chapter, i) => <li className="mo-pc__step" key={t(chapter.title)}><h3><span className="chapter-number">0{i + 1}</span>{t(chapter.title)}</h3><p><span className="mo-pc__p-in">{t(chapter.text)}</span></p><figure className="mo-pc__visual"><Image src={media(chapter.image)} alt={t(chapter.alt)} width={1400} height={900} sizes="(max-width: 1023px) 100vw, 50vw" /></figure></li>)}</ol>
    </div><div className="mo-pc__visuals frame" /></div>
  </section>;
}

const demoTabs = [
  { label: "逐字稿", image: "transcript.webp", description: "逐句保留原話，依時間與說話者排列。" },
  { label: "依人彙整", image: "speakers.webp", description: "按說話者整理觀點，保留對應時間點。" },
  { label: "摘要", image: "summary.webp", description: "決議、討論重點與待辦事項，沿用 App 的原始排版。" },
];
function ProductTour() {
  const { t, media, locale } = useCopy();
  const [tab, setTab] = useState("摘要");
  return <section className="section product-section" id="features" aria-labelledby="features-title"><div className="wrap">
    <Reveal className="section-heading"><div><span className="section-label">{t("你的會議，有不同讀法")}</span><h2 id="features-title">{t("找回那句話。")}<br /><span className="muted">{t("或直接看重點。")}</span></h2></div><p>{t("逐字稿、整理版、依人彙整與摘要。")}<br />{t("切換下方頁籤，看看 mm2t 怎麼整理。")}</p></Reveal>
    <Reveal><Tabs.Root value={tab} onValueChange={setTab} className="capture-tour">
      <div className="capture-tour-heading"><Tabs.List className="capture-tabs" aria-label={t("選擇會議紀錄格式")}>{demoTabs.map(item => <Tabs.Trigger className="capture-tab" value={item.label} key={item.label}>{tab === item.label && <motion.span className="tab-indicator" layoutId="tour-tab" transition={{ type: "spring", stiffness: 350, damping: 32 }} />}<span>{t(item.label)}</span></Tabs.Trigger>)}</Tabs.List><span className="capture-caption">{t("實際 App 畫面")}{locale === "en" && <> · <a href="/media/en/ATTRIBUTION.md" target="_blank" rel="noreferrer">Demo credits</a></>}</span></div>
      {demoTabs.map(item => <Tabs.Content key={item.label} value={item.label} className="capture-panel"><div className="capture-scroll" tabIndex={0} role="region" aria-label={t("App 畫面，可橫向捲動查看")}><Image src={media(`app/${item.image}`)} alt={t(item.description)} width={1600} height={941} sizes="(max-width: 767px) 960px, 90vw" /></div><p className="capture-description">{t(item.description)}</p></Tabs.Content>)}
    </Tabs.Root></Reveal>
  </div></section>;
}

function Details() {
  const { t, media } = useCopy();
  return <section className="section details-section" aria-labelledby="details-title"><div className="wrap"><Reveal className="section-heading"><div><span className="section-label">{t("越用，越熟悉你的會議")}</span><h2 id="details-title">{t("記住聲音，")}<br /><span className="muted">{t("也記住你的用語。")}</span></h2></div><p>{t("從常見的與會者，到團隊自己的專有名詞。")}<br />{t("每次整理，都有熟悉的依據。")}</p></Reveal>
    <div className="detail-grid actual-detail-grid"><Reveal className="actual-detail"><article><div className="detail-copy"><Icon name="users" size={25} /><h3>{t("一次命名，下次就認得。")}</h3><p>{t("聲紋留在你的 Mac。現場與線上通話，")}<br />{t("分別記住同一個人的聲音。")}</p></div><div className="actual-detail-image"><Image src={media("app/people.webp")} width={1600} height={941} alt={t("人物與聲紋的實際 App 畫面")} sizes="(max-width: 767px) 100vw, 50vw" /></div></article></Reveal>
      <Reveal className="actual-detail" delay={.1}><article><div className="detail-copy"><Icon name="book" size={25} /><h3>{t("團隊的詞彙，說得準。")}</h3><p>{t("將專有名詞加入個人詞彙庫，")}<br />{t("讓轉錄與整理時有參考依據。")}</p></div><div className="actual-detail-image"><Image src={media("app/vocabulary.webp")} width={1600} height={941} alt={t("個人詞彙庫的實際 App 畫面")} sizes="(max-width: 767px) 100vw, 50vw" /></div></article></Reveal></div>
  </div></section>;
}

function Privacy() {
  const { t } = useCopy();
  return <section id="privacy" className="section privacy-section" aria-labelledby="privacy-title"><div className="wrap privacy-grid"><Reveal className="privacy-copy"><span className="section-label">{t("資料的去向，由你決定")}</span><h2 id="privacy-title">{t("你的會議，")}<br />{t("留在你的 Mac。")}</h2><p>{t("錄音、聲紋與會議紀錄儲存在本機。")}<br />{t("mm2t 沒有自己的伺服器，也不代管你的資料。")}</p><div className="privacy-facts"><div><Icon name="lock" /><span>{t("API 金鑰存放於 macOS 鑰匙圈")}</span></div><div><Icon name="shield" /><span>{t("聲紋辨識在 Mac 本機完成")}</span></div></div><a className="text-link" href={`${REPO}/blob/main/PRIVACY.md`} target="_blank" rel="noreferrer">{t("閱讀隱私權政策")}<Icon name="diagonal" size={17} /></a></Reveal>
    <Reveal className="privacy-visual"><div className="privacy-device"><div className="device-top"><span className="small-label">{t("你的 Mac")}</span><Icon name="lock" size={18} /></div><Image src="/media/icon.png" alt="mm2t" width={78} height={78} /><div className="local-files"><span><Icon name="mic" />{t("錄音")}</span><span><Icon name="users" />{t("聲紋")}</span><span><Icon name="file" />{t("紀錄")}</span></div><div className="device-bottom"><i />{t("保存在本機")}</div></div><div className="connection-line" aria-hidden="true"><span /><span /></div><div className="processing-options"><div><Icon name="cloud" size={22} /><strong>{t("你選擇的 API")}</strong><span>{t("使用自己的金鑰")}<br />{t("直接連線至服務商")}</span></div><div><Icon name="laptop" size={22} /><strong>{t("自架轉錄伺服器")}</strong><span>{t("音訊在自己的")}<br />{t("設備之間傳輸")}</span></div></div><p className="privacy-disclosure">{t("選用雲端服務時，音訊或文字會傳送至所選服務商處理；費用由你的 API 帳號支付。")}</p></Reveal>
  </div></section>;
}

function getFaqs(t: (text: string) => string) { return [
  { question: "mm2t 是免費的嗎？", answer: <>{t("mm2t 免費、開放原始碼，採用 AGPL-3.0 授權。選用 ElevenLabs、Google Gemini 等雲端服務時，需填入自己的 API 金鑰，使用費由服務商直接計算。也可以使用自己的轉錄伺服器。")}</> },
  { question: "需要什麼版本的 Mac？", answer: <>{t("需要 macOS 14.2 以上。下載 DMG 後，將 mm2t 拖入「應用程式」，首次啟動時依設定精靈授予錄音與會議偵測所需的權限。")}<a href={`${REPO}#installation`} target="_blank" rel="noreferrer">{t("查看安裝說明")}<Icon name="diagonal" size={14} /></a></> },
  { question: "會有機器人加入會議嗎？", answer: <>{t("不會。mm2t 直接擷取你的麥克風與會議 App 音訊，支援 Google Meet、Microsoft Teams、Zoom 與 Webex。它不錄製畫面，視窗也不會出現在螢幕分享中。")}</> },
  { question: "可以完全不使用雲端服務嗎？", answer: <>{t("可以自架轉錄伺服器，讓音訊在自己的設備之間傳輸。本機轉錄與本機語言模型仍在開發中；若選用雲端摘要，逐字稿文字仍會傳至所選服務商。")}<a href={`${REPO}/blob/main/PRIVACY.md`} target="_blank" rel="noreferrer">{t("查看資料處理方式")}<Icon name="diagonal" size={14} /></a></> },
  { question: "第一次開啟時被 macOS 擋住怎麼辦？", answer: <>{t("目前版本尚未有 Developer ID 簽章與 Apple 公證。請先核對 GitHub Release 來源，再依該版本說明，在「系統設定 → 隱私權與安全性」選擇「仍要打開」。")}<a href={DOWNLOAD} target="_blank" rel="noreferrer">{t("查看版本與安裝步驟")}<Icon name="diagonal" size={14} /></a></> },
]; }

function FAQ() {
  const { t, locale } = useCopy();
  return <section className="section faq-section" id="faq" aria-labelledby="faq-title"><div className="wrap faq-grid"><Reveal><span className="section-label">{t("開始之前")}</span><h2 id="faq-title">{t("關於 mm2t，")}<br /><span className="muted">{t("你可能想知道。")}</span></h2><p className="faq-intro">{t("更多設定與使用方式，")}<br />{t("都整理在 GitHub 文件裡。")}</p><a className="text-link" href={`${REPO}/blob/main/${locale === "en" ? "README.md" : "README.zh-TW.md"}`} target="_blank" rel="noreferrer">{t("閱讀使用文件")}<Icon name="diagonal" size={17} /></a></Reveal><Reveal><Accordion.Root type="single" collapsible defaultValue="question-0" className="faq-list">{getFaqs(t).map((item, i) => <Accordion.Item key={t(item.question)} value={`question-${i}`} className="faq-item"><Accordion.Header><Accordion.Trigger><span>{t(item.question)}</span><span className="faq-plus"><i /><i /></span></Accordion.Trigger></Accordion.Header><Accordion.Content className="faq-answer"><div>{item.answer}</div></Accordion.Content></Accordion.Item>)}</Accordion.Root></Reveal></div></section>;
}

function Footer() {
  const { t } = useCopy();
  return <footer className="closing" id="download"><div className="wrap"><Reveal className="closing-cta"><Image src="/media/icon.png" width={88} height={88} alt={t("mm2t 應用程式圖示")} /><p className="section-label">{t("準備好，留給下一場會議。")}</p><h2>{t("把注意力留給對話。")}</h2><p>{t("打開 mm2t，開始你的第一份會議記錄。")}</p><DownloadButton /><span className="download-note">{t("macOS 14.2 以上 · 免費開放原始碼")}</span></Reveal><div className="footer-row"><Brand /><p>{t("為每一場值得記下的對話。")}</p><a href={REPO} className="github-footer" target="_blank" rel="noreferrer"><Icon name="github" size={18} />{t("在 GitHub 給顆星")}<Icon name="diagonal" size={15} /></a></div><div className="footer-legal"><span>© {new Date().getFullYear()} mm2t · AGPL-3.0</span><div><a href={`${REPO}/blob/main/PRIVACY.md`} target="_blank" rel="noreferrer">{t("隱私權政策")}</a><a href={`${REPO}/blob/main/TERMS.md`} target="_blank" rel="noreferrer">{t("使用條款")}</a><a href={`${REPO}/releases`} target="_blank" rel="noreferrer">{t("版本紀錄")}</a></div><span>Made for macOS.</span></div></div></footer>;
}

export function LandingPage({ locale = "zh" }: { locale?: Locale }) {
  return <LanguageProvider locale={locale}><MotionConfig reducedMotion="user"><BrandIntro><Header /><main id="top"><Hero /><Experience /><ProductTour /><Details /><AssemblyScene /><Privacy /><FAQ /></main><Footer /><Script src="/assets/moments/moments.js" type="module" strategy="afterInteractive" /></BrandIntro></MotionConfig></LanguageProvider>;
}
