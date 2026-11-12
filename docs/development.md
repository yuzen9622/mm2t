# 開發指南

給想從原始碼建置、修改或參與 mm2t 開發的人。一般使用者請看 [README](../README.md)。

## 從原始碼建置

需求：

- macOS 14.2 以上
- Xcode 26 以上（Swift 6.2 工具鏈）

```bash
git clone https://github.com/yuzen9622/mm2t.git
cd mm2t

# 執行 Swift package 的測試
swift test

# 建置 App（以 ad-hoc 簽章，只能在自己的 Mac 上執行）
xcodebuild -project App/MM2T.xcodeproj -scheme mm2t -configuration Debug \
  -derivedDataPath .build/xcode build \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
open .build/xcode/Build/Products/Debug/mm2t.app
```

macOS 依程式碼簽章記住權限。用 ad-hoc 簽章時，每次重新建置都可能需要重新授權。如果你有 Apple Development 憑證，改傳 `CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=<你的 Team ID>`，權限就能保留。

自己建置的 App 也會用 Sparkle 檢查正式版的更新。開發時不想讓它檢查，把 `App/Config/Info.plist` 的 `SUPublicEDKey` 清空即可（不要 commit 這個改動）。

說話者分群模型（約 210 MB）不隨 App 附帶。在 **設定** 按 **下載**，App 會從 Hugging Face 下載模型到 `~/Library/Application Support/mm2t/Models`。

## Google Calendar 的 OAuth 設定

App 沒有後端，任何放進 App bundle 的 client secret 都能被取出，所以 Google 改用不需要 secret 的 **iOS 類型** OAuth client（Google 官方給 macOS App 的做法），流程是 PKCE S256 + state 驗證。

1. Google Cloud Console → API 和服務 → 憑證 → 建立 OAuth 用戶端 ID，應用程式類型選 **iOS**，軟體包 ID 填 `dev.mm2t.app`。
2. 確認已啟用 Google Calendar API，OAuth 同意畫面加入 `https://www.googleapis.com/auth/calendar.readonly`。
3. 把用戶端 ID 填進 `App/Config/Info.plist` 的 `MM2TGoogleClientID`，照一般方式建置即可。

回呼網址是用戶端 ID 反轉後的自訂 scheme（例如 `com.googleusercontent.apps.1234-abc:/oauth2redirect`），由 `ASWebAuthenticationSession` 直接交回 App，不需在 Info.plist 註冊 URL type。如果登入顯示 `client_secret_required`，代表填的是「電腦版應用程式」client，請換成 iOS client。

## UI 字串翻譯

UI 字串以英文寫在程式碼裡，繁體中文翻譯放在 `App/Tools/zh-Hant.json`。建置之後執行下面的指令，它會重新產生 `App/MM2T/Localizable.xcstrings`，並在有字串缺翻譯或有翻譯沒用到時回傳非零：

```bash
python3 App/Tools/strings.py .build/xcode
```

## 發布新版本

推送 `vX.Y.Z` tag 就會觸發 GitHub Actions 建置 DMG 並建立 Release，細節與一次性設定見 [releasing.md](releasing.md)。

## 架構

```
App/MM2T/          SwiftUI App：選單列、膠囊、主視窗、設定、Sparkle 更新
Sources/
  MM2TApp/         App 層的控制器與 view model：錄音流程、處理佇列、設定、權限引導
  MM2TCore/        領域模型與核心邏輯，不碰系統或網路
  MM2TProviders/   雲端與自架服務的用戶端，以及鑰匙圈
  MM2TSystem/      macOS 系統邊界：Core Audio 錄音、會議偵測訊號、權限
  MM2TDiarization/ 本機說話者分群與聲紋向量（FluidAudio）
  MM2TLocal/       本機轉錄與本機 LLM（開發中）
  mm2t-probe/      診斷用 CLI：權限、音訊程序、錄音自我測試
server/            自架轉錄伺服器（Python、FastAPI、faster-whisper）
Evaluation/        說話者分群的評測資料與腳本
```

會議結束後，`MeetingProcessingPipeline`（`MM2TCore`）依序執行下列步驟，每一步的結果都會存檔，失敗時可以從失敗的那一步重試，錄音不會被刪除：

1. 在 Mac 上把遠端音軌分成不同說話者，並與聲紋資料庫比對。
2. 把兩條音軌分別送去轉錄，附上已知人名和自訂詞彙作為提示（`TranscriptionChain` 依設定的順序嘗試各來源）。
3. 對齊逐字時間戳記與說話者。
4. 請 LLM 推測還沒認出的說話者名字，只當作建議。
5. 產生整理版逐字稿、依人彙整和摘要。

主要模組：

- `MeetingDetector`：輸入系統訊號快照（哪些程序在用麥克風、前景視窗標題、瀏覽器網址），輸出「偵測到會議」或「會議結束」事件。判斷邏輯是純函式。
- `AudioRecorder`：用 Core Audio Process Tap 擷取目標程序的聲音，另外錄麥克風。兩軌邊錄邊寫入磁碟，App 當掉或電腦休眠時已錄的部分不會遺失。
- `VoiceprintStore`：本機聲紋資料庫。只有你改名、接受建議或合併說話者時才會寫入。
- `TranscriptionProvider` 與 `LLMProvider`：轉錄與 LLM 的介面。ElevenLabs Scribe、自架伺服器、Gemini 都實作在介面之後。
- `SpeakerEditing`：改名、接受建議、合併說話者。LLM 產出一律以說話者代號表示，顯示時才換成名字，所以改名立即生效，不用重新產生。
