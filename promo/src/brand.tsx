import React from 'react';
import { loadFont as loadNoto } from '@remotion/google-fonts/NotoSansTC';
import { loadFont as loadInter } from '@remotion/google-fonts/Inter';

// Colors and shapes from App/DesignAssets/mm2t-icon (layers/*.svg).
export const C = {
  paper: '#F6F5F1',
  tile: '#F6F5F1',
  ink: '#1C1C1E',
  orange: '#F0700F',
  muted: '#86827A',
  line: '#DEDAD1',
};

export const NOTO = loadNoto('normal', { weights: ['500', '700', '900'], ignoreTooManyRequestsWarning: true }).fontFamily;
export const INTER = loadInter('normal', { weights: ['500', '800', '900'], subsets: ['latin'] }).fontFamily;

// The voice-signal "m" (02-voice-signal.svg), in a 1024 box.
export const M_PATH =
  'M210 520V378C210 300 273 237 353 237C431 237 490 298 490 378V423C490 445 499 457 512 457C525 457 534 445 534 423V378C534 298 593 237 671 237C751 237 814 300 814 378V520C814 547 792 569 765 569C738 569 716 547 716 520V378C716 352 697 334 671 334C648 334 628 352 628 378V423C628 499 578 557 512 557C446 557 396 499 396 423V378C396 352 376 334 353 334C327 334 308 352 308 378V520C308 547 286 569 259 569C232 569 210 547 210 520Z';

/**
 * The app icon, assembled from its three layers. `draw` traces the m's outline before it fills,
 * `barA`/`barB` slide the two transcript lines in from the left (0 = hidden, 1 = in place).
 */
export const Mark: React.FC<{ size: number; draw?: number; fill?: number; barA?: number; barB?: number; tile?: number }> = ({
  size,
  draw = 1,
  fill = 1,
  barA = 1,
  barB = 1,
  tile = 1,
}) => (
  <svg width={size} height={size} viewBox="0 0 1024 1024" style={{ display: 'block', overflow: 'visible' }}>
    <defs>
      <clipPath id="tileClip">
        <rect width="1024" height="1024" rx="230" />
      </clipPath>
    </defs>
    <rect width="1024" height="1024" rx="230" fill={C.tile} opacity={tile} />
    <g clipPath="url(#tileClip)">
      <path
        d={M_PATH}
        fill={C.orange}
        fillOpacity={fill}
        stroke={C.orange}
        strokeWidth={14}
        pathLength={1}
        strokeDasharray={1}
        strokeDashoffset={1 - draw}
      />
      <rect x={203 - (1 - barA) * 900} y="648" width="619" height="68" rx="34" fill={C.ink} />
      <rect x={203 - (1 - barB) * 700} y="764" width="394" height="68" rx="34" fill={C.ink} />
    </g>
  </svg>
);

/** A macOS-style arrow pointer whose tip sits at (x, y). */
export const Cursor: React.FC<{ x: number; y: number; press: number; opacity: number; scale?: number }> = ({
  x,
  y,
  press,
  opacity,
  scale = 1,
}) => (
  <div
    style={{
      position: 'absolute',
      left: x,
      top: y,
      opacity,
      transform: `scale(${scale * (1 - 0.14 * press)})`,
      transformOrigin: '0 0',
      filter: 'drop-shadow(0 4px 6px rgba(0,0,0,0.25))',
      pointerEvents: 'none',
    }}
  >
    <svg width={34} height={46} viewBox="0 0 34 46" style={{ position: 'absolute', left: -4, top: -3 }}>
      <path d="M4 3 L4 36 L12 28.5 L17.4 41 L23 38.6 L17.8 26.4 L28.4 26.4 Z" fill="#111" stroke="#fff" strokeWidth={2.6} strokeLinejoin="round" />
    </svg>
    {press > 0.02 && (
      <div
        style={{
          position: 'absolute',
          left: -26,
          top: -26,
          width: 52,
          height: 52,
          borderRadius: 26,
          border: `3px solid ${C.orange}`,
          opacity: press * 0.8,
          transform: `scale(${1.4 - press * 0.6})`,
        }}
      />
    )}
  </div>
);
