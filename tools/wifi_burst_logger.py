#!/usr/bin/env python3
"""Long-running UDP echo logger for intermittent BL808 Wi-Fi loss.

Sends paced UDP echo probes to the m0_wifi_http_server image and records
every probe with a wall-clock timestamp. Alongside the probes it samples,
without touching JTAG or the UART:

  * the board's HTTP diagnostics (udp_rx_packets / udp_tx_packets), so each
    interval's loss splits into "request never reached the board" (downlink)
    and "board queued a reply that never came back" (uplink);
  * a wired ping to the gateway, as a control for the host and LAN;
  * optionally the Mac's Wi-Fi scan, for 2.4 GHz channel occupancy.

Output goes to <out>/probes.csv, <out>/events.jsonl and <out>/summary.json.
Stop with Ctrl-C or SIGTERM; the summary is written either way.

Example:
  tools/wifi_burst_logger.py --ip 192.168.1.114 --duration 3600
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import socket
import struct
import subprocess
import threading
import time
from collections import Counter
from pathlib import Path

MAGIC = b"BLBURST1"
HEADER = struct.Struct("<8sI")


def now() -> float:
    return time.time()


class EventLog:
    def __init__(self, path: Path) -> None:
        self._file = path.open("a", buffering=1)
        self._lock = threading.Lock()

    def write(self, kind: str, **fields) -> None:
        record = {"t": round(now(), 3), "kind": kind, **fields}
        with self._lock:
            self._file.write(json.dumps(record) + "\n")

    def close(self) -> None:
        with self._lock:
            self._file.close()


def fetch_diagnostics(ip: str, port: int, timeout: float) -> dict[str, str]:
    request = f"GET / HTTP/1.1\r\nHost: {ip}\r\nConnection: close\r\n\r\n".encode()
    with socket.create_connection((ip, port), timeout=timeout) as conn:
        conn.settimeout(timeout)
        conn.sendall(request)
        chunks = []
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
    text = b"".join(chunks).decode("utf-8", "replace")
    return dict(re.findall(r"^([a-z0-9_]+)=(.*?)\r?$", text, flags=re.M))


DIAG_COUNTERS = ("udp_rx_packets", "udp_tx_packets", "udp_send_failures", "http_requests")
DIAG_STATE = ("last_status", "last_reason", "scan_done")


def diagnostics_loop(args, log: EventLog, stop: threading.Event, samples: list) -> None:
    while not stop.is_set():
        started = now()
        try:
            diag = fetch_diagnostics(args.ip, args.http_port, args.diag_timeout)
            sample = {key: int(diag[key]) for key in DIAG_COUNTERS if key in diag}
            sample.update({key: diag[key] for key in DIAG_STATE if key in diag})
            sample["t"] = started
            sample["fetch_ms"] = round((now() - started) * 1000, 1)
            samples.append(sample)
            log.write("diag", **{k: v for k, v in sample.items() if k != "t"})
        except (OSError, ValueError) as exc:
            log.write("diag_error", error=str(exc)[:120],
                      elapsed_ms=round((now() - started) * 1000, 1))
        stop.wait(args.diag_every)


def gateway_loop(args, log: EventLog, stop: threading.Event, stats: Counter) -> None:
    while not stop.is_set():
        started = now()
        try:
            result = subprocess.run(
                ["ping", "-n", "-c", "1", "-W", "700", args.gateway],
                capture_output=True, text=True, timeout=3)
            match = re.search(r"time=([0-9.]+)", result.stdout)
            ok = result.returncode == 0 and match is not None
        except (OSError, subprocess.SubprocessError):
            ok, match = False, None
        stats["sent"] += 1
        if ok:
            stats["ok"] += 1
        else:
            log.write("gateway_miss")
        if match and float(match.group(1)) > 50:
            log.write("gateway_slow", ms=float(match.group(1)))
        stop.wait(max(0.0, args.gateway_every - (now() - started)))


def wifi_scan_loop(args, log: EventLog, stop: threading.Event) -> None:
    while not stop.is_set():
        try:
            raw = subprocess.run(
                ["system_profiler", "SPAirPortDataType", "-json"],
                capture_output=True, text=True, timeout=40).stdout
            iface = json.loads(raw)["SPAirPortDataType"][0]["spairport_airport_interfaces"][0]
            channels = Counter()
            for net in iface.get("spairport_airport_other_local_wireless_networks", []):
                channel = str(net.get("spairport_network_channel", ""))
                if "2GHz" in channel:
                    channels[channel.split()[0]] += 1
            log.write("wifi_scan", networks_2g=dict(sorted(channels.items())))
        except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError) as exc:
            log.write("wifi_scan_error", error=str(exc)[:120])
        stop.wait(args.wifi_scan_every)


def receiver_loop(sock: socket.socket, stop: threading.Event, pending: dict,
                  lock: threading.Lock, late: list) -> None:
    while not stop.is_set():
        try:
            data, _ = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            return
        arrived = time.monotonic()
        if len(data) < HEADER.size:
            continue
        magic, seq = HEADER.unpack_from(data)
        if magic != MAGIC:
            continue
        with lock:
            entry = pending.get(seq)
            if entry is None:
                continue
            if entry["done"].is_set():
                late.append((seq, round((arrived - entry["sent"]) * 1000, 1)))
                continue
            entry["rtt"] = arrived - entry["sent"]
            entry["done"].set()


def find_bursts(results: list[tuple[int, float, bool]], min_len: int) -> list[dict]:
    bursts, run = [], []
    for seq, t, ok in results:
        if not ok:
            run.append((seq, t))
            continue
        if len(run) >= min_len:
            bursts.append({"start": run[0][1], "end": run[-1][1],
                           "first_seq": run[0][0], "misses": len(run),
                           "span_s": round(run[-1][1] - run[0][1], 2)})
        run = []
    if len(run) >= min_len:
        bursts.append({"start": run[0][1], "end": run[-1][1], "first_seq": run[0][0],
                       "misses": len(run), "span_s": round(run[-1][1] - run[0][1], 2)})
    return bursts


def split_loss(results, samples) -> list[dict]:
    """Attribute loss in each diagnostics interval to downlink or uplink."""
    intervals = []
    for before, after in zip(samples, samples[1:]):
        if not all(key in before and key in after for key in ("udp_rx_packets", "udp_tx_packets")):
            continue
        # Counters going backwards mean the board rebooted in this interval.
        rx = after["udp_rx_packets"] - before["udp_rx_packets"]
        tx = after["udp_tx_packets"] - before["udp_tx_packets"]
        window = [ok for _, t, ok in results if before["t"] <= t < after["t"]]
        if rx < 0 or tx < 0:
            intervals.append({"start": before["t"], "reboot": True})
            continue
        sent, echoed = len(window), sum(window)
        if sent == echoed:
            continue
        intervals.append({
            "start": round(before["t"], 1), "end": round(after["t"], 1),
            "sent": sent, "echoed": echoed, "board_rx": rx, "board_tx": tx,
            # Probes in flight at either sample edge make these off by one or two.
            "downlink_lost": max(0, sent - rx), "uplink_lost": max(0, tx - echoed),
        })
    return intervals


def summarize(args, results, late, samples, gateway, started) -> dict:
    sent = len(results)
    echoed = sum(ok for _, _, ok in results)
    bursts = find_bursts(results, args.burst_min)
    isolated = (sent - echoed) - sum(b["misses"] for b in bursts)
    gaps = [round(b2["start"] - b1["end"], 1) for b1, b2 in zip(bursts, bursts[1:])]
    buckets: dict[int, list[int]] = {}
    for _, t, ok in results:
        bucket = buckets.setdefault(int((t - started) // args.bucket), [0, 0])
        bucket[0] += 1
        bucket[1] += not ok
    intervals = split_loss(results, samples)
    return {
        "ip": args.ip, "started": started, "duration_s": round(now() - started, 1),
        "interval_s": args.interval, "timeout_s": args.timeout,
        "sent": sent, "echoed": echoed, "missed": sent - echoed,
        "loss_pct": round(100 * (sent - echoed) / sent, 2) if sent else None,
        "late_replies": len(late), "isolated_misses": isolated,
        "bursts": len(bursts), "longest_burst_s": max((b["span_s"] for b in bursts), default=0),
        "burst_list": [{**b, "start": time.strftime("%H:%M:%S", time.localtime(b["start"])),
                        "end": time.strftime("%H:%M:%S", time.localtime(b["end"]))}
                       for b in bursts],
        "gaps_between_bursts_s": gaps,
        "loss_by_bucket": {f"{k * args.bucket // 60}m": f"{v[1]}/{v[0]}"
                           for k, v in sorted(buckets.items())},
        "downlink_lost": sum(i.get("downlink_lost", 0) for i in intervals),
        "uplink_lost": sum(i.get("uplink_lost", 0) for i in intervals),
        "board_reboots": sum(1 for i in intervals if i.get("reboot")),
        "lossy_intervals": intervals,
        "gateway_ping": {"sent": gateway["sent"], "ok": gateway["ok"]},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--ip", required=True, help="Board IPv4 address.")
    parser.add_argument("--udp-port", type=int, default=65000)
    parser.add_argument("--http-port", type=int, default=80)
    parser.add_argument("--interval", type=float, default=0.4, help="Seconds between probes.")
    parser.add_argument("--timeout", type=float, default=0.5, help="Seconds to wait for an echo.")
    parser.add_argument("--payload", type=int, default=32, help="UDP payload bytes (>= 12).")
    parser.add_argument("--duration", type=float, default=3600, help="Seconds to run; 0 runs until stopped.")
    parser.add_argument("--diag-every", type=float, default=10)
    parser.add_argument("--diag-timeout", type=float, default=4)
    parser.add_argument("--gateway", default=None, help="Gateway to ping; default is read from the board.")
    parser.add_argument("--gateway-every", type=float, default=2)
    parser.add_argument("--wifi-scan-every", type=float, default=0,
                        help="Seconds between Mac Wi-Fi scans; 0 disables them.")
    parser.add_argument("--burst-min", type=int, default=2, help="Consecutive misses that count as a burst.")
    parser.add_argument("--bucket", type=int, default=300, help="Seconds per loss bucket in the summary.")
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()
    if args.payload < HEADER.size:
        parser.error(f"--payload must be at least {HEADER.size}")

    started = now()
    out = args.out or Path("build/wifi-burst-log") / time.strftime("%Y%m%d-%H%M%S", time.localtime(started))
    out.mkdir(parents=True, exist_ok=True)
    log = EventLog(out / "events.jsonl")

    if args.gateway is None:
        try:
            args.gateway = fetch_diagnostics(args.ip, args.http_port, args.diag_timeout).get("gateway")
        except OSError as exc:
            print(f"board diagnostics unreachable at {args.ip}:{args.http_port}: {exc}")
            return 2
    log.write("start", ip=args.ip, gateway=args.gateway, interval=args.interval, timeout=args.timeout)
    print(f"logging to {out}  (board {args.ip}, gateway {args.gateway})", flush=True)

    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.2)
    pending: dict[int, dict] = {}
    lock = threading.Lock()
    late: list[tuple[int, float]] = []
    samples: list[dict] = []
    gateway: Counter = Counter()

    workers = [
        threading.Thread(target=receiver_loop, args=(sock, stop, pending, lock, late), daemon=True),
        threading.Thread(target=diagnostics_loop, args=(args, log, stop, samples), daemon=True),
    ]
    if args.gateway:
        workers.append(threading.Thread(target=gateway_loop, args=(args, log, stop, gateway), daemon=True))
    if args.wifi_scan_every > 0:
        workers.append(threading.Thread(target=wifi_scan_loop, args=(args, log, stop), daemon=True))
    for worker in workers:
        worker.start()

    results: list[tuple[int, float, bool]] = []
    probes = (out / "probes.csv").open("w", buffering=1)
    probes.write("seq,time,ok,rtt_ms\n")
    seq = 0
    miss_run = 0
    next_report = started + 60
    deadline = started + args.duration if args.duration > 0 else float("inf")
    while not stop.is_set() and now() < deadline:
        tick = time.monotonic()
        entry = {"sent": tick, "done": threading.Event(), "rtt": None}
        with lock:
            pending[seq] = entry
            pending.pop(seq - 64, None)  # late replies are tracked for 64 probes
        sent_at = now()
        try:
            sock.sendto(HEADER.pack(MAGIC, seq) + os.urandom(args.payload - HEADER.size),
                        (args.ip, args.udp_port))
            ok = entry["done"].wait(args.timeout)
        except OSError as exc:
            log.write("send_error", seq=seq, error=str(exc)[:120])
            ok = False
        with lock:
            entry["done"].set()
            rtt = entry["rtt"]
        ok = ok and rtt is not None
        results.append((seq, sent_at, ok))
        probes.write(f"{seq},{sent_at:.3f},{int(ok)},{'' if rtt is None else round(rtt * 1000, 2)}\n")
        if ok:
            if miss_run >= args.burst_min:
                log.write("burst_end", seq=seq, misses=miss_run)
            miss_run = 0
        else:
            miss_run += 1
            if miss_run == args.burst_min:
                log.write("burst_start", seq=seq - miss_run + 1)
        if now() >= next_report:
            missed = sum(not r[2] for r in results)
            print(f"{time.strftime('%H:%M:%S')}  sent={len(results)} missed={missed} "
                  f"late={len(late)} gateway={gateway['ok']}/{gateway['sent']}", flush=True)
            next_report += 60
        seq += 1
        stop.wait(max(0.0, args.interval - (time.monotonic() - tick)))

    stop.set()
    time.sleep(min(1.0, args.timeout))  # let straggling echoes register as late
    for item in late:
        log.write("late_reply", seq=item[0], delay_ms=item[1])
    summary = summarize(args, results, late, samples, gateway, started)
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    log.write("stop", sent=summary["sent"], missed=summary["missed"])
    log.close()
    probes.close()
    sock.close()

    print(f"\nsent={summary['sent']} echoed={summary['echoed']} missed={summary['missed']} "
          f"({summary['loss_pct']}%)  late={summary['late_replies']}")
    print(f"bursts={summary['bursts']} longest={summary['longest_burst_s']}s "
          f"isolated_misses={summary['isolated_misses']}")
    print(f"downlink_lost={summary['downlink_lost']} uplink_lost={summary['uplink_lost']} "
          f"board_reboots={summary['board_reboots']}")
    print(f"gateway ping {gateway['ok']}/{gateway['sent']}")
    print(f"summary: {out / 'summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
