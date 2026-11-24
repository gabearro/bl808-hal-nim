"""Exercise the normal compiled RV32 BIP MMIE append and CMAC code."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import shlex
import subprocess

from check_wifi_mgt_indication_oracle import QEMU_SHA256, extract_firmware_functions, section_hashes
from check_wifi_rx_pipeline_oracle import elf32, elf_relocations
from check_wifi_tx_confirmation_oracle import ARCHIVE_SHA256, sha

ROOT = Path(__file__).resolve().parents[1]
PROFILE_COUNT = 96
MAX_IPN = (1 << 48) - 1
OWNER_GLOBALS = {
    "TX_DESC_STORAGE": "txl_frame_desc_storage__",
    "FRAME_IDENTITIES": "txFrameIdentities__",
    "RESET_EPOCH": "txResetEpoch__",
    "VIF_EPOCHS": "rxVifEpochs__",
    "STATION_EPOCHS": "staDeleteEpochs__",
    "SECURITY_RESERVATIONS": "txSecurityReservations__",
    "SECURITY_UPDATING": "txSecurityUpdating__",
}


def write_vectors(work: Path) -> None:
    from cryptography.hazmat.primitives import cmac
    from cryptography.hazmat.primitives.ciphers import algorithms

    rng = random.Random(0xB1808054)
    definitions, rows = [], []
    for vif in (0, 1):
        for key_id in (4, 5):
            for pn in (0, 255, 0xFFFFFFFF, MAX_IPN - 1):
                for length in (24, 26, 42, 63, 128, 494):
                    frame = bytearray(rng.randbytes(length))
                    frame[:2] = b"\xc0\x40"
                    frame[4] |= 1
                    mmie = bytes((76, 16, key_id, 0)) + (pn + 1).to_bytes(6, "little") + bytes(8)
                    aad = (int.from_bytes(frame[:2], "little") & 0xC7FF).to_bytes(2, "little") + frame[4:22]
                    mac = cmac.CMAC(algorithms.AES(bytes(range(16))))
                    mac.update(aad + frame[24:] + mmie)
                    expected = mmie[:-8] + mac.finalize()[:8]
                    index = len(rows)
                    definitions.append(f"static const uint8_t frame_{index}[] = {{" +
                                       ",".join(map(str, frame)) + "};")
                    definitions.append(f"static const uint8_t mmie_{index}[] = {{" +
                                       ",".join(map(str, expected)) + "};")
                    rows.append(f"{{{length},{vif},{key_id},UINT64_C({pn}),frame_{index},mmie_{index}}}")
    assert len(rows) == PROFILE_COUNT
    (work / "vectors.h").write_text("\n".join(definitions) +
        "\nstatic const struct profile profiles[] = {\n" + ",\n".join(rows) + "\n};\n")


def parse_result(output: str, exit_code: int, fault: bool) -> dict:
    match = re.fullmatch(r"BIPTX RV32 (PASS|FAIL)((?: [0-9a-f]{8}){10}) *\n?", output)
    result = {"passed": False, "control_rejected": False, "status": "incomplete"}
    if match is None:
        return result
    cases, checks, code, failure, profile, vif, key_id, incoming, unexpected, error_flag = (
        int(v, 16) for v in match[2].split())
    result.update(status=match[1], cases=cases, checks=checks, result=code,
                  failure=failure, last_inputs=[profile, vif, key_id, incoming],
                  unexpected=unexpected, error_flag=error_flag, qemu_exit_code=exit_code)
    if fault:
        result["control_rejected"] = (match[1] == "FAIL" and cases == 1 and checks == 3
            and code == failure == exit_code == 3 and [profile, vif, key_id, incoming] == [0, 0, 4, 0]
            and unexpected == error_flag == 0)
    else:
        result["passed"] = (match[1] == "PASS" and cases == PROFILE_COUNT * 2 * 22
            and checks == PROFILE_COUNT * 2 * 131 and code == failure == exit_code == 0
            and [profile, vif, key_id, incoming] == [PROFILE_COUNT, 1, 5, 16]
            and unexpected == error_flag == 0)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wifi-object", type=Path, required=True)
    parser.add_argument("--system-object", type=Path, required=True)
    parser.add_argument("--libc-object", type=Path,
                        default=ROOT / "build/nimcache_m0/@pbl808@skernel@sbaremetal_libc.c.o")
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--fault", action="store_true", help="Corrupt the expected MIC to test the checker")
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    obj, system, libc, qemu = (p.resolve() for p in
        (args.wifi_object, args.system_object, args.libc_object, args.qemu))
    archive = ROOT / "tools/ref/libwifi_bl808.a"
    c_source = Path(__file__).with_name("wifi_bip_tx_oracle.c")
    report = {"passed": False, "control_rejected": False, "commands": [], "fault": args.fault,
              "scope": "Normal compiled RV32 BIP MMIE append, AES-CMAC, frame lease and key binding",
              "models": ["initialized descriptor/VIF/key/revision tables", "CMAC-copy state observer", "console"]}

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
        assert sha(qemu) == QEMU_SHA256 and sha(archive) == ARCHIVE_SHA256
        write_vectors(work)
        report["inputs"] = {str(p): sha(p) for p in (Path(__file__), c_source, obj,
            system, libc, qemu, archive, ROOT / "tools/check_wifi_mgt_indication_oracle.py",
            ROOT / "tools/wifi_rx_protected_oracle.S", ROOT / "tools/wifi_console_format_probe.ld")}
        report["vectors_sha256"] = sha(work / "vectors.h")
        _, _, symbols = elf32(obj)
        all_names = {name for name, _, _ in symbols}
        present = {name for name, _, s in symbols if s[5] not in (0, 0xfff1, 0xfff2)}
        defined = {name for name, _, s in symbols if s[3] & 15 == 2 and name in present}
        def one(prefix, candidates=defined):
            matches = [name for name in candidates if name.startswith(prefix)]
            assert len(matches) == 1, (prefix, matches)
            return matches[0]
        bindings = {macro: one(prefix, all_names) for macro, prefix in OWNER_GLOBALS.items()}
        bindings.update(KEY_CLOCK=one("rxKeyRevision__", present),
                        KEY_CHANGES=one("rxKeyLastChanged__", present),
                        ERROR_FLAG=one("nimInErrorMode__", all_names))
        sizes = {name: s[2] for name, _, s in symbols if s[2]}
        expected_sizes = {"vif_info_tab": 3024, bindings["KEY_CLOCK"]: 8,
            bindings["KEY_CHANGES"]: 152, bindings["TX_DESC_STORAGE"]: 880,
            bindings["FRAME_IDENTITIES"]: 208, bindings["RESET_EPOCH"]: 4,
            bindings["VIF_EPOCHS"]: 8, bindings["STATION_EPOCHS"]: 20,
            bindings["SECURITY_RESERVATIONS"]: 360, bindings["SECURITY_UPDATING"]: 4}
        assert all(sizes[name] == expected for name, expected in expected_sizes.items())
        report["global_abi_sizes"] = {name: sizes[name] for name in
            expected_sizes}
        root = "mfp_add_mgmt_mic"
        assert root in defined and "mfp_compute_bip" in defined
        all_relocations = elf_relocations(obj, {".text." + n for n in defined})
        keep = {root}
        while True:
            expanded = keep | {entry[2] for name in keep
                for entry in all_relocations.get(".text." + name, [])
                if entry[2] in defined}
            if expanded == keep:
                break
            keep = expanded
        assert "mfp_compute_bip" in keep
        extracted, extraction, relocations = extract_firmware_functions(obj, keep, work, run)
        report.update(extraction)
        report["normal_functions"] = sorted(keep)
        metadata = json.loads(run(["rabin2", "-sj", obj], "nim-symbols.json"))["symbols"]
        roots = [s for s in metadata if s["type"] == "FUNC" and
                 s["name"] in {root, "mfp_compute_bip"}]
        assert {s["name"] for s in roots} == {root, "mfp_compute_bip"}
        run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0",
             "-e", "bin.relocs.apply=true", "-c",
             "; ".join(f'pD {s["size"]} @ {s["vaddr"]}' for s in roots), obj], "nim-r2.txt")
        vendor_objects = {}
        for member, symbol in (("mfp.o", root), ("mfp_bip.o", "mfp_compute_bip")):
            raw = work / member
            raw.write_bytes(subprocess.check_output(["riscv64-unknown-elf-ar", "p", str(archive), member]))
            found = json.loads(run(["rabin2", "-sj", raw], member + ".symbols.json"))["symbols"]
            vendor, = [s for s in found if s["type"] == "FUNC" and s["name"] == symbol]
            run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0",
                 "-e", "bin.relocs.apply=true", "-c",
                 f'pD {vendor["size"]} @ {vendor["vaddr"]}', raw], member + ".r2.txt")
            vendor_objects[member] = {"sha256": sha(raw), "entry": vendor}
        report["vendor_entries"] = vendor_objects
        _, _, extracted_symbols = elf32(extracted)
        referenced = {entry[2] for entries in relocations.values() for entry in entries}
        undefined = {name for name, _, s in extracted_symbols if s[5] == 0 and name and name in referenced}
        _, _, sys_symbols = elf32(system)
        system_defined = {name for name, _, s in sys_symbols if s[3] & 15 == 2 and s[5] != 0}
        allowed = set(bindings.values()) | system_defined | {
            "memcpy", "memset", "memcmp", "nimZeroMem", "nimCopyMem", "__ashldi3", "__lshrdi3"}
        assert undefined <= allowed, sorted(undefined - allowed)
        libc_work = work / "libc"
        libc_work.mkdir(exist_ok=True)
        libc_keep = {"memcpy", "memset", "memcmp", "__ashldi3", "__lshrdi3"}
        raw_libc, libc_info, _ = extract_firmware_functions(libc, libc_keep, libc_work, run)
        bound_libc = libc_work / "bound.o"
        run(["riscv64-unknown-elf-objcopy", "--redefine-sym=memcpy=firmware_memcpy",
             raw_libc, bound_libc])
        assert section_hashes(raw_libc) == section_hashes(bound_libc)
        report["normal_libc"] = libc_info
        report["normal_libc"]["renamed_for_observation"] = {"memcpy": "firmware_memcpy"}
        (work / "bindings.h").write_text("".join(f'#define {k} "{v}"\n' for k, v in bindings.items()))
        report["bindings"] = bindings
        flags = ["-march=rv32imafc_zicsr", "-mabi=ilp32f", "-Os", "-fno-builtin",
                 "-ffunction-sections", "-fdata-sections"]
        run(["riscv64-unknown-elf-gcc", *flags, "-Wall", "-Wextra", "-Werror", "-I", work,
             f"-DFIXTURE_FAULT={int(args.fault)}", f"-DPROFILE_COUNT={PROFILE_COUNT}",
             "-c", c_source, "-o", work / "probe.o"])
        run(["riscv64-unknown-elf-gcc", *flags,
             "-Dwifi_rx_protected_probe_main=wifi_bip_tx_probe_main",
             "-Dwifi_rx_protected_probe_report=wifi_bip_tx_probe_report",
             "-Dwifi_rx_protected_trap_report=wifi_bip_tx_trap_report",
             "-c", "tools/wifi_rx_protected_oracle.S", "-o", work / "start.o"])
        elf = work / "probe.elf"
        run(["riscv64-unknown-elf-gcc", *flags[:2], "-nostdlib", "-nostartfiles", "-static",
             "-Wl,--gc-sections", "-T", "tools/wifi_console_format_probe.ld",
             work / "start.o", work / "probe.o", extracted, bound_libc, system, "-lgcc", "-o", elf])
        report["elf_sha256"] = sha(elf)
        linked = json.loads(run(["rabin2", "-sj", elf], "linked-symbols.json"))["symbols"]
        copied, sections, _ = elf32(raw_libc)
        section = sections[".text.memcpy"][1]
        original_memcpy = bytes(copied[section[4]:section[4] + section[5]])
        symbol, = [s for s in linked if s["name"] == "firmware_memcpy" and s["type"] == "FUNC"]
        linked_memcpy = elf.read_bytes()[symbol["paddr"]:symbol["paddr"] + symbol["size"]]
        assert original_memcpy == linked_memcpy
        report["normal_libc"]["linked_memcpy"] = {"size": len(linked_memcpy),
            "sha256": hashlib.sha256(linked_memcpy).hexdigest()}
        output = run([qemu, "-machine", "virt", "-cpu", "e907fdp", "-m", "32M", "-smp", "1",
                      "-bios", "none", "-nographic", "-monitor", "none", "-nic", "none",
                      "-kernel", elf], "qemu.log", False)
        report.update(parse_result(output, report["commands"][-1]["exit_code"], args.fault))
        print(output, end="")
        if not (report["passed"] or report["control_rejected"]):
            raise ValueError("BIP TX observation did not satisfy its selected contract/control")
    except Exception as error:
        report["error"] = str(error)
        print(f"BIP TX oracle failed: {error}")
    (work / "result.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return 0 if report["passed"] or report["control_rejected"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
