"""Compare compiled RX recycling code using a fixture-only observed MMIO page.

The selected routines contain no privileged instructions. QEMU S-mode paging
routes their fixed register addresses to test RAM; a checked store trap records
SW/C.SW writes without changing vendor or Nim instruction bytes.
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

from check_wifi_tx_confirmation_oracle import ARCHIVE_SHA256, CPU, sha


ROOT = Path(__file__).resolve().parents[1]
ROOT_FUNCTIONS = ["rxl_hd_append", "rxl_pd_append", "rxl_frame_release"]
VENDOR_OBJECTS = ["rxl_hwdesc.o", "rxl_cntrl.o"]
EXPECTED_CASES = 3660
EXPECTED_CHECKS = 11117
FIXTURE_FAULTS = {"none": 0, "header-halfword": 1, "payload-halfword": 2, "header-current": 3,
                  "payload-tail": 4, "trigger-order": 5, "publication": 6, "trap-context": 7}


def parse_result(output: str, exit_code: int) -> dict:
    matches = list(re.finditer(r"^RXDESC RV32 (PASS|FAIL) ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8})(?: |$)", output, re.M))
    if len(matches) != 1 or sum(line.startswith("RXDESC RV32") for line in output.splitlines()) != 1:
        return {"status": "incomplete", "passed": False, "cases": 0, "checks": 0}
    match = matches[0]
    cases, checks, result, difference, error, side = (int(match[i], 16) for i in range(2, 8))
    return {"status": match[1], "cases": cases, "checks": checks, "result": result,
            "difference_byte": difference, "fixture_error": error, "last_side": side,
            "passed": match[1] == "PASS" and exit_code == 0 and result == 0 and difference == 0 and
                      error == 0 and side == 1 and cases == EXPECTED_CASES and checks == EXPECTED_CHECKS}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wifi-object", type=Path, required=True)
    parser.add_argument("--archive", type=Path, default=ROOT / "tools/ref/libwifi_bl808.a")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--fixture-fault", choices=FIXTURE_FAULTS, default="none",
                        help="negative control: corrupt fixture observations, never firmware code")
    args = parser.parse_args()
    obj, archive, work = args.wifi_object.resolve(), args.archive.resolve(), args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "status": "incomplete", "commands": [],
              "fixture_fault": args.fixture_fault,
              "models": ["assert_err observer (zero calls required)", "memcpy/memset",
                         "non-throwing Nim error flag", "one RAM-backed register page with observed SW/C.SW stores",
                         "fixture-only S-mode paging and trap context, not BL808 privilege behavior"],
              "scope": "Header/payload append and combined frame release, descriptor bytes and ordered trigger writes; no DMA/radio/IRQ reentry"}

    def run(argv, output=None, check=True):
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=120)
        report["commands"].append({"command": shlex.join(argv), "exit_code": result.returncode,
                                   "stdout": result.stdout, "stderr": result.stderr})
        if output:
            (work / output).write_text(result.stdout)
            (work / (output + ".stderr")).write_text(result.stderr)
        if check and result.returncode:
            raise RuntimeError(f"command exited {result.returncode}: {shlex.join(argv)}\n{result.stderr}")
        return result.stdout

    def text_sections(path):
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
        if sha(archive) != ARCHIVE_SHA256: raise ValueError("WiFi archive does not match the pinned vendor SHA-256")
        info = json.loads(run(["rabin2", "-Ij", str(obj)]))["info"]
        if info["arch"] != "riscv" or info["bits"] != 32 or info["endian"] != "little":
            raise ValueError("a little-endian RV32 WiFi object is required")
        symbols = run(["riscv64-unknown-elf-nm", str(obj)])
        error = re.search(r"\bU (nimInErrorMode__\w+)", symbols)
        if error is None: raise ValueError("expected non-throwing Nim error flag import is missing")
        for name in ROOT_FUNCTIONS + ["assert_err"]:
            if re.search(r"\bT " + re.escape(name) + r"$", symbols, re.M) is None:
                raise ValueError(f"missing compiled WiFi function: {name}")
        metadata = json.loads(run(["rabin2", "-sj", str(obj)]))["symbols"]
        by_name = {s["name"]: s for s in metadata}
        sizes = {"rx_dma_hdrdesc": 4100, "rx_payload_desc": 2132, "rx_swdesc_tab": 984,
                 "rxl_cntrl_env": 28, "rx_hwdesc_env": 8}
        for name, expected in sizes.items():
            if by_name.get(name, {}).get("size") != expected:
                raise ValueError(f"unexpected RX ABI size for {name}: expected {expected}")
        paths = [obj, archive, Path(__file__).resolve(), ROOT / "tools/check_wifi_tx_confirmation_oracle.py",
                 ROOT / "tools/wifi_rx_descriptor_oracle.c", ROOT / "tools/wifi_rx_descriptor_oracle.S",
                 ROOT / "tools/wifi_console_format_probe.S", ROOT / "tools/wifi_console_format_probe.ld"]
        report["inputs"] = {str(path): sha(path) for path in paths}
        report["versions"] = {"qemu": run(["qemu-system-riscv32", "--version"]).splitlines()[0],
                              "radare2": run(["r2", "-v"]).splitlines()[0]}
        fixture = work / "nim-fixture.o"
        run(["riscv64-unknown-elf-objcopy", "--weaken-symbol=assert_err", str(obj), str(fixture)])
        before, after = text_sections(obj), text_sections(fixture)
        if before != after: raise ValueError("Nim instruction sections changed during binding preparation")
        report["nim_text_sections_unchanged"] = len(before)
        report["nim_root_sections"] = {".text." + name: before[".text." + name] for name in ROOT_FUNCTIONS}
        vendor_paths = []
        report["vendor_text_sections_unchanged"] = {}
        for name in VENDOR_OBJECTS:
            raw, prefixed = work / name, work / ("vendor-" + name)
            extracted = subprocess.run(["riscv64-unknown-elf-ar", "p", str(archive), name], cwd=ROOT, capture_output=True, check=True)
            raw.write_bytes(extracted.stdout)
            run(["riscv64-unknown-elf-objcopy", "--prefix-symbols=vendor_", str(raw), str(prefixed)])
            old, new = text_sections(raw), text_sections(prefixed)
            if old != new: raise ValueError(f"vendor instruction sections changed: {name}")
            report["vendor_text_sections_unchanged"][name] = len(old)
            vendor_paths.append(prefixed)
        for tag, target in [("nim", obj), *[(Path(name).stem, work / name) for name in VENDOR_OBJECTS]]:
            metadata = json.loads(run(["rabin2", "-sj", str(target)]))["symbols"]
            selected = [s for s in metadata if s["type"] == "FUNC" and (s["name"] in ROOT_FUNCTIONS or
                s["name"].startswith(("rxForgetStation__", "rxHeaderDescIndex__")))]
            run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0", "-e", "bin.relocs.apply=true", "-c",
                 "; ".join(f'pD {s["size"]} @ {s["vaddr"]}' for s in selected), str(target)], tag + "-r2.txt")
            decoded = run([llvm, "-dr", "--no-show-raw-insn", "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov",
                           *["--section=.text." + s["name"] for s in selected], str(target)], tag + "-llvm.txt")
            if "<unknown>" in decoded: raise ValueError(f"incomplete LLVM instruction decoding: {target}")
        flags = ["-march=rv32imafc_zicsr", "-mabi=ilp32f", "-Os", "-fno-builtin", "-ffunction-sections", "-fdata-sections", "-fstack-usage"]
        run(["riscv64-unknown-elf-gcc", *flags, '-DERROR_SYMBOL="' + error[1] + '"',
             f"-DFIXTURE_FAULT={FIXTURE_FAULTS[args.fixture_fault]}", "-c",
             str(ROOT / "tools/wifi_rx_descriptor_oracle.c"), "-o", str(work / "probe.o")])
        run(["riscv64-unknown-elf-gcc", *flags, "-c", str(ROOT / "tools/wifi_rx_descriptor_oracle.S"), "-o", str(work / "mapping.o")])
        run(["riscv64-unknown-elf-gcc", *flags, "-Dwifi_console_format_probe_main=wifi_rx_descriptor_probe_main",
             "-Dwifi_console_format_probe_report=wifi_rx_descriptor_probe_report", "-c", str(ROOT / "tools/wifi_console_format_probe.S"), "-o", str(work / "start.o")])
        elf = work / "probe.elf"
        run(["riscv64-unknown-elf-gcc", *flags[:2], "-nostdlib", "-nostartfiles", "-static", "-Wl,--gc-sections", "-T",
             str(ROOT / "tools/wifi_console_format_probe.ld"), str(work / "start.o"), str(work / "probe.o"),
             str(work / "mapping.o"), str(fixture), *map(str, vendor_paths), "-lgcc", "-o", str(elf)])
        report["elf_sha256"] = sha(elf)
        output = run(["qemu-system-riscv32", "-machine", "virt", "-cpu", CPU, "-m", "32M", "-smp", "1", "-bios", "none",
                      "-nographic", "-monitor", "none", "-nic", "none", "-kernel", str(elf)], "qemu.log", check=False)
        report["qemu_exit_code"] = report["commands"][-1]["exit_code"]
        report.update(parse_result(output, report["qemu_exit_code"]))
        print(output, end="")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(f"RX oracle incomplete: {error}", file=sys.stderr)
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
