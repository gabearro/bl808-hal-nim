"""Execute the compiled M0 formatter under QEMU without hardware or libc."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nimcache", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--cc", default="riscv64-unknown-elf-gcc")
    parser.add_argument("--qemu", default="qemu-system-riscv32")
    parser.add_argument("--skip-sprintf", action="store_true", help="compare older objects without sprintf")
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    support = args.nimcache / "@pbl808@swifi@ssupport.nim.c.o"
    libc = args.nimcache / "@pbl808@skernel@sbaremetal_libc.c.o"
    evidence = {"commands": [], "passed": False, "with_sprintf": not args.skip_sprintf, "inputs": {}}
    for path in [support, libc]:
        if not path.is_file():
            evidence["error"] = f"required object is missing: {path}"
            (args.work / "result.json").write_text(json.dumps(evidence, indent=2) + "\n")
            print(evidence["error"])
            return 2
    compiler_flags = ["-march=rv32imafc_zicsr", "-mabi=ilp32f", "-Os", "-fno-builtin",
                      "-ffunction-sections", "-fdata-sections", "-fstack-usage"]
    if args.skip_sprintf:
        compiler_flags.append("-DWIFI_CONSOLE_FORMAT_NO_SPRINTF")
    commands = []
    for source, output in [("tools/wifi_console_format_probe.c", args.work / "probe.o"),
                           ("tools/wifi_console_format_probe.S", args.work / "start.o")]:
        commands.append([args.cc, *compiler_flags, "-c", source, "-o", str(output)])
    elf = args.work / "probe.elf"
    commands.append([args.cc, "-march=rv32imafc_zicsr", "-mabi=ilp32f", "-nostdlib", "-nostartfiles",
                     "-static", "-Wl,--gc-sections", "-T", "tools/wifi_console_format_probe.ld",
                     str(args.work / "start.o"), str(args.work / "probe.o"), str(support), str(libc),
                     "-lgcc", "-o", str(elf)])
    evidence["inputs"] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in [support, libc, Path("tools/wifi_console_format_probe.c"),
                                    Path("tools/wifi_console_format_probe.S"), Path("tools/wifi_console_format_probe.ld")]}
    for argv in commands:
        try:
            result = subprocess.run(argv, capture_output=True, text=True, timeout=90)
        except (OSError, subprocess.TimeoutExpired) as error:
            evidence["error"] = str(error)
            (args.work / "result.json").write_text(json.dumps(evidence, indent=2) + "\n")
            print(error)
            return 2
        evidence["commands"].append({"command": shlex.join(argv), "exit_code": result.returncode,
                                     "stdout": result.stdout, "stderr": result.stderr})
        if result.returncode:
            (args.work / "result.json").write_text(json.dumps(evidence, indent=2) + "\n")
            print(result.stdout + result.stderr)
            return result.returncode
    argv = [args.qemu, "-machine", "virt", "-cpu", "rv32", "-m", "16M", "-smp", "1",
            "-bios", "none", "-nographic", "-monitor", "none", "-nic", "none", "-kernel", str(elf)]
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as error:
        evidence["error"] = str(error)
        (args.work / "result.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(error)
        return 2
    evidence["commands"].append({"command": shlex.join(argv), "exit_code": result.returncode,
                                 "stdout": result.stdout, "stderr": result.stderr})
    match = re.search(r"CONSOLE-FORMAT RV32 (PASS|FAIL) checks=0x([0-9a-f]+)", result.stdout)
    evidence["checks"] = int(match[2], 16) if match else 0
    evidence["status"] = match[1] if match else "missing"
    evidence["passed"] = result.returncode == 0 and evidence["status"] == "PASS" and \
        evidence["checks"] == (63 if args.skip_sprintf else 64)
    evidence["elf_sha256"] = hashlib.sha256(elf.read_bytes()).hexdigest()
    (args.work / "result.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(result.stdout + result.stderr, end="")
    return 0 if evidence["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
