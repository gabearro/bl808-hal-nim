"""Compare RX header contracts without executing unsupported packed instructions.

All 16-bit FC values are classified, not assumed to represent valid frames.
Only WEP and unrecognized-status paths of the vendor protected decoder run.
"""

import argparse
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

from check_wifi_tx_confirmation_oracle import ARCHIVE_SHA256, CPU, sha


ROOT = Path(__file__).resolve().parents[1]
FUNCTIONS = ["rxu_cntrl_machdr_len_get", "rxu_cntrl_protected_handle"]
EXPECTED_HEADERS = 65536
EXPECTED_PROTECTED = 9216
EXPECTED_CHECKS = 345095
CATEGORIES = [17408, 4096, 16384, 16384, 4096, 7168]
FIXTURE_FAULTS = {"none": 0, "length": 1, "classification": 2, "context": 3, "packet": 4}


def parse_result(output: str, exit_code: int) -> dict:
    matches = list(re.finditer(r"^RXHEADER RV32 (PASS|FAIL)((?: [0-9a-f]{8}){12}) *$", output, re.M))
    if len(matches) != 1 or sum(line.startswith("RXHEADER RV32") for line in output.splitlines()) != 1:
        return {"status": "incomplete", "passed": False}
    match = matches[0]
    headers, protected, checks, result, difference, fixture, *categories = (
        int(value, 16) for value in match[2].split())
    return {"status": match[1], "header_cases": headers, "protected_cases": protected,
            "checks": checks, "result": result, "difference": difference,
            "fixture_error": fixture, "categories": categories,
            "passed": match[1] == "PASS" and exit_code == 0 and result == difference == fixture == 0
                      and headers == EXPECTED_HEADERS and protected == EXPECTED_PROTECTED
                      and checks == EXPECTED_CHECKS and categories == CATEGORIES}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wifi-object", type=Path, required=True)
    parser.add_argument("--archive", type=Path, default=ROOT / "tools/ref/libwifi_bl808.a")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--fixture-fault", choices=FIXTURE_FAULTS, default="none")
    args = parser.parse_args()
    obj, archive, work = args.wifi_object.resolve(), args.archive.resolve(), args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "status": "incomplete", "commands": [], "fixture_fault": args.fixture_fault,
              "models": ["printf/puts/hw_validation_log_byte", "non-throwing Nim error flag", "memcpy/memset"],
              "scope": "FC helper contracts; protected decoder WEP/unrecognized statuses only; no TKIP/CCMP execution, MAC/DMA or hardware"}

    def run(argv: list[str], output: str | None = None, check: bool = True) -> str:
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=120)
        report["commands"].append({"command": shlex.join(argv), "exit_code": result.returncode,
                                   "stdout": result.stdout, "stderr": result.stderr})
        if output:
            (work / output).write_text(result.stdout)
            (work / (output + ".stderr")).write_text(result.stderr)
        if check and result.returncode:
            raise RuntimeError(f"command exited {result.returncode}: {shlex.join(argv)}\n{result.stderr}")
        return result.stdout

    def text_sections(path: Path) -> dict[str, str]:
        import hashlib
        sections = json.loads(run(["rabin2", "-Sj", str(path)]))["sections"]
        data = path.read_bytes()
        return {s["name"]: hashlib.sha256(data[s["paddr"]:s["paddr"] + s["size"]]).hexdigest()
                for s in sections if s["name"].startswith(".text.")}

    try:
        for tool in ["riscv64-unknown-elf-nm", "riscv64-unknown-elf-ar", "riscv64-unknown-elf-objcopy",
                     "riscv64-unknown-elf-gcc", "rabin2", "r2", "qemu-system-riscv32"]:
            if shutil.which(tool) is None: raise ValueError(f"missing tool: {tool}")
        llvm = shutil.which("llvm-objdump") or "/opt/homebrew/opt/llvm/bin/llvm-objdump"
        if not Path(llvm).is_file(): raise ValueError("llvm-objdump is required")
        if sha(archive) != ARCHIVE_SHA256: raise ValueError("archive does not match the pinned vendor SHA-256")
        info = json.loads(run(["rabin2", "-Ij", str(obj)]))["info"]
        if info["arch"] != "riscv" or info["bits"] != 32 or info["endian"] != "little":
            raise ValueError("a little-endian RV32 WiFi object is required")
        symbols = run(["riscv64-unknown-elf-nm", "-S", str(obj)])
        error = re.search(r"\bU (nimInErrorMode__\w+)", symbols)
        if error is None: raise ValueError("missing expected Nim error flag import")
        for name in FUNCTIONS:
            if re.search(r"\bT " + name + "$", symbols, re.M) is None:
                raise ValueError(f"missing compiled WiFi function: {name}")
        match = re.search(r"^[0-9a-f]+ ([0-9a-f]+) [BC] rxu_cntrl_env$", symbols, re.M)
        if match is None or int(match[1], 16) != 96: raise ValueError("RX context ABI mismatch")
        paths = [obj, archive, Path(__file__).resolve(), ROOT / "tools/wifi_rx_header_oracle.c",
                 ROOT / "tools/check_wifi_tx_confirmation_oracle.py",
                 ROOT / "tools/wifi_console_format_probe.S", ROOT / "tools/wifi_console_format_probe.ld"]
        report["inputs"] = {str(path): sha(path) for path in paths}
        report["versions"] = {"qemu": run(["qemu-system-riscv32", "--version"]).splitlines()[0],
                              "radare2": run(["r2", "-v"]).splitlines()[0]}
        raw, globalized, vendor = work / "rxu_cntrl.o", work / "global-rxu_cntrl.o", work / "vendor-rxu_cntrl.o"
        extracted = subprocess.run(["riscv64-unknown-elf-ar", "p", str(archive), "rxu_cntrl.o"],
                                   cwd=ROOT, capture_output=True, check=True)
        raw.write_bytes(extracted.stdout)
        run(["riscv64-unknown-elf-objcopy", *["--globalize-symbol=" + name for name in FUNCTIONS],
             str(raw), str(globalized)])
        run(["riscv64-unknown-elf-objcopy", "--prefix-symbols=vendor_", str(globalized), str(vendor)])
        before, after = text_sections(raw), text_sections(vendor)
        if before != after or before != text_sections(globalized):
            raise ValueError("vendor instruction sections changed during symbol preparation")
        report["vendor_text_sections_unchanged"] = len(before)
        report["nim_text_sections"] = text_sections(obj)
        for tag, target in [("nim", obj), ("vendor", raw)]:
            metadata = json.loads(run(["rabin2", "-sj", str(target)]))["symbols"]
            selected = [s for s in metadata if s["type"] == "FUNC" and
                        (s["name"] in FUNCTIONS or s["name"].startswith("rxMacHeaderLen__"))]
            if len(selected) < 2: raise ValueError(f"missing disassembly ranges: {tag}")
            run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0", "-e", "bin.relocs.apply=true", "-c",
                 "; ".join(f'pD {s["size"]} @ {s["vaddr"]}' for s in selected), str(target)], tag + "-r2.txt")
            decoded = run([llvm, "-dr", "--no-show-raw-insn",
                "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov",
                *["--section=.text." + s["name"] for s in selected], str(target)], tag + "-llvm.txt")
            unknowns = re.findall(r"^\s*([0-9a-f]+):\s*<unknown>", decoded, re.M)
            if tag == "nim" and unknowns: raise ValueError("incomplete Nim instruction decoding")
            if tag == "vendor":
                if unknowns != ["6c", "e2"]: raise ValueError("unexpected vendor decoding gaps")
                report["unexecuted_vendor_decode_gaps"] = ["protected_handle+0x6c", "protected_handle+0xe2"]
        flags = ["-march=rv32imafc_zicsr", "-mabi=ilp32f", "-Os", "-fno-builtin",
                 "-ffunction-sections", "-fdata-sections", "-fstack-usage"]
        run(["riscv64-unknown-elf-gcc", *flags, '-DERROR_SYMBOL="' + error[1] + '"',
             f"-DFIXTURE_FAULT={FIXTURE_FAULTS[args.fixture_fault]}", "-c",
             str(ROOT / "tools/wifi_rx_header_oracle.c"), "-o", str(work / "probe.o")])
        run(["riscv64-unknown-elf-gcc", *flags,
             "-Dwifi_console_format_probe_main=wifi_rx_header_probe_main",
             "-Dwifi_console_format_probe_report=wifi_rx_header_probe_report", "-c",
             str(ROOT / "tools/wifi_console_format_probe.S"), "-o", str(work / "start.o")])
        elf = work / "probe.elf"
        run(["riscv64-unknown-elf-gcc", *flags[:2], "-nostdlib", "-nostartfiles", "-static", "-Wl,--gc-sections",
             "-T", str(ROOT / "tools/wifi_console_format_probe.ld"), str(work / "start.o"),
             str(work / "probe.o"), str(obj), str(vendor), "-lgcc", "-o", str(elf)])
        report["elf_sha256"] = sha(elf)
        output = run(["qemu-system-riscv32", "-machine", "virt", "-cpu", CPU, "-m", "32M", "-smp", "1",
                      "-bios", "none", "-nographic", "-monitor", "none", "-nic", "none", "-kernel", str(elf)],
                     "qemu.log", check=False)
        report["qemu_exit_code"] = report["commands"][-1]["exit_code"]
        report.update(parse_result(output, report["qemu_exit_code"]))
        print(output, end="")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(f"Oracle incomplete: {error}", file=sys.stderr)
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
