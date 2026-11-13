import Link from "next/link";
import { Button } from "@/components/ui/button";
export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-svh max-w-5xl flex-col items-start justify-center gap-6 px-6">
      <p className="text-sm text-primary">404</p>
      <h1 className="text-4xl font-medium tracking-tight">
        這一頁沒有會議紀錄。
      </h1>
      <p className="text-muted-foreground">回到首頁，繼續認識 mm2t。</p>
      <Button asChild>
        <Link href="/">回到首頁</Link>
      </Button>
    </main>
  );
}
