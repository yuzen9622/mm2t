import React, { useMemo } from 'react';
import { AbsoluteFill, OffthreadVideo, Sequence, staticFile, useCurrentFrame } from 'remotion';
import { C, Cursor, INTER, Mark, NOTO } from './brand';
import { COPY, Copy, Locale } from './copy';
import { ACT, BEAT, CLICKS, Click, CUE, ease, hit, progress, rand, springAt, tween } from './timeline';

const mix = (a: number, b: number, t: number) => a + (b - a) * t;

// Captured footage: the app's main window at 1440x847 pt, recorded at 2x and stored at 1920x1130.
const PT_W = 1440;
const AR = 847 / 1440;

// ---------------------------------------------------------------------------------------------
// Lockup geometry (icon tile + "mm2t"), shared by the mark act and the end card.
// ---------------------------------------------------------------------------------------------
const WORD_SIZE = 184;
const LOCK_TILE = 212;
const LOCK_GAP = 44;

const useWordWidth = () =>
  useMemo(() => {
    if (typeof document === 'undefined') return 520;
    const ctx = document.createElement('canvas').getContext('2d');
    if (!ctx) return 520;
    ctx.font = `900 ${WORD_SIZE}px ${INTER}`;
    // letter-spacing -0.045em is applied per character in CSS
    return ctx.measureText('mm2t').width - 4 * 0.045 * WORD_SIZE;
  }, []);

const lockup = (wordW: number) => {
  const period = WORD_SIZE * 0.28;
  const total = LOCK_TILE + LOCK_GAP + wordW + period;
  const left = 960 - total / 2;
  return {
    tileCx: left + LOCK_TILE / 2,
    textLeft: left + LOCK_TILE + LOCK_GAP,
    periodX: left + LOCK_TILE + LOCK_GAP + wordW + WORD_SIZE * 0.13,
    baseline: 540 + WORD_SIZE * 0.36,
  };
};

// ---------------------------------------------------------------------------------------------
// The relay: one orange recording dot that never leaves the screen.
// ---------------------------------------------------------------------------------------------
const REC = { x: 78, y: 64 };

const dotState = (f: number, periodX: number, periodY: number) => {
  const beatPulse = (from: number, to: number) => {
    let p = 0;
    for (let b = from; b < to; b += BEAT) p = Math.max(p, hit(f, b, 4));
    return p;
  };
  if (f < CUE.dotFly) {
    const appear = springAt(f, CUE.dotIn, 12, 200, 0.6);
    const implode = tween(f, CUE.implode, CUE.silence, 0, 0.35, ease.in) - tween(f, CUE.silence, CUE.drop1, 0, 0.35, ease.out);
    const r = 17 * appear * (1 + 0.35 * beatPulse(0, CUE.implode) + implode + 0.8 * hit(f, CUE.drop1, 6));
    return { x: 960, y: 540, r };
  }
  if (f < CUE.close + 40) {
    const p = progress(f, CUE.dotFly, CUE.dotFly + 14, ease.travel);
    const arc = Math.sin(p * Math.PI) * -120;
    const r = mix(17, 9, p) * (1 + 0.3 * beatPulse(CUE.drop1, CUE.close));
    return { x: mix(960, REC.x, p), y: mix(540, REC.y, p) + arc, r };
  }
  const p = progress(f, CUE.drop2 + 10, CUE.period, ease.travel);
  const arc = Math.sin(p * Math.PI) * -260;
  const r = mix(9, WORD_SIZE * 0.075, p) * (1 + 0.45 * hit(f, CUE.period, 5) + 0.3 * hit(f, CUE.tickA, 5) + 0.3 * hit(f, CUE.tickB, 5));
  return { x: mix(REC.x, periodX, p), y: mix(REC.y, periodY, p) + arc, r };
};

// ---------------------------------------------------------------------------------------------
// The app window: where it sits, and which recording plays inside it.
// ---------------------------------------------------------------------------------------------
type Win = { cx: number; cy: number; w: number; h: number; r: number; rot: number; blur: number; op: number; zoom: number };

/** A cut on the beat settles from a hair smaller instead of swinging: one quiet step. */
const settle = (f: number, at: number) => (f >= at && f < at + 14 ? 1 - progress(f, at, at + 14, ease.enter) : 0);

const windowAt = (f: number): Win => {
  if (f < CUE.settle) {
    const p = progress(f, CUE.open, CUE.settle, ease.travel);
    return { cx: 960, cy: 540, w: mix(300, 1500, p), h: mix(300, 1500 * AR, p), r: mix(69, 18, p), rot: 0, blur: 0, op: 1, zoom: 1 };
  }
  if (f < CUE.detect) {
    const w = tween(f, CUE.settle, CUE.detect, 1500, 1580, ease.soft);
    return { cx: 960, cy: 540, w, h: w * AR, r: 18, rot: 0, blur: 0, op: 1, zoom: 1 };
  }
  if (f < CUE.speakers) {
    const p = progress(f, CUE.detect, CUE.detect + 26, ease.travel);
    const w = mix(1580, 1240, p);
    return { cx: 960, cy: mix(540, 860, p), w, h: w * AR, r: 18, rot: 0, blur: mix(0, 9, p), op: mix(1, 0.4, p), zoom: 1 };
  }
  if (f < CUE.close) {
    const p = progress(f, CUE.speakers, CUE.speakers + 24, ease.travel);
    const w = mix(1240, 1120, p);
    const rot = 0;
    const step = 0.025 * (settle(f, CUE.summary) + settle(f, CUE.perPerson) + settle(f, CUE.local) + settle(f, CUE.dashboard));
    const zoom =
      1 + 0.2 * (progress(f, CUE.speakers + 8, CUE.speakers + 30, ease.travel) - progress(f, CUE.summary - 14, CUE.summary - 4, ease.travel));
    return { cx: mix(960, 1292, p), cy: mix(860, 560, p), w: w * (1 - step), h: w * AR * (1 - step), r: 18, rot, blur: mix(9, 0, p), op: mix(0.4, 1, p), zoom };
  }
  const p = progress(f, CUE.close, CUE.drop2 + 6, ease.travel);
  return {
    cx: mix(1292, 960, p),
    cy: mix(560, 540, p),
    w: mix(1120, 300, p),
    h: mix(1120 * AR, 300, p),
    r: mix(18, 69, p),
    rot: 0,
    blur: 0,
    op: 1,
    zoom: 1,
  };
};

// Which clip plays when, and from where in the clip (seconds).
const CLIPS: { from: number; to: number; src: string; at: number }[] = [
  { from: CUE.open, to: CUE.detect, src: 'home', at: 0.75 },
  { from: CUE.detect, to: CUE.speakers, src: 'home', at: 2.4 },
  { from: CUE.speakers, to: CUE.summary, src: 'names', at: 0.9 },
  { from: CUE.summary, to: CUE.perPerson, src: 'summary', at: 0.6 },
  { from: CUE.perPerson, to: CUE.local, src: 'perperson', at: 1.25 },
  { from: CUE.local, to: CUE.dashboard, src: 'people', at: 0.4 },
  { from: CUE.dashboard, to: CUE.drop2 + 8, src: 'home', at: 2.6 },
];

/** Cursor glide between the clicks of one scene: arrive two frames early, press on the cue. */
const cursorAt = (f: number, clicks: Click[], toPx: (c: Click) => { x: number; y: number }) => {
  if (!clicks.length) return null;
  const first = clicks[0];
  const last = clicks[clicks.length - 1];
  if (f < first.f - 24 || f > last.f + 16) return null;
  const pts = clicks.map(toPx);
  let x = pts[0].x + 160;
  let y = pts[0].y + 190;
  for (let i = 0; i < clicks.length; i++) {
    const p = progress(f, clicks[i].f - (i === 0 ? 22 : 14), clicks[i].f - 2, ease.travel);
    x = mix(x, pts[i].x, p);
    y = mix(y, pts[i].y, p);
  }
  const press = Math.max(...clicks.map((c) => hit(f, c.f, 4)));
  const opacity = progress(f, first.f - 24, first.f - 16) * (1 - progress(f, last.f + 8, last.f + 16));
  return { x, y, press, opacity };
};

const AppWindow: React.FC<{ f: number }> = ({ f }) => {
  if (f < CUE.open || f >= CUE.drop2 + 8) return null;
  const s = windowAt(f);
  const footageOp = Math.min(progress(f, CUE.open + 3, CUE.open + 16), 1 - progress(f, CUE.drop2 - 10, CUE.drop2 + 2));
  const markOp = 1 - progress(f, CUE.open, CUE.open + 10) + progress(f, CUE.drop2 - 8, CUE.drop2 + 4);
  const px = s.w / PT_W; // screen px per app point
  const appClicks = CLICKS.filter((c) => c.scene === 'app');
  const act = Object.values(ACT).find(([a, b]) => f >= a && f < b) ?? [0, 0];
  const cur = cursorAt(f, appClicks.filter((c) => c.f >= act[0] && c.f < act[1]), (c) => ({ x: c.x * px, y: c.y * px }));
  // the speaker panel zoom grows from the panel's corner
  const origin = `${(1258 / PT_W) * 100}% ${(150 / 847) * 100}%`;
  return (
    <div style={{ position: 'absolute', inset: 0, perspective: 2600 }}>
      <div
        style={{
          position: 'absolute',
          left: s.cx - s.w / 2,
          top: s.cy - s.h / 2,
          width: s.w,
          height: s.h,
          borderRadius: s.r,
          overflow: 'hidden',
          background: C.tile,
          transform: `rotateY(${s.rot}deg)`,
          filter: s.blur > 0.1 ? `blur(${s.blur}px)` : undefined,
          opacity: s.op,
          boxShadow: '0 50px 120px rgba(40,30,20,0.22), 0 0 0 1px rgba(0,0,0,0.06)',
        }}
      >
        <div style={{ position: 'absolute', left: 0, top: 0, width: s.w, height: s.w * AR, transform: `scale(${s.zoom})`, transformOrigin: origin, opacity: footageOp }}>
          {CLIPS.map((c) => (
            <Sequence key={c.from} from={c.from} durationInFrames={c.to - c.from} layout="none">
              <OffthreadVideo
                src={staticFile(`footage/${c.src}.mp4`)}
                startFrom={Math.round(c.at * 30)}
                muted
                style={{ position: 'absolute', left: 0, top: 0, width: s.w, height: s.w * AR }}
              />
            </Sequence>
          ))}
          {cur && <Cursor x={cur.x} y={cur.y} press={cur.press} opacity={cur.opacity} scale={Math.max(0.9, px * 1.05)} />}
        </div>
        {markOp > 0.01 && (
          <div style={{ position: 'absolute', left: s.w / 2 - Math.min(s.w, s.h) / 2, top: s.h / 2 - Math.min(s.w, s.h) / 2, opacity: Math.min(1, markOp) }}>
            <Mark size={Math.min(s.w, s.h)} tile={0} />
          </div>
        )}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------------------------
// The notch island (meeting prompt -> recording -> countdown), recorded from the app's panel.
// ---------------------------------------------------------------------------------------------
const ISLAND_SCALE = 1.5;
const ISLAND_LEFT = (1920 - 1520 * ISLAND_SCALE) / 2;
const ISLAND_CLIPS = [
  { from: CUE.detect - 4, to: CUE.islandRecord, at: 0.12 },
  { from: CUE.islandRecord, to: CUE.countdown, at: 2.5 },
  { from: CUE.countdown, to: CUE.speakers + 10, at: 6.75 },
];

const Island: React.FC<{ f: number }> = ({ f }) => {
  if (f < CUE.detect - 4 || f >= CUE.speakers + 10) return null;
  const drop = tween(f, CUE.detect - 4, CUE.detect + 10, -260, 0) + tween(f, CUE.speakers - 6, CUE.speakers + 8, 0, -260, ease.in);
  const clicks = CLICKS.filter((c) => c.scene === 'island');
  const cur = cursorAt(f, clicks, (c) => ({ x: ISLAND_LEFT + c.x * ISLAND_SCALE, y: c.y * ISLAND_SCALE }));
  return (
    <AbsoluteFill style={{ transform: `translateY(${drop}px)`, mixBlendMode: 'multiply' }}>
      <div style={{ position: 'absolute', left: 0, top: 0, width: 1920, height: 46, background: '#E7E3DB' }} />
      {ISLAND_CLIPS.map((c) => (
        <Sequence key={c.from} from={c.from} durationInFrames={c.to - c.from} layout="none">
          <OffthreadVideo
            src={staticFile('footage/island.mp4')}
            startFrom={Math.round(c.at * 30)}
            muted
            style={{ position: 'absolute', left: ISLAND_LEFT, top: 0, width: 1520 * ISLAND_SCALE, height: 200 * ISLAND_SCALE  }}
          />
        </Sequence>
      ))}
      {cur && <Cursor x={cur.x} y={cur.y} press={cur.press} opacity={cur.opacity} scale={1.2} />}
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------------------------
// Typography
// ---------------------------------------------------------------------------------------------
/** One line rising out of a mask, sharpening as it lands; leaves upward. */
const Line: React.FC<{ f: number; at: number; out?: number; children: React.ReactNode; style?: React.CSSProperties }> = ({ f, at, out, children, style }) => {
  const p = progress(f, at, at + 21, ease.enter);
  const q = out === undefined ? 0 : progress(f, out, out + 5, ease.ui);
  return (
    <div style={{ overflow: 'hidden', paddingBottom: '0.08em', marginBottom: '-0.08em' }}>
      <div
        style={{
          transform: `translateY(${(1 - p) * 110 - q * 18}%)`,
          opacity: (p > 0 ? 1 : 0) * (1 - q),
          ...style,
        }}
      >
        {children}
      </div>
    </div>
  );
};

const Feature: React.FC<{
  f: number;
  at: number;
  out: number;
  kicker: string;
  title: string[];
  sub: string[];
  align?: 'left' | 'center';
  left?: number;
  top?: number;
  width?: number;
  locale: Locale;
  size?: number;
}> = ({ f, at, out, kicker, title, sub, align = 'left', left = 112, top = 330, width = 640, locale, size }) => {
  if (f < at || f > out + 14) return null;
  const font = locale === 'en' ? INTER : NOTO;
  const titleSize = size ?? (locale === 'en' ? 84 : 88);
  return (
    <div style={{ position: 'absolute', left, top, width, textAlign: align, fontFamily: font }}>
      <Line f={f} at={at} out={out} style={{ color: C.orange, fontSize: 28, fontWeight: 700, letterSpacing: locale === 'en' ? '0.02em' : '0.08em', marginBottom: 22 }}>
        {kicker}
      </Line>
      {title.map((t, i) => (
        <Line key={i} f={f} at={at + 3 + i * 3} out={out} style={{ color: C.ink, fontSize: titleSize, fontWeight: 900, lineHeight: 1.12, letterSpacing: locale === 'en' ? '-0.035em' : '-0.01em' }}>
          {t}
        </Line>
      ))}
      <div style={{ height: 30 }} />
      {sub.map((t, i) => (
        <Line key={i} f={f} at={at + 3 + title.length * 3 + 8 + i * 2} out={out} style={{ color: C.muted, fontSize: locale === 'en' ? 30 : 31, fontWeight: 500, lineHeight: 1.55 }}>
          {t}
        </Line>
      ))}
    </div>
  );
};

// ---------------------------------------------------------------------------------------------
// Act 1: the hook. The dot ticks, a voice signal draws out of it, two lines slam in, then
// everything collapses back into the dot.
// ---------------------------------------------------------------------------------------------
const BARS = 61;
const Hook: React.FC<{ f: number; copy: Copy; locale: Locale }> = ({ f, copy, locale }) => {
  if (f >= CUE.drop1 + 2) return null;
  const implode = progress(f, CUE.implode, CUE.silence, ease.in);
  const shake = 9 * (hit(f, CUE.slam1, 4) + hit(f, CUE.slam2, 4));
  const sx = (rand(f) - 0.5) * shake;
  const sy = (rand(f + 99) - 0.5) * shake;
  const grow = progress(f, CUE.waveIn, CUE.waveIn + 30, ease.out);
  const slam = (at: number) => {
    const s = springAt(f, at, 14, 260, 0.6);
    return { transform: `scale(${mix(1.35, 1, s)})`, opacity: Math.min(1, (f - at) / 3), filter: `blur(${Math.max(0, (1 - s) * 14)}px)` };
  };
  return (
    <AbsoluteFill style={{ transform: `translate(${sx}px, ${sy}px) scale(${1 - implode * 0.96})`, filter: `blur(${implode * 18}px)`, opacity: 1 - progress(f, CUE.silence - 4, CUE.silence + 4) }}>
      <svg width={1920} height={1080} style={{ position: 'absolute' }}>
        {Array.from({ length: BARS }, (_, i) => {
          const k = i - (BARS - 1) / 2;
          const dist = Math.abs(k) / ((BARS - 1) / 2);
          const reach = grow * 1.15 - dist;
          if (reach <= 0 || k === 0) return null;
          const voice = 0.45 + 0.55 * Math.abs(Math.sin(f * 0.21 + i * 0.73) * Math.cos(f * 0.07 + i * 1.31));
          const env = Math.exp(-dist * 2.2) * Math.min(1, reach * 4);
          const h = 14 + 230 * voice * env * (1 + 0.5 * (hit(f, CUE.slam1, 6) + hit(f, CUE.slam2, 6)));
          return <rect key={i} x={960 + k * 26 - 5} y={540 - h / 2} width={10} height={h} rx={5} fill={C.ink} opacity={0.16 + 0.7 * env} />;
        })}
      </svg>
      <div style={{ position: 'absolute', top: 190, width: 1920, textAlign: 'center', fontFamily: locale === 'en' ? INTER : NOTO, fontWeight: 900, fontSize: locale === 'en' ? 136 : 132, letterSpacing: locale === 'en' ? '-0.04em' : undefined, color: C.ink, ...(f >= CUE.slam1 ? slam(CUE.slam1) : { opacity: 0 }) }}>
        {copy.hook[0]}
      </div>
      <div style={{ position: 'absolute', top: 690, width: 1920, textAlign: 'center', fontFamily: locale === 'en' ? INTER : NOTO, fontWeight: 900, fontSize: 196, color: C.ink, letterSpacing: locale === 'en' ? '-0.045em' : '-0.02em', ...(f >= CUE.slam2 ? slam(CUE.slam2) : { opacity: 0 }) }}>
        {copy.hook[1]}
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------------------------
// The mark: tile + wordmark, used after the drop and again at the end.
// ---------------------------------------------------------------------------------------------
const MarkAct: React.FC<{ f: number; wordW: number; copy: Copy; locale: Locale }> = ({ f, wordW, copy, locale }) => {
  const L = lockup(wordW);
  const inFirst = f >= CUE.drop1 && f < CUE.open + 2;
  const inEnd = f >= CUE.drop2 + 4;
  if (!inFirst && !inEnd) return null;
  let size: number;
  let cx: number;
  let word: number; // 0 hidden behind the tile, 1 out
  let desc: number;
  const draw = inFirst ? progress(f, CUE.drop1, CUE.drop1 + 14, ease.travel) : 1;
  const fill = inFirst ? progress(f, CUE.drop1 + 9, CUE.drop1 + 18) : 1;
  const barA = inFirst ? springAt(f, CUE.barA, 15, 240) : 1;
  const barB = inFirst ? springAt(f, CUE.barB, 15, 240) : 1;
  if (inFirst) {
    const s = springAt(f, CUE.drop1, 13, 210, 0.7);
    const toLock = progress(f, CUE.wordmark - 4, CUE.wordmark + 12, ease.travel);
    const back = progress(f, CUE.tuck, CUE.open, ease.travel);
    const lockMix = toLock * (1 - back);
    size = mix(300 * s, LOCK_TILE, lockMix);
    cx = mix(960, L.tileCx, lockMix);
    word = progress(f, CUE.wordmark, CUE.wordmark + 14, ease.out) * (1 - progress(f, CUE.tuck - 2, CUE.tuck + 9, ease.in));
    desc = progress(f, CUE.descriptor, CUE.descriptor + 14) * (1 - progress(f, CUE.tuck - 6, CUE.tuck + 2, ease.in));
  } else {
    const toLock = progress(f, CUE.wordmarkEnd - 4, CUE.wordmarkEnd + 14, ease.travel);
    size = mix(300, LOCK_TILE, toLock);
    cx = mix(960, L.tileCx, toLock);
    word = progress(f, CUE.wordmarkEnd, CUE.wordmarkEnd + 16, ease.out);
    desc = 0;
  }
  const ring = progress(f, CUE.drop1, CUE.drop1 + 26, ease.out);
  return (
    <AbsoluteFill>
      {inFirst && ring < 1 && (
        <div style={{ position: 'absolute', left: 960 - 900 * ring, top: 540 - 900 * ring, width: 1800 * ring, height: 1800 * ring, borderRadius: '50%', border: `${3 + 20 * (1 - ring)}px solid ${C.orange}`, opacity: 0.55 * (1 - ring) }} />
      )}
      {/* wordmark slides out from behind the tile */}
      <div style={{ position: 'absolute', left: L.textLeft - LOCK_GAP, top: 0, width: 1200, height: 1080, overflow: 'hidden' }}>
        <div
          style={{
            position: 'absolute',
            left: LOCK_GAP,
            top: L.baseline - WORD_SIZE * 1.02,
            fontFamily: INTER,
            fontWeight: 900,
            fontSize: WORD_SIZE,
            letterSpacing: '-0.045em',
            color: C.ink,
            transform: `translateX(${(word - 1) * (wordW + 140)}px)`,
            lineHeight: 1.2,
          }}
        >
          mm2t
        </div>
        <div style={{ position: 'absolute', left: LOCK_GAP + 6, top: L.baseline + 34, fontFamily: locale === 'en' ? INTER : NOTO, fontWeight: 500, fontSize: 40, whiteSpace: 'nowrap', color: C.muted, opacity: desc, transform: `translateY(${(1 - desc) * 24}px)` }}>
          {copy.descriptor}
        </div>
      </div>
      <div style={{ position: 'absolute', left: cx - size / 2, top: 540 - size / 2, filter: 'drop-shadow(0 30px 60px rgba(60,40,20,0.20))' }}>
        <Mark size={size} draw={draw} fill={fill} barA={barA} barB={barB} />
      </div>
    </AbsoluteFill>
  );
};

const EndCard: React.FC<{ f: number; copy: Copy; locale: Locale }> = ({ f, copy, locale }) => {
  if (f < CUE.tagline) return null;
  return (
    <div style={{ position: 'absolute', top: 744, width: 1920, textAlign: 'center' }}>
      <Line f={f} at={CUE.tagline} style={{ fontFamily: locale === 'en' ? INTER : NOTO, fontWeight: 700, fontSize: 52, color: C.ink, letterSpacing: locale === 'en' ? '-0.02em' : undefined }}>
        {copy.tagline}
      </Line>
      <div style={{ height: 34 }} />
      <Line f={f} at={CUE.url}>
        <span
          style={{
            display: 'inline-block',
            fontFamily: INTER,
            fontWeight: 500,
            fontSize: 32,
            color: C.ink,
            padding: '14px 30px',
            borderRadius: 999,
            background: '#ECE8E0',
          }}
        >
          github.com/yuzen9622/mm2t/releases
        </span>
      </Line>
    </div>
  );
};

const RecLabel: React.FC<{ f: number }> = ({ f }) => {
  const op = progress(f, CUE.dotFly + 10, CUE.dotFly + 20) * (1 - progress(f, CUE.close, CUE.close + 10));
  if (op <= 0) return null;
  const secs = Math.max(0, Math.floor((f - CUE.dotFly) / 30));
  const tc = `00:${String(Math.floor(secs / 60)).padStart(2, '0')}:${String(secs % 60).padStart(2, '0')}`;
  return (
    <div style={{ position: 'absolute', left: REC.x + 22, top: REC.y - 15, opacity: op, fontFamily: INTER, fontSize: 24, fontWeight: 800, color: C.ink, letterSpacing: '0.06em', display: 'flex', gap: 14 }}>
      <span>REC</span>
      <span style={{ fontWeight: 500, color: C.muted, fontVariantNumeric: 'tabular-nums' }}>{tc}</span>
    </div>
  );
};

export const Promo: React.FC<{ locale: Locale }> = ({ locale }) => {
  const f = useCurrentFrame();
  const copy = COPY[locale];
  const wordW = useWordWidth();
  const L = lockup(wordW);
  const dot = dotState(f, L.periodX, L.baseline - WORD_SIZE * 0.075);
  const feat = (key: 'speakers' | 'summary' | 'perPerson' | 'local' | 'dashboard', at: number, out: number) => (
    <Feature f={f} at={at} out={out} locale={locale} {...copy[key]} />
  );
  return (
    <AbsoluteFill style={{ background: C.paper, overflow: 'hidden' }}>
      <Hook f={f} copy={copy} locale={locale} />
      <Island f={f} />
      <AppWindow f={f} />
      <MarkAct f={f} wordW={wordW} copy={copy} locale={locale} />
      <Feature f={f} at={CUE.detect + 8} out={CUE.speakers - 12} locale={locale} {...copy.detect} align="center" left={160} top={300} width={1600} />
      {feat('speakers', CUE.speakers + 6, CUE.summary - 8)}
      {feat('summary', CUE.summary + 4, CUE.perPerson - 6)}
      {feat('perPerson', CUE.perPerson + 2, CUE.local - 8)}
      {feat('local', CUE.local + 4, CUE.dashboard - 6)}
      {feat('dashboard', CUE.dashboard + 2, CUE.close - 8)}
      <EndCard f={f} copy={copy} locale={locale} />
      <RecLabel f={f} />
      <div style={{ position: 'absolute', left: dot.x - dot.r, top: dot.y - dot.r, width: dot.r * 2, height: dot.r * 2, borderRadius: '50%', background: C.orange }} />
    </AbsoluteFill>
  );
};
