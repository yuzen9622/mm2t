# 變更記錄

這個專案的所有重要變更都記錄在這份文件。

格式依循 [Keep a Changelog 1.1.0](https://keepachangelog.com/zh-TW/1.1.0/)，版本號依循[語意化版本 2.0.0](https://semver.org/lang/zh-TW/)。

## [Unreleased]

### Added

- App 介面新增英文，英文為找不到對應語言時的預設語言。

### Fixed

- 英文會議的摘要與待辦改用英文回覆，不再一律轉成中文。

## [0.1.1] - 2026-11-12

### Added

- 公開文件改寫成產品介紹頁，開發者文件移到 `docs/`。

### Changed

- 在 `Info.plist` 填入 Sparkle 公鑰，簽章版本可以透過 Sparkle 自動更新。

## [0.1.0] - 2026-11-12

第一個公開版本。

### Added

- 常駐選單列的會議記錄工具：偵測 Google Meet、Microsoft Teams、Zoom 與 Webex 會議後詢問是否錄音，會議結束倒數後自動停止。
- 麥克風與系統音訊分成兩條音軌錄製，在 Mac 本機做說話者分群與聲紋比對；替說話者命名後，之後的會議自動標上名字。
- 聲紋區分會議室現場與線上通話兩種聲音，並可認領自己的聲音。
- 即時逐字稿，以及 STFT 為基礎的回音消除，降低會議室喇叭回灌造成的重複內容。
- 離線模式：本機語音辨識與 LLM 推論，並可管理本機模型。
- 會議摘要（含標題）、待辦事項，逐字稿與摘要一律轉成繁體中文。
- 逐字稿編輯、會議重新命名、複製文字與匯出 SRT 字幕。
- 首頁儀表板，整合 Google 與 Microsoft 行事曆，顯示今日會議與待辦。
- 詞彙學習與詞彙管理，改善專有名詞的辨識。
- 瀏海位置的倒數膠囊、詞雲與全域提示框。
- 以 Sparkle 提供應用程式內更新。
- 自架 faster-whisper 轉錄伺服器與說話者分群評測工具。
- 應用程式圖示、授權、隱私權政策與服務條款、開發與發布文件，以及 GitHub Actions 的 CI 與發布流程。

### Changed

- 最低支援版本調高為 macOS 14.2。
- Google 行事曆登入改用 iOS 型態的 OAuth 用戶端與 `ASWebAuthenticationSession`。
- 沒有 Developer ID 簽章時，發布流程改為產生 ad-hoc 簽章的 DMG，並在版本說明附上安裝方式。

### Fixed

- 以 Swift 6.2 建置時明確呼叫 `Subtitles.cues`。
- 補上缺漏的繁體中文翻譯，移除未使用的字串。
- 將聲紋建議門檻調高為 0.70。
- 修正回音消除的取樣率檢查與影格長度對齊。
- 修正瀏海倒數膠囊在只有轉圈圖示時位置偏移。
- 修正系統音訊權限預檢的回傳型別（32 位元列舉）。

[Unreleased]: https://github.com/yuzen9622/mm2t/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/yuzen9622/mm2t/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/yuzen9622/mm2t/releases/tag/v0.1.0
