"""Compare compiled Nim message tables with radare2-decoded vendor relocations."""

import json
from pathlib import Path
import re
import shutil
import struct
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "tools/ref/libwifi_bl808.a"
TABLE_OBJECTS = {
    "mm_default_state": "mm_task.o",
    "scan_default_state": "scan_task.o",
    "scanu_default_state": "scanu_task.o",
    "scanu_idle": "scanu_task.o",
    "scanu_scanning": "scanu_task.o",
    "sm_default_state": "sm_task.o",
    "apm_default_state": "apm_task.o",
    "bam_default_state": "bam_task.o",
    "me_default_state": "me_task.o",
    "cfg_default_state": "cfg_task.o",
}


def run(*args: str) -> str:
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr + result.stdout
    return result.stdout


def vendor_tables(tmp_path: Path, r2: str, ar: str) -> dict[str, list[tuple[int, str]]]:
    tables = {}
    for member in sorted(set(TABLE_OBJECTS.values())):
        result = subprocess.run([ar, "p", str(ARCHIVE), member], capture_output=True)
        assert result.returncode == 0, result.stderr.decode()
        raw = result.stdout
        obj = tmp_path / member
        obj.write_bytes(raw)
        # Each command emits one JSON document. Ignore stderr diagnostics, not data.
        documents = [json.loads(line) for line in run(r2, "-q", "-c", "iSj;irj;q", str(obj)).splitlines()]
        assert len(documents) == 2
        sections, relocations = documents
        relocation_names = {entry["paddr"]: entry["name"].removeprefix("imp.") for entry in relocations}
        for name, object_name in TABLE_OBJECTS.items():
            if object_name != member:
                continue
            section = next(entry for entry in sections if entry["name"] == ".rodata." + name)
            assert section["size"] % 8 == 0
            entries = []
            for offset in range(0, section["size"], 8):
                address = section["paddr"] + offset
                message_id = struct.unpack_from("<I", raw, address)[0]
                target = relocation_names[address + 4]
                assert target
                entries.append((message_id, target))
            tables[name] = entries
    return tables


def nim_tables(tmp_path: Path, nim: str) -> dict[str, list[tuple[int, str]]]:
    source = (ROOT / "src/bl808/wifi/fw/dispatch_tables.nim").read_text()
    matches = re.findall(
        r"(var (\w+)\*[^\n]*: array\[\d+, KeMsgHandler\] = \[.*?\n\])",
        source, re.S,
    )
    # Key by name while retaining the original table expressions for Nim to evaluate.
    declarations = {name: body for body, name in matches}
    assert TABLE_OBJECTS.keys() <= declarations.keys()
    bodies = [declarations[name] for name in TABLE_OBJECTS]
    handlers = sorted(set(re.findall(r"handler: keMsgHandlerAddress\((\w+)\)", "\n".join(bodies))))
    header = """import std/json
import bl808/wifi/fw_messages
{.pragma: wifiCtrlExport.}
type KeMsgHandler = object
  msgId: uint32
  handler: pointer
"""
    helper = re.search(r"(?ms)^template keMsgHandlerAddress\(.*?(?=\n\S|\Z)", source)
    assert helper
    header += helper.group(0) + "\n"
    stubs = "\n".join(f"proc {name}(param: pointer): cint {{.cdecl.}} = {index}" for index, name in enumerate(handlers))
    reverse_map = "\n".join(f'  (cast[pointer]({name}), "{name}"),' for name in handlers)
    output = "\nlet names = [\n" + reverse_map + "\n]\nvar result = newJObject()\n"
    for name in TABLE_OBJECTS:
        output += f'''result["{name}"] = newJArray()
for entry in {name}:
  var target = ""
  for item in names:
    if item[0] == entry.handler: target = item[1]
  doAssert target.len != 0
  result["{name}"].add(%*[entry.msgId, target])
'''
    output += "echo result\n"
    program = tmp_path / "message_tables.nim"
    program.write_text(header + stubs + "\n" + "\n".join(bodies) + output)
    binary = tmp_path / "message_tables"
    run(nim, "c", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{binary}", str(program))
    return {name: [tuple(entry) for entry in entries] for name, entries in json.loads(run(str(binary))).items()}


def normalized_handler(table: str, name: str) -> str:
    # Separate C translation units have same-named static handlers. Nim gives
    # these explicit task suffixes so they can live in the combined module.
    if table == "sm_default_state":
        name = name.removesuffix("_sm")
    elif table == "apm_default_state":
        name = name.removesuffix("_apm")
    elif table.startswith("scanu_"):
        name = name.removesuffix("_scanu")
    elif table == "bam_default_state":
        name = name.removesuffix("_bam")
    return name


def compiled_constants(tmp_path: Path, nim: str, header: str, names: list[str], suffix: str) -> dict[str, int]:
    source = "import std/json\n" + header + "\nvar result = newJObject()\n"
    source += "\n".join(f'result["{name}"] = %{name}.uint32' for name in names)
    source += "\necho result\n"
    path = tmp_path / (suffix + ".nim")
    binary = tmp_path / suffix
    path.write_text(source)
    run(nim, "c", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / (suffix + '_cache')}",
        f"-o:{binary}", str(path))
    return json.loads(run(str(binary)))


def test_firmware_and_host_mm_ids_match_vendor_enum(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    ar = shutil.which("riscv64-unknown-elf-ar") or shutil.which("ar")
    dwarf = shutil.which("llvm-dwarfdump")
    if dwarf is None:
        bundled = Path("/opt/homebrew/opt/llvm/bin/llvm-dwarfdump")
        if bundled.is_file():
            dwarf = str(bundled)
    if not all((nim, ar, dwarf)):
        pytest.skip("Nim, ar and llvm-dwarfdump are required")
    member = subprocess.run([ar, "p", str(ARCHIVE), "mm_task.o"], capture_output=True)
    assert member.returncode == 0, member.stderr.decode()
    obj = tmp_path / "mm_task.o"
    obj.write_bytes(member.stdout)
    debug = run(dwarf, str(obj))
    vendor = {name: int(value, 0) for name, value in re.findall(
        r'DW_TAG_enumerator\s+DW_AT_name\s+\("(MM_[^"]+)"\)\s+'
        r'DW_AT_const_value\s+\((0x[0-9a-f]+|[0-9]+)\)', debug,
    )}
    assert vendor["MM_MAX"] == 78
    fw_root = ROOT / "src/bl808/wifi/fw_messages/mm_parts"
    names = sorted({name for path in fw_root.glob("*.nim") for name in re.findall(
        r"^\s+(MM_\w+)\*\s*=", path.read_text(), re.M
    )})
    actual = compiled_constants(tmp_path, nim, "import bl808/wifi/fw_messages", names, "fw_ids")
    assert len(actual) == 78
    assert set(actual.values()) == set(range(78)), "MM IDs must be unique and cover the vendor message space"
    for name, value in actual.items():
        vendor_name = "MM_FORCE_IDLE_REQ" if name == "MM_FORCE_IDLE_REQ_MSG" else name
        assert value == vendor[vendor_name], f"{name}: Nim {value}, vendor {vendor[vendor_name]}"
    host_file = ROOT / "src/bl808/wifi/msg_tx/layout/message_ids.nim"
    host_names = re.findall(r"^\s+(MM_\w+)\s*=", host_file.read_text(), re.M)
    host = compiled_constants(tmp_path, nim, f'include "{host_file}"', host_names, "host_ids")
    for name, value in host.items():
        assert value == vendor[name], f"host {name}: Nim {value}, vendor {vendor[name]}"


def test_compiled_message_tables_match_vendor(tmp_path: Path) -> None:
    nim, r2 = (shutil.which(name) for name in ("nim", "r2"))
    ar = shutil.which("riscv64-unknown-elf-ar") or shutil.which("ar")
    if not all((nim, r2, ar)):
        pytest.skip("Nim, radare2, and ar are required")
    assert ARCHIVE.exists(), "BL808 reference archive is missing"
    vendor = vendor_tables(tmp_path, r2, ar)
    actual = nim_tables(tmp_path, nim)
    differences = []
    for table, expected in vendor.items():
        observed = [(msg, normalized_handler(table, target)) for msg, target in actual[table]]
        if table == "apm_default_state":
            # The vendor discards this reply; Nim waits for it during rollback.
            assert expected[9] == (25, "ke_msg_discard")
            assert actual[table][9] == (25, "mm_set_vif_state_cfm_handler_apm")
            expected = list(expected)
            expected[9] = (25, "mm_set_vif_state_cfm_handler")
        elif table == "sm_default_state":
            # The port waits for PS options before publishing station readiness.
            assert expected[17] == (58, "ke_msg_discard")
            assert actual[table][17] == (58, "smActivationOptionsCfmHandler")
            # The port waits for deletion before finishing station cleanup.
            assert expected[18] == (13, "ke_msg_discard")
            assert actual[table][18] == (13, "smCleanupCfmHandler")
            expected = list(expected)
            expected[17] = (58, "smActivationOptionsCfmHandler")
            expected[18] = (13, "smCleanupCfmHandler")
        if observed != expected:
            for index in range(max(len(observed), len(expected))):
                got = observed[index] if index < len(observed) else None
                want = expected[index] if index < len(expected) else None
                if got != want:
                    differences.append(f"{table}[{index}]: Nim {got}, vendor {want}")
    assert not differences, "\n".join(differences)
