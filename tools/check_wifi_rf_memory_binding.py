"""Check two memory-only RV32 entrypoints with radare2 ESIL, not full RF emulation.

The ELF must retain wl_env_get and rf_pri_init_calib_mem. Configuration lookup
and nil branches are deliberately not covered: radare2 6.2.6 emits incorrect
ESIL for some compressed jumps. Native tests cover those source-level paths.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def check_case(elf: Path, symbols: dict, entry: str, memory: int, initial: dict,
               expected: dict, r2: str) -> dict:
    stop = 0x7001E000
    stack = 0x7001F000
    commands = ["e io.cache=true", "aei", "aeim 0x70000000 0x20000 scratch",
                f"aer sp={stack}", f"aer ra={stop}", f"aer a0={memory}",
                f'aer gp={symbols.get("__global_pointer$", {}).get("vaddr", 0)}',
                f'aer pc={symbols[entry]["vaddr"]}']
    for symbol_name, value in initial.items():
        commands.append(f'wv4 {value} @ {symbols[symbol_name]["vaddr"]}')
    commands.extend([f"aecu {stop}", "aerj"])
    for symbol_name in initial:
        commands.append(f'pxj 4 @ {symbols[symbol_name]["vaddr"]}')
    result = subprocess.run([r2, "-q", "-e", "scr.color=0", "-e", "esil.maxsteps=2048",
                             "-c", "; ".join(commands), str(elf)], text=True,
                            capture_output=True, timeout=20)
    data = [json.loads(line) for line in result.stdout.splitlines() if line.startswith(("{", "["))]
    if result.returncode != 0 or len(data) != len(initial) + 1:
        raise RuntimeError(f"invalid ESIL response: {result.stdout}\n{result.stderr}")
    registers = data[0]
    returned = registers["pc"] == stop and registers["sp"] == stack
    actual = {symbol_name: int.from_bytes(bytes(value), "little")
              for symbol_name, value in zip(initial, data[1:])}
    return_ok = entry != "wl_env_get" or registers["a0"] == memory + 532
    return {"entry": entry, "argument": memory, "initial": initial,
            "returned": returned, "return_value_ok": return_ok,
            "actual": actual, "expected": expected,
            "passed": returned and return_ok and actual == expected,
            "registers": registers, "stderr": result.stderr}


def check(elf: Path, r2: str, rabin2: str) -> dict:
    metadata = json.loads(subprocess.check_output([rabin2, "-Ij", str(elf)], text=True))
    info = metadata["info"]
    if info["arch"] != "riscv" or info["bits"] != 32 or info["endian"] != "little":
        raise ValueError("this checker requires a little-endian RV32 ELF")
    symbol_data = json.loads(subprocess.check_output([rabin2, "-sj", str(elf)], text=True))
    symbols = {s["name"]: s for s in symbol_data["symbols"]}
    required = {"wl_env_get", "rf_pri_init_calib_mem", "wl_cfg", "wl_cal", "wl_env", "rf_calib_data"}
    if missing := required - symbols.keys():
        raise ValueError(f"ELF does not retain required symbols: {sorted(missing)}")
    for symbol_name in required - {"wl_env_get", "rf_pri_init_calib_mem"}:
        if symbols[symbol_name]["size"] != 4:
            raise ValueError(f"{symbol_name} is not an RV32 pointer export")
    cases = []
    for memory in [0x70001000, 0x70002000]:
        for rf_pointer in [0, 0x70010000, 0xFFFFFFFC, 0x70000800]:
            initial = {"wl_cfg": 0x70008000, "wl_cal": 0x70008200,
                       "wl_env": 0x70008400, "rf_calib_data": rf_pointer}
            expected = {"wl_cfg": memory, "wl_cal": memory + 212,
                        "wl_env": memory + 532, "rf_calib_data": rf_pointer}
            cases.append(check_case(elf, symbols, "wl_env_get", memory, initial, expected, r2))
    for calibration in [0, 0x700010D4, 0x70002000, 0xFFFFFFFC]:
        initial = {"wl_cfg": 0x70008000, "wl_cal": calibration,
                   "wl_env": 0x70008400, "rf_calib_data": 0x70010000}
        expected = {**initial, "rf_calib_data": calibration}
        cases.append(check_case(elf, symbols, "rf_pri_init_calib_mem", 0, initial, expected, r2))
    return {"elf": str(elf), "elf_sha256": hashlib.sha256(elf.read_bytes()).hexdigest(),
            "engine": subprocess.check_output([r2, "-v"], text=True).splitlines()[0],
            "passed": all(case["passed"] for case in cases), "cases": cases,
            "scope": "nonnull WL environment lookup and explicit RF calibration binding only"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--r2", default="r2")
    parser.add_argument("--rabin2", default="rabin2")
    args = parser.parse_args()
    try:
        report = check(args.elf, args.r2, args.rabin2)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        report = {"elf": str(args.elf), "passed": False, "error": str(error)}
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(f"Target check incomplete: {error}")
        return 2
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    passed = sum(case["passed"] for case in report["cases"])
    print(f"{passed}/{len(report['cases'])} target memory-binding cases passed")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
