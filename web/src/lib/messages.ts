export type Locale = "zh" | "en";

/** Shared keys keep the App's Traditional Chinese terminology consistent. */
export const english: Record<string, string> = {
  // Header and navigation
  跳至主要內容: "Skip to content",
  主要導覽: "Main navigation",
  使用流程: "How it works",
  四種讀法: "Four views",
  隱私: "Privacy",
  常見問題: "FAQ",
  "mm2t 首頁": "mm2t home",
  "下載 mm2t": "Download mm2t",
  "在 GitHub 查看 mm2t 原始碼": "View mm2t on GitHub",
  開啟導覽選單: "Open navigation",
  網站導覽: "Navigation",
  "選擇想查看的官網章節。": "Choose a section to explore.",
  關閉導覽選單: "Close navigation",
  手機版導覽: "Mobile navigation",

  // Hero
  "直接錄下麥克風與會議 App 的聲音，不需要機器人進會議。會後在 Mac 上分出說話者，整理成逐字稿與摘要。":
    "Records your microphone and the meeting app directly, with no bot in the call. Afterwards your Mac tells the speakers apart and writes the transcript and summary.",
  "免費開源 · macOS 14.2 以上": "Free and open source · macOS 14.2 or later",
  "錄得到這些會議 App": "Records calls in",
  觀看示範: "Watch the demo",
  "一分鐘看懂 mm2t": "Meet mm2t in 44 seconds",
  關閉示範影片: "Close demo",
  "mm2t 的實際操作示範：錄音、命名說話者與查看摘要。影片以畫面文字說明，沒有口述。":
    "See mm2t record meetings, identify speakers, and create summaries. This demo uses on-screen text, with no narration.",
  "mm2t 操作示範": "mm2t product demo",
  繁體中文: "English",
  "你的瀏覽器無法播放影片，請": "Your browser cannot play this video. Please ",
  下載示範影片: "download the demo",

  // Recording capsule demo
  錄音膠囊互動示範: "Interactive recording capsule demo",
  取消麥克風請求: "Cancel microphone request",
  暫停麥克風: "Pause microphone",
  開啟麥克風試試: "Try your microphone",
  結束麥克風體驗: "Finish microphone demo",
  "請允許麥克風權限，再點一下重試。": "Allow microphone access, then click to try again.",
  "無法使用麥克風，請確認裝置與瀏覽器設定後重試。":
    "Microphone unavailable. Check your device and browser settings, then try again.",
  等待麥克風權限: "Waiting for microphone permission",
  "麥克風已開啟，聲音僅在此裝置分析，不會儲存或上傳。":
    "Microphone on. Audio is analyzed only on this device, never saved or uploaded.",
  "點擊麥克風，讓波形跟著你的聲音。": "Click the microphone to see your voice move the waveform.",

  // Flow scene
  "錄下會議，": "Record the meeting,",
  標出每位說話者: "name every speaker",
  "偵測到會議，一按就錄": "Spots the meeting, records on one click",
  "Google Meet、Teams、Zoom 或 Webex 開始時，選單列的膠囊會問你要不要錄音。":
    "When Google Meet, Teams, Zoom or Webex starts, a capsule in the menu bar asks whether to record.",
  分出每位說話者: "Tells each speaker apart",
  "麥克風與遠端聲音分兩軌錄，在 Mac 上辨識說話者。命名一次，下次自動套用聲紋。":
    "Your mic and the remote audio are recorded on two tracks and sorted by speaker on your Mac. Name a voice once and it is matched next time.",
  整理成逐字稿: "Writes the transcript",
  "每句話附上說話者與時間，點一下就從那裡重播。":
    "Every line carries its speaker and time. Click one to play the meeting back from there.",

  // Views
  "同一場會議，四種讀法": "One meeting, four ways to read it",
  "要找原話時看逐字稿，只要結論時看摘要。點上方的分頁切換，這就是 App 裡的畫面。":
    "Read the transcript for the exact words, or the summary for the decisions. Switch the tabs above: this is the screen in the app.",
  選擇會議紀錄格式: "Choose a meeting note format",

  // Memory
  記住常見的與會者和團隊用語: "Remembers your regulars and your team's words",
  "同一個人在會議室和線上通話各存一份聲紋。會議中聽到的專有名詞，以及你改過的字，會自動加進詞彙庫。":
    "Each person keeps one voiceprint for the meeting room and one for calls. Names heard in meetings, and words you correct, join your vocabulary on their own.",

  // Privacy
  隱私與資料: "Privacy and your data",
  "錄音、聲紋和會議紀錄都存在": "Recordings, voiceprints and notes stay on",
  "這台 Mac": "this Mac",
  "。mm2t 沒有自己的伺服器：轉錄和摘要用你自己的 API 金鑰直接連到服務商，也可以改用你自架的轉錄伺服器。":
    ". mm2t runs no servers of its own: transcription and summaries go straight to the provider with your own API key, or to a transcription server you host.",
  "API 金鑰存在 macOS 鑰匙圈": "API keys are kept in the macOS Keychain",
  "聲紋辨識在 Mac 本機完成": "Speaker recognition runs on your Mac",
  "不錄螢幕，視窗也不會出現在螢幕分享": "No screen recording, and its windows stay out of screen shares",
  閱讀隱私權政策: "Read the privacy policy",

  // FAQ
  "安裝步驟、支援的服務與每項設定，都寫在 GitHub 的使用文件。":
    "Installation, supported services and every setting are covered in the docs on GitHub.",
  閱讀使用文件: "Read the docs",
  "mm2t 是免費的嗎？": "Is mm2t free?",
  "mm2t 免費、開放原始碼，採用 AGPL-3.0 授權。選用 ElevenLabs、Google Gemini 等雲端服務時，需填入自己的 API 金鑰，使用費由服務商直接計算。也可以使用自己的轉錄伺服器。":
    "mm2t is free and open source under AGPL-3.0. Cloud services such as ElevenLabs and Google Gemini require your own API keys and bill you directly for usage. You can also connect your own transcription server.",
  "需要什麼版本的 Mac？": "Which Macs are supported?",
  "需要 macOS 14.2 以上。下載 DMG 後，將 mm2t 拖入「應用程式」，首次啟動時依設定精靈授予錄音與會議偵測所需的權限。":
    "You'll need macOS 14.2 or later. Download the DMG and drag mm2t into Applications. The setup assistant will guide you through the permissions needed for recording and meeting detection.",
  查看安裝說明: "Installation guide",
  "會有機器人加入會議嗎？": "Does a bot join my meeting?",
  "不會。mm2t 直接擷取你的麥克風與會議 App 音訊，支援 Google Meet、Microsoft Teams、Zoom 與 Webex。它不錄製畫面，視窗也不會出現在螢幕分享中。":
    "No. mm2t captures your microphone and meeting app audio directly, supporting Google Meet, Microsoft Teams, Zoom, and Webex. It doesn't record your screen, and its windows stay out of screen shares.",
  "可以完全不使用雲端服務嗎？": "Can I avoid cloud services entirely?",
  "可以自架轉錄伺服器，讓音訊在自己的設備之間傳輸。本機轉錄與本機語言模型仍在開發中；若選用雲端摘要，逐字稿文字仍會傳至所選服務商。":
    "You can self-host a transcription server to keep audio between your own devices. On-device transcription and local language models are still in development. If you choose cloud summaries, transcript text is still sent to the selected provider.",
  查看資料處理方式: "How data is processed",
  "第一次開啟時被 macOS 擋住怎麼辦？": "What if macOS blocks the first launch?",
  "目前版本尚未有 Developer ID 簽章與 Apple 公證。請先核對 GitHub Release 來源，再依該版本說明，在「系統設定 → 隱私權與安全性」選擇「仍要打開」。":
    "The current release is not yet Developer ID signed or notarized by Apple. Verify that you downloaded it from the official GitHub release, then follow that release's instructions to choose Open Anyway in System Settings → Privacy & Security.",
  查看版本與安裝步驟: "Release and installation steps",

  // Close and footer
  "mm2t 應用程式圖示": "mm2t app icon",
  "下一場會議，": "Your next meeting,",
  "交給 mm2t 記錄": "noted by mm2t",
  "在 GitHub 查看原始碼": "View the source on GitHub",
  頁尾連結: "Footer links",
  隱私權政策: "Privacy policy",
  使用條款: "Terms of use",
  版本紀錄: "Releases",
  原始碼: "Source code",

  // The rebuilt App
  首頁: "Home",
  會議: "Meetings",
  人物: "People",
  詞彙: "Vocabulary",
  設定: "Settings",
  逐字稿: "Transcript",
  整理版逐字稿: "Clean transcript",
  依人彙整: "By speaker",
  摘要: "Summary",
  說話者: "Speaker",
  全部: "All",
  自動新增: "Auto-added",
  新品發表會: "Launch event",
  新增: "Add",
  會議室現場: "In person",
  線上通話: "Online call",
  "1 個聲紋": "1 voiceprint",
  "2 個聲紋": "2 voiceprints",
  "3 個聲紋": "3 voiceprints",

  // The demo meeting (src/lib/meeting.ts)
  陳志明: "Zhiming Chen",
  陳: "C",
  林佳怡: "Jiayi Lin",
  林: "L",
  王建宏: "Jianhong Wang",
  王: "W",
  張雅婷: "Yating Zhang",
  張: "Z",
  新款手機上市行銷與通路規劃: "New phone launch: marketing and channels",
  "好，嗯，我們今天針對新產品的上市，呃，討論一下目標客群跟行銷方向。":
    "OK, um, today we're, uh, going over the audience and marketing direction for the new launch.",
  "我們今天針對新產品的上市，討論一下目標客群與行銷方向。":
    "Today we're going over the audience and marketing direction for the new launch.",
  "我覺得這款手機的外觀比較時尚嘛，所以不必、不必把客群侷限在單一年齡層。":
    "I think the phone looks pretty stylish, so we don't, we don't need to tie it to one age group.",
  "這款手機的外觀比較時尚，我覺得不必把客群侷限在單一年齡層。":
    "The phone looks stylish, so I don't think we need to tie it to one age group.",
  "嗯，我覺得還是要有明確的受眾，才能決定後面的廣告跟通路策略。":
    "Hmm, I still think we need a clear audience before we pick the ads and the channels.",
  "我覺得還是要有明確的受眾，才能決定後續的廣告與通路策略。":
    "I still think we need a clear audience before we decide on ads and channels.",
  "對，那我建議先鎖定 18 到 45 歲的中青年，呃，再看長輩需要哪些規格。":
    "Right, so I'd start with 18 to 45, uh, then see what older buyers need.",
  "我建議先鎖定 18 至 45 歲的中青年客群，再評估長輩需要的規格。":
    "I suggest we start with 18 to 45, then look at what older buyers need.",
  "主持新手機上市討論，確認目標客群鎖定在 18 至 45 歲之間。":
    "Led the launch discussion and settled the target audience at ages 18 to 45.",
  "提出可考慮電商、電信商合作或找大 V 直播帶貨。":
    "Proposed online stores, carrier deals or livestream sales with major creators.",
  "認為客群不必劃分太嚴格，長輩也能接受亮色系外觀。":
    "Argued the audience need not be narrow; older buyers like bright colours too.",
  "擔心多平台同時直播影響利潤，建議推廣排定完整流程。":
    "Worried that livestreams on several platforms would cut margins; asked for a full schedule.",
  "主張客群設定要有明確針對性，這款手機更適合年輕人。":
    "Wants a clearly defined audience; sees the phone as a better fit for younger buyers.",
  "提議贈送印有品牌 LOGO 的限量手機殼或盲盒。": "Suggested limited branded cases or blind boxes as gifts.",
  "建議鎖定 18 至 45 歲客群，為長輩另做字體與音量設計。":
    "Suggested ages 18 to 45, with larger type and louder audio settings for older buyers.",
  "建議贈品成本控制在 50 元以內，可洽談盲盒廠商合作。":
    "Suggested keeping each gift under 50 dollars and talking to blind-box makers.",
  決議: "Decisions",
  討論重點: "Discussion",
  待辦事項: "Action items",
  "目標客群鎖定為 18 至 45 歲的中青年與年輕族群，產品設計主推年輕化。":
    "Target buyers aged 18 to 45, with a design aimed at younger buyers.",
  "促銷通路以主流電商平台與網紅直播帶貨為主，暫不聘請高價明星代言。":
    "Sell through major online stores and creator livestreams; no celebrity endorsement for now.",
  "贈品採「盲盒」形式，單個贈品成本控制在 50 元以內。": "Gifts come as blind boxes, each under 50 dollars.",
  "目標客群範圍：林佳怡主張放寬到年長者；王建宏與張雅婷認為應集中在 18 至 45 歲。":
    "Audience: Jiayi Lin wants to include older buyers; Jianhong Wang and Yating Zhang prefer 18 to 45.",
  "通路與價格：多平台同時促銷可能造成價格混亂，團隊討論分時段秒殺與直播限定價。":
    "Channels and pricing: parallel promotions could muddle prices; the team discussed timed flash sales and livestream-only prices.",
  "聯繫贈品與盲盒製造商比價，並準備直播用樣品。": "Get quotes from gift and blind-box makers, and prepare livestream samples.",
  "請設計團隊提出主打色的多版配色方案。": "Ask the design team for several colourways of the lead colour.",
  "各部門於下週二前提出推廣執行方案與進度表。": "Each team sends its launch plan and timeline by next Tuesday.",
  大V: "KOL",
  直播帶貨: "Livestream sales",
  合約機: "Contract phone",
  雙十一: "Singles' Day",
  盲盒: "Blind box",
};
