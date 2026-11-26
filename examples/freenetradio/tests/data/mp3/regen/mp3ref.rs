// Reference trace of upstream's decoder, in the format tests/t_mp3dec.nim checks.
// usage: mp3ref <file.mp3> <window> [pcm-out]
//   window = 0: every call sees the rest of the file; otherwise at most
//   <window> bytes (a stream buffer).
use nanomp3_core::{DecodeError, Decoder, MAX_SAMPLES_PER_FRAME};
use std::io::Write;

fn fnv(h: &mut u64, bytes: &[u8]) {
    for &b in bytes {
        *h ^= b as u64;
        *h = h.wrapping_mul(0x100000001b3);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&args[1]).unwrap();
    let window: usize = args[2].parse().unwrap();
    let mut out = args.get(3).map(|p| std::fs::File::create(p).unwrap());
    let mut dec = Decoder::new();
    let mut pcm = [0i16; MAX_SAMPLES_PER_FRAME];
    let mut pos = 0usize;
    let mut calls = 0u32;
    let mut total: u64 = 0xcbf29ce484222325;
    let mut spec_h: u64 = 0xcbf29ce484222325;
    let stdout = std::io::stdout();
    let mut o = stdout.lock();
    while pos < data.len() {
        let end = if window == 0 { data.len() } else { (pos + window).min(data.len()) };
        let (consumed, res) = dec.decode(&data[pos..end], &mut pcm);
        let (st, info) = match res {
            Ok(i) => (0, Some(i)),
            Err(DecodeError::NoFrame) => (1, None),
            Err(DecodeError::ReservoirUnavailable(i)) => (2, Some(i)),
            Err(DecodeError::Corrupt(i)) => (3, Some(i)),
            Err(DecodeError::UnsupportedLayer(i)) => (4, Some(i)),
            Err(_) => unreachable!(),
        };
        let mut fh: u64 = 0xcbf29ce484222325;
        let (mut n, mut ch, mut hz, mut kbps, mut layer) = (0, 0, 0, 0, 0);
        if let Some(i) = info {
            n = i.samples_produced;
            ch = i.channels.num() as usize;
            hz = i.sample_rate;
            kbps = i.bitrate;
            layer = i.layer;
            for s in &pcm[..n * ch] {
                let b = s.to_le_bytes();
                fnv(&mut fh, &b);
                fnv(&mut total, &b);
                if let Some(f) = out.as_mut() {
                    f.write_all(&b).unwrap();
                }
            }
        }
        writeln!(o, "{} {} {} {} {} {} {} {:016x}", consumed, st, n, ch, hz, kbps, layer, fh).unwrap();
        pos += consumed;
        calls += 1;
        if calls % 4 == 0 {
            let (spec, sn) = dec.spectrum();
            for v in spec.iter() {
                fnv(&mut spec_h, &v.to_bits().to_le_bytes());
            }
            fnv(&mut spec_h, &sn.to_le_bytes());
            writeln!(o, "S {} {:016x}", sn, spec_h).unwrap();
            dec.reset_spectrum();
        }
        if consumed == 0 {
            break;
        }
    }
    let (spec, sn) = dec.spectrum();
    for v in spec.iter() {
        fnv(&mut spec_h, &v.to_bits().to_le_bytes());
    }
    fnv(&mut spec_h, &sn.to_le_bytes());
    writeln!(o, "E {} {:016x} {} {:016x}", calls, total, sn, spec_h).unwrap();
}
