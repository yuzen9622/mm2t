# mm2t 官網

延續 macOS App 的暖白、炭黑與橘色設計，使用 Next.js App Router、TypeScript、Motion 與 Radix UI。這個網站是可獨立部署的靜態官網，不需要後端。

## 啟動

需求：Node.js 20.9 以上，pnpm 10。

```sh
cd web
pnpm install --frozen-lockfile
pnpm dev
```

繁體中文：http://localhost:3000/

English：http://localhost:3000/en/

右上角 EN／繁中可切換語言。兩版皆為獨立靜態 HTML，包含各自的 document language、SEO 文案、圖片、影片與字幕。

```sh
# 正式建置，輸出至 out/
pnpm build

# 預覽已建置的靜態網站（含影片 Range 請求支援）
pnpm preview

# TypeScript、ESLint、建置與靜態資源檢查
pnpm check
```

`PORT=3001 pnpm preview` 可變更預覽埠號。`pnpm dev` 使用 Next.js 開發伺服器；`pnpm start` 與 `pnpm preview` 都預覽 `out/`。

## 設計與互動

- App 原始色彩：`#F6F5F1`、`#EEEDE8`、`#1C1C1E`、`#F0700F`，深色區域沿用 `#1B1B1D`。
- 開場中央大型 mm2t 透過共享 layoutId 飛入 Hero 品牌文字，再依序顯示標題、實際 App 畫面；滾動、觸控或鍵盤操作會提早結束等待，減少動態模式直接顯示。
- 浮動玻璃導覽列、按壓／hover 效果。
- 首屏 App 隨捲動帶出透視傾斜與縮放；手機與減少動態效果模式停用。
- 原生風格 11 柱對稱波形：沿用 FloatingContent.swift 的寬度、間距、六筆歷史與漸縮比例，聲音由中央向外傳遞；可暫停，離開畫面或背景分頁時停用更新。
- 聲音到摘要場景：波形縮小淡出，完整真實 App 截圖帶出；不拆改 App 介面。窄螢幕、短視窗、減少動態模式呈現靜態畫面。
- 桌面以原生捲動呈現錄音、辨識人物、產出摘要三個章節。修正 sticky 父層的 flex 垂直置中，以 3.6 屏捲動距離讓每點保留 1.2 屏。手機、短視窗與減少動態效果模式改為完整靜態排列。
- 逐字稿、依人彙整、摘要三個實拍範例可手動切換，支援方向鍵與焦點狀態。App 亦提供整理版逐字稿。手機可橫向捲動實拍介面。
- Radix Dialog 提供影片播放與手機全螢幕選單，包含焦點管理、Escape 關閉與背景鎖定。
- 問答收合、影片字幕、skip link、減少動態效果及無 JavaScript 內容回退。
- 圖片、影片、字體均在本機提供；影片點擊後才載入，沒有分析追蹤程式。

## 主要檔案

| 路徑 | 用途 |
| --- | --- |
| `src/components/landing-page.tsx` | 首頁區塊、文案與互動 |
| `src/components/icon.tsx` | 延續 App Tabler 風格的線條圖示 |
| `src/app/globals.css` | 顏色、響應式版面、動態效果 |
| `src/app/(zh)/`、`src/app/(en)/` | 各語言的 HTML 根佈局與頁面 |
| `src/lib/messages.ts`、`src/components/i18n.tsx` | 共用雙語文案與語言環境 |
| `src/lib/site-metadata.ts` | 各語言 SEO 與分享資訊 |
| `src/components/assembly-scene.tsx` | 波形到真實摘要畫面的滾動場景 |
| `src/components/brand-intro.tsx` | 中央品牌大字飛入 Hero 的共享 layout 動畫 |
| `src/components/native-waveform.tsx` | 與 App 相同演算法的波形與錄音膠囊示範 |
| `public/media/` | 既有 App 截圖的 WebP 版本、原有宣傳影片與字幕 |
| `public/assets/moments/`、`public/assets/scenes/` | 滾動章節與組裝動畫的原始套件檔案 |
| `scripts/check-export.mjs` | 匯出檔案、錨點與靜態資源檢查 |

## 部署

將 `out/` 部署到可提供靜態檔案的主機。Vercel 可將專案根目錄指定為 `web`，Build Command 設為 `pnpm build`，Output Directory 設為 `out`。

正式網域確認後，在建置環境設定 `NEXT_PUBLIC_SITE_URL=https://你的網域`，再執行建置，即會產生各語言 canonical、hreflang 與正式網域的分享圖片網址。未設定時不宣告 canonical，分享圖指向 GitHub 專案的既有圖片。網站目前使用根目錄資源路徑，若要部署於 GitHub Pages 的子路徑，需先設定並驗證資源前綴。

下載連結指向 GitHub 最新 Release；隱私、條款與使用文件指向專案現有文件。沒有假下載、假登入或未接上的表單。

## 驗證狀態

- 正式建置、TypeScript 與 ESLint 通過。
- 兩種語言的匯出資源、頁內錨點、HTML lang 與未翻譯文案檢查通過；檢查也涵蓋 Dialog、尚未啟用的 Tabs 和收合的 FAQ 文案。
- pnpm lockfile 已由現有可用套件的解析資訊建立，通過離線 lockfile 驗證。此次環境的套件 registry DNS 無法使用，尚未在全新環境執行線上安裝。
- 瀏覽器畫面、互動與效能測量**尚未完成**。驗證工具無法監聽本機 HTTP 埠，沒有產生可供檢查的桌面／手機截圖。

完整設計取捨與檢查限制見 [DESIGN.md](DESIGN.md)。

## 素材來源

產品圖示、中英文截圖與 44 秒影片來自本專案 `docs/assets/`，示範人物沿用既有宣傳素材中的虛構姓名。畫面內的資料為示範會議內容，不是客戶見證。沒有使用外部產品照片或虛構使用人數。

Geist Latin 字體採 SIL Open Font License 1.1，授權全文見 `public/fonts/OFL.txt`。中文沿用系統黑體，macOS 優先使用 PingFang TC。Tabler 圖示授權見 `public/icons/TABLER-LICENSE.txt`。網站其餘程式碼沿用上層專案的 AGPL-3.0 授權。

英文示範影片中的會議文字衍生自 AMI Meeting Corpus（CC BY 4.0），演示人物使用虛構姓名。完整出處、改作與授權連結見 `public/media/en/ATTRIBUTION.md`，影片視窗亦提供來源連結。

`public/media/{app,en/app}/` 為 `promo/public/footage/{zh,en}/` 的實錄擷取，保留完整 App 排版，只有縮放與 WebP 壓縮。首頁、功能範例、人物、詞彙與摘要場景均使用這些真實畫面。
