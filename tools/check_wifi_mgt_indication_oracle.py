"""Exercise the normal compiled RV32 management producer and segmented copy."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import struct
import subprocess
import sys

from check_wifi_rx_pipeline_oracle import elf32, elf_relocations
from check_wifi_tx_confirmation_oracle import ARCHIVE_SHA256, sha

ROOT = Path(__file__).resolve().parents[1]
FAULTS = ["none", "length", "body", "cleanup", "routing"]
QEMU_SHA256 = "4b288a5a52c1eb1878c76487a135e97270c3813836c998896640e5b123bb75f9"


def parse_result(output: str, exit_code: int, fault: str = "none") -> dict:
    incomplete = {"passed": False, "control_rejected": False, "status": "incomplete"}
    if fault not in FAULTS:
        return incomplete
    match = re.fullmatch(r"MGTCOPY RV32 (PASS|FAIL)((?: [0-9a-f]{8}){13}) *\n?", output)
    if match is None:
        return incomplete
    values = [int(v, 16) for v in match[2].split()]
    cases, checks, result, failure, *rest = values
    inputs, errors = rest[:6], rest[6:]
    fields = {"passed": False, "control_rejected": False, "status": match[1],
              "cases": cases, "checks": checks, "result": result, "failure": failure,
              "last_inputs": inputs, "qemu_exit_code": exit_code,
              "unexpected": errors[0], "callback_error": errors[1], "error_flag": errors[2]}
    if any(errors):
        return fields
    if fault == "none":
        fields["passed"] = (match[1] == "PASS" and exit_code == result == failure == 0
                            and cases == 3036 and checks == 30228
                            and inputs == [11, 2304, 2, 9, 16, 2])
    else:
        expected = {"length": (1, 7, 9, [0, 12, 0, 0, 0, 0]),
                    "body": (1, 9, 11, [0, 12, 0, 0, 0, 0]),
                    "cleanup": (146, 1601, 6, [0, 1713, 0, 0, 0, 1]),
                    "routing": (1, 8, 10, [0, 12, 0, 0, 0, 0])}[fault]
        fields["control_rejected"] = (match[1] == "FAIL" and exit_code == result == failure == expected[2]
                                      and (cases, checks) == expected[:2] and inputs == expected[3])
    return fields


def section_hashes(path: Path) -> dict:
    data, named, _ = elf32(path)
    return {name: {"size": s[5], "sha256": hashlib.sha256(data[s[4]:s[4] + s[5]]).hexdigest()}
            for name, (_, s) in named.items() if name.startswith(".text.")}


def extract_firmware_functions(obj: Path, keep: set[str], work: Path, run):
    """Bind selected normal functions without changing their instructions or relocations."""
    _, _, symbols = elf32(obj)
    defined = {name for name, _, s in symbols if s[3] & 15 == 2 and s[5] not in [0, 0xfff1, 0xfff2]}
    assert keep <= defined
    names = work / "global-functions.txt"
    names.write_text("\n".join(sorted(defined)) + "\n")
    globalized = work / "globalized.o"
    run(["riscv64-unknown-elf-objcopy", "--globalize-symbols=" + str(names), obj, globalized])
    assert section_hashes(obj) == section_hashes(globalized)
    data, named, symbols = elf32(globalized)
    for name, at, s in symbols:
        if name in defined - keep:
            struct.pack_into("<I", data, at + 4, 0)
            struct.pack_into("<H", data, at + 14, 0)
    metadata_only = work / "external-callees.o"
    metadata_only.write_bytes(data)
    assert section_hashes(obj) == section_hashes(metadata_only)
    data, named, symbols = elf32(metadata_only)
    retained = {named[".text." + name][0] for name in keep}
    by_index = {i: (name, s) for name, (i, s) in named.items()}
    while True:
        previous = set(retained)
        for _, (_, s) in named.items():
            if s[1] not in [4, 9] or s[7] not in retained:
                continue
            for at in range(s[4], s[4] + s[5], s[9]):
                info = struct.unpack_from("<I", data, at + 4)[0]
                index = symbols[info >> 8][2][5]
                if 0 < index < 0xff00:
                    assert not by_index[index][0].startswith(".text.") or index in previous
                    retained.add(index)
        if retained == previous:
            break
    selected = [by_index[i][0] for i in sorted(retained)]
    selected += [name for name, (_, s) in named.items() if s[1] in [4, 9] and s[7] in retained]
    extracted = work / "management.o"
    run(["/opt/homebrew/opt/llvm/bin/llvm-objcopy", "--keep-symbols=" + str(names),
         *["--only-section=" + name for name in selected], metadata_only, extracted])
    original, actual = section_hashes(obj), section_hashes(extracted)
    assert set(actual) == {".text." + name for name in keep}
    assert all(original[name] == digest for name, digest in actual.items())
    info = {"retained_text_sections_unchanged": actual,
            "retained_data_sections": [by_index[i][0] for i in sorted(retained)
                                        if not by_index[i][0].startswith(".text.")]}
    owners = set(actual) | set(info["retained_data_sections"])
    relocations = elf_relocations(obj, owners)
    assert relocations == elf_relocations(extracted, owners)
    info["relocations_unchanged"] = {name: len(entries) for name, entries in relocations.items()}
    info["relocations_sha256"] = hashlib.sha256(json.dumps(relocations, sort_keys=True).encode()).hexdigest()
    return extracted, info, relocations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wifi-object", type=Path, required=True)
    parser.add_argument("--system-object", type=Path, required=True)
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--archive", type=Path, default=ROOT / "tools/ref/libwifi_bl808.a")
    parser.add_argument("--fault", choices=FAULTS, default="none")
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    obj, system, qemu, archive = [p.resolve() for p in
                                  [args.wifi_object, args.system_object, args.qemu, args.archive]]
    c_source = Path(__file__).with_name("wifi_mgt_indication_oracle.c")
    report = {"passed": False, "commands": [], "fault": args.fault,
              "scope": "Compiled RV32 management producer/copy; no radio, cryptographic verification or full vendor equivalence",
              "models": ["session and VIF binding predicates", "accepted MFP result", "channel and PHY decode",
                         "message allocation/publication/free", "raw management upload", "logging and memory functions"]}

    def run(command, output=None, check=True):
        command = [str(p) for p in command]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=360)
        report["commands"].append({"command": shlex.join(command), "exit_code": result.returncode,
                                   "stdout": result.stdout, "stderr": result.stderr})
        if output:
            (work / output).write_text(result.stdout)
            (work / (output + ".stderr")).write_text(result.stderr)
        if check and result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout

    try:
        assert sha(qemu) == QEMU_SHA256
        assert sha(archive) == ARCHIVE_SHA256
        report["inputs"] = {str(p): sha(p) for p in [Path(__file__), c_source, obj, system, qemu, archive,
            ROOT / "tools/check_wifi_rx_pipeline_oracle.py", ROOT / "tools/test_wifi_michael.py",
            ROOT / "tools/check_wifi_tx_confirmation_oracle.py", ROOT / "tools/wifi_rx_protected_oracle.S",
            ROOT / "tools/wifi_console_format_probe.ld"]}
        _, _, symbols = elf32(obj)
        defined = {name for name, _, s in symbols if s[3] & 15 == 2 and s[5] not in [0, 0xfff1, 0xfff2]}
        keep = {"rxu_mgt_frame_check"} | {name for name in defined if name.startswith(
            ("rxuCopyFrameBytes__", "rxMacHeaderLen__", "rxMgmtBodyValid__", "contains__"))}
        assert keep <= defined and any(n.startswith("rxuCopyFrameBytes__") for n in keep)
        extracted, extraction, relocations = extract_firmware_functions(obj, keep, work, run)
        report.update(extraction)
        _, _, symbols = elf32(extracted)
        referenced = {entry[2] for entries in relocations.values() for entry in entries}
        undefined = {name for name, _, s in symbols if s[5] == 0 and name and name in referenced}
        _, _, sys_symbols = elf32(system)
        system_defined = {name for name, _, s in sys_symbols if s[3] & 15 == 2 and s[5] != 0}
        patterns = {"STATION_CURRENT": "rxStationCurrent__", "MPDU_HEADER": "rxMpduHeader__",
                    "UPLOAD_GENERATION": "rxUploadGeneration__", "UPLOAD_CURRENT": "rxUploadCurrent__",
                    "BIND_VIF": "rxBindVif__", "MFP_IGNORE": "mfpIgnoreRxMgmtFrame__",
                    "READ_CHANNEL": "rxReadCapturedChannel__", "ALLOC_MGT": "rxMgtAllocMessage__",
                    "UPLOAD_MGT": "rxuMgtUpload__", "FREE_MGT": "ke_msg_free_payload__",
                    "ERROR_FLAG": "nimInErrorMode__"}
        bindings = {}
        for macro, prefix in patterns.items():
            matches = [name for name in undefined if name.startswith(prefix)]
            assert len(matches) == 1, (macro, matches)
            bindings[macro] = matches[0]
        special = set(bindings.values()) | system_defined | {
            "ke_state_get", "nimZeroMem", "nimCopyMem", "memcpy", "memset", "memcmp", "g_bl_ops_funcs",
            "vif_mgmt_get_vif", "apm_embedded_enabled", "phyif_utils_decode", "phy_get_channel_raw",
            "me_beacon_check", "ke_msg_send", "ke_msg_free_payload", "assert_warn"}
        aliases, unexpected_aliases = [], []
        for index, name in enumerate(sorted(undefined - special)):
            if name.startswith(("nimFw", "printf", "puts", "hw_validation_log_byte")):
                aliases.append(f'uintptr_t stub_{index}(void) __asm__("{name}") '
                               '__attribute__((alias("diagnostic_model")));')
            else:
                unexpected_aliases.append(name)
                aliases.append(f'uintptr_t stub_{index}(void) __asm__("{name}"); '
                               f'uintptr_t stub_{index}(void) {{ unexpected = {index + 1}; return 0; }}')
        (work / "bindings.h").write_text("".join(f'#define {k} "{v}"\n' for k, v in bindings.items())
                                         + "\n".join(aliases) + "\n")
        report["bindings"], report["unexpected_callee_aliases"] = bindings, unexpected_aliases
        flags = ["-march=rv32imafc_zicsr", "-mabi=ilp32f", "-Os", "-fno-builtin",
                 "-ffunction-sections", "-fdata-sections"]
        run(["riscv64-unknown-elf-gcc", *flags, "-Wall", "-Wextra", "-Werror", "-I", work,
             f"-DFIXTURE_FAULT={FAULTS.index(args.fault)}", "-c", c_source, "-o", work / "probe.o"])
        run(["riscv64-unknown-elf-gcc", *flags, "-Dwifi_rx_protected_probe_main=wifi_mgt_probe_main",
             "-Dwifi_rx_protected_probe_report=wifi_mgt_probe_report",
             "-Dwifi_rx_protected_trap_report=wifi_mgt_trap_report",
             "-c", "tools/wifi_rx_protected_oracle.S", "-o", work / "start.o"])
        elf = work / "probe.elf"
        run(["riscv64-unknown-elf-gcc", *flags[:2], "-nostdlib", "-nostartfiles", "-static", "-Wl,--gc-sections",
             "-T", "tools/wifi_console_format_probe.ld", work / "start.o", work / "probe.o",
             extracted, system, "-lgcc", "-o", elf])
        report["elf_sha256"] = sha(elf)
        metadata = json.loads(run(["rabin2", "-sj", obj], "nim-symbols.json"))["symbols"]
        roots = [s for s in metadata if s["type"] == "FUNC" and s["name"] in keep]
        assert {s["name"] for s in roots} == keep
        run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0", "-e", "bin.relocs.apply=true", "-c",
             "; ".join(f'pD {s["size"]} @ {s["vaddr"]}' for s in roots), obj], "nim-r2.txt")
        run(["/opt/homebrew/opt/llvm/bin/llvm-objdump", "-dr", "--no-show-raw-insn",
             "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov",
             *["--section=.text." + name for name in sorted(keep)], obj], "nim-llvm.txt")
        raw = work / "vendor-rxu_cntrl.o"
        raw.write_bytes(subprocess.check_output(["riscv64-unknown-elf-ar", "p", str(archive), "rxu_cntrl.o"]))
        metadata = json.loads(run(["rabin2", "-sj", raw], "vendor-symbols.json"))["symbols"]
        root, = [s for s in metadata if s["type"] == "FUNC" and s["name"] == "rxu_mgt_frame_check"]
        assert root["size"] == 1350
        report["vendor_root"] = root
        run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0", "-e", "bin.relocs.apply=true", "-c",
             f'pD {root["size"]} @ {root["vaddr"]}', raw], "vendor-r2.txt")
        run(["/opt/homebrew/opt/llvm/bin/llvm-objdump", "-dr", "--no-show-raw-insn",
             "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov",
             "--section=.text.rxu_mgt_frame_check", raw], "vendor-llvm.txt")
        output = run([qemu, "-machine", "virt", "-cpu", "e907fdp", "-m", "32M", "-smp", "1", "-bios", "none",
                      "-nographic", "-monitor", "none", "-nic", "none", "-kernel", elf], "qemu.log", False)
        result = parse_result(output, report["commands"][-1]["exit_code"], args.fault)
        report.update(result)
        print(output, end="")
        if not (result["passed"] or result["control_rejected"]):
            raise ValueError("Management observation did not satisfy the selected contract/control")
    except Exception as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report.get("passed") or report.get("control_rejected") else 1


if __name__ == "__main__":
    raise SystemExit(main())
