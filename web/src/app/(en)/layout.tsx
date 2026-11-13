import type { Viewport } from "next";
import { siteMetadata } from "@/lib/site-metadata";
import "../globals.css";
export const metadata = siteMetadata("en");
export const viewport: Viewport = { themeColor: "#F6F5F1", width: "device-width", initialScale: 1 };
export default function Layout({ children }: { children: React.ReactNode }) {
  return <html lang="en" data-type="software" data-radius="soft" data-buttons="pill" data-motion="true"><body>{children}<noscript><style>{`.reveal { opacity: 1 !important; transform: none !important; } .intro-curtain,.intro-source { display:none !important; } .intro-waiting .hero-copy > *, .intro-waiting .hero-product-motion,.intro-waiting .hero-foot,.intro-waiting .header { opacity:1 !important; translate:none !important; } .signal-scene {height:auto !important} .signal-stage {position:static !important;height:auto !important} .signal-live {display:none !important} .signal-capture {opacity:1 !important;transform:none !important}`}</style></noscript></body></html>;
}
