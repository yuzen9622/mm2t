# 參與貢獻

感謝你願意參與 mm2t。這份文件說明如何回報問題、送 pull request，以及為什麼需要簽署 CLA。

## 回報問題

在 [GitHub Issues](https://github.com/yuzen9622/mm2t/issues) 開新 issue，附上：

- macOS 版本、Mac 機型（Apple 晶片或 Intel）、mm2t 版本。
- 會議平台與加入方式（桌面 App 或哪個瀏覽器）。
- 重現步驟、你預期的結果、實際的結果。

不要在 issue 裡貼 API 金鑰、錄音檔或含有他人發言的逐字稿。

## 開發環境

建置與測試方式見 [README.md 的「從原始碼建置」](README.md#從原始碼建置)。送 pull request 前，請確認：

1. `swift test` 全部通過。需要說話者分群模型或 `Evaluation/` 錄音的測試，在缺少這些檔案時會自動略過。
2. App 能用 `xcodebuild` 建置。
3. 新增或修改 UI 字串時，直接在 `App/MM2T/Localizable.xcstrings` 加上繁體中文翻譯（使用臺灣用語），並讓 `python3 App/Tools/strings.py <derived-data-path>` 回傳 0。
4. 改動對外連線（`Sources/MM2TProviders`）或處理流程送出的資料時，同步更新 [PRIVACY.md](PRIVACY.md)。

CI（`.github/workflows/ci.yml`）會在每個 pull request 上執行第 1 到 3 項。

## 分支

- `development`：日常整合分支。從它開分支，pull request 也以它為目標。
- `release`：只用來發布，由維護者從 `development` 合併，tag 只打在這個分支上。
- `main`：預設分支，內容等於最新一次發布。請不要直接對它開 pull request。

發布流程見 [docs/releasing.md](docs/releasing.md)。

## 更新 CHANGELOG

使用者看得到的變更（新功能、行為改變、修正、移除、安全性問題）都要在 [CHANGELOG.md](CHANGELOG.md) 的 `## [Unreleased]` 底下加一行，歸入 `Added`、`Changed`、`Deprecated`、`Removed`、`Fixed` 或 `Security`，用繁體中文（臺灣用語）寫，描述使用者感受到的改變而不是程式細節。純內部重構、測試與 CI 調整不需要寫。

維護者發布時，會把 `[Unreleased]` 的內容移到新的版本標題底下。Release workflow 把該版本的區段當作 GitHub Release 與自動更新的版本說明，區段不存在時發布會失敗。

## Commit 與 pull request

- Commit 訊息採 [Conventional Commits](https://www.conventionalcommits.org/)，例如 `feat(app): ...`、`fix(diarization): ...`、`build: ...`。
- Pull request 以 `development` 為目標。一個 pull request 只做一件事，說明為什麼要改，以及你怎麼驗證，並更新 CHANGELOG（見下方）。
- 新加入的相依套件或模型，授權必須與 AGPL-3.0 相容，並加進 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 貢獻者授權協議（CLA）

外部貢獻需要簽署 [CLA.md](CLA.md)。mm2t 以 AGPL-3.0 開源，CLA 讓維護者日後能以其他授權（例如商業授權或付費託管版本）散布包含你貢獻的版本。你保留自己貢獻的著作權。

### 怎麼簽

你第一次送 pull request 時，[CLA Assistant](https://cla-assistant.io) 會在 pull request 留言，附上簽署連結。用你的 GitHub 帳號登入並同意 CLA 即可。簽一次就涵蓋你之後所有的 pull request。

如果 pull request 中有多位作者，每一位都要簽。Commit 的作者 email 必須連結到某個 GitHub 帳號，CLA Assistant 才認得出是誰。

### 怎麼強制執行

CLA Assistant 會在每個 pull request 上回報 `license/cla` 狀態檢查。`development` 與 `release` 分支的保護規則要求這項檢查通過，所以沒有簽 CLA 的 pull request 無法合併。

簽署紀錄（GitHub 帳號、簽署時間、CLA 版本）由 CLA Assistant 保存。

## 維護者：啟用 CLA 檢查

這些步驟只需要做一次：

1. 建立一個公開的 GitHub Gist，內容是 `CLA.md` 的全文。CLA Assistant 從 Gist 讀取協議內容。
2. 用 GitHub 帳號登入 [cla-assistant.io](https://cla-assistant.io)，選擇 `yuzen9622/mm2t` 儲存庫與上一步的 Gist，按 **Link**。
3. 在 GitHub 儲存庫的 **Settings > Branches**（或 **Rules > Rulesets**）為 `development` 與 `release` 加上規則：合併前必須通過 `license/cla` 狀態檢查。同一條規則也可以要求 CI 的 `Swift package tests` 與 `App build and translations` 通過。
4. 開一個測試用的 pull request，確認 CLA Assistant 有留言，且 `license/cla` 出現在檢查清單中。

修改 `CLA.md` 時，同步更新 Gist。CLA Assistant 會要求所有人重新簽署新版本。
