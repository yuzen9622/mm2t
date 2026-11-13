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

開場透過 LayoutGroup／layoutId 將中央大字移入 Hero；其他首屏內容依序顯示。大字與目標共用字體比例，沒有整頁圖片變形。減少動態模式直接顯示完成畫面。

第二區塊的 sticky 父層保持 block，避免 flex 垂直置中提前消耗第一點的行程。整段 4.6 個視窗高度，扣掉固定畫面的 1 個視窗高度，三點各有 1.2 屏行程。較窄或較短畫面直接排列完整文字與截圖。

波形依照 FloatingContent.swift 的 11 柱、2.5pt 寬／間距、六筆歷史與漸縮公式；新樣本從中央向兩側傳遞。黑色膠囊與大型展示共用此元件。動畫是展示訊號，不是麥克風輸入。

## 驗證

ESLint、TypeScript、靜態建置、兩個語言的 HTML／錨點／資源／文案，以及 Tabler 與 App 原檔的逐檔比對通過。lockfile 通過 frozen offline 驗證。

瀏覽器畫面與互動尚未驗證：本執行環境無法連線 localhost:3000，先前截圖工具回報 Chrome did not start。沒有以建置成功宣稱視覺、焦點操作或效能測量通過。
