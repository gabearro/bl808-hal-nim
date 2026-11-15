"""Check compiler shift fallbacks without relying on their host lowering."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/bl808/kernel/baremetal_libc.c"


def helpers():
    source = SOURCE.read_text()
    marker = "/* Compiler 64-bit shift helpers. */"
    start = source.index(marker) if marker in source else source.index(
        "__attribute__((weak)) uint64_t __ashldi3")
    return "#include <stdint.h>\n" + source[start:source.index("/* Network byte-order", start)]


HARNESS = r'''
#include <assert.h>
#include <string.h>

int main(void) {
    uint64_t (*volatile left)(uint64_t, int) = __ashldi3;
    uint64_t (*volatile right)(uint64_t, int) = __lshrdi3;
    int64_t (*volatile arithmetic)(int64_t, int) = __ashrdi3;
    const uint64_t values[] = {0, 1, UINT64_MAX, UINT64_C(0x8000000000000000),
        UINT64_C(0x7fffffffffffffff), UINT64_C(0x0123456789abcdef),
        UINT64_C(0xfedcba9876543210), UINT64_C(0xffffffff00000000),
        UINT64_C(0x00000000ffffffff)};
    for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
        for (int shift = -2; shift <= 66; ++shift) {
            uint64_t value = values[i], signed_bits;
            int64_t signed_value;
            memcpy(&signed_value, &value, sizeof(value));
            uint64_t expected_left = shift <= 0 ? value : shift >= 64 ? 0 : value << shift;
            uint64_t expected_right = shift <= 0 ? value : shift >= 64 ? 0 : value >> shift;
            if (shift <= 0) signed_bits = value;
            else if (shift >= 64) signed_bits = signed_value < 0 ? UINT64_MAX : 0;
            else signed_bits = (value >> shift) |
                (signed_value < 0 ? UINT64_MAX << (64 - shift) : 0);
            int64_t expected_signed;
            memcpy(&expected_signed, &signed_bits, sizeof(signed_bits));
            assert(left(value, shift) == expected_left);
            assert(right(value, shift) == expected_right);
            assert(arithmetic(signed_value, shift) == expected_signed);
        }
    }
    return 0;
}
'''


@pytest.mark.parametrize("sanitized", [False, True])
def test_shift_results(tmp_path, sanitized):
    compiler = shutil.which("clang")
    if compiler is None:
        pytest.skip("clang is required")
    source = tmp_path / "shifts.c"
    executable = tmp_path / "shifts"
    source.write_text(helpers() + HARNESS)
    command = [compiler, "-std=c11", "-O2", "-fno-builtin", str(source), "-o", str(executable)]
    if sanitized:
        command += ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("architecture,abi", [("rv32imafc", "ilp32f"), ("rv64imafdc", "lp64d")])
def test_target_helpers_are_leaf_functions(tmp_path, architecture, abi):
    compiler = shutil.which("riscv64-unknown-elf-gcc")
    objdump = shutil.which("llvm-objdump") or shutil.which("riscv64-unknown-elf-objdump")
    if compiler is None or objdump is None:
        pytest.skip("RISC-V compiler and objdump are required")
    source = tmp_path / "shifts.c"
    output = tmp_path / "shifts.o"
    source.write_text(helpers())
    result = subprocess.run([compiler, f"-march={architecture}", f"-mabi={abi}", "-std=c11",
        "-Os", "-ffreestanding", "-fno-builtin", "-fno-optimize-sibling-calls",
        "-ffunction-sections", "-c", str(source), "-o", str(output)],
        capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    result = subprocess.run([objdump, "-dr", str(output)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not re.search(r"R_RISCV_CALL(?:_PLT)?\b", result.stdout), result.stdout
