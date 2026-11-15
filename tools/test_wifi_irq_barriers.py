"""Check memory ordering around the firmware's actual IRQ assembly templates."""

import json
from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]


def irq_assembly(boundary: str = "firmware") -> tuple[str, str]:
    if boundary == "firmware":
        path, save_name, restore_name, variable = (
            "fw/runtime_helpers.nim", "irqSave", "irqRestore", "irqPrev")
    else:
        assert boundary == "mac-service"
        path, save_name, restore_name, variable = (
            "support/backend_irq.nim", "macServiceIrqSave", "macServiceIrqRestore", "prev")
    source = (ROOT / "src/bl808/wifi" / path).read_text()
    save = source.split(f"template {save_name}", 1)[1]
    save, restore = save.split(f"template {restore_name}", 1)
    restore = restore.split("\nproc ", 1)[0]
    save_emit = re.search(r'\{\.emit: \["(.*?)", ' + variable + r', "(.*?)"\]\.\}', save)
    restore_emit = re.search(r'\{\.emit: \["(.*?)"\]\.\}', restore)
    assert save_emit and restore_emit
    decode = lambda text: json.loads('"' + text + '"')
    return (decode(save_emit[1]) + "saved" + decode(save_emit[2]),
            decode(restore_emit[1]))


@pytest.mark.parametrize("optimization", ["-Os", "-O2", "-O3"])
@pytest.mark.parametrize("boundary", ["firmware", "mac-service"])
def test_irq_boundaries_reload_shared_memory(
    tmp_path: Path, optimization: str, boundary: str
) -> None:
    compiler = shutil.which("riscv64-unknown-elf-gcc")
    if compiler is None:
        pytest.skip("RISC-V GCC is required")
    save, restore = irq_assembly(boundary)
    source = tmp_path / "irq_barrier.c"
    assembly = tmp_path / "irq_barrier.s"
    source.write_text(f'''
#include <stdint.h>
uint32_t irq_barrier_probe(uint32_t *shared) {{
    uint32_t before = *shared;
    uint32_t saved;
    {save}
    uint32_t inside = *shared;
    *shared = inside + 1;
    {restore}
    return before + inside + *shared;
}}
''')
    result = subprocess.run([compiler, "-march=rv32imafc", "-mabi=ilp32f",
        optimization, "-ffreestanding", "-S", str(source), "-o", str(assembly)],
        capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    text = assembly.read_text()
    lines = text.splitlines()
    reads = [i for i, line in enumerate(lines) if re.match(r"\s*lw\s", line)]
    writes = [i for i, line in enumerate(lines) if re.match(r"\s*sw\s", line)]
    disabled = next(i for i, line in enumerate(lines) if "csrrci" in line)
    enabled = next(i for i, line in enumerate(lines) if "csrsi" in line)
    assert len(reads) == 3 and len(writes) == 1, text
    assert reads[0] < disabled < reads[1] < writes[0] < enabled < reads[2], text
