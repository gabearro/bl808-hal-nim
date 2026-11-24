#!/usr/bin/env python3
"""Run the vendor CKLink DebugServer during the LP pad activity window.

This is intended to be launched as a hardware-validation host_action after
the LP firmware has started sampling candidate debug pins. It reports a
classification marker and exits 0 so the UART diagnostics remain the source
of truth for whether LP observed physical pin activity.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
LOG_DIR = REPO_ROOT / "build" / "hw-validation" / "logs"
USBIP_LOG = LOG_DIR / "lp_vendor_cklink_probe.usbip.log"
ATTACH_LOG = LOG_DIR / "lp_vendor_cklink_probe.usbip-attach.log"
SNAPSHOT_LOG = LOG_DIR / "lp_vendor_cklink_probe.snapshot.log"


def command_to_text(cmd: list[str]) -> str:
    return " ".join(subprocess.list2cmdline([part]) for part in cmd)


def run(cmd: list[str], *, timeout: float | None = None) -> subprocess.CompletedProcess[str]:
    print(f"$ {command_to_text(cmd)}", flush=True)
    try:
        proc = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        if output:
            print(output, end="" if output.endswith("\n") else "\n", flush=True)
        print(f"timeout after {timeout}s", flush=True)
        return subprocess.CompletedProcess(cmd, 124, output)
    if proc.stdout:
        print(proc.stdout, end="" if proc.stdout.endswith("\n") else "\n", flush=True)
    return proc


def docker_exec(script: str, *, timeout: float | None = None) -> subprocess.CompletedProcess[str]:
    return run(["docker", "exec", "cklink-usbip", "sh", "-lc", script], timeout=timeout)


def detach_usbip_ports() -> None:
    for port in range(8):
        docker_exec(
            f"nsenter -t 1 -m sh -lc 'usbip detach -p {port} 2>&1 || true'",
            timeout=5,
        )


def find_cklink_busid() -> str | None:
    proc = docker_exec(
        'nsenter -t 1 -m sh -lc "usbip list -r host.docker.internal 2>&1"',
        timeout=10,
    )
    for line in proc.stdout.splitlines():
        if "42bf:b210" not in line.lower():
            continue
        first = line.split()[0] if line.split() else ""
        return first.replace(":", "")
    return None


def attach_cklink(busid: str) -> bool:
    ATTACH_LOG.write_text("", encoding="utf-8")
    for _ in range(3):
        proc = docker_exec(
            "nsenter -t 1 -m sh -lc "
            f"'usbip attach -r host.docker.internal -d {busid} 2>&1; "
            "sleep 1; usbip port 2>&1; lsusb -d 42bf:b210 || true'",
            timeout=15,
        )
        with ATTACH_LOG.open("a", encoding="utf-8") as log:
            log.write(proc.stdout)
        check = docker_exec(
            'nsenter -t 1 -m sh -lc "lsusb -d 42bf:b210 >/dev/null 2>&1"',
            timeout=5,
        )
        if check.returncode == 0:
            return True
    return False


def start_usbip_host() -> subprocess.Popen[str]:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = USBIP_LOG.open("w", encoding="utf-8")
    env = os.environ.copy()
    env.setdefault("RUST_LOG", "debug")
    proc = subprocess.Popen(
        ["cargo", "run", "--example", "cklink_host"],
        cwd=REPO_ROOT / "build" / "usbip",
        text=True,
        stdout=log,
        stderr=subprocess.STDOUT,
        env=env,
    )
    # Keep the log file alive via stdout; no Python reference needed after start.
    return proc


def stop_process(proc: subprocess.Popen[str] | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def run_debugserver(setcdi: str) -> subprocess.CompletedProcess[str]:
    script = (
        "timeout -k 2s 45s "
        "env LD_LIBRARY_PATH=. "
        "LD_PRELOAD=/work/libusb_cklink_trace.so "
        "LIBUSB_DEBUG=2 "
        "./DebugServerConsole.elf "
        "-select-vendor CK-Link "
        "-arch riscv "
        f"-setcdi {setcdi} "
        "-tdescfile tdescriptions/riscv/riscv-e902-tdesc.xml "
        "-no-trst "
        "-check-target "
        "--debug all "
        "2>&1"
    )
    return run(
        [
            "docker",
            "run",
            "--rm",
            "--platform",
            "linux/amd64",
            "--privileged",
            "-e",
            "LIBUSB_DEBUG=2",
            "-v",
            "/dev/bus/usb:/dev/bus/usb",
            "-v",
            f"{REPO_ROOT / 'build' / 'vendor-debugserver'}:/work:rw",
            "-v",
            f"{REPO_ROOT / 'build' / 'vendor-debugserver' / 'thserver-bl808sdk-cklink'}:/opt/thserver:rw",
            "-w",
            "/opt/thserver",
            "debian:bookworm-slim",
            "sh",
            "-lc",
            script,
        ],
        timeout=60,
    )


def run_openocd_snapshot() -> subprocess.CompletedProcess[str]:
    openocd = os.environ.get("BL808_VENDOR_OPENOCD", "/opt/homebrew/bin/openocd")
    interface = os.environ.get(
        "BL808_VENDOR_OPENOCD_INTERFACE",
        "/opt/homebrew/share/openocd/scripts/interface/cklink.cfg",
    )
    target = os.environ.get("BL808_VENDOR_OPENOCD_TARGET", str(REPO_ROOT / "tgt_e907_v2.cfg"))
    commands = [
        "halt",
        "mdw 0x40002f60 8",
        "mdw 0x40002f80 48",
        "shutdown",
    ]
    cmd = [openocd, "-f", interface, "-f", target]
    for command in commands:
        cmd.extend(["-c", command])
    proc = run(cmd, timeout=60)
    SNAPSHOT_LOG.write_text(proc.stdout or "", encoding="utf-8")
    return proc


def reset_cklink_for_host() -> None:
    helper = REPO_ROOT / "build" / "usb_reset"
    if helper.exists():
        run([str(helper), "0x42bf", "0xb210", "FactoryAIOT"], timeout=10)
        time.sleep(2.0)


def classify(output: str) -> str:
    if "Read DTM IDCODE get" in output or "Read DTMCS get" in output:
        return "debugserver attempted DTM reads"
    if "can't setup cJTAG-2" in output:
        return "debugserver failed before DTM reads while setting cJTAG2"
    if "probe initialization failed" in output:
        return "debugserver failed during probe initialization"
    if "CKLink" in output or "T-HEAD" in output:
        return "debugserver reached CKLink setup"
    return "debugserver did not reach recognizable CKLink attach output"


def main() -> int:
    print("BL808_LP_VENDOR_PROBE begin", flush=True)
    setcdi = os.environ.get("BL808_VENDOR_SETCDI", "2")
    snapshot_delay = float(os.environ.get("BL808_VENDOR_SNAPSHOT_DELAY", "125"))
    usbip_proc: subprocess.Popen[str] | None = None
    try:
        detach_usbip_ports()
        usbip_proc = start_usbip_host()
        time.sleep(2.0)

        busid = find_cklink_busid()
        print(f"BL808_LP_VENDOR_PROBE busid={busid or '<none>'}", flush=True)
        if not busid:
            print("BL808_LP_VENDOR_PROBE no CKLink USB/IP export found", flush=True)
            return 0
        if not attach_cklink(busid):
            print("BL808_LP_VENDOR_PROBE CKLink USB/IP attach failed", flush=True)
            return 0

        proc = run_debugserver(setcdi)
        print(f"BL808_LP_VENDOR_PROBE debugserver_exit={proc.returncode}", flush=True)
        print(f"BL808_LP_VENDOR_PROBE classification={classify(proc.stdout)}", flush=True)
        if snapshot_delay >= 0:
            detach_usbip_ports()
            stop_process(usbip_proc)
            usbip_proc = None
            if os.environ.get("BL808_VENDOR_RESET_BEFORE_SNAPSHOT") == "1":
                reset_cklink_for_host()
            print(f"BL808_LP_VENDOR_SNAPSHOT wait_s={snapshot_delay:g}", flush=True)
            time.sleep(snapshot_delay)
            snapshot = run_openocd_snapshot()
            print(f"BL808_LP_VENDOR_SNAPSHOT openocd_exit={snapshot.returncode}", flush=True)
            print(f"BL808_LP_VENDOR_SNAPSHOT log={SNAPSHOT_LOG}", flush=True)
            if snapshot.returncode == 0:
                print("BL808_LP_VENDOR_SNAPSHOT done", flush=True)
            else:
                print("BL808_LP_VENDOR_SNAPSHOT failed", flush=True)
        return 0
    except KeyboardInterrupt:
        os.kill(os.getpid(), signal.SIGINT)
        return 130
    except Exception as exc:
        print(f"BL808_LP_VENDOR_PROBE error={exc}", flush=True)
        return 0
    finally:
        try:
            detach_usbip_ports()
        except Exception as exc:
            print(f"BL808_LP_VENDOR_PROBE cleanup_warning={exc}", flush=True)
        stop_process(usbip_proc)
        print(f"BL808_LP_VENDOR_PROBE usbip_log={USBIP_LOG}", flush=True)
        print(f"BL808_LP_VENDOR_PROBE attach_log={ATTACH_LOG}", flush=True)
        print("BL808_LP_VENDOR_PROBE done", flush=True)


if __name__ == "__main__":
    sys.exit(main())
