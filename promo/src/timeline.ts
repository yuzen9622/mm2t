// Timing for the picture. The numbers live in cues.json so the soundtrack reads the same ones.
import { Easing, interpolate, spring } from 'remotion';
import cues from './cues.json';

export const FPS = cues.fps;
export const TOTAL = cues.total;
export const W = 1920;
export const H = 1080;
export const BEAT = (60 / cues.bpm) * FPS; // 15 frames
export const BAR = BEAT * 4; // 60 frames

export const ACT = cues.acts as Record<keyof typeof cues.acts, [number, number]>;
export const CUE = cues.cue;
export type Click = { f: number; scene: 'island' | 'app'; x: number; y: number };
export const CLICKS = cues.clicks as Click[];

type Ease = (t: number) => number;
// Curves follow the taste-skill motion tokens: one entrance curve for things settling, one travel
// curve for camera and window moves, the UI curve for small steps.
export const ease = {
  enter: Easing.bezier(0.22, 1, 0.36, 1),
  travel: Easing.bezier(0.65, 0, 0.35, 1),
  ui: Easing.bezier(0.2, 0.8, 0.2, 1),
  out: Easing.bezier(0.16, 1, 0.3, 1),
  in: Easing.bezier(0.64, 0, 0.78, 0),
  inOut: Easing.bezier(0.83, 0, 0.17, 1),
  soft: Easing.bezier(0.33, 0, 0.2, 1),
  linear: (t: number) => t,
};

/** Value between a and b while the frame runs from f0 to f1, clamped outside. */
export const tween = (f: number, f0: number, f1: number, a: number, b: number, e: Ease = ease.out) =>
  interpolate(f, [f0, f1], [a, b], { easing: e, extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });

export const progress = (f: number, f0: number, f1: number, e: Ease = ease.out) => tween(f, f0, f1, 0, 1, e);

export const springAt = (f: number, start: number, damping = 16, stiffness = 220, mass = 0.7) =>
  spring({ frame: f - start, fps: FPS, config: { damping, stiffness, mass } });

/** A hit that peaks two frames after `start` and decays, so the picture peaks with its sound. */
export const hit = (f: number, start: number, tau = 5) => {
  const t = f - start;
  if (t <= 0 || t > 40) return 0;
  return t < 2 ? Math.sin((t / 2) * (Math.PI / 2)) : Math.exp(-(t - 2) / tau);
};

/** Deterministic pseudo-random number in [0, 1). */
export const rand = (seed: number) => {
  const x = Math.sin(seed * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};
