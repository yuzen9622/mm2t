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
| `src/components/marketing/` | 導覽、Hero、捲動場景（flow-scene）、四種讀法、聲紋與詞彙、隱私、FAQ、頁尾 |
| `src/components/app-ui.tsx` | 以 HTML 重建的 App 介面（視窗、逐字稿、摘要、人物、詞彙），色彩取自 `Tokens.swift` |
| `src/lib/meeting.ts` | 重建介面共用的示範會議內容 |
| `src/components/ui/` | shadcn Button、Dialog、Sheet、Tabs、Accordion、Card |
| `components.json` | shadcn 設定，Tabler 圖示來源 |
| `src/app/globals.css` | Tailwind 入口、字體、App／shadcn 語意色彩、基礎設定 |
| `postcss.config.mjs` | Tailwind CSS 4 PostCSS 外掛 |
| `src/lib/utils.ts` | shadcn `cn()`，整合 clsx 與 tailwind-merge |
| `src/components/native-waveform.tsx` | App 的 11 柱對稱波形與示範控制 |
| `src/hooks/use-motion-scene.ts` | 螢幕尺寸、減少動態偏好、SSR 回退 |
| `src/components/icon.tsx` | 顯示與 App 相同的 Tabler SVG 原檔 |
| `src/lib/messages.ts` | 中英共用文案 |
| `scripts/check-export.mjs` | 兩種語言、素材、頁內錨點、圖示一致性檢查 |

shadcn 採手動安裝方式，元件原始碼位於 `src/components/ui/`；沒有以「安裝 shadcn 套件」替代實際元件。按鈕使用 CVA、Slot 與 Tailwind variants，Dialog／Sheet／Tabs／Accordion 由 Radix 提供鍵盤與焦點行為。`components.json` 可供之後的 shadcn CLI 使用。

版面樣式寫在 TSX 的 Tailwind utilities 中。動畫由 React／Motion 管理；`public/` 沒有另行載入、搬動 DOM 的動畫腳本。

## 圖示與素材

App 的 `App/MM2T/Design/Icon.swift` 使用內附的 **Tabler（MIT）SVG**。官網直接複用 `App/MM2T/Icons/*.svg` 至 `public/icons/tabler/`，以 CSS mask 顯示原始圖形並繼承文字顏色。沒有手畫 SVG path，也沒有混入 Lucide。檢查會逐檔比對兩邊內容；更新 App 圖示後，也應同步官網副本。授權位於 `public/icons/tabler/LICENSE.txt`。

頁面上的 App 介面以 HTML 依實際 App 畫面（`public/media/app/`）重建，可在任何尺寸保持清晰；版面與功能對照原畫面，示範內容來自同一場示範會議。`public/media/app/` 的實拍檔保留作為對照與檢查依據。

英文示範文字衍生自 AMI Meeting Corpus（CC BY 4.0），人物使用虛構姓名。出處與改作說明見 `public/media/en/ATTRIBUTION.md`。Geist 授權見 `public/fonts/OFL.txt`。

## 動態與無障礙

- Hero 載入時進場一次：`<head>` 的腳本加上 `html.m-enter`，CSS 讓標題逐行升起，之後畫面靜止。沒有 JavaScript 時內容直接顯示。
- `#flow` 是全頁唯一的捲動場景（4 屏行程，sticky 舞台）：錄音膠囊放大淹滿畫面 → 逐字稿以 App 的 karaoke 方式逐字點亮並標出說話者 → 鏡頭拉遠，回到 mm2t 視窗。寬度 1024 以下、高度 700 以下或減少動態時，改為 1 屏的靜態完整畫面。
- Karaoke 依照 `LyricTranscript.swift`：未讀字 34% 墨色、0.7pt 模糊、低於基線 2pt，讀到時升回原位；由單一 CSS 變數 `--k` 驅動。
- 隱私區塊的聲明句隨捲動逐字點亮（word-highlight），往回捲會退回；減少動態時整句直接顯示。
- 錄音膠囊可開啟麥克風體驗，聲音只在瀏覽器內分析。
- 影片只有開啟對話框後才載入；含字幕。語言切換使用完整文件導覽。

## 部署與驗證

`out/` 可部署至靜態主機。正式網域確認後，設定 `NEXT_PUBLIC_SITE_URL` 再建置，產生各語言 canonical、hreflang 和分享圖網址。資源目前使用網站根路徑，子路徑部署需要另行設定。

提交依賴變更前，必須執行 `pnpm install --frozen-lockfile` 和 `pnpm check`；僅使用既有 `node_modules` 建置不能驗證 lockfile 完整性。GitHub Actions 的 Website install and build 工作會在 Linux 執行上述檢查。

2026-11-17 已在無頭 Chrome 以 1440、390 寬截圖檢查各區塊與場景中間幀，並跑過 taste-skill 的版面、copy-lint 與效能檢查。
