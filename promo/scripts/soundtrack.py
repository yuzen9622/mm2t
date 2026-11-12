#!/usr/bin/env python3
"""mm2t promo soundtrack and sound effects, synthesized from oscillators and noise.

Reads src/cues.json (the same timeline the picture uses) and writes public/audio/soundtrack.wav,
48 kHz stereo, exactly as long as the film. Deterministic: the same cues give the same mix.

Approach (beat-locked cues, synthesized score and SFX, mastered to about -14 LUFS) follows the
MIT-licensed claude-launchvideo project by Leonxlnx; the instruments and score here are our own.
"""
import json
import os

import numpy as np
import pyloudnorm
import soundfile
from scipy import signal

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CUES = json.load(open(os.path.join(ROOT, 'src', 'cues.json')))
SR = 48000
FPS = CUES['fps']
BEAT = 60.0 / CUES['bpm']
BAR = 4 * BEAT
LENGTH = CUES['total'] / FPS
N = int(round(LENGTH * SR)) + SR  # one second of tail, cut at the end
Q = CUES['cue']
rng = np.random.default_rng(2026)


def t_of(frame):
    return frame / FPS


def bar_t(n, beat=0.0):
    return (n - 1) * BAR + beat * BEAT


def mtof(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def stereo():
    return np.zeros((N, 2))


def add(dst, x, at, gain=1.0, pan=0.0):
    """Mix mono or stereo x into dst starting at `at` seconds, equal-power pan in [-1, 1]."""
    i = int(round(at * SR))
    if i >= N:
        return
    if x.ndim == 1:
        a = (pan + 1) * np.pi / 4
        x = np.stack([x * np.cos(a), x * np.sin(a)], axis=1) * np.sqrt(2)
    n = min(len(x), N - i)
    if i < 0:
        x, n, i = x[-i:], min(len(x) + i, N), 0
    dst[i:i + n] += x[:n] * gain


def tvec(d):
    return np.arange(int(d * SR)) / SR


def env_exp(d, tau, attack=0.002):
    t = tvec(d)
    return np.minimum(1, t / attack) * np.exp(-t / tau)


def lp(x, f, order=2):
    return signal.sosfilt(signal.butter(order, min(f, SR / 2.2), 'low', fs=SR, output='sos'), x, axis=0)


def hp(x, f, order=2):
    return signal.sosfilt(signal.butter(order, f, 'high', fs=SR, output='sos'), x, axis=0)


def bp(x, lo, hi, order=2):
    return signal.sosfilt(signal.butter(order, [lo, hi], 'band', fs=SR, output='sos'), x, axis=0)


def noise(d):
    return rng.standard_normal(int(d * SR))


def saw(freq, d, phase=0.0):
    t = tvec(d)
    ph = (phase + freq * t) % 1.0
    return 2 * ph - 1


# ---------------------------------------------------------------------------------------------
# instruments
# ---------------------------------------------------------------------------------------------
def kick(d=0.5, punch=1.0):
    t = tvec(d)
    f = 48 + 120 * np.exp(-t / 0.03)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.16)
    click = hp(noise(d), 2500) * np.exp(-t / 0.004) * 0.25
    return np.tanh((body + click) * 1.6 * punch)


def boom(d=2.4, f0=62, f1=38):
    t = tvec(d)
    f = f1 + (f0 - f1) * np.exp(-t / 0.35)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.9)
    return np.tanh(x * 1.4)


def hat(d=0.08, tau=0.016):
    return hp(noise(d), 7000) * env_exp(d, tau) * 0.5


def clap(d=0.35):
    x = bp(noise(d), 900, 3200)
    t = tvec(d)
    e = np.exp(-t / 0.09)
    for k in (0.0, 0.011, 0.023):
        e += 0.6 * np.exp(-np.maximum(0, t - k) / 0.004) * (t >= k)
    return x * e * 0.4


def tick(freq=2350.0, d=0.07):
    """The recording tick: a short tuned woodblock."""
    t = tvec(d)
    tone = np.sin(2 * np.pi * freq * t) * np.exp(-t / 0.012) + 0.5 * np.sin(2 * np.pi * freq * 1.51 * t) * np.exp(-t / 0.006)
    return tone + hp(noise(d), 4000) * np.exp(-t / 0.002) * 0.3


def ui_click(d=0.06):
    t = tvec(d)
    return (np.sin(2 * np.pi * 1800 * t) * np.exp(-t / 0.006) + bp(noise(d), 2000, 6000) * np.exp(-t / 0.003)) * 0.6


def blip(f0, f1, d=0.14):
    t = tvec(d)
    f = f0 * (f1 / f0) ** (t / d)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * env_exp(d, d / 3, 0.004)


def whoosh(d=0.9, peak=0.6, lo=300, hi=5000):
    """Filtered noise swept up to `peak` (fraction of d) and back down."""
    x = noise(d)
    t = tvec(d)
    pos = t / d
    shape = np.where(pos < peak, (pos / peak) ** 2, ((1 - pos) / (1 - peak)) ** 1.5)
    out = np.zeros_like(x)
    block = 512
    for i in range(0, len(x), block):
        c = lo + (hi - lo) * shape[i]
        seg = bp(x[max(0, i - 2048):i + block], max(60, c * 0.5), min(SR / 2.3, c * 1.6))
        out[i:i + block] = seg[-len(x[i:i + block]):]
    return out * shape * 0.6


def riser(d=1.6):
    x = whoosh(d, 0.98, 200, 9000)
    t = tvec(d)
    tone = np.sin(2 * np.pi * np.cumsum(220 * 4 ** (t / d)) / SR) * (t / d) ** 2 * 0.15
    return x + tone


def reverse_swell(d=0.5):
    x = lp(noise(d), 6000) * np.linspace(0, 1, int(d * SR)) ** 3
    return x * 0.5


def fm_bell(midi, d=2.6, idx=2.0, ratio=3.5):
    t = tvec(d)
    f = mtof(midi)
    mod = np.sin(2 * np.pi * f * ratio * t) * idx * np.exp(-t / 0.5)
    return np.sin(2 * np.pi * f * t + mod) * env_exp(d, 0.9, 0.003) * 0.4


def pad_note(midi, d, cutoff=1400, voices=5):
    out = np.zeros(int(d * SR))
    for v in range(voices):
        det = (v - (voices - 1) / 2) * 0.09
        out += saw(mtof(midi + det / 1), d, phase=rng.random())
    out = lp(out / voices, cutoff, 2)
    t = tvec(d)
    a, r = 0.25, 0.5
    e = np.minimum(1, t / a) * np.minimum(1, np.maximum(0, (d - t) / r))
    return out * e


def pluck(midi, d=0.35):
    t = tvec(d)
    x = saw(mtof(midi), d) + 0.5 * saw(mtof(midi + 12), d)
    out = np.zeros_like(x)
    block = 256
    for i in range(0, len(x), block):
        c = 500 + 4800 * np.exp(-t[i] / 0.07)
        seg = lp(x[max(0, i - 2048):i + block], c)
        out[i:i + block] = seg[-len(x[i:i + block]):]
    return out * np.exp(-t / 0.16) * 0.35


def bass_note(midi, d):
    t = tvec(d)
    x = np.sin(2 * np.pi * mtof(midi) * t) + 0.3 * saw(mtof(midi), d)
    x = lp(x, 700)
    e = np.minimum(1, t / 0.005) * np.minimum(1, np.maximum(0, (d - t) / 0.03))
    return np.tanh(x * 1.5) * e * 0.5


def murmur(d=3.6, density=(4, 14)):
    """Overlapping 'syllables': formant-filtered noise bursts, the sound of a room talking."""
    out = np.zeros(int(d * SR))
    t_now = 0.0
    while t_now < d:
        progress_ = t_now / d
        rate = density[0] + (density[1] - density[0]) * progress_
        dur = rng.uniform(0.06, 0.18)
        f1 = rng.uniform(350, 800)
        f2 = rng.uniform(1100, 2400)
        x = bp(noise(dur), f1 * 0.8, f1 * 1.25) + 0.6 * bp(noise(dur), f2 * 0.85, f2 * 1.15)
        tt = tvec(dur)
        x *= np.sin(np.pi * tt / dur) ** 2 * rng.uniform(0.4, 1.0)
        i = int(t_now * SR)
        n = min(len(x), len(out) - i)
        out[i:i + n] += x[:n]
        t_now += rng.exponential(1 / rate)
    return out * 0.35


def reverb(x, rt60=1.8, mix_=0.25):
    d = rt60 * 1.2
    t = tvec(d)
    ir = rng.standard_normal((len(t), 2)) * np.exp(-6.9 * t / rt60)[:, None]
    ir = lp(ir, 5200)
    ir /= np.sqrt((ir ** 2).sum(axis=0))
    wet = np.stack([signal.fftconvolve(x[:, c], ir[:, c])[:len(x)] for c in range(2)], axis=1)
    return x + wet * mix_


# ---------------------------------------------------------------------------------------------
# score: F major, 120 BPM, one chord per bar from the drop; it resolves to F on the period.
# ---------------------------------------------------------------------------------------------
CHORDS = {
    'Dm': [50, 57, 62, 65, 69],
    'Bb': [46, 58, 62, 65, 70],
    'F': [41, 57, 60, 65, 69],
    'C': [48, 55, 60, 64, 67],
    'Csus': [48, 55, 60, 65, 67],
}
PROG = {3: 'Dm', 4: 'Bb', 5: 'F', 6: 'C', 7: 'Dm', 8: 'Bb', 9: 'F', 10: 'C', 11: 'Dm', 12: 'Bb', 13: 'Csus', 14: 'F', 15: 'F'}


def build_music():
    pad, bass, drums, keys = stereo(), stereo(), stereo(), stereo()
    kicks = []
    # hook: a low drone under the ticks, swelling into the implosion
    drone = pad_note(38, 3.7, cutoff=500, voices=3) * np.linspace(0.3, 1, int(3.7 * SR))
    add(pad, drone, 0.0, 0.35)
    for b, name in PROG.items():
        notes = CHORDS[name]
        start = bar_t(b)
        dur = BAR + (0.6 if b < 15 else 1.0)
        bright = 900 if b < 5 else 1700 if b < 13 else 1300
        for k, m in enumerate(notes[1:]):
            add(pad, pad_note(m, dur, cutoff=bright), start, 0.12, pan=(k - 1.5) * 0.35)
        root = notes[0] if notes[0] < 48 else notes[0] - 12
        if 5 <= b <= 12:
            for e in range(8):
                add(bass, bass_note(root, BEAT / 2 * 0.9), start + e * BEAT / 2, 0.55 if e % 2 else 0.7)
        elif b in (3, 4, 13):
            add(bass, bass_note(root, BAR * 0.95), start, 0.55)
        elif b == 14:
            add(bass, bass_note(root, BAR * 1.6), start, 0.65)
        if 5 <= b <= 12:
            arp = [notes[1] + 12, notes[2] + 12, notes[3] + 12, notes[2] + 12]
            for s in range(16):
                if s % 4 == 3 and b % 2 == 0:
                    continue
                add(keys, pluck(arp[s % 4] + (12 if s in (6, 14) else 0)), start + s * BEAT / 4, 0.22, pan=0.45 if s % 2 else -0.45)
    # drums: kicks from the drop, full groove through the features, out for the close
    for b in range(3, 15):
        for q in range(4):
            tt = bar_t(b, q)
            if b in (3, 4) and q not in (0,):
                continue
            if b == 13 and q > 1:
                continue
            add(drums, kick(), tt, 0.8)
            kicks.append(tt)
            if 5 <= b <= 12:
                add(drums, hat(), tt + BEAT / 2, 0.35, pan=0.3)
                add(drums, hat(0.05, 0.01), tt + BEAT / 4 * 3, 0.15, pan=-0.3)
                if q in (1, 3) and b >= 7:
                    add(drums, clap(), tt, 0.5)
    add(drums, kick(0.7, 1.3), t_of(Q['period']), 0.9)
    kicks.append(t_of(Q['period']))
    return pad, bass, drums, keys, kicks


def build_sfx():
    sfx = stereo()
    # the recording tick, on every beat of the hook and twice at the end
    for f in range(Q['dotIn'], Q['implode'], 15):
        add(sfx, tick(2350 if (f // 15) % 2 == 0 else 1760), t_of(f), 0.35)
    for f in (Q['tickA'], Q['tickB']):
        add(sfx, tick(2350), t_of(f), 0.4)
    add(sfx, murmur(t_of(Q['implode']) - t_of(Q['waveIn']) + 0.1), t_of(Q['waveIn']), 0.45)
    for f in (Q['slam1'], Q['slam2']):
        add(sfx, boom(1.2, 90, 45), t_of(f), 0.6)
        add(sfx, hp(noise(0.25), 1500) * env_exp(0.25, 0.05), t_of(f), 0.25)
    add(sfx, reverse_swell(t_of(Q['silence'] - Q['implode'])), t_of(Q['implode']), 0.5)
    # the drop: the mark assembles
    add(sfx, boom(2.6), t_of(Q['drop1']), 0.9)
    for k, m in enumerate([65, 72, 77, 81]):
        add(sfx, fm_bell(m), t_of(Q['drop1']) + k * 0.02, 0.3, pan=(k - 1.5) * 0.3)
    add(sfx, ui_click(), t_of(Q['barA']), 0.5, -0.2)
    add(sfx, ui_click(), t_of(Q['barB']), 0.5, 0.2)
    add(sfx, blip(900, 2400), t_of(Q['dotFly']), 0.25, -0.6)
    add(sfx, whoosh(0.6, 0.5, 400, 4000), t_of(Q['wordmark']) - 0.25, 0.4, 0.3)
    add(sfx, whoosh(0.5, 0.5, 400, 3000), t_of(Q['tuck']) - 0.2, 0.25)
    # the window opens; each feature arrives on a whoosh
    add(sfx, whoosh(1.1, 0.55, 200, 6000), t_of(Q['open']) - 0.45, 0.6)
    for key in ('detect', 'speakers', 'summary', 'local'):
        add(sfx, whoosh(0.8, 0.6, 250, 5500), t_of(Q[key]) - 0.45, 0.5, 0.2)
    add(sfx, riser(1.4), t_of(Q['summary']) - 1.4, 0.3)
    add(sfx, riser(1.4), t_of(Q['local']) - 1.4, 0.3)
    add(sfx, whoosh(0.6, 0.6, 400, 4000), t_of(Q['perPerson']) - 0.3, 0.3, -0.2)
    add(sfx, whoosh(0.6, 0.6, 400, 4000), t_of(Q['dashboard']) - 0.3, 0.3, -0.2)
    for c in CUES['clicks']:
        add(sfx, ui_click(), t_of(c['f']), 0.7, pan=(c['x'] / 1440 - 0.5) if c['scene'] == 'app' else 0)
    add(sfx, blip(660, 1320), t_of(Q['islandRecord']), 0.3)
    for f in (Q['countdown'] + 2, Q['countdown'] + 32):
        add(sfx, blip(1320, 1320, 0.09), t_of(f), 0.18)
    # the close and the lockup
    add(sfx, whoosh(1.0, 0.7, 6000, 300), t_of(Q['close']), 0.45)
    add(sfx, riser(1.3), t_of(Q['period']) - 1.3, 0.35)
    add(sfx, boom(2.0, 70, 40), t_of(Q['drop2']), 0.5)
    add(sfx, whoosh(0.6, 0.5, 400, 4000), t_of(Q['wordmarkEnd']) - 0.25, 0.4, 0.3)
    for k, m in enumerate([65, 69, 72, 77]):
        add(sfx, fm_bell(m, 3.5), t_of(Q['period']) + k * 0.03, 0.32, pan=(k - 1.5) * 0.3)
    add(sfx, ui_click(), t_of(Q['url']), 0.4)
    return sfx


def sidechain(x, kicks, depth=0.5, tau=0.16):
    g = np.ones(N)
    for k in kicks:
        i = int(k * SR)
        n = min(int(0.5 * SR), N - i)
        if n > 0:
            g[i:i + n] = np.minimum(g[i:i + n], 1 - depth * np.exp(-np.arange(n) / SR / tau))
    return x * g[:, None]


def main():
    pad, bass, drums, keys, kicks = build_music()
    sfx = build_sfx()
    music = sidechain(reverb(pad, 2.4, 0.35) + reverb(keys, 1.6, 0.3), kicks) + sidechain(bass, kicks, 0.35) + drums
    # silence before the drop: duck everything but the swell
    duck = np.ones(N)
    a, b = int(t_of(Q['silence']) * SR), int(t_of(Q['drop1']) * SR)
    duck[a:b] = 0.15
    mix = music * duck[:, None] * 0.8 + reverb(sfx, 1.4, 0.18)
    mix = hp(mix, 28)
    total = int(round(LENGTH * SR))
    mix = mix[:total]
    fade = int(0.35 * SR)
    mix[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 2
    meter = pyloudnorm.Meter(SR)
    loud = meter.integrated_loudness(mix)
    mix *= 10 ** ((-14.0 - loud) / 20)
    mix = np.tanh(mix * 1.1) / 1.1  # gentle clip for the peaks
    peak = np.abs(mix).max()
    if peak > 0.89:
        mix *= 0.89 / peak
    out = os.path.join(ROOT, 'public', 'audio', 'soundtrack.wav')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    soundfile.write(out, mix.astype(np.float32), SR, subtype='PCM_24')
    print(out, f'{len(mix) / SR:.3f}s', f'{meter.integrated_loudness(mix):.1f} LUFS', f'peak {20 * np.log10(np.abs(mix).max()):.1f} dBFS')


if __name__ == '__main__':
    main()
