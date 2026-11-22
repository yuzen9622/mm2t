export type Locale = "zh" | "en";

/** Shared keys keep the App's Traditional Chinese terminology consistent. */
export const english: Record<string, string> = {
  // Model guide and plan comparison
  "全英文會議首選 Parakeet。有華語發言，又想讓字幕跟上對話，首選 Nemotron。": "Choose Parakeet for English-only meetings. When people speak Mandarin and you want captions to keep up, choose Nemotron.",
  "辨識速度很快，適合全英文會議，也適合使用法語、德語等歐洲語言的場合。": "Speech recognition is fast. Use it for English-only meetings or other supported European languages such as French and German.",
  "華語和英語都能快速出字，適合需要一邊看字幕、一邊跟上討論的人。": "Captions appear quickly in both Mandarin and English, so you can read along while following the discussion.",
  "擅長辨識台灣華語裡穿插的英文術語，但出字很慢，字幕容易落在發言後面。較適合會後轉錄。": "It handles English terms in Taiwanese Mandarin well, but captions are slow to appear and can lag behind the speaker. A better fit for transcribing after the meeting.",
  "首選 Apple Translation，其次是 Hy-MT2。Bergamot 可作為備選。": "Try Apple Translation first, then Hy-MT2. Bergamot is a fallback.",
  "我們測過的會議短句翻得快，也能準確傳達原意。Mac 已安裝所需語言包時，優先選它。": "It translated short meeting captions quickly and accurately in our tests. Choose it first when the language packs are installed on your Mac.",
  "翻譯準確，遇到會議術語也有不錯的表現。譯文會比原文字幕晚一點出現。": "Accurate translations that handle meeting terminology well. The translation appears a little after the original caption.",
  "翻得快，但在我們測過的會議短句中較容易譯錯細節，適合用來掌握大意。": "It translates quickly, but missed more details in our short meeting captions. Useful for following the gist.",
  "想盡快拿到逐字稿，或想保留中英夾雜的用字，可以依錄音內容來選。": "Choose based on the recording: a quick turnaround for an English meeting, or careful handling of Mandarin mixed with English.",
  "全英文或其他支援的歐洲語言錄音，首選 Parakeet，很快就能拿到逐字稿。": "The first choice for a quick transcript of a recording in English or another supported European language.",
  "想快速整理有華語發言的錄音，或同一場會議裡有人說中文、有人說英文，可優先選它。": "Choose this for a quick transcript when people speak Mandarin, including meetings with both Mandarin and English speakers.",
  "台灣華語裡夾雜英文人名、產品名或術語時，Breeze 較能保留原話。轉錄較慢，適合願意等完整逐字稿的人。": "Breeze is a good fit for Taiwanese Mandarin mixed with English names, products or technical terms. Allow more time for the complete transcript.",
  "華語、英語、日語、韓語等": "Mandarin, English, Japanese, Korean and more",
  "即時字幕翻譯": "Live caption translation",
  "繁中與英文互譯，也可選已安裝的目標語言": "Traditional Chinese ↔ English, plus installed target languages",
  "繁中與英文互譯，也可譯成日、韓、德、捷文等": "Traditional Chinese ↔ English, with targets including Japanese, Korean, German and Czech",
  "繁中或英文可直譯成法、西、越、捷文等": "From Traditional Chinese or English directly into French, Spanish, Vietnamese, Czech and more",
  "模型比較": "Model comparison",
  "定價": "Pricing",
  "Free 幫你在會後查回誰說了什麼。Standard 和 Pro 讓你開會時就能看字幕與翻譯，會後也能不限次數用 AI 提問或改寫。": "Use Free to find who said what after the meeting. With Standard or Pro, follow live captions and translations as people speak, then ask AI questions or rewrite your notes as often as you like.",
  "無限": "Unlimited",
  "未包含": "Not included",
  "偶爾開會，會後整理重點": "For occasional meetings and notes afterwards",
  "回放原音核對細節": "Replay the recording to check a detail",
  "從會議摘要找回決議": "Find decisions in the meeting summary",
  "每週例會，開會當下就跟上討論": "Follow the discussion in weekly meetings",
  "邊聽邊看即時字幕": "Read live captions as people speak",
  "用即時翻譯跟上外語發言": "Follow speakers in another language with live translation",
  "會後不限次數向 AI 追問": "Ask unlimited follow-up questions after the meeting",
  "長時間訪談，留足整月的處理時數": "More hours for a month of long interviews",
  "包含 Standard 的所有即時功能": "Includes every live feature in Standard",
  "會後不限次數改寫訪談紀錄": "Rewrite interview notes as often as you need",
  "免費額度每月重置": "Free allowances reset monthly",
  "首次訂購・首月優惠": "First month for new subscribers",
  "原價": "Regular price",
  "次月起每人每月": "Then per person each month:",
  "（含稅）": " (tax included)",
  "每人每月・含稅": "per person / month, tax included",
  "每月雲端額度": "Monthly cloud allowances",
  "分鐘": "min",
  "次": "requests",
  "小時": "hours",
  "雲端會議處理": "Cloud meeting processing",
  "AI 使用額度": "AI usage allowance",
  "Free 的單場 AI 助理與跨場會議整理合計每月可用 30 次。": "On Free, single-meeting AI tools and cross-meeting tasks share a total of 30 requests per month.",
  "基礎模型轉錄，逐字稿標示每位說話者": "Get a speaker-labeled transcript with the basic model",
  "進階模型提供更好的轉錄品質": "Get higher-quality transcripts with the advanced model",
  "使用與 Standard 相同的進階轉錄模型": "Use the same advanced transcription model as Standard",
  "轉錄品質與即時功能": "Transcription quality and live features",
  "基礎模型": "Basic model",
  "進階模型": "Advanced model",
  "轉錄模型": "Transcription model",
  "每月共用": "Shared monthly",
  "跨場會議整理": "Working across meetings",
  "向 AI 查詢多場會議的決議": "Ask AI about decisions across meetings",
  "由 AI 建議會議資料夾分類": "Get AI suggestions for filing meetings into folders",
  "單場會議 AI 助理": "AI assistance within one meeting",
  "自備金鑰可使用全部功能": "Use every feature with your own API keys",
  "錄音與會後整理": "Recording and meeting notes",
  "錄音": "Recording",
  "會後逐字稿": "Post-meeting transcript",
  "說話者辨識": "Speaker identification",
  "搜尋": "Search",
  "回放": "Playback",
  "匯出": "Export",
  "即時字幕": "Live captions",
  "即時轉錄": "Live transcription",
  "即時翻譯": "Live translation",
  "AI 提問": "Ask AI a question",
  "AI 改寫": "Rewrite text with AI",
  "所有方案都能自備金鑰使用完整功能，包含會議中的即時功能。用量由你的服務商計費，保留 mm2t 的每月額度。": "Use your own API keys on any plan to access every feature, including live meeting tools. Your provider bills this usage directly, so your monthly mm2t allowances stay available.",
  "／月": "/ month",
  "方案概覽": "Plan overview",
  "各方案功能對照": "Compare plan features",
  "功能": "Feature",
  "已包含": "Included",
  "使用自己的 API 金鑰": "Using your own API keys",
  "台灣華語、中英夾雜": "Taiwanese Mandarin and Mandarin mixed with English",
  "華語、英語、法語等 90 多種語言": "90+ languages including Mandarin, English and French",
  "即時語音與字幕": "Live speech and captions",
  "需要多語即時字幕，並希望由雲端處理語音。": "For multilingual live captions with speech processing in the cloud.",
  "會後轉錄": "Recorded meetings",
  "英、法、德、西語等 25 種歐洲語言": "25 European languages including English, French, German and Spanish",
  "華語、英語、日語等多種語言": "Mandarin, English, Japanese and more",
  "使用 Intel Mac，或透過 Rosetta 執行 App 時的本機選擇。": "An on-device option for an Intel Mac or for running the app under Rosetta.",
  "需要雲端逐字稿、說話者標籤與逐字時間戳記。": "For cloud transcripts with speaker labels and word-level timestamps.",
  "地端大語言模型": "On-device language model",
  "逐字稿完成後，由 Mac 在本機整理。建議使用配備 16 GB 以上記憶體的 Apple 晶片 Mac。": "Summarize the transcript on your Mac. An Apple silicon Mac with at least 16 GB of memory is recommended.",
  "繁體中文、英文等": "Traditional Chinese, English and more",
  "從逐字稿整理重點與待辦，保留英文術語。模型下載約 5.7 GB。": "Extract key points and action items while keeping English terms intact. The model download is about 5.7 GB.",
  "依用途瀏覽模型": "Browse models by task",

  // Header and navigation
  跳至主要內容: "Skip to content",
  主要導覽: "Main navigation",
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
  "人物卡會標出聲紋來自現場或線上通話。儲存逐字稿修正後，mm2t 會學習你改過的人名與術語，也可以手動新增詞彙。":
    "People cards show whether a voiceprint came from the room or a call. Save a transcript correction to teach mm2t names and terms, or add them to your vocabulary by hand.",

  // Privacy
  隱私與資料: "Privacy and your data",
  "錄音、聲紋和會議紀錄都存在": "Recordings, voiceprints and notes stay on",
  "這台 Mac": "this Mac",
  "。選用雲端轉錄時，音訊會送到服務商；選用雲端摘要時，則會送出逐字稿。":
    ". If you choose cloud transcription, the provider receives the audio. For cloud summaries, it receives the transcript.",
  "API 金鑰存在 macOS 鑰匙圈": "API keys are kept in the macOS Keychain",
  "聲紋辨識在 Mac 本機完成": "Speaker recognition runs on your Mac",
  "不錄螢幕，視窗也不會出現在螢幕分享": "No screen recording, and its windows stay out of screen shares",
  閱讀隱私權政策: "Read the privacy policy",

  // FAQ
  "安裝步驟、支援的服務與每項設定，都寫在 GitHub 的使用文件。":
    "Installation, supported services and every setting are covered in the docs on GitHub.",
  閱讀使用文件: "Read the docs",
  "mm2t 是免費的嗎？": "Is mm2t free?",
  "mm2t 採用 AGPL-3.0 授權。你可以免費使用本機模型，或自備 API 金鑰使用全部功能，由服務商計費。規劃中的免費方案每月包含 120 分鐘，由 mm2t 負擔轉錄與雲端處理費用。":
    "mm2t is open source under AGPL-3.0. Use local models for free, or access every feature with your own API keys and pay your provider directly. The planned Free tier covers transcription and cloud processing for 120 meeting minutes each month.",
  "需要什麼版本的 Mac？": "Which Macs are supported?",
  "需要 macOS 14.2 以上。下載 DMG 後，將 mm2t 拖入「應用程式」，首次啟動時依設定精靈授予錄音與會議偵測所需的權限。":
    "You'll need macOS 14.2 or later. Download the DMG and drag mm2t into Applications. The setup assistant will guide you through the permissions needed for recording and meeting detection.",
  查看安裝說明: "Installation guide",
  "會有機器人加入會議嗎？": "Does a bot join my meeting?",
  "不會。mm2t 直接擷取你的麥克風與會議 App 音訊，支援 Google Meet、Microsoft Teams、Zoom 與 Webex。它不錄製畫面，視窗也不會出現在螢幕分享中。":
    "No. mm2t captures your microphone and meeting app audio directly, supporting Google Meet, Microsoft Teams, Zoom, and Webex. It doesn't record your screen, and its windows stay out of screen shares.",
  "可以完全不使用雲端服務嗎？": "Can I avoid cloud services entirely?",
  "可以。在支援的 Mac 上下載語音與語言模型後，就能在本機轉錄與整理摘要。你也可以連到自己架設的轉錄伺服器。":
    "Yes. Download the speech and language models on a supported Mac to transcribe and summarize locally. You can also connect your own transcription server.",
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
  版本紀錄: "Changelog",
  原始碼: "Source code",

  // The rebuilt App
  首頁: "Home",
  會議: "Meetings",
  人物: "People",
  詞彙: "Vocabulary",
  設定: "Settings",
  逐字稿: "Transcript",
  整理版逐字稿: "Cleaned transcript",
  依人彙整: "By person",
  摘要: "Summary",
  說話者: "Speaker",
  全部: "All",
  開始記錄: "Start Recording",
  我的資料夾: "My Folders",
  未分類: "Unfiled",
  說明: "Help",
  管理待辦事項: "Manage action items",
  來源: "Source",
  新增詞彙: "Add terms",
  從修正學習: "Learned from corrections",
  手動新增: "Manually added",
  全選搜尋結果: "Select all results",
  取消選取: "Deselect all",
  刪除: "Delete",
  儲存: "Save",
  取消: "Cancel",
  編輯詞彙: "Edit term",
  "刪除選取的詞彙？": "Delete selected terms?",
  沒有符合的結果: "No results",
  "以逗號或換行分隔，一次新增多個詞彙。": "Separate terms with commas or new lines.",
  "儲存逐字稿修正後，mm2t 會將修正的人名和術語加入詞彙庫。": "When you save a transcript correction, mm2t automatically adds the names and terms you corrected to your vocabulary.",
  新增: "Add",
  現場: "In the room",
  線上通話: "On calls",
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
  討論重點: "Discussion points",
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
