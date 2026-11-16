"""Compare compiled Nim TX confirmations/getters with the pinned vendor code.

Runs in QEMU with T-Head extensions. Cross-layer callbacks and diagnostics are
explicit fixtures; this is not a whole firmware boot or hardware validation.
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


ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_SHA256 = "6458808ea976de70c0d9f218645efe61ba6e56c9d33fca697abb36a41efe91e7"
ROOT_FUNCTIONS = ["txl_cfm_push", "txl_cfm_evt", "txl_cfm_flush", "txl_cfm_flush_desc",
                  "txl_current_desc_get", "txl_cntrl_inc_pck_cnt", "rxl_current_desc_get"]
MODELED = ["assert_err", "hal_machw_disable_int", "ke_evt_set", "ke_evt_clear",
           "me_tx_cfm_singleton", "txu_cntrl_cfm", "ipc_emb_txcfm", "ipc_emb_txcfm_ind",
           "txl_frame_cfm", "txl_frame_evt"]
VENDOR_OBJECTS = ["txl_cfm.o", "txl_cntrl.o", "rxl_cntrl.o", "co_list.o"]
CPU = "rv32,xtheadcondmov=on,xtheadbb=on,xtheadmemidx=on,xtheadba=on,xtheadmac=on,xtheadmempair=on"
EXPECTED_CASES = 17280
EXPECTED_CHECKS = 51890
FIXTURE_FAULTS = {"none": 0, "status": 1, "accounting": 2, "event": 3, "queue": 4, "callback": 5}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_result(output: str, exit_code: int) -> dict:
    matches = list(re.finditer(r"^CONFIRM RV32 (PASS|FAIL) ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8})(?: |$)", output, re.M))
    if len(matches) != 1 or sum(line.startswith("CONFIRM RV32") for line in output.splitlines()) != 1:
        return {"status": "incomplete", "passed": False, "cases": 0, "checks": 0}
    match = matches[0]
    status = match[1]
    cases, checks, result, difference_word, fixture_error, last_side = (int(match[i], 16) for i in range(2, 8))
    return {"status": status, "cases": cases, "checks": checks, "result": result,
            "difference_word": difference_word, "fixture_error": fixture_error, "last_side": last_side,
            "passed": status == "PASS" and exit_code == 0 and result == 0 and difference_word == 0 and
                      fixture_error == 0 and last_side == 1 and cases == EXPECTED_CASES and checks == EXPECTED_CHECKS}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wifi-object", type=Path, required=True)
    parser.add_argument("--archive", type=Path, default=ROOT / "tools/ref/libwifi_bl808.a")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--fixture-fault", choices=FIXTURE_FAULTS, default="none",
                        help="negative control: corrupt one fixture observation, not firmware code")
    args = parser.parse_args()
    obj, archive, work = args.wifi_object.resolve(), args.archive.resolve(), args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "status": "incomplete", "commands": [],
              "fixture_fault": args.fixture_fault,
              "models": MODELED + ["printf/puts/hw_validation_log_byte", "memcpy/memset",
                                    "non-throwing Nim error flag"],
              "scope": "Normal non-reentrant TX confirmation callbacks, FIFO state/status/accounting, TX/RX getters; no MAC/DMA or hardware timing"}

    def run(argv: list[str], output: str | None = None, timeout: int = 120, check: bool = True) -> str:
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        row = {"command": shlex.join(argv), "exit_code": result.returncode,
               "stdout": result.stdout, "stderr": result.stderr}
        report["commands"].append(row)
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
        if sha(archive) != ARCHIVE_SHA256: raise ValueError("WiFi archive does not match the pinned vendor SHA-256")
        info = json.loads(run(["rabin2", "-Ij", str(obj)]))["info"]
        if info["arch"] != "riscv" or info["bits"] != 32 or info["endian"] != "little":
            raise ValueError("a little-endian RV32 WiFi object is required")
        symbols = run(["riscv64-unknown-elf-nm", str(obj)])
        error = re.search(r"\bU (nimInErrorMode__\w+)", symbols)
        if error is None: raise ValueError("missing expected non-throwing Nim error flag import")
        for name in ROOT_FUNCTIONS + MODELED:
            if re.search(r"\bT " + re.escape(name) + r"$", symbols, re.M) is None:
                raise ValueError(f"missing compiled WiFi function: {name}")
        paths = [obj, archive, Path(__file__).resolve(), ROOT / "tools/wifi_tx_confirmation_oracle.c",
                 ROOT / "tools/wifi_console_format_probe.S", ROOT / "tools/wifi_console_format_probe.ld"]
        report["inputs"] = {str(path): sha(path) for path in paths}
        report["versions"] = {"qemu": run(["qemu-system-riscv32", "--version"]).splitlines()[0],
                              "radare2": run(["r2", "-v"]).splitlines()[0]}
        fixture_obj = work / "nim-fixture.o"
        run(["riscv64-unknown-elf-objcopy", *["--weaken-symbol=" + s for s in MODELED], str(obj), str(fixture_obj)])
        original_sections, fixture_sections = text_sections(obj), text_sections(fixture_obj)
        if original_sections != fixture_sections: raise ValueError("Nim instruction sections changed during binding preparation")
        report["nim_text_sections_unchanged"] = len(original_sections)
        report["nim_root_sections"] = {".text." + n: original_sections[".text." + n] for n in ROOT_FUNCTIONS}
        vendor_paths = []
        report["vendor_text_sections_unchanged"] = {}
        for name in VENDOR_OBJECTS:
            raw = work / name
            result = subprocess.run(["riscv64-unknown-elf-ar", "p", str(archive), name], cwd=ROOT, capture_output=True, check=True)
            raw.write_bytes(result.stdout)
            prefixed = work / ("vendor-" + name)
            run(["riscv64-unknown-elf-objcopy", "--prefix-symbols=vendor_", str(raw), str(prefixed)])
            before, after = text_sections(raw), text_sections(prefixed)
            if before != after: raise ValueError(f"vendor instruction sections changed: {name}")
            report["vendor_text_sections_unchanged"][name] = len(before)
            vendor_paths.append(prefixed)

        for tag, target in [("nim", obj), *[(p.stem, work / p.name) for p in [Path(n) for n in VENDOR_OBJECTS]]]:
            metadata = json.loads(run(["rabin2", "-sj", str(target)]))["symbols"]
            selected = [s for s in metadata if s["name"] in ROOT_FUNCTIONS and s["type"] == "FUNC"]
            if not selected: continue
            run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0", "-e", "bin.relocs.apply=true", "-c",
                 "; ".join(f'pD {s["size"]} @ {s["vaddr"]}' for s in selected), str(target)], tag + "-r2.txt")
            decoded = run([llvm, "-dr", "--no-show-raw-insn", "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov",
                           *["--section=.text." + s["name"] for s in selected], str(target)], tag + "-llvm.txt")
            if "<unknown>" in decoded: raise ValueError(f"incomplete LLVM instruction decoding: {target}")

        flags = ["-march=rv32imafc_zicsr", "-mabi=ilp32f", "-Os", "-fno-builtin",
                 "-ffunction-sections", "-fdata-sections", "-fstack-usage"]
        run(["riscv64-unknown-elf-gcc", *flags, '-DERROR_SYMBOL="' + error[1] + '"',
             f"-DFIXTURE_FAULT={FIXTURE_FAULTS[args.fixture_fault]}", "-c",
             str(ROOT / "tools/wifi_tx_confirmation_oracle.c"), "-o", str(work / "probe.o")])
        run(["riscv64-unknown-elf-gcc", *flags, "-Dwifi_console_format_probe_main=wifi_confirmation_probe_main",
             "-Dwifi_console_format_probe_report=wifi_confirmation_probe_report", "-c",
             str(ROOT / "tools/wifi_console_format_probe.S"), "-o", str(work / "start.o")])
        elf = work / "probe.elf"
        run(["riscv64-unknown-elf-gcc", *flags[:2], "-nostdlib", "-nostartfiles", "-static", "-Wl,--gc-sections",
             "-T", str(ROOT / "tools/wifi_console_format_probe.ld"), str(work / "start.o"), str(work / "probe.o"),
             str(fixture_obj), *map(str, vendor_paths), "-lgcc", "-o", str(elf)])
        report["elf_sha256"] = sha(elf)
        output = run(["qemu-system-riscv32", "-machine", "virt", "-cpu", CPU, "-m", "32M", "-smp", "1",
                      "-bios", "none", "-nographic", "-monitor", "none", "-nic", "none", "-kernel", str(elf)], "qemu.log", check=False)
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
