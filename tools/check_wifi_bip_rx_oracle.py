"""Run normal RV32 BIP/CMAC and RX identity code with production descriptor pools."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import shlex
import subprocess
import sys
from importlib.metadata import version

from check_wifi_mgt_indication_oracle import QEMU_SHA256, extract_firmware_functions, section_hashes
from check_wifi_rx_pipeline_oracle import elf32, elf_relocations
from check_wifi_tx_confirmation_oracle import ARCHIVE_SHA256, sha

ROOT = Path(__file__).resolve().parents[1]
FAULTS = ["none", "accept", "replay", "input", "stack"]
PROFILE_COUNT = 39


def parse_result(output: str, exit_code: int, profiles: int = PROFILE_COUNT, fault: str = "none") -> dict:
    incomplete = {"passed": False, "control_rejected": False, "status": "incomplete"}
    if not 1 <= profiles <= PROFILE_COUNT or fault not in FAULTS:
        return incomplete
    match = re.fullmatch(r"BIPRX RV32 (PASS|FAIL)((?: [0-9a-f]{8}){14}) *\n?", output)
    if match is None:
        return incomplete
    values = [int(v, 16) for v in match[2].split()]
    cases, checks, result, failure = values[:4]
    inputs, errors, touched = values[4:10], values[10:13], values[13]
    fields = {"passed": False, "control_rejected": False, "status": match[1],
              "cases": cases, "checks": checks, "result": result, "failure": failure,
              "last_inputs": inputs, "qemu_exit_code": exit_code, "unexpected": errors[0],
              "observer_error": errors[1], "error_flag": errors[2], "peak_stack_bytes_touched": touched}
    if any(errors) or not 0 < touched <= 2048 or touched % 4:
        return fields
    if fault == "none":
        fields["passed"] = (match[1] == "PASS" and exit_code == result == failure == 0
                            and cases == profiles * 304 and checks == cases * 12
                            and inputs == [profiles, 6, 2, 8, 16, 19])
    else:
        designated = {"accept": 3, "replay": 5, "input": 6, "stack": 11}[fault]
        fields["control_rejected"] = (match[1] == "FAIL" and cases == 1 and checks == designated
                                      and exit_code == result == failure == designated
                                      and inputs == [0, 4, 0, 0, 0, 0])
    return fields


def write_vectors(work: Path) -> int:
    from cryptography.hazmat.primitives import cmac
    from cryptography.hazmat.primitives.ciphers import algorithms

    check = cmac.CMAC(algorithms.AES(bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")))
    assert check.finalize().hex() == "bb1d6929e95937287fa37d129b756746"
    rng = random.Random(0xB1808525632)
    lengths = [44, 47, 64, 97, 1735, 1736, 1737, 1743, 1753, 1754, 1755, 1758, 1760, 2328]
    definitions, rows = [], []
    for fc, header in [(0xC0, 24), (0xD0, 24), (0x80D0, 28)]:
        for length in lengths:
            body = bytearray([5, 0, 255, 255, 0] if fc & 0xFC == 0xD0 else [3, 0])
            extra = length - header - len(body) - 18
            if extra < 0 or extra == 1:
                continue
            if extra % 2:
                body += bytes([221, 1, 77])
                extra -= 3
            body += bytes([221, 0]) * (extra // 2)
            prefix = bytearray(rng.randbytes(header))
            prefix[:2] = (fc | [0, 0x800, 0x1000, 0x2000][len(rows) % 4]).to_bytes(2, "little")
            prefix[4] |= 1
            prefix[22:24] = bytes(2)
            pn = [1, 255, 65535, 0x100000000, 0x010203040506, 0xFFFFFFFFFFFF][len(rows) % 6]
            for slot in [4, 5]:
                frame = prefix + body + bytes([76, 16]) + slot.to_bytes(2, "little") + pn.to_bytes(6, "little") + bytes(8)
                assert len(frame) == length
                aad = (int.from_bytes(frame[:2], "little") & 0xC7FF).to_bytes(2, "little") + frame[4:22]
                mac = cmac.CMAC(algorithms.AES(bytes(range(16))))
                mac.update(aad + frame[header:])
                frame[-8:] = mac.finalize()[:8]
                definitions.append(f'static const uint8_t data_{len(rows)}_{slot}[] = {{'
                                   + ",".join(str(b) for b in frame) + "};")
            rows.append(f'{{{length},{header},UINT64_C({pn}),{{data_{len(rows)}_4,data_{len(rows)}_5}}}}')
    assert len(rows) == PROFILE_COUNT
    (work / "vectors.h").write_text("\n".join(definitions) + "\nstatic const struct profile profiles[] = {\n"
                                    + ",\n".join(rows) + "\n};\n")
    return len(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wifi-object", type=Path, required=True)
    parser.add_argument("--system-object", type=Path, required=True)
    parser.add_argument("--libc-object", type=Path, default=ROOT / "build/nimcache_m0/@pbl808@skernel@sbaremetal_libc.c.o")
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--fault", choices=FAULTS, default="none")
    parser.add_argument("--archive", type=Path, default=ROOT / "tools/ref/libwifi_bl808.a")
    args = parser.parse_args()
    if not 0 <= args.limit <= PROFILE_COUNT:
        parser.error("limit is outside the corpus")
    profiles = args.limit or PROFILE_COUNT
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    obj, system, qemu, archive = [p.resolve() for p in [args.wifi_object, args.system_object, args.qemu, args.archive]]
    libc = args.libc_object.resolve()
    c_source, assembly = [Path(__file__).with_name(n) for n in ["wifi_bip_rx_oracle.c", "wifi_bip_rx_oracle.S"]]
    report = {"passed": False, "commands": [], "profiles": profiles, "fault": args.fault,
              "scope": "Normal compiled BIP/AES-CMAC and RX predicates; no actual DMA, interrupt arrival or full vendor equivalence",
              "models": ["completed RX pool contents", "observers around original memory primitives",
                         "console", "state changes at hash-work boundaries"],
              "stack_scope": "Canary bytes touched below the isolated policy call, not exact minimum SP or whole application headroom"}

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
        report["inputs"] = {str(p): sha(p) for p in [Path(__file__), c_source, assembly, obj, system, libc, qemu, archive,
            ROOT / "tools/check_wifi_mgt_indication_oracle.py", ROOT / "tools/check_wifi_rx_pipeline_oracle.py",
            ROOT / "tools/test_wifi_michael.py", ROOT / "tools/check_wifi_tx_confirmation_oracle.py",
            ROOT / "tools/wifi_rx_protected_oracle.S", ROOT / "tools/wifi_console_format_probe.ld"]}
        assert write_vectors(work) == PROFILE_COUNT
        report["reference_library"] = {"name": "cryptography", "version": version("cryptography"),
                                        "known_answer": "NIST AES-CMAC empty input"}
        report["vectors_sha256"] = sha(work / "vectors.h")
        _, _, symbols = elf32(obj)
        defined = {name for name, _, s in symbols if s[3] & 15 == 2 and s[5] not in [0, 0xfff1, 0xfff2]}
        def one(prefix):
            matches = [name for name, _, _ in symbols if name.startswith(prefix)]
            assert len(matches) == 1, (prefix, matches)
            return matches[0]
        root, capture = one("mfpIgnoreRxMgmtFrame__"), one("rxCaptureStation__")
        bindings = {macro: one(prefix) for macro, prefix in {
            "MFP_POLICY": "mfpIgnoreRxMgmtFrame__", "CAPTURE_STATION": "rxCaptureStation__",
            "ADMIT": "rxAdmitMpdu__",
            "UPLOAD_EPOCHS": "rxUploadEpochs__", "VIF_EPOCHS": "rxVifEpochs__",
            "STATION_EPOCHS": "staDeleteEpochs__", "KEY_CLOCK": "rxKeyRevision__",
            "KEY_CHANGES": "rxKeyLastChanged__", "ERROR_FLAG": "nimInErrorMode__"}.items()}
        sizes = {name: s[2] for name, _, s in symbols}
        _, _, sys_symbols = elf32(system)
        sizes.update({name: s[2] for name, _, s in sys_symbols if s[2]})
        expected_sizes = {"UPLOAD_EPOCHS": 164, "VIF_EPOCHS": 8, "STATION_EPOCHS": 20,
                          "KEY_CLOCK": 8, "KEY_CHANGES": 152, "ERROR_FLAG": 1}
        assert all(sizes[bindings[k]] == v for k, v in expected_sizes.items()), {
            k: [sizes[bindings[k]], v] for k, v in expected_sizes.items()}
        report["global_abi_sizes"] = {k: sizes[bindings[k]] for k in expected_sizes}
        pool_sizes = {"rx_dma_hdrdesc": 4100, "rx_payload_desc": 2132, "rx_swdesc_tab": 984,
                      "rx_payload_desc_buffer": 71176, "vif_info_tab": 3024, "sta_info_tab": 2576}
        assert all(sizes[n] == size for n, size in pool_sizes.items())
        report["pool_abi_sizes"] = {n: sizes[n] for n in pool_sizes}
        all_relocations = elf_relocations(obj, {".text." + n for n in defined})
        keep = {root, capture, bindings["ADMIT"]}
        while True:
            expanded = keep | {entry[2] for n in keep for entry in all_relocations.get(".text." + n, []) if entry[2] in defined}
            if expanded == keep:
                break
            keep = expanded
        extracted, extraction, relocations = extract_firmware_functions(obj, keep, work, run)
        report.update(extraction)
        libc_work = work / "libc"
        libc_work.mkdir(exist_ok=True)
        libc_keep = {"memcpy", "memset", "memcmp", "__ashldi3", "__lshrdi3"}
        raw_libc, libc_info, libc_relocations = extract_firmware_functions(libc, libc_keep, libc_work, run)
        bound_libc = libc_work / "bound.o"
        run(["riscv64-unknown-elf-objcopy", "--redefine-sym=memcpy=firmware_memcpy",
             "--redefine-sym=memset=firmware_memset", raw_libc, bound_libc])
        assert section_hashes(raw_libc) == section_hashes(bound_libc)
        assert libc_relocations == elf_relocations(bound_libc, set(libc_info["retained_text_sections_unchanged"]))
        report["normal_libc"] = libc_info
        report["normal_libc"]["renamed_for_observation"] = {"memcpy": "firmware_memcpy", "memset": "firmware_memset"}
        _, _, extracted_symbols = elf32(extracted)
        referenced = {entry[2] for entries in relocations.values() for entry in entries}
        undefined = {name for name, _, s in extracted_symbols if s[5] == 0 and name and name in referenced}
        _, _, sys_symbols = elf32(system)
        system_defined = {name for name, _, s in sys_symbols if s[3] & 15 == 2 and s[5] != 0}
        external = undefined - system_defined - libc_keep - {"nimZeroMem", "nimCopyMem"}
        assert external <= {bindings["ERROR_FLAG"]}, external
        (work / "bindings.h").write_text("".join(f'#define {k} "{v}"\n' for k, v in bindings.items()))
        (work / "entry.h").write_text(f"#define MFP_ENTRY {root}\n")
        report["bindings"] = bindings
        flags = ["-march=rv32imafc_zicsr", "-mabi=ilp32f", "-Os", "-fno-builtin",
                 "-ffunction-sections", "-fdata-sections", "-fstack-usage"]
        libgcc = Path(run(["riscv64-unknown-elf-gcc", *flags[:2], "-print-libgcc-file-name"]).strip())
        report["inputs"][str(libgcc)] = sha(libgcc)
        run(["riscv64-unknown-elf-gcc", *flags, "-Wall", "-Wextra", "-Werror", "-I", work,
             f"-DPROFILE_COUNT={profiles}", f"-DFIXTURE_FAULT={FAULTS.index(args.fault)}",
             "-c", c_source, "-o", work / "probe.o"])
        run(["riscv64-unknown-elf-gcc", *flags, "-I", work, "-c", assembly, "-o", work / "start.o"])
        elf = work / "probe.elf"
        run(["riscv64-unknown-elf-gcc", *flags[:2], "-nostdlib", "-nostartfiles", "-static", "-Wl,--gc-sections",
             "-T", "tools/wifi_console_format_probe.ld", work / "start.o", work / "probe.o",
             extracted, bound_libc, system, "-lgcc", "-o", elf])
        report["elf_sha256"] = sha(elf)
        linked = json.loads(run(["rabin2", "-sj", elf], "linked-symbols.json"))["symbols"]
        libc_data, libc_sections, _ = elf32(libc)
        linked_data = elf.read_bytes()
        aliases = {n: {"memcpy": "firmware_memcpy", "memset": "firmware_memset"}.get(n, n) for n in libc_keep}
        report["linked_normal_libc_bytes_unchanged"] = {}
        for name, alias in aliases.items():
            symbol, = [s for s in linked if s["name"] == alias and s["type"] == "FUNC"]
            section = libc_sections[".text." + name][1]
            before = bytes(libc_data[section[4]:section[4] + section[5]])
            after = linked_data[symbol["paddr"]:symbol["paddr"] + symbol["size"]]
            assert before == after, (name, "linked helper differs from normal object")
            report["linked_normal_libc_bytes_unchanged"][name] = {
                "linked_symbol": alias, "bytes": len(after), "sha256": hashlib.sha256(after).hexdigest()}
        metadata = json.loads(run(["rabin2", "-sj", obj], "nim-symbols.json"))["symbols"]
        roots = [s for s in metadata if s["type"] == "FUNC" and s["name"] in keep]
        assert {s["name"] for s in roots} == keep
        run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0", "-e", "bin.relocs.apply=true", "-c",
             "; ".join(f'pD {s["size"]} @ {s["vaddr"]}' for s in roots), obj], "nim-r2.txt")
        run(["/opt/homebrew/opt/llvm/bin/llvm-objdump", "-dr", "--no-show-raw-insn",
             "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov",
             *["--section=.text." + n for n in sorted(keep)], obj], "nim-llvm.txt")
        run(["/opt/homebrew/opt/llvm/bin/llvm-objdump", "-dr", "--no-show-raw-insn",
             *["--section=.text." + n for n in sorted(libc_keep)], libc], "libc-llvm.txt")
        for member, entry in [("mfp.o", "mfp_ignore_mgmt_frame"), ("mfp_bip.o", "mfp_compute_bip")]:
            raw = work / ("vendor-" + member)
            raw.write_bytes(subprocess.check_output(["riscv64-unknown-elf-ar", "p", str(archive), member]))
            symbols_meta = json.loads(run(["rabin2", "-sj", raw]))["symbols"]
            r, = [s for s in symbols_meta if s["type"] == "FUNC" and s["name"] == entry]
            run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0", "-e", "bin.relocs.apply=true", "-c",
                 f'pD {r["size"]} @ {r["vaddr"]}', raw], "vendor-" + member + "-r2.txt")
            run(["/opt/homebrew/opt/llvm/bin/llvm-objdump", "-dr", "--no-show-raw-insn",
                 "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov",
                 "--section=.text." + entry, raw], "vendor-" + member + "-llvm.txt")
        output = run([qemu, "-machine", "virt", "-cpu", "e907fdp", "-m", "32M", "-smp", "1", "-bios", "none",
                      "-nographic", "-monitor", "none", "-nic", "none", "-kernel", elf], "qemu.log", False)
        result = parse_result(output, report["commands"][-1]["exit_code"], profiles, args.fault)
        report.update(result)
        print(output, end="")
        if not (result["passed"] or result["control_rejected"]):
            raise ValueError("BIP observation did not satisfy the selected corpus/control")
    except Exception as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report.get("passed") or report.get("control_rejected") else 1


if __name__ == "__main__":
    raise SystemExit(main())
