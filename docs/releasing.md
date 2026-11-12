# 發布新版本

推送 `vX.Y.Z` 格式的 git tag 後，`.github/workflows/release.yml` 會：

1. 以 tag 的版本號設定 `CFBundleShortVersionString` 與 `CFBundleVersion`（兩者都是 `X.Y.Z`），用 Release 組態封存（archive）App。
2. 以 Developer ID Application 憑證匯出並簽章 App。
3. 把 App 送去公證，完成後 staple。
4. 建立 `mm2t-X.Y.Z.dmg`（APFS、lzfse 壓縮，內含 App 與「應用程式」捷徑），簽章、公證、staple。
5. 下載上一個 Release 的 `appcast.xml`，加入新版本的項目與 EdDSA 簽章，並把 GitHub 自動產生的版本說明嵌入項目中。
6. 建立 GitHub Release，上傳 DMG 與 `appcast.xml`。

## 未簽章模式（暫時）

還沒設定 `MACOS_CERTIFICATE_P12_BASE64` secret 時，workflow 的「Choose signed or unsigned mode」步驟會切到未簽章模式，改做：

1. 用 Release 組態封存 App，以 ad-hoc 簽章（`CODE_SIGN_IDENTITY=-`）。因為 ad-hoc 簽章沒有 Team ID，hardened runtime 的 library validation 會拒絕載入 Sparkle 與 llama 等 framework，所以 workflow 會加上 `com.apple.security.cs.disable-library-validation` entitlement，再用 `codesign --force --sign -` 重新簽 App 本身（framework 保留 Xcode 給的 ad-hoc 簽章）。
2. 建立同樣格式的 `mm2t-X.Y.Z.dmg`，不簽章、不公證。
3. 跳過 Sparkle 公鑰檢查與 appcast，Release 只上傳 DMG。
4. 在 GitHub 自動產生的版本說明前面，加上未簽章 App 的安裝說明（按右鍵 **打開**、**系統設定 > 隱私權與安全性 > 仍要打開**，或 `xattr -dr com.apple.quarantine /Applications/mm2t.app`）。

未簽章版本的限制：

- 使用者第一次打開時會看到 Gatekeeper 警告，必須依版本說明手動允許。
- 沒有 appcast，`SUPublicEDKey` 也還是佔位字串，App 內不會出現 **檢查更新⋯**，使用者要自己回 Releases 下載新版。
- ad-hoc 簽章的身分每個版本都不同，更新後 macOS 可能重新詢問麥克風、系統音訊錄製等權限，鑰匙圈中的 API 金鑰也可能要求重新允許存取。

完成下面「一次性設定」的第 2 到第 4 步後，下一個 tag 就會自動走簽章、公證與 appcast 的流程，不需要修改 workflow。注意第一次切到簽章版時，舊的未簽章版本沒有 appcast 可以檢查，使用者仍要手動下載一次。

App 的 `SUFeedURL` 是 `https://github.com/yuzen9622/mm2t/releases/latest/download/appcast.xml`，永遠指向最新一個正式 Release 的 appcast。每個 Release 的 appcast 都包含最近 3 個版本。

## 一次性設定

### 1. 公開儲存庫

Sparkle 與使用者下載 DMG 時不會登入 GitHub。儲存庫維持私有的話，`appcast.xml` 與 DMG 的下載網址都會回應 404，更新功能無法運作。第一次發布前，把儲存庫設為公開。

### 2. Developer ID Application 憑證

建立憑證需要 Apple Developer Program 的 Account Holder 身分。

1. 在 Xcode 打開 **Settings > Accounts**，選擇你的 Apple ID 與團隊，按 **Manage Certificates⋯**。
2. 按 **+**，選擇 **Developer ID Application**。
3. 打開「鑰匙圈存取」，在「我的憑證」中找到 `Developer ID Application: <你的名字> (<Team ID>)`，展開後連同私密金鑰一起選取，按右鍵選擇 **輸出 2 個項目⋯**，存成 `.p12` 並設定密碼。
4. 把 `.p12` 轉成 base64 並存成 secret：

   ```bash
   base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64 --repo yuzen9622/mm2t
   gh secret set MACOS_CERTIFICATE_PASSWORD --repo yuzen9622/mm2t   # 貼上第 3 步設定的密碼
   ```

Team ID 不需要另外設定。workflow 從憑證名稱括號中的 Team ID 讀取。

### 3. 公證用的 App Store Connect API 金鑰

1. 到 [App Store Connect > 使用者與存取權限 > 整合 > App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)，在 **團隊金鑰** 新增一把金鑰，存取權限選 **Developer**。
2. 下載 `AuthKey_<Key ID>.p8`。這個檔案只能下載一次。
3. 記下頁面上的 **Issuer ID** 與這把金鑰的 **Key ID**。
4. 存成 secret：

   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set APP_STORE_CONNECT_API_KEY_P8_BASE64 --repo yuzen9622/mm2t
   gh secret set APP_STORE_CONNECT_KEY_ID --repo yuzen9622/mm2t      # 例如 XXXXXXXXXX
   gh secret set APP_STORE_CONNECT_ISSUER_ID --repo yuzen9622/mm2t   # UUID 格式
   ```

### 4. Sparkle 的 EdDSA 金鑰

Sparkle 用這組金鑰確認更新檔真的由你發布。**私鑰遺失的話，已安裝的 App 就再也收不到更新**，請把私鑰備份到密碼管理工具。

1. 先用 Xcode 建置一次 App，讓 Swift Package Manager 下載 Sparkle 與它的工具：

   ```bash
   xcodebuild -project App/MM2T.xcodeproj -scheme mm2t -configuration Debug \
     -derivedDataPath .build/xcode-release build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
   ```

2. 產生金鑰。私鑰存進登入鑰匙圈，終端機會印出公鑰：

   ```bash
   .build/xcode-release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

3. 把 `App/Config/Info.plist` 中 `SUPublicEDKey` 的佔位字串 `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` 換成印出的公鑰，然後 commit。公鑰可以公開。
4. 匯出私鑰、存成 secret，再刪除匯出的檔案：

   ```bash
   bin=.build/xcode-release/SourcePackages/artifacts/sparkle/Sparkle/bin
   $bin/generate_keys -x sparkle_private_key.txt
   gh secret set SPARKLE_ED_PRIVATE_KEY --repo yuzen9622/mm2t < sparkle_private_key.txt
   rm sparkle_private_key.txt
   ```

`SUPublicEDKey` 還是佔位字串時，簽章模式的 release workflow 會在檢查公鑰的步驟失敗，App 也不會啟動 Sparkle。

### 5. Developer ID 描述檔（選用）

有了描述檔，App 會把 API 金鑰存進資料保護鑰匙圈（data protection keychain），同一個團隊簽出的每個版本都能直接讀取，更新後不會再跳出鑰匙圈密碼視窗。沒有設定時，金鑰照舊存在登入鑰匙圈。

1. 到 [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) 註冊 macOS App ID `dev.mm2t.app`（不需要勾選額外功能）。
2. 在 **Profiles** 新增 **Developer ID** 類型的描述檔，App ID 選 `dev.mm2t.app`，憑證選第 2 步的 Developer ID Application 憑證，下載 `.provisionprofile`。
3. 存成 secret：

   ```bash
   base64 -i mm2t_Developer_ID.provisionprofile | gh secret set MACOS_PROVISIONING_PROFILE_BASE64 --repo yuzen9622/mm2t
   ```

release workflow 會把描述檔嵌進 App、加上 `TEAM_ID.dev.mm2t.app` 鑰匙圈存取群組，並在匯出後檢查兩者都在。第一次以新版本啟動時，App 會把登入鑰匙圈裡的舊金鑰搬過去，macOS 可能會再問一次。

### Secret 一覽

| Secret | 內容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application 憑證與私密金鑰（`.p12`）的 base64 |
| `MACOS_CERTIFICATE_PASSWORD` | `.p12` 的密碼 |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | App Store Connect API 金鑰（`.p8`）的 base64 |
| `APP_STORE_CONNECT_KEY_ID` | 上述金鑰的 Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API 的 Issuer ID |
| `SPARKLE_ED_PRIVATE_KEY` | `generate_keys -x` 匯出的 Sparkle EdDSA 私鑰 |
| `MACOS_PROVISIONING_PROFILE_BASE64` | 選用：`dev.mm2t.app` 的 Developer ID 描述檔（`.provisionprofile`）的 base64 |

`GITHUB_TOKEN` 由 GitHub Actions 自動提供，不需要設定。

## 每次發布

1. 確認 `main` 上的 CI 通過，且要發布的 commit 已推送。
2. 建立並推送 tag。版本號必須是 `X.Y.Z`，而且大於上一版，因為 Sparkle 依 `CFBundleVersion` 判斷新舊：

   ```bash
   git tag -a v0.2.0 -m "mm2t 0.2.0"
   git push origin v0.2.0
   ```

3. 看 workflow 執行。公證通常要幾分鐘，最久可能一小時：

   ```bash
   gh run watch --repo yuzen9622/mm2t
   ```

4. 到 [Releases](https://github.com/yuzen9622/mm2t/releases) 檢查新版本有 `mm2t-X.Y.Z.dmg` 與 `appcast.xml`。需要的話，修改版本說明。

`App/MM2T.xcodeproj` 裡的 `MARKETING_VERSION` 與 `CURRENT_PROJECT_VERSION` 只用於本機建置，發布時由 tag 覆寫，不需要每次修改。

## 發布後檢查

1. 下載 DMG，確認簽章與公證：

   ```bash
   spctl --assess --type open --context context:primary-signature --verbose=2 mm2t-0.2.0.dmg
   ```

   預期輸出包含 `accepted` 與 `source=Notarized Developer ID`。

2. 打開 DMG，把 App 拖進「應用程式」並執行，確認沒有出現 Gatekeeper 警告。
3. 確認更新流程：在另一台 Mac（或先刪除新版）安裝上一版，從選單列選擇 **檢查更新⋯**，應該會看到新版本與版本說明，並能完成安裝。要強制立刻檢查，先執行 `defaults delete dev.mm2t.app SULastCheckTime`。

## 發布失敗時

- **Workflow 在某一步失敗**：修正後在 Actions 頁面按 **Re-run all jobs**。Release 已經存在時，workflow 會覆蓋上傳 DMG 與 `appcast.xml`，而不是建立新的 Release。
- **需要改 tag 指向的 commit**：先刪除 Release 與 tag，再重新建立：

  ```bash
  gh release delete v0.2.0 --repo yuzen9622/mm2t --yes
  git push --delete origin v0.2.0
  git tag -d v0.2.0
  ```

- **公證被拒（Invalid）**：workflow 會印出 `notarytool log` 的內容，列出哪個檔案的簽章或 hardened runtime 有問題。
- **「the X.Y.Z item has no sparkle:edSignature」**：`SPARKLE_ED_PRIVATE_KEY` 和 `Info.plist` 裡的 `SUPublicEDKey` 不是同一組。`generate_appcast` 遇到這種情況不會報錯，只會產生沒有簽章的項目，Sparkle 會拒絕安裝，所以 workflow 會在這裡停下。

## 建置環境

Workflow 在 GitHub 的 `macos-26` runner 上執行，用 `maxim-lobanov/setup-xcode` 選擇 runner 上最新的穩定版 Xcode。Swift package 需要 Swift 6.2 以上（Xcode 26 以上）。如果程式碼開始用到 runner 上 Xcode 還沒有的 Swift 或 SDK 功能，請改用更新的 runner 標籤，或改用自架 runner。
