import Link from "next/link";
import "./globals.css";
export default function GlobalNotFound() {
  return <html lang="en"><body><main className="section"><div className="wrap"><p className="section-label">404</p><h1>This page has no meeting notes.</h1><p style={{ marginBlock: 24 }}>Let&apos;s get you back to mm2t.</p><div className="button-row"><Link className="button button-primary" href="/en/">English home</Link><Link className="button button-secondary" href="/" lang="zh-Hant">繁體中文首頁</Link></div></div></main></body></html>;
}
