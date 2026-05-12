#!/usr/bin/env python3
"""Build and run BL808 kernel validation examples under QEMU."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = REPO_ROOT / "tools" / "kernel_validation.json"
DEFAULT_WORK_DIR = REPO_ROOT / "build" / "validation"


@dataclass
class TestResult:
    name: str
    ok: bool
    elapsed: float
    reason: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate the BL808 kernel in QEMU")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--tier", choices=("smoke", "full"), default="smoke")
    parser.add_argument("--test", action="append", default=[],
                        help="Run only the named test. May be supplied more than once.")
    parser.add_argument("--qemu", type=Path, default=None,
                        help="Path to qemu-system-riscv64 with -M bl808 support.")
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--keep-going", action="store_true",
                        help="Continue after failures.")
    return parser.parse_args()


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def run_checked(cmd: list[str], *, cwd: Path, timeout: float | None = None) -> str:
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stdout)
    return proc.stdout


def build_firmware(test: dict[str, Any], work_dir: Path) -> dict[str, Path]:
    build_outputs: dict[str, Path] = {}
    bin_dir = work_dir / "bin" / test["name"]
    bin_dir.mkdir(parents=True, exist_ok=True)

    for item in test.get("build", []):
        build_id = item["id"]
        core = item["core"]
        source = item["source"]
        out_path = bin_dir / build_id
        cmd = [
            "nim",
            "c",
            f"-d:{core}",
            "-d:bl808kernel",
            f"--out:{out_path}",
            source,
        ]
        build_log = work_dir / "logs" / f"{test['name']}.{build_id}.build.log"
        ensure_parent(build_log)
        try:
            output = run_checked(cmd, cwd=REPO_ROOT)
        except RuntimeError as exc:
            build_log.write_text(str(exc), encoding="utf-8")
            raise
        build_outputs[build_id] = out_path
        build_log.write_text(output, encoding="utf-8")

    return build_outputs


def create_assets(test: dict[str, Any], work_dir: Path) -> dict[str, Path]:
    assets: dict[str, Path] = {}
    asset_dir = work_dir / "assets" / test["name"]
    asset_dir.mkdir(parents=True, exist_ok=True)

    for item in test.get("assets", []):
        asset_id = item["id"]
        asset_type = item["type"]
        path = asset_dir / item.get("filename", asset_id + ".img")
        if asset_type == "empty_file":
            size = int(item["size"])
            fill_byte = item.get("fill_byte")
            with path.open("wb") as f:
                if fill_byte is None:
                    f.truncate(size)
                else:
                    chunk = bytes([int(fill_byte) & 0xFF]) * 65536
                    remaining = size
                    while remaining > 0:
                        n = min(remaining, len(chunk))
                        f.write(chunk[:n])
                        remaining -= n
        else:
            raise ValueError(f"{test['name']}: unknown asset type {asset_type!r}")
        assets[asset_id] = path

    return assets


class PlaceholderContext:
    def __init__(
        self,
        *,
        qemu: Path,
        work_dir: Path,
        test_name: str,
        builds: dict[str, Path],
        assets: dict[str, Path],
    ) -> None:
        self.qemu = qemu
        self.work_dir = work_dir
        self.test_name = test_name
        self.builds = builds
        self.assets = assets
        self.logs: dict[str, Path] = {}
        self.qmp_sockets: dict[str, Path] = {}

    def format(self, value: str) -> str:
        result = value
        result = result.replace("{qemu}", str(self.qemu))
        result = result.replace("{repo}", str(REPO_ROOT))
        for key, path in self.builds.items():
            result = result.replace(f"{{build:{key}}}", str(path))
        for key, path in self.assets.items():
            result = result.replace(f"{{asset:{key}}}", str(path))
        while "{log:" in result:
            start = result.index("{log:")
            end = result.index("}", start)
            log_id = result[start + len("{log:"):end]
            log_path = self.logs.setdefault(
                log_id,
                self.work_dir / "logs" / f"{self.test_name}.{log_id}.serial.log",
            )
            ensure_parent(log_path)
            log_path.write_text("", encoding="utf-8")
            result = result[:start] + str(log_path) + result[end + 1:]
        while "{qmp:" in result:
            start = result.index("{qmp:")
            end = result.index("}", start)
            qmp_id = result[start + len("{qmp:"):end]
            qmp_path = self.qmp_sockets.setdefault(
                qmp_id,
                Path("/tmp") / f"bk{os.getpid()}-{len(self.qmp_sockets)}.sock",
            )
            ensure_parent(qmp_path)
            if qmp_path.exists():
                qmp_path.unlink()
            result = result[:start] + str(qmp_path) + result[end + 1:]
        return result


def check_forbidden(output: str, forbidden: list[str]) -> str | None:
    for marker in forbidden:
        if marker in output:
            return marker
    return None


def missing_required(output: str, required: list[str]) -> list[str]:
    return [marker for marker in required if marker not in output]


def marker_in_any_output(marker: str, outputs: list[str]) -> bool:
    return any(marker in output for output in outputs)


def check_forbidden_outputs(outputs: list[str], forbidden: list[str]) -> str | None:
    for output in outputs:
        marker = check_forbidden(output, forbidden)
        if marker is not None:
            return marker
    return None


def missing_required_outputs(outputs: list[str], required: list[str]) -> list[str]:
    return [
        marker
        for marker in required
        if not marker_in_any_output(marker, outputs)
    ]


def read_new_file_text(path: Path, offset: int) -> tuple[str, int]:
    if not path.exists():
        return "", offset
    data = path.read_bytes()
    if len(data) < offset:
        offset = 0
    chunk = data[offset:]
    return chunk.decode("utf-8", errors="replace"), len(data)


def run_tcp_echo(check: dict[str, Any], timeout_s: float = 10.0) -> tuple[bool, str]:
    host = check.get("host", "127.0.0.1")
    port = int(check["port"])
    payload = check.get("send", "").encode()
    expected = check.get("expect", "").encode()
    deadline = time.monotonic() + timeout_s
    last_error = ""

    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1.0) as sock:
                sock.settimeout(2.0)
                sock.sendall(payload)
                received = b""
                while len(received) < len(expected):
                    chunk = sock.recv(max(1, len(expected) - len(received)))
                    if not chunk:
                        break
                    received += chunk
                if received == expected:
                    return True, "ok"
                return False, f"TCP echo mismatch: expected {expected!r}, got {received!r}"
        except OSError as exc:
            last_error = str(exc)
            time.sleep(0.2)

    return False, f"TCP echo connection failed: {last_error}"


def _qmp_read_response(qmp_file: Any, timeout_s: float) -> tuple[bool, str]:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            line = qmp_file.readline()
        except socket.timeout:
            continue
        if not line:
            continue
        try:
            msg = json.loads(line.decode("utf-8"))
        except json.JSONDecodeError as exc:
            return False, f"invalid QMP JSON response: {exc}"
        if "event" in msg:
            continue
        if "error" in msg:
            return False, f"QMP error: {msg['error']}"
        if "return" in msg:
            return True, "ok"
    return False, "QMP response timeout"


def run_qmp_commands(
    qmp_path: Path,
    commands: list[dict[str, Any]],
    timeout_s: float = 5.0,
) -> tuple[bool, str]:
    deadline = time.monotonic() + timeout_s
    last_error = ""

    while time.monotonic() < deadline:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(0.5)
            sock.connect(str(qmp_path))
            qmp_file = sock.makefile("rwb", buffering=0)
            try:
                greeting = qmp_file.readline()
            except socket.timeout:
                greeting = b""
            if not greeting:
                return False, "QMP greeting missing"
            json.loads(greeting.decode("utf-8"))

            all_commands = [{"execute": "qmp_capabilities"}] + commands
            for command in all_commands:
                qmp_file.write(json.dumps(command, separators=(",", ":")).encode("utf-8") + b"\n")
                ok, reason = _qmp_read_response(qmp_file, min(1.0, timeout_s))
                if not ok:
                    return False, reason
            return True, "ok"
        except (OSError, json.JSONDecodeError) as exc:
            last_error = str(exc)
            time.sleep(0.05)
        finally:
            sock.close()

    return False, f"QMP connection failed: {last_error}"


def run_qemu_test(
    test: dict[str, Any],
    *,
    qemu: Path,
    work_dir: Path,
    builds: dict[str, Path],
    assets: dict[str, Path],
    forbidden: list[str],
) -> TestResult:
    start = time.monotonic()
    context = PlaceholderContext(
        qemu=qemu,
        work_dir=work_dir,
        test_name=test["name"],
        builds=builds,
        assets=assets,
    )
    cmd = [str(qemu)] + [context.format(arg) for arg in test["qemu_args"]]
    timeout_s = float(test.get("timeout", 30))
    required = list(test.get("required", []))
    host_checks = list(test.get("host_checks", []))
    pending_host_checks = list(host_checks)
    qmp_actions = list(test.get("qmp_actions", []))
    pending_qmp_actions = list(qmp_actions)
    combined_output = ""
    process_output = ""
    log_outputs = {path: "" for path in context.logs.values()}
    file_offsets = {path: 0 for path in context.logs.values()}
    log_path = work_dir / "logs" / f"{test['name']}.run.log"
    ensure_parent(log_path)

    proc = subprocess.Popen(
        cmd,
        cwd=REPO_ROOT,
        stdin=subprocess.PIPE if "input" in test else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=False,
        bufsize=0,
    )
    if "input" in test and proc.stdin is not None:
        proc.stdin.write(test["input"].encode())
        proc.stdin.close()

    selector = selectors.DefaultSelector()
    assert proc.stdout is not None
    assert proc.stderr is not None
    selector.register(proc.stdout, selectors.EVENT_READ)
    selector.register(proc.stderr, selectors.EVENT_READ)
    deadline = start + timeout_s
    reason = ""
    ok = False

    try:
        while True:
            now = time.monotonic()
            if now >= deadline:
                reason = f"timeout after {timeout_s:.1f}s"
                break

            for key, _ in selector.select(timeout=0.05):
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    try:
                        selector.unregister(key.fileobj)
                    except KeyError:
                        pass
                    continue
                text = chunk.decode("utf-8", errors="replace")
                process_output += text
                combined_output += text

            for log_file in list(context.logs.values()):
                text, offset = read_new_file_text(log_file, file_offsets.get(log_file, 0))
                if text:
                    log_outputs[log_file] = log_outputs.get(log_file, "") + text
                    combined_output += text
                file_offsets[log_file] = offset

            outputs = [combined_output, process_output] + list(log_outputs.values())
            forbidden_marker = check_forbidden_outputs(outputs, forbidden)
            if forbidden_marker is not None:
                reason = f"forbidden marker {forbidden_marker!r}"
                break

            still_pending_qmp: list[dict[str, Any]] = []
            for action in pending_qmp_actions:
                after_marker = action.get("after_marker")
                if after_marker and not marker_in_any_output(after_marker, outputs):
                    still_pending_qmp.append(action)
                    continue
                socket_id = action.get("socket", "main")
                qmp_path = context.qmp_sockets.get(socket_id)
                if qmp_path is None:
                    reason = f"unknown QMP socket {socket_id!r}"
                    still_pending_qmp = []
                    break
                commands = list(action.get("commands", []))
                delay_ms = int(action.get("delay_ms", 0))
                if delay_ms > 0:
                    time.sleep(delay_ms / 1000.0)
                qmp_ok, qmp_reason = run_qmp_commands(qmp_path, commands)
                if not qmp_ok:
                    reason = qmp_reason
                    still_pending_qmp = []
                    break
                combined_output += f"\n[QMP] {socket_id} PASS\n"
            pending_qmp_actions = still_pending_qmp
            if reason:
                break

            still_pending: list[dict[str, Any]] = []
            for check in pending_host_checks:
                after_marker = check.get("after_marker")
                if after_marker and not marker_in_any_output(after_marker, outputs):
                    still_pending.append(check)
                    continue
                check_ok, check_reason = run_tcp_echo(check)
                if not check_ok:
                    reason = check_reason
                    still_pending = []
                    break
                combined_output += f"\n[HOST_CHECK] tcp_echo {check['host']}:{check['port']} PASS\n"
            pending_host_checks = still_pending
            if reason:
                break

            outputs = [combined_output, process_output] + list(log_outputs.values())
            if (
                not missing_required_outputs(outputs, required)
                and not pending_host_checks
                and not pending_qmp_actions
            ):
                ok = True
                reason = "ok"
                break

            if proc.poll() is not None and selector.get_map() == {}:
                missing = missing_required_outputs(outputs, required)
                reason = f"qemu exited before success; missing {missing!r}"
                break
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        for stream in (proc.stdout, proc.stderr):
            if stream is not None:
                try:
                    remaining = stream.read()
                    if remaining:
                        text = remaining.decode("utf-8", errors="replace")
                        process_output += text
                        combined_output += text
                except Exception:
                    pass
        for log_file in list(context.logs.values()):
            text, offset = read_new_file_text(log_file, file_offsets.get(log_file, 0))
            if text:
                log_outputs[log_file] = log_outputs.get(log_file, "") + text
                combined_output += text
            file_offsets[log_file] = offset
        log_path.write_text(combined_output, encoding="utf-8")

    return TestResult(test["name"], ok, time.monotonic() - start, reason)


def run_command_test(
    test: dict[str, Any],
    *,
    qemu: Path,
    work_dir: Path,
    forbidden: list[str],
) -> TestResult:
    start = time.monotonic()
    context = PlaceholderContext(
        qemu=qemu,
        work_dir=work_dir,
        test_name=test["name"],
        builds={},
        assets={},
    )
    cmd = [context.format(arg) for arg in test["cmd"]]
    timeout_s = float(test.get("timeout", 30))
    log_path = work_dir / "logs" / f"{test['name']}.run.log"
    ensure_parent(log_path)

    try:
        proc = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout_s,
        )
        output = proc.stdout
    except subprocess.TimeoutExpired as exc:
        output = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
        log_path.write_text(output, encoding="utf-8")
        return TestResult(test["name"], False, time.monotonic() - start,
                          f"timeout after {timeout_s:.1f}s")

    log_path.write_text(output, encoding="utf-8")
    if proc.returncode != 0:
        last = output.strip().splitlines()[-1:] or ["no output"]
        return TestResult(test["name"], False, time.monotonic() - start,
                          f"exit {proc.returncode}: {last[0]}")
    forbidden_marker = check_forbidden(output, forbidden)
    if forbidden_marker is not None:
        return TestResult(test["name"], False, time.monotonic() - start,
                          f"forbidden marker {forbidden_marker!r}")
    missing = missing_required(output, list(test.get("required", [])))
    if missing:
        return TestResult(test["name"], False, time.monotonic() - start,
                          f"missing {missing!r}")
    return TestResult(test["name"], True, time.monotonic() - start, "ok")


def select_tests(manifest: dict[str, Any], tier: str, names: list[str]) -> list[dict[str, Any]]:
    tests = manifest["tests"]
    if names:
        wanted = set(names)
        selected = [test for test in tests if test["name"] in wanted]
        missing = wanted - {test["name"] for test in selected}
        if missing:
            raise SystemExit(f"unknown test(s): {', '.join(sorted(missing))}")
        return selected
    return [test for test in tests if tier in test.get("tiers", [])]


def main() -> int:
    args = parse_args()
    manifest = load_manifest(args.manifest)
    defaults = manifest.get("defaults", {})
    qemu = args.qemu or Path(defaults.get("qemu", "qemu-system-riscv64"))
    qemu = qemu.expanduser()
    work_dir = args.work_dir
    work_dir.mkdir(parents=True, exist_ok=True)
    (work_dir / "logs").mkdir(parents=True, exist_ok=True)

    tests = select_tests(manifest, args.tier, args.test)
    forbidden = list(defaults.get("forbidden", []))
    results: list[TestResult] = []

    print(f"kernel validation tier={args.tier} tests={len(tests)}", flush=True)
    print(f"qemu={qemu}", flush=True)
    print(f"work_dir={work_dir}", flush=True)

    for test in tests:
        name = test["name"]
        print(f"\n== {name} ==", flush=True)
        try:
            builds = build_firmware(test, work_dir)
            assets = create_assets(test, work_dir)
            if args.build_only:
                result = TestResult(name, True, 0.0, "built")
            elif test["kind"] == "qemu":
                result = run_qemu_test(
                    test,
                    qemu=qemu,
                    work_dir=work_dir,
                    builds=builds,
                    assets=assets,
                    forbidden=forbidden + list(test.get("forbidden", [])),
                )
            elif test["kind"] == "command":
                result = run_command_test(
                    test,
                    qemu=qemu,
                    work_dir=work_dir,
                    forbidden=forbidden + list(test.get("forbidden", [])),
                )
            else:
                raise ValueError(f"unknown test kind {test['kind']!r}")
        except Exception as exc:
            result = TestResult(name, False, 0.0, str(exc).splitlines()[-1] if str(exc) else repr(exc))

        results.append(result)
        status = "PASS" if result.ok else "FAIL"
        print(f"{status} {name} ({result.elapsed:.1f}s): {result.reason}", flush=True)
        if not result.ok and not args.keep_going:
            break

    print("\nSummary", flush=True)
    width = max([len(r.name) for r in results] + [4])
    for result in results:
        status = "PASS" if result.ok else "FAIL"
        print(f"  {status:<4} {result.name:<{width}} {result.elapsed:6.1f}s  {result.reason}", flush=True)

    failed = [result for result in results if not result.ok]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
