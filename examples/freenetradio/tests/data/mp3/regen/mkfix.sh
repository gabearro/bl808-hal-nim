#!/bin/sh
# Makes the decoder fixtures (needs ffmpeg, lame, python3).
# usage: mkfix.sh <outdir>   then write the references, see ../README
set -e
O=$1; T=$O/tmp; mkdir -p $O/noref $T
PY="python3 $(dirname $0)/mp3tool.py"
# 2 s of stereo: a sweep with clicks left, two tones and bursts of noise
# right, a shared low tone (so joint stereo has something to do).
SRC="aevalsrc=0.35*sin(2*PI*(150+2500*t)*t)+0.2*sin(2*PI*110*t)+0.5*(random(0)-0.5)*exp(-45*mod(t\,0.21))|0.3*sin(2*PI*440*t)+0.2*sin(2*PI*110*t)+0.15*sin(2*PI*5200*t)*gt(mod(t\,0.5)\,0.25)+0.4*(random(1)-0.5)*exp(-60*mod(t+0.1\,0.33)):d=2"
for r in 48000 44100 32000 24000 22050 16000 12000 11025 8000; do
  ffmpeg -v error -y -f lavfi -i "$SRC:s=$r" -c:a pcm_s16le $T/s$r.wav
  ffmpeg -v error -y -i $T/s$r.wav -af "pan=mono|c0=0.6*c0+0.4*c1" $T/m$r.wav
done
# near-identical channels: joint stereo picks mid/side almost always
ffmpeg -v error -y -i $T/s44100.wav -af "pan=stereo|c0=0.8*c0+0.2*c1|c1=0.7*c0+0.3*c1" $T/c44100.wav
ffmpeg -v error -y -i $T/s22050.wav -af "pan=stereo|c0=0.8*c0+0.2*c1|c1=0.7*c0+0.3*c1" $T/c22050.wav
cut() { ffmpeg -v error -y -i $1 -t $2 $T/cut.wav; }
enc() { # enc <wav> <seconds> <out> lame-args...
  cut $1 $2; out=$3; shift 3; lame --quiet -t "$@" $T/cut.wav $out; }

# MPEG-1
enc $T/c44100.wav 0.7 $T/js128.mp3 -m j -b 128 --resample 44.1
lame --quiet --add-id3v2 --tt "FreeNetRadio fixture" --ta "ffmpeg + lame" -m j -b 128 --resample 44.1 $T/cut.wav $O/m1_44k_js128_id3.mp3
enc $T/s44100.wav 0.7 $T/s192.mp3 -m s -b 192 --resample 44.1
enc $T/s48000.wav 0.4 $O/m1_48k_s320.mp3 -m s -b 320 --resample 48
enc $T/s48000.wav 0.5 $O/m1_48k_js256.mp3 -m j -b 256 --resample 48
enc $T/m32000.wav 1.2 $O/m1_32k_mono32.mp3 -m m -b 32 --resample 32
enc $T/s32000.wav 0.8 $O/m1_32k_s96.mp3 -m s -b 96 --resample 32
enc $T/c44100.wav 1.0 $O/m1_44k_ms64.mp3 -m f -b 64 --resample 44.1
enc $T/s44100.wav 0.8 $O/m1_44k_vbr_v3.mp3 -m j -V 3 --resample 44.1
enc $T/s44100.wav 0.7 $O/m1_44k_js160.mp3 -m j -b 160 --resample 44.1
enc $T/c44100.wav 0.6 $O/m1_44k_js128_crc.mp3 -m j -b 128 -p --resample 44.1
enc $T/s44100.wav 0.5 $O/m1_44k_free200.mp3 -m j --freeformat -b 200 --resample 44.1
# mono, stereo, mono, stereo in one stream (the filterbank keeps the right
# channel's history across the mono parts)
enc $T/m44100.wav 0.3 $T/a.mp3 -m m -b 96 --resample 44.1
enc $T/s44100.wav 0.3 $T/b.mp3 -m s -b 96 --resample 44.1
cat $T/a.mp3 $T/b.mp3 $T/a.mp3 $T/b.mp3 > $O/m1_44k_mono_stereo_switch.mp3
# MPEG-2
enc $T/c22050.wav 1.0 $T/m2js.mp3 -m j -b 64 --resample 22.05
cp $T/m2js.mp3 $O/m2_22k_js64.mp3
enc $T/s24000.wav 0.7 $O/m2_24k_s160.mp3 -m s -b 160 --resample 24
enc $T/m16000.wav 1.5 $O/m2_16k_mono24.mp3 -m m -b 24 --resample 16
enc $T/s22050.wav 1.0 $O/m2_22k_vbr_v6.mp3 -m j -V 6 --resample 22.05
enc $T/s16000.wav 1.0 $T/m2short.mp3 -m j -b 48 --resample 16
# MPEG-2.5
enc $T/s11025.wav 1.5 $O/m25_11k_js32.mp3 -m j -b 32 --resample 11.025
enc $T/s12000.wav 1.2 $O/m25_12k_s64.mp3 -m s -b 64 --resample 12
enc $T/m8000.wav 2.0 $O/m25_8k_mono16.mp3 -m m -b 16 --resample 8
enc $T/s8000.wav 1.5 $T/m25short.mp3 -m j -b 24 --resample 8
enc $T/m8000.wav 1.5 $T/m25shortmono.mp3 -m m -b 16 --resample 8

# Intensity stereo and mixed blocks: no encoder at hand makes them, so they
# are switched on in streams encoded without (the audio is nonsense, the
# decoding paths are the real ones).
enc $T/c44100.wav 0.8 $T/js96.mp3 -m j -b 96 --resample 44.1
$PY patch $T/js96.mp3 $O/m1_44k_intensity96.mp3 istereo
$PY patch $T/m2js.mp3 $O/m2_22k_intensity64.mp3 istereo
enc $T/s11025.wav 1.2 $T/m25js.mp3 -m j -b 24 --resample 11.025
$PY patch $T/m25js.mp3 $O/m25_11k_intensity24.mp3 istereo
enc $T/s44100.wav 0.7 $T/short.mp3 -m j -b 128 --resample 44.1
$PY patch $T/short.mp3 $O/m1_44k_mixed128.mp3 mixed
$PY patch $T/short.mp3 $O/m1_44k_mixed_intensity128.mp3 mixed istereo
$PY patch $T/m2short.mp3 $O/m2_16k_mixed48.mp3 mixed
$PY patch $T/m2short.mp3 $O/m2_16k_mixed_intensity48.mp3 mixed istereo
enc $T/m44100.wav 0.8 $T/mono.mp3 -m m -b 64 --resample 44.1
$PY patch $T/mono.mp3 $O/m1_44k_mono_modeext64.mp3 modeext
# upstream cannot decode these two (see README)
$PY patch $T/m25shortmono.mp3 $O/noref/m25_8k_mixed.mp3 mixed
$PY patch $T/m25short.mp3 $O/noref/m25_8k_mixed_stereo.mp3 mixed

# Layer II
ffmpeg -v error -y -i $T/s44100.wav -t 0.4 -c:a mp2 -b:a 192k -f mp2 $O/layer2_44k_192.mp2
mv $O/layer2_44k_192.mp2 $O/layer2_44k_192.mp3

python3 - $T $O $(dirname $0)/mp3tool.py <<'PY'
import sys, random, subprocess
T, O, TOOL = sys.argv[1:4]
js = open(T + '/js128.mp3', 'rb').read()
s192 = open(T + '/s192.mp3', 'rb').read()
def offsets(p):
    return [int(x) for x in subprocess.check_output([sys.executable, TOOL, 'offsets', p]).split()]
offs = offsets(T + '/js128.mp3')
# leading junk, with bytes that look like frame headers in it
rnd = random.Random(808)
junk = bytearray(rnd.randrange(256) for _ in range(2500))
for at in (100, 700, 1500, 2496): junk[at:at+4] = b'\xff\xfb\x90\x64'
open(O + '/m1_44k_js128_junk.mp3', 'wb').write(bytes(junk) + js)
# start in the middle of a frame, a third of the way in
mid = offs[len(offs) // 3] + 150
open(O + '/m1_44k_js128_midstart.mp3', 'wb').write(js[mid:])
# end in the middle of a frame
so = offsets(T + '/s192.mp3')
open(O + '/m1_44k_s192_truncated.mp3', 'wb').write(s192[:so[-3] + 300])
# damage: side info of some frames, main data of others, one lost header
d = bytearray(js)
for n, o in enumerate(offs):
    if n % 9 == 4: d[o + 4 + rnd.randrange(30)] ^= 1 << rnd.randrange(8)   # side info
    if n % 9 == 7: d[o + 60 + rnd.randrange(300)] = rnd.randrange(256)       # main data
    if n == 20: d[o + 6] = 0xFF; d[o + 7] = 0xFF; d[o + 8] = 0xFF            # big_values > 288 somewhere
    if n == 30: d[o + 1] = 0x00                                              # header gone
open(O + '/m1_44k_js128_damaged.mp3', 'wb').write(bytes(d))
PY
rm -rf $T
