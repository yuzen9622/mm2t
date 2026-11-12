# mm2t

mm2t 是原生 macOS 會議記錄 App。它常駐選單列，在 Google Meet、Microsoft Teams、Zoom、Webex 開會時錄下你的麥克風和會議 App 的聲音，會後產生帶發言者的逐字稿、整理版逐字稿、依人彙整和會議摘要。

- 不派 Bot 進會議，也不錄畫面。
- 兩條音軌分開錄：「我」（麥克風）和「遠端」（只擷取會議 App 或瀏覽器的聲音）。
- 說話者分群和聲紋比對都在 Mac 上執行。認出過的人，下次會議會自動填上名字。
- 錄音、聲紋資料庫和會議紀錄只存在你的 Mac。
- 自備 API 金鑰（BYOK）：語音轉文字預設用 ElevenLabs Scribe v2，摘要等文字整理用 Google Gemini。也可以改用自架的轉錄伺服器。
- 錄音時螢幕頂端會出現膠囊，顯示時間、兩軌音量和控制按鈕。所有 mm2t 視窗都不會出現在螢幕分享畫面裡。

![會議清單](docs/screenshots/main-list.png)

## 安裝

需求：macOS 14.2 以上（Core Audio Process Tap 的最低版本）。

1. 到 [GitHub Releases](https://github.com/yuzen9622/mm2t/releases/latest) 下載 `mm2t-X.Y.Z.dmg`。
2. 打開 DMG，把 `mm2t.app` 拖到「應用程式」資料夾。
3. 從「應用程式」打開 mm2t。

DMG 和 App 都用 Developer ID 簽章並經過 Apple 公證，打開時不會出現「無法驗證開發者」的警告。

mm2t 用 [Sparkle](https://sparkle-project.org) 檢查更新。第二次啟動時它會詢問你要不要自動檢查；之後也可以從選單列選單的 **檢查更新⋯** 手動檢查。

## 第一次使用：授予權限

第一次打開時會出現設定精靈，逐一說明每個權限的用途。之後可以從選單列選單的 **設定精靈⋯** 回到這個視窗。所有權限都在 **系統設定 > 隱私權與安全性** 裡管理。

| 權限 | 用途 | 沒有的話 |
| --- | --- | --- |
| 麥克風 | 錄下「我」的音軌 | 無法錄音 |
| 系統音訊錄製 | 只錄會議 App 播放的聲音，作為「遠端」音軌 | 遠端音軌是靜音 |
| 輔助使用 | 讀取前景視窗標題，判斷是否在開會 | 只能手動開始錄音 |
| 自動化（各瀏覽器） | 讀取瀏覽器目前分頁的網址，偵測網頁版會議 | 無法偵測 Google Meet 等網頁版會議 |

權限被拒絕時，設定精靈會說明原因，並提供打開系統設定的按鈕。

錄 Google Meet 時，mm2t 擷取的是整個瀏覽器的聲音。開會時不要在同一個瀏覽器播放其他聲音，否則會一起被錄進去。

## 設定 API 金鑰

mm2t 不經過任何 mm2t 自己的伺服器。你填入自己的金鑰，費用由你的帳號直接支付。金鑰存在 macOS 鑰匙圈，不會以明文寫進磁碟。在主視窗的 **設定** 填入金鑰並按 **儲存**，mm2t 會先試用一次，確認金鑰可用。

- **ElevenLabs**（語音轉文字）：到 [ElevenLabs](https://elevenlabs.io/app/settings/api-keys) 建立 API 金鑰，需要有 Speech to Text 權限和足夠額度。驗證金鑰時會送出 0.5 秒的靜音，花費極少。
- **Google Gemini**（名字推測、整理版逐字稿、依人彙整、摘要）：到 [Google AI Studio](https://aistudio.google.com/apikey) 建立 API 金鑰。**請使用已啟用付費方案的金鑰。** 依 [Gemini API 條款](https://ai.google.dev/gemini-api/terms)，免費方案送出的內容可能被 Google 用來改進產品，付費方案則不會。

每種資料送到哪裡，請見 [隱私權政策](PRIVACY.md)。

## 自架轉錄伺服器

如果你有 NVIDIA GPU 主機，可以自架轉錄伺服器，讓音訊只在你自己的機器之間傳輸，也不用付語音轉文字的 API 費用。伺服器用 faster-whisper 執行 Breeze-ASR-25（針對台灣華語與中英夾雜），提供 Docker image。

部署方式見 [server/README.md](server/README.md)。部署好之後，在 mm2t 的設定裡填入伺服器網址（例如 Tailscale 網址 `http://gpu.tailnet:8000`），有設定 `MM2T_SERVER_TOKEN` 的話一併填入權杖。轉錄來源可以排順序：自架伺服器連不上時，mm2t 會改用下一個來源，並在結果中標示實際使用的來源。

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

從原始碼建置的 App 不會檢查更新：`App/Config/Info.plist` 裡的 `SUPublicEDKey` 是佔位字串時，mm2t 不啟動 Sparkle。

說話者分群模型（約 210 MB）不隨 App 附帶。在 **設定** 按 **下載**，App 會從 Hugging Face 下載模型到 `~/Library/Application Support/mm2t/Models`。

### Google Calendar 的 Desktop OAuth 本機設定

Google OAuth Client 必須是「電腦版應用程式」，且 `App/Config/Info.plist` 的 `MM2TGoogleClientID` 必須對應同一個 Client。若 Google 回報 `client_secret_required`，可由你在自己的 Terminal 輸入該 Client 既有的 secret，不要貼進聊天、Issue、命令列參數或 Git。

```bash
# 只在自己的互動式 Terminal 執行；輸入不回顯，也不進 shell history
python3 App/Tools/google_oauth.py configure

# 使用既有 Apple Development 憑證建置；不會開啟或重啟 App
python3 App/Tools/google_oauth.py build --team <你的 Team ID>
```

設定存放在 Git 忽略的 `App/Config/GoogleOAuth.local.plist`，權限為 `0600`。工具每次讀取當下的原始 Info.plist，保留 icon 等設定，僅在私有暫存副本加入 `MM2TGoogleClientSecret`，再交給 Xcode；不修改原始 Info.plist 或 Xcode 專案，也不把 secret 值放在建置參數中。一般 `xcodebuild`／Xcode 的 Build 不會自動載入此本機設定；需要 Google secret 的版本請用上述工具建置。

**Desktop client_secret 會包含在產出的 App bundle，能被取出，不是 App 身分或機密性的證明。** 它僅供 Google token 端點的協定相容；登入仍使用系統瀏覽器、每次獨立的 PKCE S256，以及成功、取消和錯誤回呼都必須通過的 state 驗證。secret 只送到 Google 的 HTTPS token/refresh POST，不放在授權網址、回呼頁、Microsoft 請求或診斷中。不要提交本機設定、分享含憑證的建置紀錄，或在未確認分發需求前上傳該產物。

建置完成後，等目前錄音／轉錄處理結束，再自行結束舊 App 並開啟 `.build/xcode/Build/Products/Debug/mm2t.app`。首次真實登入仍需你在 Google 的系統瀏覽器畫面完成授權。

本機設定工具的測試只使用合成資料：`python3 -m unittest discover -s App/Tools -p 'test_google_oauth.py'`。

### UI 字串翻譯

UI 字串以英文寫在程式碼裡，繁體中文翻譯放在 `App/Tools/zh-Hant.json`。建置之後執行下面的指令，它會重新產生 `App/MM2T/Localizable.xcstrings`，並在有字串缺翻譯或有翻譯沒用到時回傳非零：

```bash
python3 App/Tools/strings.py .build/xcode
```

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

## 參與貢獻

歡迎回報問題和送 pull request。外部貢獻需要簽署貢獻者授權協議（CLA），流程見 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 授權

mm2t 以 [GNU Affero General Public License v3.0](LICENSE) 授權。使用的第三方軟體與模型列在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

使用前請閱讀 [隱私權政策](PRIVACY.md) 與 [使用條款](TERMS.md)。
