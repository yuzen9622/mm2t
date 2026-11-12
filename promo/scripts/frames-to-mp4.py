#!/usr/bin/env python3
"""Retimes a clip recorded by the app's DEBUG frame recorder (MM2T_RECORD_DIR) to constant 30 fps.

Frames are named by milliseconds since the clip started; each is held until the next one arrives.
Usage: frames-to-mp4.py <frames dir> <out.mp4> [ffmpeg video filter]
"""
import os
import subprocess
import sys
import tempfile

src, out = sys.argv[1], sys.argv[2]
vf = sys.argv[3] if len(sys.argv) > 3 else 'scale=1920:-2'
frames = sorted(f for f in os.listdir(src) if f.endswith('.jpg'))
times = [int(f[:-4]) / 1000 for f in frames]
with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as lst:
    for i, f in enumerate(frames):
        dur = (times[i + 1] - times[i]) if i + 1 < len(frames) else 1 / 30
        lst.write(f"file '{os.path.abspath(os.path.join(src, f))}'\nduration {dur:.4f}\n")
    lst.write(f"file '{os.path.abspath(os.path.join(src, frames[-1]))}'\n")
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', lst.name,
                '-vf', f'{vf},fps=30,format=yuv420p', '-c:v', 'libx264', '-crf', '14', '-preset', 'slow',
                '-movflags', '+faststart', out], check=True)
os.unlink(lst.name)
print(out, f'{times[-1]:.2f}s', len(frames), 'frames')
