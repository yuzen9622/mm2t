import type { Viewport } from "next";
import { siteMetadata } from "@/lib/site-metadata";
import "../globals.css";
export const metadata = siteMetadata("zh");
export const viewport: Viewport = {
  themeColor: "#F6F5F1",
  width: "device-width",
  initialScale: 1,
};
export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html
      lang="zh-Hant"
      data-type="software"
      data-radius="soft"
      data-buttons="pill"
      // Translation extensions can add attributes to this root before hydration.
      suppressHydrationWarning
    >
      <head>
        {/* The hero's entrance runs only when script is on; without it the page stands as written. */}
        <script>{`document.documentElement.classList.add('m-enter')`}</script>
      </head>
      <body>
        {children}
      </body>
    </html>
  );
}
