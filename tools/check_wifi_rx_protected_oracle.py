"""Compare complete TKIP/CCMP header decoding using an E907 P-capable QEMU.

The two original WEXTI encodings are capability-checked before decoder cases.
No illegal instruction is emulated or patched by this fixture.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

from check_wifi_tx_confirmation_oracle import ARCHIVE_SHA256, sha


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_MATRIX = 172032
EXPECTED_WIRE = 16384
EXPECTED_CHECKS = 2072705
EXPECTED_INSTRUCTIONS = 128
FIXTURE_FAULTS = {"none": 0, "instruction": 1, "pn": 2, "key": 3,
                  "flags": 4, "context": 5, "packet": 6}


def parse_result(output: str, exit_code: int) -> dict:
    matches = list(re.finditer(r"^RXPROTECTED RV32 (PASS|FAIL)((?: [0-9a-f]{8}){14}) *$", output, re.M))
    traps = re.findall(r"^RXPROTECTED TRAP ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8}) *$", output, re.M)
    if (len(matches) != 1 or traps or
            sum(line.startswith("RXPROTECTED") for line in output.splitlines()) != 1):
        result = {"status": "incomplete", "passed": False}
        if len(traps) == 1:
            result["trap"] = dict(zip(["cause", "pc", "value"], (int(v, 16) for v in traps[0])))
        return result
    match = matches[0]
    matrix, wire, checks, instructions, result, difference, *inputs = (int(v, 16) for v in match[2].split())
    return {"status": match[1], "matrix_cases": matrix, "wire_cases": wire,
            "checks": checks, "instruction_checks": instructions, "result": result,
            "difference": difference, "last_inputs": inputs,
            "passed": match[1] == "PASS" and exit_code == 0 and result == difference == 0
                      and matrix == EXPECTED_MATRIX and wire == EXPECTED_WIRE
                      and checks == EXPECTED_CHECKS and instructions == EXPECTED_INSTRUCTIONS
                      and inputs == [28, 1, 26, 3, 3, 1, 255, 8]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wifi-object", type=Path, required=True)
    parser.add_argument("--archive", type=Path, default=ROOT / "tools/ref/libwifi_bl808.a")
    parser.add_argument("--qemu", type=Path, required=True, help="XuanTie QEMU with E907/P support")
    parser.add_argument("--cpu", default="e907fdp")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--fixture-fault", choices=FIXTURE_FAULTS, default="none")
    args = parser.parse_args()
    obj, archive, work, qemu = args.wifi_object.resolve(), args.archive.resolve(), args.work.resolve(), args.qemu.resolve()
    work.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "status": "incomplete", "commands": [], "fixture_fault": args.fixture_fault,
              "cpu": args.cpu, "models": ["diagnostic output", "memcpy/memset", "non-throwing Nim error flag"],
              "scope": "TKIP/CCMP PN/key/context decode only; no key lifecycle, replay admission, packet delivery, radio or hardware"}

    def run(argv: list[str], output: str | None = None, check: bool = True) -> str:
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=240)
        report["commands"].append({"command": shlex.join(argv), "exit_code": result.returncode,
                                   "stdout": result.stdout, "stderr": result.stderr})
        if output:
            (work / output).write_text(result.stdout)
            (work / (output + ".stderr")).write_text(result.stderr)
        if check and result.returncode:
            raise RuntimeError(f"command exited {result.returncode}: {shlex.join(argv)}\n{result.stderr}")
        return result.stdout

    def text_sections(path: Path) -> dict[str, str]:
        sections = json.loads(run(["rabin2", "-Sj", str(path)]))["sections"]
        data = path.read_bytes()
        return {s["name"]: hashlib.sha256(data[s["paddr"]:s["paddr"] + s["size"]]).hexdigest()
                for s in sections if s["name"].startswith(".text.")}

    try:
        for tool in ["riscv64-unknown-elf-nm", "riscv64-unknown-elf-ar", "riscv64-unknown-elf-objcopy",
                     "riscv64-unknown-elf-gcc", "rabin2", "r2"]:
            if shutil.which(tool) is None: raise ValueError(f"missing tool: {tool}")
        llvm = shutil.which("llvm-objdump") or "/opt/homebrew/opt/llvm/bin/llvm-objdump"
        if not Path(llvm).is_file() or not qemu.is_file(): raise ValueError("LLVM and a QEMU binary are required")
        if sha(archive) != ARCHIVE_SHA256: raise ValueError("archive does not match the pinned vendor SHA-256")
        info = json.loads(run(["rabin2", "-Ij", str(obj)]))["info"]
        if info["arch"] != "riscv" or info["bits"] != 32 or info["endian"] != "little":
            raise ValueError("a little-endian RV32 WiFi object is required")
        symbols = run(["riscv64-unknown-elf-nm", "-S", str(obj)])
        error = re.search(r"\bU (nimInErrorMode__\w+)", symbols)
        if error is None: raise ValueError("missing expected Nim error flag import")
        for name, size in [("rxu_cntrl_env", 96), ("sta_info_tab", 2576), ("vif_info_tab", 3024)]:
            match = re.search(r"^[0-9a-f]+ ([0-9a-f]+) [BCD] " + name + "$", symbols, re.M)
            if match is None or int(match[1], 16) != size: raise ValueError(f"ABI mismatch: {name}")
        if re.search(r"\bT rxu_cntrl_protected_handle$", symbols, re.M) is None:
            raise ValueError("missing compiled protected decoder")
        paths = [obj, archive, qemu, Path(__file__).resolve(), ROOT / "tools/wifi_rx_protected_oracle.c",
                 ROOT / "tools/wifi_rx_protected_oracle.S", ROOT / "tools/check_wifi_tx_confirmation_oracle.py",
                 ROOT / "tools/wifi_console_format_probe.ld"]
        report["inputs"] = {str(path): sha(path) for path in paths}
        report["versions"] = {"qemu": run([str(qemu), "--version"]).splitlines()[0],
                              "radare2": run(["r2", "-v"]).splitlines()[0]}
        raw, globalized, vendor = work / "rxu_cntrl.o", work / "global-rxu_cntrl.o", work / "vendor-rxu_cntrl.o"
        content = subprocess.run(["riscv64-unknown-elf-ar", "p", str(archive), "rxu_cntrl.o"],
                                 capture_output=True, check=True).stdout
        raw.write_bytes(content)
        run(["riscv64-unknown-elf-objcopy", "--globalize-symbol=rxu_cntrl_protected_handle", str(raw), str(globalized)])
        prefixed = work / "prefixed-rxu_cntrl.o"
        run(["riscv64-unknown-elf-objcopy", "--prefix-symbols=vendor_", str(globalized), str(prefixed)])
        run(["riscv64-unknown-elf-objcopy", "--redefine-sym=vendor_sta_info_tab=sta_info_tab",
             "--redefine-sym=vendor_vif_info_tab=vif_info_tab", str(prefixed), str(vendor)])
        original = text_sections(raw)
        if any(text_sections(path) != original for path in [globalized, prefixed, vendor]):
            raise ValueError("vendor instruction sections changed during symbol preparation")
        report["vendor_text_sections_unchanged"] = len(original)
        report["nim_text_sections"] = text_sections(obj)
        section = work / "vendor-protected.bin"
        run(["riscv64-unknown-elf-objcopy", "--dump-section=.text.rxu_cntrl_protected_handle=" + str(section),
             str(raw), str(work / "dump-source.o")])
        data = section.read_bytes()
        if len(data) != 318 or data[0x6c:0x70] != bytes.fromhex("770608df") or data[0xe2:0xe6] != bytes.fromhex("f7080edf"):
            raise ValueError("unexpected vendor WEXTI instruction locations")
        for tag, target in [("nim", obj), ("vendor", raw)]:
            metadata = json.loads(run(["rabin2", "-sj", str(target)]))["symbols"]
            selected = [s for s in metadata if s["type"] == "FUNC" and s["name"] == "rxu_cntrl_protected_handle"]
            if len(selected) != 1: raise ValueError("missing protected decoder disassembly range")
            s = selected[0]
            run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0", "-e", "bin.relocs.apply=true", "-c",
                 f'pD {s["size"]} @ {s["vaddr"]}', str(target)], tag + "-r2.txt")
            decoded = run([llvm, "-dr", "--no-show-raw-insn",
                "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov",
                "--section=.text.rxu_cntrl_protected_handle", str(target)], tag + "-llvm.txt")
            unknowns = re.findall(r"^\s*([0-9a-f]+):\s*<unknown>", decoded, re.M)
            if unknowns != (["6c", "e2"] if tag == "vendor" else []):
                raise ValueError("unexpected instruction decoding gaps")
        flags = ["-march=rv32imafc_zicsr", "-mabi=ilp32f", "-Os", "-fno-builtin", "-ffunction-sections", "-fdata-sections", "-fstack-usage"]
        run(["riscv64-unknown-elf-gcc", *flags, "-Wall", "-Wextra", "-Werror", '-DERROR_SYMBOL="' + error[1] + '"',
             f"-DFIXTURE_FAULT={FIXTURE_FAULTS[args.fixture_fault]}", "-c", str(ROOT / "tools/wifi_rx_protected_oracle.c"), "-o", str(work / "probe.o")])
        run(["riscv64-unknown-elf-gcc", *flags, "-c", str(ROOT / "tools/wifi_rx_protected_oracle.S"), "-o", str(work / "start.o")])
        elf = work / "probe.elf"
        run(["riscv64-unknown-elf-gcc", *flags[:2], "-nostdlib", "-nostartfiles", "-static", "-Wl,--gc-sections",
             "-T", str(ROOT / "tools/wifi_console_format_probe.ld"), str(work / "start.o"), str(work / "probe.o"),
             str(obj), str(vendor), "-lgcc", "-o", str(elf)])
        report["elf_sha256"] = sha(elf)
        report["retained_symbols"] = json.loads(run(["rabin2", "-sj", str(elf)]))["symbols"]
        output = run([str(qemu), "-machine", "virt", "-cpu", args.cpu, "-m", "32M", "-smp", "1", "-bios", "none",
                      "-nographic", "-monitor", "none", "-nic", "none", "-kernel", str(elf)], "qemu.log", check=False)
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
