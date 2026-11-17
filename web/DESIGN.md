# 設計與實作紀錄

官方網站延續 mm2t 的暖白 `#F6F5F1`、側欄灰 `#EEEDE8`、深色 `#1B1B1D`、橘色 `#F0700F`。展示實際 App 畫面，保留原側欄、分頁、說話者面板與文字配置。

## 最終技術結構

- Next.js App Router、React 19、TypeScript、Tailwind CSS 4。
- shadcn/ui 手動安裝的 Radix 版本：Button、Dialog、Sheet、Tabs、Accordion、Card。
- Motion 處理共享 layout、scroll progress、轉場與波形；元件自行管理生命週期。
- Tabler 圖示直接共用 App 內附 SVG，逐檔檢查完全一致。
- globals.css 僅保留 Tailwind 入口、App 色彩／shadcn tokens、字體和基礎規則。排版、響應式、hover 與元件狀態使用 Tailwind utilities。
- 原本 public/assets 的獨立動畫 JS/CSS 已移除，沒有額外的 DOM 搬動腳本。

使用者指定這個技術方向，因此以 React／Tailwind 實作取代設計套件原本建議的獨立腳本流程。

## 互動

2026-11-17 重新設計：移除開場大字飛入、Hero 截圖 3D 傾斜與各區塊捲動淡入，改為一個 Hero 進場、一個捲動場景與一個逐字點亮的聲明。App 畫面全部以 HTML 重建，不再縮放截圖。

捲動場景 `#flow` 分三拍：膠囊淹滿舞台（錄音）、2 倍放大的逐字稿依 karaoke 讀出並由「說話者 A」換成姓名（辨識），最後鏡頭拉遠成完整的深色 mm2t 視窗（逐字稿）。三拍屬於同一個功能流程，不把不同功能的介面互相變形。

色彩只用 App 的象牙底、側欄灰、深色與橘色；橘色只標示錄音中或正在說的位置。時間戳一律等寬字。

## 驗證

ESLint、TypeScript、靜態建置、兩個語言的 HTML／錨點／資源／文案，以及 Tabler 與 App 原檔的逐檔比對通過。lockfile 通過 frozen offline 驗證。

瀏覽器畫面與互動尚未驗證：本執行環境無法連線 localhost:3000，先前截圖工具回報 Chrome did not start。沒有以建置成功宣稱視覺、焦點操作或效能測量通過。
