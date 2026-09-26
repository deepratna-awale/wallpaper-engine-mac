import numpy as np, subprocess, os
from PIL import Image
O = os.path.dirname(os.path.abspath(__file__))
g = lambda p: np.asarray(Image.open(os.path.join(O, p)).convert('L'), dtype=np.float32)[:1030]

# Parallax: best horizontal (and vertical) shift between cursor-left and cursor-right frames.
l, r = g('3802047741/default/mouse_left.png'), g('3802047741/default/mouse_right.png')
c = g('3802047741/default/mouse_center.png')
def shift(a, b):
    best = None
    for dy in range(-20, 21, 2):
        for dx in range(-120, 121):
            e = np.mean((a[200:800, 300:1600] - b[200 + dy:800 + dy, 300 + dx:1600 + dx]) ** 2)
            if best is None or e < best[0]: best = (e, dx, dy)
    return best
print('parallax left->right (err,dx,dy):', shift(l, r))
print('parallax left->center (err,dx,dy):', shift(l, c))

# Shadows/volumetrics off vs high.
for i in ['3455121165', '3159348391', '3378346807']:
    a, b = g(f'{i}/shadowsOff_volOff/still1.png'), g(f'{i}/shadowsHigh_volHigh/still1.png')
    print(i, 'off vs high mean|diff|=%.2f  mean off=%.1f high=%.1f' % (np.abs(a - b).mean(), a.mean(), b.mean()))

# Puppet motion: frame differences across clip for Knight and Samurai.
for i in ['2515150033', '2321732083']:
    p = os.path.join(O, i, 'default', 'clip.mp4')
    raw = subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', p, '-vf', 'fps=2,scale=480:270,format=gray', '-f', 'rawvideo', '-'], capture_output=True).stdout
    f = np.frombuffer(raw, np.uint8).reshape(-1, 270, 480).astype(np.float32)[:, :255]
    d = np.abs(f[1:] - f[:-1])
    print(i, 'mean frame diff per 0.5s:', np.round(d.mean(axis=(1, 2)), 2).tolist())
    m = d.mean(axis=0)
    ys, xs = np.where(m > m.mean() + 2 * m.std())
    if len(xs): print('   moving region bbox (1920 scale): x %d-%d y %d-%d' % (xs.min() * 4, xs.max() * 4, ys.min() * 4, ys.max() * 4))
