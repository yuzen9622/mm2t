# 設計與驗證紀錄

Kind: software — macOS 會議記錄工具。主行動：下載 mm2t。

配色使用 App 的既有 tokens，取代抽取的 cool-white-slate。首頁採 split，風格為暖白 Soft Structuralism 與 Editorial Split；結尾採產品圖示與大型下載行動。字體改用本機可用的 Geist 搭配 PingFang TC，延續 App 的系統中文；不使用需要在建置時下載的字體。滾動 moment 為 pinned-chapters；counter-rolls 缺乏可支持的實證數字，因此排除後重抽。

## 使用者優先的取捨

- 使用者明確要求 App 相同風格，因此保留 App 色彩、圖示筆畫與中文系統字體。
- 使用者明確要求滾動動畫，因此採區塊進場與滾動章節。桌面導覽使用浮動膠囊，依 high-end-visual-design 的方向處理。
- 不額外加入不相關的 shader、虛構客戶、假成效數字或等待清單。
- 保留套件內 pinned-chapters 原始程式，未為通過檢查修改檢查器或套件。手機與 reduced-motion 使用套件的靜態排列。

## 區塊

| 區塊 | 目的 | 素材與互動 |
| --- | --- | --- |
| Hero | Mac 會議記錄、下載與示範 | 依真實 App 重建的 HTML 介面、錄音膠囊、影片 Dialog |
| Experience | 說明錄音到摘要的流程 | 原有 App 截圖，桌面滾動章節；小螢幕靜態排列 |
| Features | 四種輸出格式 | HTML App 預覽、手動操作的 Radix Tabs |
| Details | 聲紋與個人詞彙 | 真實產品功能的 UI 示意、有限次 hover 波形 |
| Assembly | 將零散資訊收束成摘要 | 巨型標題縮回、四面板飛入、三層資訊顯現、整體移至側邊；使用未修改的 parts-lock-into-the-whole 套件 |
| Privacy | 解釋本機資料與處理去向 | App 深色配色、本機／服務商的資料路徑示意 |
| FAQ | 費用、需求與限制 | Radix Accordion |
| Closing | 下載與開源專案 | 既有圖示、GitHub Releases 及文件連結 |

Voice: 沿用 README 的直接繁體中文；以會議記錄、說話者、聲紋與 API 等既有產品名詞描述功能，不宣稱未量測的速度或辨識準確率。

## 檢查紀錄

`GATE: ERROR (consistency.mjs gave no report (exit 1: Error: no free port in 5200-5299); check.mjs could not run)`

自動截圖工具也無法取得 5300–5399 的監聽埠。依工具要求，在此環境未重跑 gate。這是執行環境限制，不是視覺或互動檢查通過。

- `next build --webpack`：通過，產出靜態首頁、404 與圖示。
- `tsc --noEmit`：通過。
- `eslint .`：通過。
- `check-export.mjs`：檢查所有 SSR 參照資源、動態素材、錨點、語言、下載連結與分享資訊。
- copy-lint：0 FAIL、1 WARN（7 個 eyebrow／kicker）。為中文長頁的區塊辨識保留短標籤；未設定 waiver。
- 桌面 1440、1024，平板 820、768，手機 390、320 的瀏覽器檢查未能執行；響應式 CSS 已實作，但不能將此視為視覺驗證。
- 效能、影片播放、焦點陷阱、鍵盤切換與 reduced-motion 的實際瀏覽器行為待可用本機預覽環境確認。

沒有未提供的客戶照片、假表單端點或假聯絡資訊。正式 canonical 網域待設定；下載與文件均有既有目的地。沒有捏造產品數據或引用見證。

## 英文與進階動態更新

- 使用者追加完整英文版與更大膽的滾動設計。`/en/` 使用獨立英文根佈局、metadata 和本專案英文截圖／影片；`/` 保留繁體中文。跨語言切換使用完整頁面導覽，讓動畫套件隨新文件重新初始化。
- 共享文案集中於 `src/lib/messages.ts`，操作介面、替代文字、FAQ、對話框與圖像標籤均翻譯；透過匯出檢查避免英文頁殘留中文正文。
- Hero 使用 Motion 的原生 scroll progress 與 spring，驅動視窗的 y／rotateX／rotateZ／scale；手機和 reduced-motion 停用。
- 新增 parts-lock-into-the-whole 大場景，使用 2.4 屏的捲動行程。從巨型摘要文字、面板重組、聲紋和摘要顯現，到待辦與末段說明。沒有劫持滾輪。影片不是背景自動播放素材。
- 保留組裝套件 JS/CSS 原檔，頁面樣式只調整產品視覺與排版；靜態畫面的高度隨翻譯文字伸展，避免裁切。
- Next 多個根佈局使用 `experimental.globalNotFound` 提供完整的雙語 404 導覽。
- 本次外接瀏覽器截圖仍回報 `Chrome did not start`，且 `localhost:3000` 沒有可連線的伺服器，因此尚未驗證真實瀏覽器的動畫中間狀態、響應式版面或互動。

## 依實際 App 修正（含開場）

使用者指出重畫的 UI 與 App 不同，因此以此要求覆蓋前版的 HTML 組裝展示。Hero、功能 Tabs、人物、詞彙與滾動摘要改用 promo 的真實 App 錄影擷取；未修改其側欄、分頁、說話者面板與內容配置。移除自創錄音通知與四面板組裝場景。功能範例提供三個已取得實拍素材的格式，不將逐字稿圖片冒充整理版逐字稿。

Waveform 對齊 FloatingContent.swift：11 根、2.5pt 寬／間距、6 筆歷史、中央最新樣本向兩側傳遞、`3 + 21 * sample * (1 - distance / 6 * .75)`。錄音膠囊維持黑底白波形，新增可暫停／播放控制。大場景放大同一個波形，再帶出完整真實摘要畫面。示範訊號由程式產生，沒有讀取使用者麥克風。

第二區塊過快的原因是 `.section` 的 flex 置中使 sticky stage 在較晚的位置才進場，加上三點僅共用一屏行程。現在使用 block 父層，從區塊頂端 pin；hold 為 3.6 屏，三點各 1.2 屏。只在頁面 CSS 修正，套件 JS 保留原檔。

依追加需求，使用 Motion LayoutGroup 與相同 layoutId，將中央大字移入 Hero wordmark。等待 650ms 後以 spring 飛入，其他首屏內容錯開出現；任何捲動、觸控、鍵盤操作可提前結束等待。無 JS／減少動態提供直接內容回退。

程式、雙語匯出與資源檢查已通過；當前 localhost:3000 仍無法連線，未將這些檢查當成瀏覽器視覺驗證。
