#!/usr/bin/env python3
"""Compile and execute one RV64 JIT function on QEMU virt, never on Ox64."""

import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "wasm-jit-d0-qemu"


def run(*argv, timeout=90):
    return subprocess.run(argv, cwd=ROOT, check=True, text=True,
                          capture_output=True, timeout=timeout).stdout


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    elf = OUT / "d0.elf"
    run("wat2wasm", "tools/wasm_jit_d0_fallback.wat", "-o",
        str(OUT / "fallback.wasm"))
    run("nim", "c", "-d:release", "--skipUserCfg", "--skipParentCfg",
        "--skipProjCfg", "--path:src", "--os:any", "--cpu:riscv64",
        "--cc:gcc", "--gcc.exe:riscv64-unknown-elf-gcc",
        "--gcc.linkerexe:riscv64-unknown-elf-gcc", "--mm:arc",
        "-d:useMalloc", "-d:nimNoLibc", "-d:noSignalHandler",
        "-d:bl808d0", "-d:bl808WasmFull", "-d:wasmJitQemu",
        "-d:wasmD0JitQemu", "--noMain:on", "--threads:off",
        "--checks:off", "--assertions:off", "--stackTrace:off",
        "--lineTrace:off", "--panics:on",
        "--passC:-march=rv64imafdc -mabi=lp64d -mcmodel=medany "
        "-ffunction-sections -fdata-sections -fno-builtin",
        "--passL:-march=rv64imafdc -mabi=lp64d -mcmodel=medany "
        "-nostdlib -nostartfiles -static -Wl,--gc-sections "
        "-T tools/wasm_jit_d0_qemu.ld -lgcc",
        f"--nimcache:{OUT / 'cache'}", f"--out:{elf}",
        "tools/wasm_full_qemu.nim")
    output = run("qemu-system-riscv64", "-machine", "virt",
                 "-cpu", "rv64,m=true,a=true,f=true,d=true,c=true",
                 "-m", "32M", "-bios", "none", "-nographic",
                 "-no-reboot", "-kernel", str(elf), timeout=30)
    assert "[PASS] D0 RV64 JIT add/f64/fallback" in output and "[FAIL]" not in output, output
    heap = int(re.search(r"D0 JIT heap peak bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    stack = int(re.search(r"D0 JIT native stack used bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    assert heap < 256 * 1024 and stack < 32 * 1024, (heap, stack)
    print(f"D0 QEMU Tier-2 add/f64/fallback PASS: heap peak={heap}, native stack used={stack}")


if __name__ == "__main__":
    main()
