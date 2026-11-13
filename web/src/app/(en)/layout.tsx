import type { Viewport } from "next";
import { siteMetadata } from "@/lib/site-metadata";
import "../globals.css";
export const metadata = siteMetadata("en");
export const viewport: Viewport = {
  themeColor: "#F6F5F1",
  width: "device-width",
  initialScale: 1,
};
export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html
      lang="en"
      data-type="software"
      data-radius="soft"
      data-buttons="pill"
      data-motion="true"
    >
      <body>
        {children}
        <noscript>
          <style>{`[data-reveal], [data-intro-content] { opacity: 1 !important; transform: none !important; } [data-intro-overlay] { display: none !important; }`}</style>
        </noscript>
      </body>
    </html>
  );
}
