// All on-screen words, per locale. The timeline, footage and soundtrack are shared.
export type Locale = 'zh' | 'en';

type Feature = { kicker: string; title: string[]; sub: string[] };

export type Copy = {
  hook: [string, string];
  descriptor: string;
  detect: Feature;
  speakers: Feature;
  summary: Feature;
  perPerson: Feature;
  local: Feature;
  dashboard: Feature;
  tagline: string;
};

export const COPY: Record<Locale, Copy> = {
  zh: {
    hook: ['會議一直講，', '筆記跟不上。'],
    descriptor: 'Mac 上的會議記錄 App',
    detect: {
      kicker: '自動偵測',
      title: ['會議一開始，它就知道。'],
      sub: ['Zoom、Google Meet、Teams、Webex 都能偵測，', '瀏海膠囊一鍵開錄，會議結束自動停止。'],
    },
    speakers: { kicker: '說話者分群', title: ['認得', '每一位講者'], sub: ['在 Mac 上分出說話者、比對聲紋，', '名字建議一點就套用。'] },
    summary: { kicker: 'AI 整理', title: ['決議、待辦', '一次整理好'], sub: ['整理版逐字稿與會議摘要，', '每一條都附上時間點。'] },
    perPerson: { kicker: 'AI 整理', title: ['誰說了什麼', '一目了然'], sub: ['依人彙整每位與會者的', '重點與承諾。'] },
    local: { kicker: '隱私', title: ['紀錄只存在', '你的 Mac'], sub: ['錄音、聲紋與會議紀錄都在本機；', '自備 API 金鑰，不經過 mm2t 伺服器。'] },
    dashboard: { kicker: '首頁', title: ['行事曆與待辦', '一頁看完'], sub: ['接上 Apple、Google 行事曆，', '會議的待辦自動彙整。'] },
    tagline: '開會，專心聽就好。',
  },
  en: {
    hook: ['Meetings move fast.', "Notes don't."],
    descriptor: 'Meeting notes for your Mac',
    detect: {
      kicker: 'Auto-detect',
      title: ["Join a call. It's ready."],
      sub: ['Spots Zoom, Google Meet, Teams and Webex.', 'One click in the notch to record. It stops when the call ends.'],
    },
    speakers: {
      kicker: 'Speakers',
      title: ['Every voice,', 'named.'],
      sub: ['Speakers split and matched by', 'voiceprint, right on your Mac.', 'One click accepts a suggested name.'],
    },
    summary: { kicker: 'AI notes', title: ['Decisions.', 'To-dos.', 'Done.'], sub: ['A clean transcript and a summary,', 'every point timestamped.'] },
    perPerson: { kicker: 'AI notes', title: ['Who said', 'what.'], sub: ["Each person's points and promises,", 'gathered in one place.'] },
    local: {
      kicker: 'Private',
      title: ['Your notes,', 'your Mac.'],
      sub: ['Recordings, voiceprints and notes', 'are stored only on this Mac.', 'Your own API keys. No mm2t servers.'],
    },
    dashboard: { kicker: 'Home', title: ['Your day,', 'at a glance.'], sub: ['Apple and Google Calendar,', "plus every meeting's to-dos."] },
    tagline: 'Just listen. mm2t takes the notes.',
  },
};
