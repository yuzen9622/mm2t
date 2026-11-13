# mm2t 官網

使用 **Next.js App Router、React、TypeScript、Tailwind CSS 4、shadcn/ui（Radix 版本）與 Motion**。繁體中文 `/` 和英文 `/en/` 都輸出獨立靜態 HTML。

## 啟動

需求：Node.js 20.9 以上、pnpm 10。

```sh
cd web
pnpm install --frozen-lockfile
pnpm dev
```

- 繁體中文：http://localhost:3000/
- English：http://localhost:3000/en/

```sh
pnpm check      # ESLint、TypeScript、正式建置、雙語／資源／圖示檢查
pnpm build      # 輸出 out/
pnpm preview    # 預覽 out/，支援影片 Range 請求
```

## 架構

| 路徑 | 用途 |
| --- | --- |
| `src/app/(zh)/`、`src/app/(en)/` | 語言根佈局、靜態路由 |
| `src/components/marketing/` | 導覽、Hero、捲動章節、產品、FAQ、頁尾 |
| `src/components/ui/` | shadcn Button、Dialog、Sheet、Tabs、Accordion、Card |
| `components.json` | shadcn 設定，Tabler 圖示來源 |
| `src/app/globals.css` | Tailwind 入口、字體、App／shadcn 語意色彩、基礎設定 |
| `postcss.config.mjs` | Tailwind CSS 4 PostCSS 外掛 |
| `src/lib/utils.ts` | shadcn `cn()`，整合 clsx 與 tailwind-merge |
| `src/components/brand-intro.tsx` | 中央大字飛入 Hero 的共享 layout 動畫 |
| `src/components/assembly-scene.tsx` | 波形轉為完整真實 App 摘要畫面 |
| `src/components/native-waveform.tsx` | App 的 11 柱對稱波形與示範控制 |
| `src/hooks/use-motion-scene.ts` | 螢幕尺寸、減少動態偏好、SSR 回退 |
| `src/components/icon.tsx` | 顯示與 App 相同的 Tabler SVG 原檔 |
| `src/lib/messages.ts` | 中英共用文案 |
| `scripts/check-export.mjs` | 兩種語言、素材、頁內錨點、圖示一致性檢查 |

shadcn 採手動安裝方式，元件原始碼位於 `src/components/ui/`；沒有以「安裝 shadcn 套件」替代實際元件。按鈕使用 CVA、Slot 與 Tailwind variants，Dialog／Sheet／Tabs／Accordion 由 Radix 提供鍵盤與焦點行為。`components.json` 可供之後的 shadcn CLI 使用。

版面樣式寫在 TSX 的 Tailwind utilities 中。動畫由 React／Motion 管理；`public/` 沒有另行載入、搬動 DOM 的動畫腳本。

## 圖示與素材

App 的 `App/MM2T/Design/Icon.swift` 使用內附的 **Tabler（MIT）SVG**。官網直接複用 `App/MM2T/Icons/*.svg` 至 `public/icons/tabler/`，以 CSS mask 顯示原始圖形並繼承文字顏色。沒有手畫 SVG path，也沒有混入 Lucide。檢查會逐檔比對兩邊內容；更新 App 圖示後，也應同步官網副本。授權位於 `public/icons/tabler/LICENSE.txt`。

產品畫面來自 `docs/assets/` 與 `promo/public/footage/{zh,en}/` 的實際 App 素材，使用 WebP 壓縮。介面沒有重新排列或捏造。功能頁籤展示已取得實拍的逐字稿、依人彙整、摘要；App 同時提供整理版逐字稿。

英文示範文字衍生自 AMI Meeting Corpus（CC BY 4.0），人物使用虛構姓名。出處與改作說明見 `public/media/en/ATTRIBUTION.md`。Geist 授權見 `public/fonts/OFL.txt`。

## 動態與無障礙

- 開場共用 `layoutId`，中央 mm2t 縮放飛入 Hero；650ms 後開始，鍵盤／觸控／捲動可提前結束等待。
- 第二區塊使用原生 sticky 與 Motion scroll progress，3.6 屏行程分給三點，每點約 1.2 屏。
- 波形沿用 `FloatingContent.swift` 的 11 柱、六筆歷史與外側漸縮公式。訊號由程式模擬，不讀取麥克風；可暫停，離開畫面或分頁在背景時停止更新。
- 手機、短視窗與減少動態模式顯示靜態完整內容。SSR／無 JavaScript 仍可閱讀頁面。
- 影片只有開啟對話框後才載入；含字幕。語言切換使用完整文件導覽。

## 部署與驗證

`out/` 可部署至靜態主機。正式網域確認後，設定 `NEXT_PUBLIC_SITE_URL` 再建置，產生各語言 canonical、hreflang 和分享圖網址。資源目前使用網站根路徑，子路徑部署需要另行設定。

ESLint、TypeScript、建置、雙語資源與原始圖示一致性檢查通過。此次環境無法解析 npm registry，使用已存在的套件完成建置，並通過 frozen offline lockfile 檢查；尚未在乾淨環境進行線上安裝。

實際瀏覽器版面、開場中間狀態、互動與效能驗證仍未完成；目前執行環境無法連線 localhost:3000，先前瀏覽器工具也未能啟動。程式檢查不等於視覺驗證。
