"""Compare normal station-mode RX control with unmodified vendor instructions.

Upper RX, frame release and beacon/power callbacks are explicit models. AP
power-save, reentry and hardware are outside this differential probe.
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
EXPECTED_CASES = 6336
EXPECTED_CHECKS = 69696
MODELED = ["assert_rec", "ke_evt_set", "ke_evt_clear", "rxu_cntrl_frame_handle", "rxl_mpdu_free",
           "td_pck_ind", "mm_check_beacon", "ps_check_beacon", "vif_mgmt_bcn_recv",
           "chan_tbtt_switch_update", "ps_check_frame"]
FIXTURE_FAULTS = {"none": 0, "event": 1, "timestamp": 2, "callback": 3, "queue": 4}


def parse_result(output: str, exit_code: int) -> dict:
    matches = list(re.finditer(r"^RXCONTROL RV32 (PASS|FAIL)((?: [0-9a-f]{8}){13}) *$", output, re.M))
    if len(matches) != 1 or sum(line.startswith("RXCONTROL RV32") for line in output.splitlines()) != 1:
        return {"status": "incomplete", "passed": False}
    match = matches[0]
    cases, checks, result, difference, fixture, *inputs = (int(value, 16) for value in match[2].split())
    return {"status": match[1], "cases": cases, "checks": checks, "result": result,
            "difference_byte": difference, "fixture_error": fixture, "last_inputs": inputs,
            "passed": match[1] == "PASS" and exit_code == 0 and result == difference == fixture == 0
                      and cases == EXPECTED_CASES and checks == EXPECTED_CHECKS
                      and inputs == [11, 2, 2, 9, 2, 2, 2, 16]}


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
              "models": MODELED + ["non-AP power-save hook", "printf/puts/hw_validation_log_byte",
                                    "memcpy/memset", "non-throwing Nim error flag", "platform timestamp"],
              "scope": "Station-mode normal RX dispatch, drain budget, callback order and ownership decisions; no packet parsing, AP, reentry or hardware"}

    def run(argv: list[str], output: str | None = None, check: bool = True) -> str:
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=180)
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
                     "riscv64-unknown-elf-gcc", "rabin2", "r2", "qemu-system-riscv32"]:
            if shutil.which(tool) is None: raise ValueError(f"missing tool: {tool}")
        llvm = shutil.which("llvm-objdump") or "/opt/homebrew/opt/llvm/bin/llvm-objdump"
        if not Path(llvm).is_file(): raise ValueError("llvm-objdump is required")
        if sha(archive) != ARCHIVE_SHA256: raise ValueError("archive does not match the pinned vendor SHA-256")
        info = json.loads(run(["rabin2", "-Ij", str(obj)]))["info"]
        if info["arch"] != "riscv" or info["bits"] != 32 or info["endian"] != "little":
            raise ValueError("a little-endian RV32 WiFi object is required")
        symbols = run(["riscv64-unknown-elf-nm", "-S", str(obj)])

        def symbol(prefix: str, kind: str = "T") -> str:
            matches = re.findall(r"\b[" + kind + r"] (" + prefix + r"__\w+)$", symbols, re.M)
            if len(matches) != 1: raise ValueError(f"expected one compiled symbol for {prefix}")
            return matches[0]

        bindings = {"ERROR_SYMBOL": symbol("nimInErrorMode", "U"),
                    "ACTIVE_SYMBOL": symbol("rxlControlActive", "BCD"),
                    "CAPTURE_SYMBOL": symbol("rxCaptureStation"), "AP_SYMBOL": symbol("rxlHandleApPowerSave")}
        modeled = MODELED + [bindings["AP_SYMBOL"]]
        for name in ["rxl_cntrl_evt", "rx_swdesc_init", *MODELED]:
            if re.search(r"\bT " + re.escape(name) + "$", symbols, re.M) is None:
                raise ValueError(f"missing compiled function: {name}")
        for name, size in [("rx_dma_hdrdesc", 4100), ("rx_payload_desc", 2132), ("rx_swdesc_tab", 984),
                           ("rx_payload_desc_buffer", 71176), ("sta_info_tab", 2576), ("vif_info_tab", 3024)]:
            match = re.search(r"^[0-9a-f]+ ([0-9a-f]+) [BCD] " + name + "$", symbols, re.M)
            if match is None or int(match[1], 16) != size: raise ValueError(f"ABI mismatch: {name}")
        paths = [obj, archive, Path(__file__).resolve(), ROOT / "tools/wifi_rx_control_oracle.c",
                 ROOT / "tools/check_wifi_tx_confirmation_oracle.py",
                 ROOT / "tools/wifi_console_format_probe.S", ROOT / "tools/wifi_console_format_probe.ld"]
        report["inputs"] = {str(path): sha(path) for path in paths}
        report["bindings"] = bindings
        report["versions"] = {"qemu": run(["qemu-system-riscv32", "--version"]).splitlines()[0],
                              "radare2": run(["r2", "-v"]).splitlines()[0]}
        fixture = work / "nim-fixture.o"
        run(["riscv64-unknown-elf-objcopy", *["--weaken-symbol=" + name for name in modeled], str(obj), str(fixture)])
        original = text_sections(obj)
        if original != text_sections(fixture): raise ValueError("Nim instruction sections changed during binding preparation")
        report["nim_text_sections_unchanged"] = len(original)
        vendors = []
        report["vendor_text_sections_unchanged"] = {}
        aliases = ["sta_info_tab", "vif_info_tab", "g_bl_ops_funcs", "rxl_cntrl_env", "mac_tid2ac", "mac_ac2uapsd"]
        for member in ["rxl_cntrl.o", "co_list.o"]:
            raw, prefixed, bound = work / member, work / ("prefixed-" + member), work / ("vendor-" + member)
            extracted = subprocess.run(["riscv64-unknown-elf-ar", "p", str(archive), member],
                                       cwd=ROOT, capture_output=True, check=True)
            raw.write_bytes(extracted.stdout)
            run(["riscv64-unknown-elf-objcopy", "--prefix-symbols=vendor_", str(raw), str(prefixed)])
            run(["riscv64-unknown-elf-objcopy", "--weaken-symbol=vendor_rxl_mpdu_free",
                 *["--redefine-sym=vendor_" + name + "=" + name for name in aliases],
                 str(prefixed), str(bound)])
            before = text_sections(raw)
            if before != text_sections(prefixed) or before != text_sections(bound):
                raise ValueError(f"vendor instruction sections changed: {member}")
            report["vendor_text_sections_unchanged"][member] = len(before)
            vendors.append(bound)
        for tag, target in [("nim", obj), ("vendor", work / "rxl_cntrl.o")]:
            metadata = json.loads(run(["rabin2", "-sj", str(target)]))["symbols"]
            root = [s for s in metadata if s["type"] == "FUNC" and s["name"] == "rxl_cntrl_evt"]
            if len(root) != 1: raise ValueError("missing RX control disassembly range")
            s = root[0]
            run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0", "-e", "bin.relocs.apply=true", "-c",
                 f'pD {s["size"]} @ {s["vaddr"]}', str(target)], tag + "-r2.txt")
            run([llvm, "-dr", "--no-show-raw-insn",
                 "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov",
                 "--section=.text.rxl_cntrl_evt", str(target)], tag + "-llvm.txt")
        flags = ["-march=rv32imafc_zicsr", "-mabi=ilp32f", "-Os", "-fno-builtin", "-ffunction-sections", "-fdata-sections", "-fstack-usage"]
        run(["riscv64-unknown-elf-gcc", *flags, "-Wall", "-Wextra", "-Werror",
             *[f'-D{key}="{value}"' for key, value in bindings.items()],
             f"-DFIXTURE_FAULT={FIXTURE_FAULTS[args.fixture_fault]}", "-c", str(ROOT / "tools/wifi_rx_control_oracle.c"),
             "-o", str(work / "probe.o")])
        run(["riscv64-unknown-elf-gcc", *flags, "-Dwifi_console_format_probe_main=wifi_rx_control_probe_main",
             "-Dwifi_console_format_probe_report=wifi_rx_control_probe_report", "-c",
             str(ROOT / "tools/wifi_console_format_probe.S"), "-o", str(work / "start.o")])
        elf = work / "probe.elf"
        run(["riscv64-unknown-elf-gcc", *flags[:2], "-nostdlib", "-nostartfiles", "-static", "-Wl,--gc-sections",
             "-T", str(ROOT / "tools/wifi_console_format_probe.ld"), str(work / "start.o"), str(work / "probe.o"),
             str(fixture), *map(str, vendors), "-lgcc", "-o", str(elf)])
        decoded = run([llvm, "-d", "--no-show-raw-insn",
                       "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov", str(elf)], "linked-llvm.txt")
        retained = [s for s in json.loads(run(["rabin2", "-sj", str(elf)]))["symbols"]
                    if s["type"] == "FUNC" and s["size"] > 0]
        if not {"rxl_cntrl_evt", "vendor_rxl_cntrl_evt"} <= {s["name"] for s in retained}:
            raise ValueError("missing retained RX control function ranges")
        unknowns = [int(value, 16) for value in re.findall(r"^\s*([0-9a-f]+):\s*<unknown>", decoded, re.M)]
        if any(s["vaddr"] <= pc < s["vaddr"] + s["size"] for pc in unknowns for s in retained):
            raise ValueError("incomplete retained function instruction decoding")
        report["retained_functions"] = [{key: s[key] for key in ["name", "vaddr", "size"]} for s in retained]
        # The shared probe linker script also places read-only data in .text.
        report["nonfunction_decode_gaps"] = [hex(pc) for pc in unknowns]
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
