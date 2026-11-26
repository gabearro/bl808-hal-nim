#!/usr/bin/env python3
"""Inspect and patch MPEG audio Layer III streams (fixture making).
  mp3tool.py info  in.mp3
  mp3tool.py patch in.mp3 out.mp3 [istereo] [mixed] [modeext]
"""
import sys
BR = {(1,1):[0,32,64,96,128,160,192,224,256,288,320,352,384,416,448],
      (1,2):[0,32,48,56,64,80,96,112,128,160,192,224,256,320,384],
      (1,3):[0,32,40,48,56,64,80,96,112,128,160,192,224,256,320],
      (2,1):[0,32,48,56,64,80,96,112,128,144,160,176,192,224,256],
      (2,2):[0,8,16,24,32,40,48,56,64,80,96,112,128,144,160],
      (2,3):[0,8,16,24,32,40,48,56,64,80,96,112,128,144,160]}
SR = [44100,48000,32000]
def hdr(b, i):
    if i + 4 > len(b) or b[i] != 0xFF or (b[i+1] & 0xE0) != 0xE0: return None
    ver = (b[i+1] >> 3) & 3; layer = 4 - ((b[i+1] >> 1) & 3)
    if ver == 1 or layer == 4: return None
    bri = b[i+2] >> 4; sri = (b[i+2] >> 2) & 3
    if bri == 15 or sri == 3: return None
    mpeg1 = ver == 3
    sr = SR[sri] >> (0 if mpeg1 else 1 if ver == 2 else 2)
    kbps = BR[(1 if mpeg1 else 2, layer)][bri]
    pad = (b[i+2] >> 1) & 1
    if layer == 1: size = (12 * kbps * 1000 // sr + pad) * 4
    elif layer == 3 and not mpeg1: size = 72 * kbps * 1000 // sr + pad
    else: size = 144 * kbps * 1000 // sr + pad
    return dict(ver=ver, mpeg1=mpeg1, layer=layer, kbps=kbps, sr=sr, size=size, crc=not (b[i+1] & 1),
                mode=b[i+3] >> 6, ext=(b[i+3] >> 4) & 3)
def frames(b, free_size=None):
    i = 0
    while i + 4 <= len(b):
        h = hdr(b, i)
        if h and h['kbps'] == 0 and free_size: h['size'] = free_size + ((b[i+2] >> 1) & 1)
        if h and h['size'] > 4 and (i + h['size'] + 4 > len(b) or hdr(b, i + h['size'])):
            yield i, h
            i += h['size']
        else:
            i += 1
class Bits:
    def __init__(s, b, pos): s.b = b; s.pos = pos
    def get(s, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((s.b[s.pos >> 3] >> (7 - (s.pos & 7))) & 1); s.pos += 1
        return v
def side(b, i, h):
    """yields (gr, ch, block_type, mixed_flag_bitpos or None)"""
    bs = Bits(b, (i + 4 + (2 if h['crc'] else 0)) * 8)
    nch = 1 if h['mode'] == 3 else 2
    if h['mpeg1']:
        bs.get(9); bs.get(5 if nch == 1 else 3); bs.get(4 * nch); ngr = 2
    else:
        bs.get(8); bs.get(1 if nch == 1 else 2); ngr = 1
    for gr in range(ngr):
        for ch in range(nch):
            bs.get(12); bs.get(9); bs.get(8); bs.get(4 if h['mpeg1'] else 9)
            if bs.get(1):
                bt = bs.get(2); pos = bs.pos; bs.get(1); bs.get(10); bs.get(9)
                yield gr, ch, bt, pos
            else:
                bs.get(15); bs.get(7)
                yield gr, ch, 0, None
            bs.get(3 if h['mpeg1'] else 2)
def main():
    cmd = sys.argv[1]; b = bytearray(open(sys.argv[2], 'rb').read())
    if cmd == 'info':
        from collections import Counter
        c = Counter(); n = 0; first = None
        for i, h in frames(b):
            if first is None: first = (i, h)
            n += 1; c['kbps%d' % h['kbps']] += 1; c['mode%d' % h['mode']] += 1
            if h['mode'] == 1: c['ext%d' % h['ext']] += 1
            if h['layer'] == 3:
                for gr, ch, bt, pos in side(b, i, h): c['bt%d' % bt] += 1
        print(sys.argv[2], len(b), 'bytes', n, 'frames', 'first@%d' % first[0],
              {k: first[1][k] for k in ('ver', 'layer', 'sr', 'crc')}, dict(sorted(c.items())))
    elif cmd == 'offsets':
        print(' '.join(str(i) for i, h in frames(b)))
    elif cmd == 'patch':
        ops = sys.argv[4:]; k = 0
        for i, h in list(frames(b)):
            k += 1
            if 'istereo' in ops and h['mode'] == 1:
                b[i+3] |= 0x10                      # intensity stereo on
            if 'modeext' in ops and k % 3:
                b[i+3] |= 0x30 if k % 3 == 1 else 0x10
            if 'mixed' in ops:
                for gr, ch, bt, pos in side(b, i, h):
                    if bt == 2: b[pos >> 3] |= 0x80 >> (pos & 7)
        open(sys.argv[3], 'wb').write(b)
main()
