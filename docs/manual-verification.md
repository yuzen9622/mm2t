# 手動驗證清單：錄音與會議偵測（MM2TSystem）

AudioRecorder 與系統訊號來源依賴 macOS 權限與真實的會議 App，無法以單元測試涵蓋到底。本清單逐項用 `mm2t-probe` 驗證。每一項都寫出「操作」與「預期結果」，結果不符時把 probe 的完整輸出貼進 issue。

## 0. 準備

1. 在專案根目錄建置：

   ```sh
   swift build
   ```

2. 建立 probe 的 App 外殼。macOS 會把權限記在「負責的 App」名下；直接在終端機執行 probe 時，負責的 App 是終端機本身，而終端機的 Info.plist 沒有 `NSAudioCaptureUsageDescription`，系統會**不跳提示、直接拒絕**系統音訊擷取，遠端音軌會是全零。`make-app` 會產生帶有三個用途說明鍵、以 ad-hoc 簽章的 `MM2T Probe.app`：

   ```sh
   .build/debug/mm2t-probe make-app
   ```

   之後所有指令都透過這個 App 執行，輸出會導回目前的終端機。以下以 `probe` 代表這一串：

   ```sh
   probe() { open -n -W --stdout "$(tty)" --stderr "$(tty)" "$HOME/Applications/MM2T Probe.app" --args "$@"; }
   ```

   每次重新 `swift build` 後都要重跑 `make-app`；ad-hoc 簽章改變後，系統可能把它當成新 App 而要求重新授權。

3. 確認歸屬正確：

   ```sh
   probe permissions
   ```

   預期：`TCC attributes this probe to dev.mm2t.probe`，且三個 `Ns…UsageDescription` 都是 `present`。

## 1. 權限引導與缺權限的路徑（user story 12、13）

| # | 操作 | 預期結果 |
|---|------|----------|
| 1.1 | 尚未授權麥克風時執行 `probe record "Google Chrome" --seconds 3` | 立即失敗，印出 `error: microphoneAccessNotDetermined` 與 `x-apple.systempreferences:…Privacy_Microphone`，且沒有留下錄音資料夾 |
| 1.2 | 執行 `probe request-permissions`，在麥克風提示中按「不允許」，再重跑 1.1 | 印出 `microphoneAccessDenied` 與同一個設定連結 |
| 1.3 | 到「系統設定 › 隱私權與安全性 › 麥克風」打開 MM2T Probe，重跑 `probe permissions` | `microphone granted` |
| 1.4 | 執行 `probe tap-selftest`，第一次會跳出「系統音訊錄製」提示，按「不允許」 | 錄音約 6 秒後印出 `event: remoteSilentWhileTargetPlaying`，結尾 `FAIL: remote track is digital silence`。系統音訊被拒時，tap 不會報錯而是給全零，這個事件就是 App 判斷「缺系統音訊權限」的依據 |
| 1.5 | 到「系統設定 › 隱私權與安全性 › 螢幕與系統音訊錄製」下方的「僅限系統音訊錄製」打開 MM2T Probe，重跑 `probe tap-selftest` | `PASS: tapped the helper's tone and excluded the other process`，440 Hz 約 -20 dB 以上、1000 Hz 低於它 30 dB 以上 |
| 1.6 | `probe request-permissions` 時在「輔助使用」提示中前往設定並打開 MM2T Probe；Chrome 開著時接受「控制 Google Chrome」 | `probe permissions` 顯示 `accessibility granted`、`automation com.google.Chrome granted` |
| 1.7 | 撤銷輔助使用與自動化權限，執行 `probe signals --seconds 20`，在 Zoom 桌面版入會 | 仍偵測到 Zoom（`EVENT detected zoom desktop`）；`title=-`、`url=-`。桌面版偵測只靠麥克風訊號，不需要這兩個權限 |

tap-selftest 會在一個暫存的 `Tone.app/Contents/Helpers/Player.app` 中以輔助程序播放 440 Hz，另用 `/usr/bin/afplay` 播 1000 Hz 干擾音，只擷取 `dev.mm2t.probe.tone`。它同時驗證三件事：系統音訊權限、輔助程序歸屬到外層 App、其他 App 的聲音被排除。執行時喇叭會發出小聲的嗶聲。

## 2. 會議偵測與結束（user story 1–3、7）

先執行 `probe processes`，確認會議 App 與瀏覽器的輔助程序都歸屬到正確的 App（`owner app` 欄），例如 `com.google.Chrome.helper` 應歸屬 `com.google.Chrome`、Safari 的 `com.apple.WebKit.GPU` 應歸屬 `com.apple.Safari`。

每一列都另開一個終端機執行 `probe signals --seconds 300`，再進行操作：

| # | 平台 | 操作 | 預期 |
|---|------|------|------|
| 2.1 | Zoom 桌面版 | 加入會議 | `mic=` 含 `us.zoom.xos`，出現 `EVENT detected zoom desktop target=us.zoom.xos` |
| 2.2 | Teams 桌面版 | 加入會議 | `EVENT detected teams desktop target=com.microsoft.teams2` |
| 2.3 | Webex 桌面版 | 加入會議 | `EVENT detected webex desktop target=Cisco-Systems.Spark`（若 bundle id 不同，記下 `processes` 顯示的實際值並回報） |
| 2.4 | Google Meet（Chrome） | 開啟 `meet.google.com/xxx-xxxx-xxx` 並入會，Chrome 在前景 | `url=https://meet.google.com/…`，`EVENT detected googleMeet browser target=com.google.Chrome` |
| 2.5 | Google Meet（Safari） | 同上，用 Safari | `mic=` 含 `com.apple.Safari`（經 WebKit GPU 程序歸屬），偵測到 googleMeet |
| 2.6 | Meet，無自動化權限 | 撤銷 Chrome 自動化、保留輔助使用，重做 2.4 | `url=-` 但 `title="Meet - xxx-xxxx-xxx…"`，仍偵測到 googleMeet |
| 2.7 | Zoom / Teams / Webex 網頁版 | 在 Chrome 入會 | 分別偵測為 zoom / teams / webex browser |
| 2.8 | 結束 | 每個平台離開會議 | App 放開麥克風後約 3 秒內（release grace）出現 `EVENT ended`；入會中切換分頁或 App 不會結束 |
| 2.9 | 短暫中斷 | 會議中把輸入裝置切到另一支麥克風再切回 | 不出現 `ended` 後又 `detected` 的抖動 |

## 3. 錄音、雙軌與只擷取目標 App（user story 9、10、11）

| # | 操作 | 預期 |
|---|------|------|
| 3.1 | 在 Zoom 會議中執行 `probe record zoom.us --seconds 60 --out ~/mm2t-probe/zoom`，自己說話、也請對方說話 | 每 0.5 秒印出兩條音量條；自己說話時 `me` 跳動，對方說話時 `remote` 跳動 |
| 3.2 | 錄音同時用「音樂」App 播歌 | `remote` 不受音樂影響；用 `probe analyze ~/mm2t-probe/zoom` 檢查遠端軌只有會議聲音 |
| 3.3 | Teams、Webex 桌面版各重做 3.1 | 同上 |
| 3.4 | Meet：`probe record "Google Chrome" --seconds 60 --out ~/mm2t-probe/meet`，期間在**另一個** Chrome 分頁播 YouTube | YouTube 聲音**會**進入遠端軌。這是以瀏覽器程序為單位擷取的已知限制，對應 user story 11 的提醒文案 |
| 3.5 | 用 QuickTime 開啟 `mic.wav` 與 `remote.wav` | 兩檔皆可播放，16 kHz 單聲道，長度相同（`analyze` 第一行的 difference 為 0 ms） |

## 4. 暫停／繼續與時間對齊（user story 8、20）

1. 在任一會議中執行：

   ```sh
   probe record zoom.us --seconds 40 --pause-at 10 --resume-at 20 --highlight-at 25 --out ~/mm2t-probe/pause
   ```

2. 在牆鐘第 5 秒左右對著麥克風拍一下手，同時請對方也在第 5 秒拍手（或讓會議 App 播放一段有明顯起音的聲音）。在暫停期間（第 10–20 秒）說一句「這句不該被錄到」。
3. 預期：
   - 結尾 `duration` 約 30 秒（40 減 10 秒暫停）。
   - `highlights` 約為 15 秒（牆鐘 25 秒減 10 秒暫停）。
   - `probe analyze ~/mm2t-probe/pause` 中兩軌長度相同；用音訊編輯器（如 Audacity）同時開兩檔，拍手的起音在兩軌落在同一時間點（誤差數十毫秒內，含聲音經過網路的延遲）。
   - 暫停期間那句話不在任一軌中，暫停前後的聲音直接相接。
4. 重複暫停／繼續三次以上，檢查最後一段的拍手在兩軌仍對齊（不會累積偏移）。

## 5. 崩潰與休眠復原（user story 14）

| # | 操作 | 預期 |
|---|------|------|
| 5.1 | 執行 `probe record zoom.us --seconds 600 --highlight-at 30 --out ~/mm2t-probe/crash`，約 60 秒時在另一個終端機 `pkill -9 -f "MM2T Probe"` | 程序被殺 |
| 5.2 | 不修復直接 `afinfo ~/mm2t-probe/crash/remote.wav` | 可讀，長度約為被殺時間減 1 秒以內。檔頭每秒更新一次，所以未修復的檔案已是合法 WAV |
| 5.3 | `probe recover ~/mm2t-probe/crash` | 印出 `session was interrupted; repairing`，`duration` 約 60 秒，`highlights` 含約 30 秒；兩軌長度差在 1.5 秒以內 |
| 5.4 | 錄音中蓋上筆電（休眠）1 分鐘再打開，錄滿後停止 | 不崩潰；休眠前的音訊完整；若喚醒後裝置沒有自動恢復，會看到 `event: captureRestarted(…)`，之後音量條恢復跳動 |

## 6. 裝置變更（不中斷錄音）

在會議中執行 `probe record zoom.us --seconds 120 --out ~/mm2t-probe/device`，期間依序：

| # | 操作 | 預期 |
|---|------|------|
| 6.1 | 插入有線耳機（或連上 AirPods） | 錄音不停；若預設輸入改變，印出 `event: microphoneSwitched(deviceName: "…")`，之後 `me` 音量條來自新麥克風 |
| 6.2 | 在「系統設定 › 聲音 › 輸入」手動切換預設輸入 | 同 6.1 |
| 6.3 | 拔掉耳機 | 錄音不停；`remote` 持續有聲音（遠端 tap 不綁定輸出裝置） |
| 6.4 | 切換 AirPods 的取樣率會變的模式（例如在會議中改用 AirPods 麥克風，會從 48 kHz 降為 16/24 kHz） | 不出現變調；`analyze` 結果兩軌長度一致 |
| 6.5 | 停止後 `probe analyze ~/mm2t-probe/device` | 兩軌等長；切換瞬間可能有不到 2 秒的靜音，之後的聲音沒有位移 |

## 7. 回報

每項結果記錄「通過／不通過／無法測（原因）」。不通過時附上：`probe permissions`、`probe processes --all` 的輸出，以及該項 probe 指令的完整輸出與錄音資料夾。
