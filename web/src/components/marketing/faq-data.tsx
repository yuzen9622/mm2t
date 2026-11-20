import { Icon } from "@/components/icon";
import { REPO, DOWNLOAD } from "./shared";

export function getFaqs(t: (text: string) => string) {
  return [
    {
      question: "mm2t 是免費的嗎？",
      answer: (
        <>
          {t(
            "mm2t 採用 AGPL-3.0 授權。你可以免費使用本機模型，或自備 API 金鑰使用全部功能，由服務商計費。規劃中的免費方案每月包含 120 分鐘，由 mm2t 負擔轉錄與雲端處理費用。",
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
            "可以。在支援的 Mac 上下載語音與語言模型後，就能在本機轉錄與整理摘要。你也可以連到自己架設的轉錄伺服器。",
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
