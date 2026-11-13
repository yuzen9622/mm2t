import { Icon } from "@/components/icon";
import { REPO, DOWNLOAD } from "./shared";

export function getFaqs(t: (text: string) => string) {
  return [
    {
      question: "mm2t 是免費的嗎？",
      answer: (
        <>
          {t(
            "mm2t 免費、開放原始碼，採用 AGPL-3.0 授權。選用 ElevenLabs、Google Gemini 等雲端服務時，需填入自己的 API 金鑰，使用費由服務商直接計算。也可以使用自己的轉錄伺服器。",
          )}
        </>
      ),
    },
    {
      question: "需要什麼版本的 Mac？",
      answer: (
        <>
          {t(
            "需要 macOS 14.2 以上。下載 DMG 後，將 mm2t 拖入「應用程式」，首次啟動時依設定精靈授予錄音與會議偵測所需的權限。",
          )}
          <a href={`${REPO}#installation`} target="_blank" rel="noreferrer">
            {t("查看安裝說明")}
            <Icon name="diagonal" size={14} />
          </a>
        </>
      ),
    },
    {
      question: "會有機器人加入會議嗎？",
      answer: (
        <>
          {t(
            "不會。mm2t 直接擷取你的麥克風與會議 App 音訊，支援 Google Meet、Microsoft Teams、Zoom 與 Webex。它不錄製畫面，視窗也不會出現在螢幕分享中。",
          )}
        </>
      ),
    },
    {
      question: "可以完全不使用雲端服務嗎？",
      answer: (
        <>
          {t(
            "可以自架轉錄伺服器，讓音訊在自己的設備之間傳輸。本機轉錄與本機語言模型仍在開發中；若選用雲端摘要，逐字稿文字仍會傳至所選服務商。",
          )}
          <a
            href={`${REPO}/blob/main/PRIVACY.md`}
            target="_blank"
            rel="noreferrer"
          >
            {t("查看資料處理方式")}
            <Icon name="diagonal" size={14} />
          </a>
        </>
      ),
    },
    {
      question: "第一次開啟時被 macOS 擋住怎麼辦？",
      answer: (
        <>
          {t(
            "目前版本尚未有 Developer ID 簽章與 Apple 公證。請先核對 GitHub Release 來源，再依該版本說明，在「系統設定 → 隱私權與安全性」選擇「仍要打開」。",
          )}
          <a href={DOWNLOAD} target="_blank" rel="noreferrer">
            {t("查看版本與安裝步驟")}
            <Icon name="diagonal" size={14} />
          </a>
        </>
      ),
    },
  ];
}
