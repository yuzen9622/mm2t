import React from 'react';
import { Composition } from 'remotion';
import { Promo } from './Promo';
import { HERO, ReadmeHero } from './ReadmeHero';
import { FPS, H, TOTAL, W } from './timeline';

// One film, two locales: only the words differ.
export const Root: React.FC = () => (
  <>
    <Composition id="PromoZh" component={Promo} durationInFrames={TOTAL} fps={FPS} width={W} height={H} defaultProps={{ locale: 'zh' as const }} />
    <Composition id="PromoEn" component={Promo} durationInFrames={TOTAL} fps={FPS} width={W} height={H} defaultProps={{ locale: 'en' as const }} />
    <Composition id="ReadmeHero" component={ReadmeHero} durationInFrames={HERO.frames} fps={FPS} width={HERO.width} height={HERO.height} />
  </>
);
