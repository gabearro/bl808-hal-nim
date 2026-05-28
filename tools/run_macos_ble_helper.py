#!/usr/bin/env python3
"""Build and run the native macOS CoreBluetooth validation helper."""

from __future__ import annotations

import plistlib
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
SOURCE = REPO_ROOT / "tools" / "macos_ble_helper.swift"
APP = Path(
    os.environ.get(
        "BL808_MACOS_BLE_HELPER_APP",
        Path.home()
        / "Library"
        / "Application Support"
        / "bl808-hal"
        / "MacOSBLEHelper.app",
    )
).expanduser()
CONTENTS = APP / "Contents"
MACOS = CONTENTS / "MacOS"
EXECUTABLE = MACOS / "MacOSBLEHelper"
PLIST = CONTENTS / "Info.plist"
ENTITLEMENTS = CONTENTS / "Entitlements.plist"
BUNDLE_ID = "dev.bl808hal.MacOSBLEHelper"


def newest_mtime(paths: list[Path]) -> float:
    return max(path.stat().st_mtime for path in paths if path.exists())


def expected_info_plist() -> dict[str, object]:
    return {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": EXECUTABLE.name,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "MacOSBLEHelper",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "13.0",
        "NSPrincipalClass": "NSApplication",
        "NSBluetoothAlwaysUsageDescription": (
            "Hardware BLE validation advertises and connects to local BL808 test peripherals."
        ),
        "NSBluetoothPeripheralUsageDescription": (
            "Hardware BLE validation advertises and connects to local BL808 test peripherals."
        ),
    }


def expected_entitlements() -> dict[str, object]:
    entitlements: dict[str, object] = {
        "com.apple.security.device.bluetooth": True,
    }
    if os.environ.get("BL808_MACOS_BLE_HELPER_SANDBOX", "").lower() not in {
        "1",
        "true",
        "yes",
        "on",
    }:
        return entitlements
    entitlements["com.apple.security.app-sandbox"] = True
    return entitlements


def info_plist_matches() -> bool:
    if not PLIST.exists():
        return False
    try:
        with PLIST.open("rb") as handle:
            return plistlib.load(handle) == expected_info_plist()
    except (OSError, plistlib.InvalidFileException):
        return False


def entitlements_plist_matches() -> bool:
    expected = expected_entitlements()
    if not expected:
        return not ENTITLEMENTS.exists()
    if not ENTITLEMENTS.exists():
        return False
    try:
        with ENTITLEMENTS.open("rb") as handle:
            return plistlib.load(handle) == expected
    except (OSError, plistlib.InvalidFileException):
        return False


def app_is_fresh() -> bool:
    if not EXECUTABLE.exists() or not PLIST.exists():
        return False
    return (
        EXECUTABLE.stat().st_mtime >= newest_mtime([SOURCE])
        and info_plist_matches()
        and entitlements_plist_matches()
    )


def write_info_plist() -> None:
    CONTENTS.mkdir(parents=True, exist_ok=True)
    info = expected_info_plist()
    with PLIST.open("wb") as handle:
        plistlib.dump(info, handle, sort_keys=True)


def write_entitlements_plist() -> None:
    entitlements = expected_entitlements()
    if not entitlements:
        ENTITLEMENTS.unlink(missing_ok=True)
        return
    CONTENTS.mkdir(parents=True, exist_ok=True)
    with ENTITLEMENTS.open("wb") as handle:
        plistlib.dump(entitlements, handle, sort_keys=True)


def run(cmd: list[str]) -> None:
    proc = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if proc.returncode != 0:
        sys.stdout.write(proc.stdout)
        raise SystemExit(proc.returncode)


def clear_app_metadata() -> None:
    if not APP.exists() or shutil.which("xattr") is None:
        return
    subprocess.run(["xattr", "-cr", str(APP)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for attr in (
        "com.apple.FinderInfo",
        "com.apple.ResourceFork",
        "com.apple.fileprovider.fpfs#P",
        "com.apple.provenance",
    ):
        subprocess.run(["xattr", "-dr", attr, str(APP)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def build_app() -> None:
    if app_is_fresh():
        return
    if shutil.which("swiftc") is None:
        print("[FAIL] swiftc not found; install Xcode command line tools", flush=True)
        raise SystemExit(1)
    if APP.exists():
        shutil.rmtree(APP)
    MACOS.mkdir(parents=True, exist_ok=True)
    write_info_plist()
    write_entitlements_plist()
    run([
        "swiftc",
        str(SOURCE),
        "-O",
        "-framework",
        "CoreBluetooth",
        "-framework",
        "AppKit",
        "-Xlinker",
        "-sectcreate",
        "-Xlinker",
        "__TEXT",
        "-Xlinker",
        "__info_plist",
        "-Xlinker",
        str(PLIST),
        "-o",
        str(EXECUTABLE),
    ])
    if shutil.which("codesign") is not None:
        clear_app_metadata()
        codesign_cmd = [
            "codesign",
            "--force",
            "--deep",
            "--sign",
            "-",
            str(APP),
        ]
        if expected_entitlements():
            codesign_cmd[-1:-1] = ["--entitlements", str(ENTITLEMENTS)]
        run(codesign_cmd)
        clear_app_metadata()


def helper_runtime_limit(arguments: list[str]) -> float | None:
    if not arguments:
        return None
    command = arguments[0]
    values: dict[str, str] = {}
    index = 1
    while index < len(arguments):
        if arguments[index].startswith("--") and index + 1 < len(arguments):
            values[arguments[index][2:]] = arguments[index + 1]
            index += 2
        else:
            index += 1

    def option(name: str, default: float) -> float:
        try:
            return float(values.get(name, default))
        except ValueError:
            return default

    if command == "advertise":
        return option("duration", 20.0) + option("startup-timeout", 8.0) + 5.0
    if command == "connect":
        return option("timeout", 20.0) + 5.0
    if command == "permission":
        return option("timeout", 20.0) + 5.0
    return None


def helper_pids_for_log(log_path: Path) -> list[int]:
    proc = subprocess.run(
        ["/usr/bin/pgrep", "-f", str(log_path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if proc.returncode != 0:
        return []
    current_pid = os.getpid()
    pids: list[int] = []
    for line in proc.stdout.splitlines():
        try:
            pid = int(line)
        except ValueError:
            continue
        if pid != current_pid:
            pids.append(pid)
    return pids


def terminate_pids(pids: list[int], sig: int) -> None:
    for pid in pids:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            pass


def terminate_helper(log_path: Path | None = None) -> None:
    if log_path is None:
        subprocess.run(
            ["/usr/bin/pkill", "-f", str(EXECUTABLE)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return

    pids = helper_pids_for_log(log_path)
    if not pids:
        return
    terminate_pids(pids, signal.SIGTERM)
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        remaining = helper_pids_for_log(log_path)
        if not remaining:
            return
        time.sleep(0.05)
    terminate_pids(helper_pids_for_log(log_path), signal.SIGKILL)


def run_helper(arguments: list[str]) -> int:
    terminated = False
    active_log_path: Path | None = None
    launch_mode = os.environ.get("BL808_MACOS_BLE_HELPER_LAUNCH", "open").lower()
    launch_with_open = launch_mode == "open"
    runtime_limit = helper_runtime_limit(arguments)

    def handle_signal(signum: int, _frame: object) -> None:
        nonlocal terminated
        terminated = True
        terminate_helper(active_log_path)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    log_root = Path.home() / "Library" / "Containers" / BUNDLE_ID / "Data" / "tmp"
    log_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bl808-macos-ble-", dir=log_root) as tmp:
        log_path = Path(tmp) / "helper.log"
        active_log_path = log_path
        if launch_with_open:
            cmd = [
                "/usr/bin/open",
                "-W",
                "-n",
                str(APP),
                "--args",
                "--log-file",
                str(log_path),
                *arguments,
            ]
            stdout = subprocess.PIPE
        else:
            cmd = [str(EXECUTABLE), "--log-file", str(log_path), *arguments]
            stdout = subprocess.DEVNULL
        proc = subprocess.Popen(
            cmd,
            cwd=REPO_ROOT,
            stdout=stdout,
            stderr=subprocess.STDOUT,
            text=True,
        )
        emitted = 0
        captured = ""
        start_time = time.monotonic()
        try:
            while True:
                if log_path.exists():
                    text = log_path.read_text(encoding="utf-8", errors="replace")
                    if len(text) > emitted:
                        chunk = text[emitted:]
                        sys.stdout.write(chunk)
                        sys.stdout.flush()
                        captured += chunk
                        emitted = len(text)
                if terminated:
                    proc.terminate()
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    return 143
                if proc.poll() is not None:
                    if launch_with_open and helper_pids_for_log(log_path):
                        time.sleep(0.05)
                        continue
                    break
                if runtime_limit is not None and time.monotonic() - start_time >= runtime_limit:
                    print(
                        f"[FAIL] BLE helper timed out after {runtime_limit:.1f}s",
                        flush=True,
                    )
                    terminate_helper(log_path)
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    return 124
                time.sleep(0.05)
        finally:
            if terminated or proc.poll() is None:
                terminate_helper(log_path)

        if proc.stdout is not None:
            tail = proc.stdout.read()
            if tail:
                sys.stdout.write(tail)
                sys.stdout.flush()
                captured += tail
        if log_path.exists():
            text = log_path.read_text(encoding="utf-8", errors="replace")
            if len(text) > emitted:
                chunk = text[emitted:]
                sys.stdout.write(chunk)
                sys.stdout.flush()
                captured += chunk

        if "[FAIL]" in captured:
            return 1
        return proc.returncode or 0


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] in {"-h", "--help"}:
        print(
            "usage: run_macos_ble_helper.py advertise|connect|permission [helper args...]",
            flush=True,
        )
        return 2
    build_app()
    return run_helper(sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
