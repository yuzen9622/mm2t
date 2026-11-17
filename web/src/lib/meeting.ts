/**
 * The demo meeting every rebuilt App view on the site reads from. Content follows the real App
 * captures in docs/assets (new phone launch meeting); names are fictional.
 */
export type Person = { name: string; initial: string; code: string };

export const people: Person[] = [
  { name: "陳志明", initial: "陳", code: "A" },
  { name: "林佳怡", initial: "林", code: "B" },
  { name: "王建宏", initial: "王", code: "C" },
  { name: "張雅婷", initial: "張", code: "D" },
];

export const meetingTitle = "新款手機上市行銷與通路規劃";

/** Raw transcript keeps the fillers; the clean one is what the App's cleaned view shows. */
export const transcript = [
  {
    who: 0,
    at: "00:00:07",
    raw: "好，嗯，我們今天針對新產品的上市，呃，討論一下目標客群跟行銷方向。",
    clean: "我們今天針對新產品的上市，討論一下目標客群與行銷方向。",
  },
  {
    who: 1,
    at: "00:00:25",
    raw: "我覺得這款手機的外觀比較時尚嘛，所以不必、不必把客群侷限在單一年齡層。",
    clean: "這款手機的外觀比較時尚，我覺得不必把客群侷限在單一年齡層。",
  },
  {
    who: 2,
    at: "00:00:52",
    raw: "嗯，我覺得還是要有明確的受眾，才能決定後面的廣告跟通路策略。",
    clean: "我覺得還是要有明確的受眾，才能決定後續的廣告與通路策略。",
  },
  {
    who: 3,
    at: "00:01:23",
    raw: "對，那我建議先鎖定 18 到 45 歲的中青年，呃，再看長輩需要哪些規格。",
    clean: "我建議先鎖定 18 至 45 歲的中青年客群，再評估長輩需要的規格。",
  },
];

export const bySpeaker = [
  [
    ["主持新手機上市討論，確認目標客群鎖定在 18 至 45 歲之間。", "00:00:07"],
    ["提出可考慮電商、電信商合作或找大 V 直播帶貨。", "00:04:32"],
  ],
  [
    ["認為客群不必劃分太嚴格，長輩也能接受亮色系外觀。", "00:00:25"],
    ["擔心多平台同時直播影響利潤，建議推廣排定完整流程。", "00:16:31"],
  ],
  [
    ["主張客群設定要有明確針對性，這款手機更適合年輕人。", "00:00:52"],
    ["提議贈送印有品牌 LOGO 的限量手機殼或盲盒。", "00:09:32"],
  ],
  [
    ["建議鎖定 18 至 45 歲客群，為長輩另做字體與音量設計。", "00:01:23"],
    ["建議贈品成本控制在 50 元以內，可洽談盲盒廠商合作。", "00:10:04"],
  ],
] as const;

export const summary = [
  {
    title: "決議",
    rows: [
      ["目標客群鎖定為 18 至 45 歲的中青年與年輕族群，產品設計主推年輕化。", "00:01:23"],
      ["促銷通路以主流電商平台與網紅直播帶貨為主，暫不聘請高價明星代言。", "00:06:10"],
      ["贈品採「盲盒」形式，單個贈品成本控制在 50 元以內。", "00:10:47"],
    ],
  },
  {
    title: "討論重點",
    rows: [
      ["目標客群範圍：林佳怡主張放寬到年長者；王建宏與張雅婷認為應集中在 18 至 45 歲。", "00:00:25"],
      ["通路與價格：多平台同時促銷可能造成價格混亂，團隊討論分時段秒殺與直播限定價。", "00:20:00"],
    ],
  },
  {
    title: "待辦事項",
    rows: [
      ["聯繫贈品與盲盒製造商比價，並準備直播用樣品。", "00:12:41"],
      ["請設計團隊提出主打色的多版配色方案。", "00:15:06"],
      ["各部門於下週二前提出推廣執行方案與進度表。", "00:19:54"],
    ],
  },
] as const;

export const voiceprints = [
  { who: 2, count: 1, tags: ["會議室現場"] },
  { who: 1, count: 2, tags: ["線上通話"] },
  { who: 3, count: 3, tags: ["會議室現場", "線上通話"] },
  { who: 0, count: 3, tags: ["會議室現場", "線上通話"] },
] as const;

export const vocabulary = [
  { term: "大V", auto: false },
  { term: "直播帶貨", auto: false },
  { term: "合約機", auto: false },
  { term: "POP MART", auto: true },
  { term: "雙十一", auto: true },
  { term: "盲盒", auto: true },
] as const;
