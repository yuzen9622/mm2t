import React from 'react';
import { AbsoluteFill, Freeze, OffthreadVideo, Sequence, staticFile, useCurrentFrame } from 'remotion';
import { C, Cursor } from './brand';
import { ease, hit, progress } from './timeline';

// A seamless README loop cut from the same footage: name suggestions accepted one by one, then the
// summary tab; the last frames dissolve back into the first.
export const HERO = { width: 1200, height: 740, frames: 240 };
const WIN_W = 1104;
const AR = 847 / 1440;
const PX = WIN_W / 1440;
const NAMES_AT = 0.6; // seconds into names.mp4
const SUMMARY_FROM = 150;
const FADE = 18;
const CLICKS = [
  { f: 26, x: 1258, y: 123 },
  { f: 56, x: 1258, y: 163 },
  { f: 87, x: 1258, y: 203 },
  { f: 117, x: 1258, y: 243 },
  { f: SUMMARY_FROM + 11, x: 476, y: 76 },
];

const video = (src: string, at: number) => (
  <OffthreadVideo src={staticFile(`footage/${src}.mp4`)} startFrom={Math.round(at * 30)} muted style={{ position: 'absolute', width: WIN_W, height: WIN_W * AR }} />
);

export const ReadmeHero: React.FC = () => {
  const f = useCurrentFrame();
  const end = HERO.frames;
  let x = 1258 * PX + 70;
  let y = 330 * PX;
  CLICKS.forEach((c, i) => {
    const p = progress(f, c.f - (i === 0 ? 20 : 14), c.f - 2, ease.travel);
    x += (c.x * PX - x) * p;
    y += (c.y * PX - y) * p;
  });
  const back = progress(f, end - FADE, end, ease.travel);
  x += (1258 * PX + 70 - x) * back;
  y += (330 * PX - y) * back;
  const press = Math.max(...CLICKS.map((c) => hit(f, c.f, 4)));
  return (
    <AbsoluteFill style={{ background: C.paper }}>
      <div
        style={{
          position: 'absolute',
          left: (HERO.width - WIN_W) / 2,
          top: 36,
          width: WIN_W,
          height: WIN_W * AR,
          borderRadius: 14,
          overflow: 'hidden',
          boxShadow: '0 30px 70px rgba(60,40,20,0.18), 0 0 0 1px rgba(0,0,0,0.06)',
        }}
      >
        <Sequence durationInFrames={SUMMARY_FROM} layout="none">{video('names', NAMES_AT)}</Sequence>
        <Sequence from={SUMMARY_FROM} layout="none">{video('summary', 0.6)}</Sequence>
        <Sequence from={end - FADE} layout="none">
          <div style={{ position: 'absolute', inset: 0, opacity: back }}>
            <Freeze frame={0}>{video('names', NAMES_AT)}</Freeze>
          </div>
        </Sequence>
        <Cursor x={x} y={y} press={press} opacity={1} scale={0.95} />
      </div>
    </AbsoluteFill>
  );
};
