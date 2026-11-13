import Link from "next/link";

export default function NotFound() {
  return <main className="section"><div className="wrap"><p className="section-label">404</p><h1>這一頁沒有會議紀錄。</h1><p style={{ marginBlock: 24 }}>回到首頁，繼續認識 mm2t。</p><Link className="button button-primary" href="/">回到首頁</Link></div></main>;
}
