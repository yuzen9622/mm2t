import Link from "next/link";
import { Button } from "@/components/ui/button";
import "./globals.css";
export default function GlobalNotFound() {
  return (
    <html lang="en">
      <body>
        <main className="mx-auto flex min-h-svh max-w-5xl flex-col items-start justify-center gap-6 px-6">
          <p className="text-sm text-primary">404</p>
          <h1 className="text-4xl font-medium tracking-tight">
            This page has no meeting notes.
          </h1>
          <p className="text-muted-foreground">
            Let&apos;s get you back to mm2t.
          </p>
          <div className="flex flex-wrap gap-3">
            <Button asChild>
              <Link href="/en/">English home</Link>
            </Button>
            <Button variant="secondary" asChild>
              <Link href="/" lang="zh-Hant">
                繁體中文首頁
              </Link>
            </Button>
          </div>
        </main>
      </body>
    </html>
  );
}
