"""Run normal compiled RX through MIC/replay, decapsulation and host/queue handoff."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import shlex
import struct
import subprocess
import sys

from test_wifi_michael import VECTORS, michael
from check_wifi_tx_confirmation_oracle import ARCHIVE_SHA256, sha

ROOT = Path(__file__).resolve().parents[1]

def elf32(path):
    data = bytearray(Path(path).read_bytes())
    header = struct.Struct("<16sHHIIIIIHHHHHH").unpack_from(data)
    assert header[0][:7] == b"\x7fELF\x01\x01\x01" and header[1:3] == (1, 243)
    offset, size, count, names = header[6], header[11], header[12], header[13]
    assert size == 40 and count and names < count
    sections = [struct.unpack_from("<10I", data, offset + i * size) for i in range(count)]
    name_bytes = data[sections[names][4]:sections[names][4] + sections[names][5]]
    def string(table, at):
        end = table.index(0, at)
        return bytes(table[at:end]).decode()
    named = {string(name_bytes, section[0]): (i, section) for i, section in enumerate(sections)}
    table = named[".symtab"][1]
    assert table[9] == 16
    strings = sections[table[6]]
    strings = data[strings[4]:strings[4] + strings[5]]
    symbols = []
    for at in range(table[4], table[4] + table[5], 16):
        value = struct.unpack_from("<IIIBBH", data, at)
        symbols.append((string(strings, value[0]), at, value))
    return data, named, symbols

def elf_relocations(path: Path, owners: set[str]) -> dict:
    data, named, symbols = elf32(path)
    by_index = {index: name for name, (index, _) in named.items()}
    result = {}
    for _, (_, section) in named.items():
        if section[1] not in [4, 9] or by_index[section[7]] not in owners:
            continue
        assert section[9] == (12 if section[1] == 4 else 8)
        entries = []
        for at in range(section[4], section[4] + section[5], section[9]):
            offset, info = struct.unpack_from("<II", data, at)
            addend = struct.unpack_from("<i", data, at + 8)[0] if section[1] == 4 else None
            name, _, symbol = symbols[info >> 8]
            if not name and symbol[5] in by_index:
                name = by_index[symbol[5]]
            entries.append((offset, info & 255, name, symbol[1], addend))
        result[by_index[section[7]]] = entries
    return result


def parse_result(output: str, exit_code: int, profiles: int = 490, fault: str = "none",
                 role: str = "sta", corpus: str = "msdu") -> dict:
    incomplete = {"passed": False, "control_rejected": False, "status": "incomplete"}
    if (role not in ["sta", "ap"] or corpus not in ["msdu", "amsdu"]
            or not 1 <= profiles <= (336 if corpus == "amsdu" else {"sta": 490, "ap": 560}[role])
            or fault not in ["none", "key", "chain", "counter", "packet", "destination", "context", "aggregate"]
            or (role != "ap" and fault in ["destination", "context"])
            or (corpus == "amsdu" and fault in ["key", "chain", "context"])
            or (corpus != "amsdu" and fault == "aggregate")):
        return incomplete
    match = re.fullmatch(r"RXPIPE RV32 (PASS|FAIL)((?: [0-9a-f]{8}){12}) *\n?", output)
    if match is None:
        return incomplete
    cases, checks, result, failure, profile, cipher, stage, mode, extra, unexpected, callback_error, error_flag = (
        int(v, 16) for v in match[2].split())
    fields = {"passed": False, "control_rejected": False, "status": match[1],
              "cases": cases, "checks": checks, "result": result, "failure": failure,
              "last_inputs": [profile, cipher, stage, mode, extra], "qemu_exit_code": exit_code,
              "unexpected": unexpected, "callback_error": callback_error, "error_flag": error_flag}
    expected_callback_error = int(role == "ap" and fault == "context")
    if unexpected or error_flag or callback_error != expected_callback_error:
        return fields
    eapol_profiles = sum(i % 5 == 1 for i in range(profiles))
    expected_cases = (profiles * 6 + eapol_profiles) * 128
    if role == "ap":
        expected_cases += eapol_profiles * 48
    expected_checks = expected_cases * (15 if role == "ap" else 13) + (profiles - eapol_profiles) * 304
    if role == "ap":
        expected_checks += eapol_profiles * 68
    if corpus == "amsdu":
        wds_profiles = sum((index // 84) % 2 == 1 for index in range(profiles))
        expected_cases = profiles * 512
        expected_checks = expected_cases * (15 if role == "ap" else 13) + profiles * 168 + wds_profiles * 8
    if fault == "none":
        ending = [profiles, 2, 6, 0, 0x80302] if role == "ap" and (profiles - 1) % 5 == 1 else [profiles, 3, 6, 2, 0x80303]
        if corpus == "amsdu":
            ending = [profiles, 2, 23, 0, 0x8030f]
        fields["passed"] = (match[1] == "PASS" and exit_code == result == failure == 0
            and cases == expected_cases and checks == expected_checks
            and fields["last_inputs"] == ending)
    else:
        expected = {"key": (1, 3, [0, 1, 1, 0, 0]),
                    "chain": (15873, 3, [20, 1, 1, 0, 0]),
                    "counter": (1, 9, [0, 1, 1, 0, 0]),
                    "packet": (0, 12, [0, 1, 0, 0, 0]),
                    "destination": (1, 10, [0, 1, 1, 0, 0]),
                    "context": (769, 1, [1, 1, 1, 0, 0]),
                    "aggregate": (4, 10, [0, 2, 4, 0, 0])}[fault]
        if role == "ap" and fault == "chain":
            expected = (16065, 3, [20, 1, 1, 0, 0])
        if corpus == "amsdu":
            expected = {"counter": (4, 9, [0, 2, 4, 0, 0]),
                        "packet": (0, 12, [0, 2, 0, 0, 0]),
                        "destination": (4, 10, [0, 2, 4, 0, 0]),
                        "aggregate": (4, 10, [0, 2, 4, 0, 0])}[fault]
        fields["control_rejected"] = (match[1] == "FAIL" and result != 0
            and exit_code == (result & 255) and cases == expected[0]
            and failure == expected[1] and fields["last_inputs"] == expected[2])
    return fields


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wifi-object", type=Path, required=True)
    parser.add_argument("--system-object", type=Path, required=True)
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--role", choices=["sta", "ap"], default="sta")
    parser.add_argument("--corpus", choices=["msdu", "amsdu"], default="msdu")
    parser.add_argument("--archive", type=Path, default=ROOT / "tools/ref/libwifi_bl808.a")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--fault", choices=["none", "key", "chain", "counter", "packet", "destination", "context", "aggregate"], default="none")
    args = parser.parse_args()
    if args.role != "ap" and args.fault in ["destination", "context"]:
        parser.error("destination/context controls require --role ap")
    if args.corpus == "amsdu" and args.fault in ["key", "chain", "context"]:
        parser.error("key/chain/context controls require the msdu corpus")
    if args.corpus != "amsdu" and args.fault == "aggregate":
        parser.error("aggregate control requires --corpus amsdu")
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    obj = args.wifi_object.resolve()
    system = args.system_object.resolve()
    qemu = args.qemu.resolve()
    c_source = Path(__file__).with_name("wifi_rx_pipeline_oracle.c")
    report = {"passed": False, "commands": [], "profile_limit": args.limit, "fault": args.fault, "role": args.role,
              "corpus": args.corpus,
              "scope": "Actual RV32 data RX pipeline for selected current-session inputs; no radio/DMA or full vendor-dispatcher equivalence",
              "models": ["session/descriptor/key-current predicates", "DMA transfer completion",
                         "logging", "memory functions and allocation", "MIC-failure message transport",
                         "EAPOL callback", "scheduler event notification", "Nim error flag"]}
    if args.role == "ap":
        report["models"].append("MAC address-search result; WPA host callback")

    def run(command, output=None, check=True):
        command = [str(p) for p in command]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=360)
        report["commands"].append({"command": shlex.join(command), "exit_code": result.returncode,
                                  "stdout": result.stdout, "stderr": result.stderr})
        if output:
            (work / output).write_text(result.stdout)
            (work / (output + ".stderr")).write_text(result.stderr)
        if check and result.returncode: raise RuntimeError(result.stderr)
        return result.stdout

    def section_hashes(path):
        data, named, _ = elf32(path)
        return {name: {"size": s[5], "sha256": hashlib.sha256(data[s[4]:s[4] + s[5]]).hexdigest()}
                for name, (_, s) in named.items() if name.startswith(".text.")}

    def vectors():
        for key, message, answer in VECTORS:
            assert michael(bytes.fromhex(key), message).hex() == answer
        rng = random.Random(0x8085258504950)
        rows, definitions = [], []
        def literal(data): return "{" + ",".join(str(v) for v in data) + "}"
        if args.corpus == "amsdu":
            frames = [0x4188, 0x4388, 0xC188, 0xC388] if args.role == "ap" else [0x4288, 0x4388, 0xC288, 0xC388]
            lengths = [1, 7, 8, 9, 10, 11, 12, 31, 64, 1680, 1681, 1682, 1683, 2304]
            frame_lengths = []
            for fc in frames:
                for group in [False, True]:
                    for count in [1, 2, 3]:
                        for first_length in lengths:
                            index = len(rows)
                            tid, keyid = [0, 3, 7][index % 3], index % 4
                            a1, a2 = bytes([2,1,2,3,4,5]), bytes([4,6,7,8,9,10])
                            a3, a4 = bytes([6,11,12,13,14,15]), bytes([8,16,17,18,19,20])
                            da = a3 if fc & 0x100 else a1
                            sa = a4 if fc & 0x300 == 0x300 else a3 if fc & 0x200 else a2
                            data, last = bytearray(), 0
                            for subframe in range(count):
                                last = len(data)
                                length = first_length if subframe == 0 else 2304
                                inner_da = bytes.fromhex("01005e000001") if group else da
                                payload = bytearray(rng.randbytes(length))
                                if length >= 8:
                                    payload[:8] = [b"\xaa\xaa\x03\x00\x00\x00\x08\x00",
                                                   b"\xaa\xaa\x03\x00\x00\xf8\x80\xf3",
                                                   b"\xe0\xe0\x03\x00\x00\x00\x00\x00"][subframe % 3]
                                data += inner_da + sa + length.to_bytes(2, "big") + payload
                                if subframe + 1 < count:
                                    data += b"\xdd" * (-len(data) % 4)
                            definitions.append(f"static const uint8_t payload_{index}[] = {literal(data)};")
                            frame_lengths.append(len(data) + (30 if fc & 0x300 == 0x300 else 24)
                                                 + (6 if fc & 0x8000 else 2) + 8)
                            material, mic = rng.randbytes(8), bytes(8)
                            destination = [0,1,2,3,4,5,6,255][index % 8] if args.role == "ap" else 255
                            rows.append("{" + f"{fc},{len(data)},{tid},{keyid},0,5,{index % 7},{index % 2},"
                                        + ",".join(literal(v) for v in [a1,a2,a3,a4,da,sa,material,mic,da,mic])
                                        + f",{last},{destination},payload_{index}" + "}")
            assert len(rows) == 336
            report["aggregate_max_frame_bytes"] = max(frame_lengths)
            (work / "vectors.h").write_text("\n".join(definitions) + "\nstatic const struct Profile profiles[] = {\n"
                                           + ",\n".join(rows) + "\n};\n")
            return len(rows)
        frames = [0x4108, 0x4188, 0x4388, 0xC388] if args.role == "ap" else [0x4208, 0x4288, 0x4388, 0xC288]
        for fc in frames:
            mac = (30 if fc & 0x300 == 0x300 else 24) + (
                (2 + (4 if fc & 0x8000 else 0)) if fc & 0x80 else 0)
            header = mac + 8
            for group in [False, True]:
                if args.role == "sta" and group and fc & 0x300 == 0x300: continue
                for length in [12, 31, 64, *range(1736 - header - 8, 1736 - header + 2), 2304]:
                    for protocol in range(5):
                        index = len(rows)
                        tid = [0, 3, 7][index % 3] if fc & 0x80 else 0
                        keyid = index % 4
                        data = bytearray(rng.randbytes(length))
                        if protocol < 4:
                            etype = [0x0800, 0x888E, 0x80F3, 0x8137][protocol]
                            data[:8] = b"\xaa\xaa\x03\x00\x00" + bytes([0xF8 if protocol >= 2 else 0]) + etype.to_bytes(2, "big")
                            if protocol == 1: data[8:12] = b"\x02\x03" + (length - 12).to_bytes(2, "big")
                        else:
                            data[:3] = b"\xe0\xe0\x03"
                        a1 = bytes([2,1,2,3,4,5])
                        a2 = bytes([4,6,7,8,9,10])
                        a3 = bytes([6,11,12,13,14,15])
                        a4 = bytes([8,16,17,18,19,20])
                        if group and args.role == "sta":
                            a1 = bytes.fromhex("0180c2000003" if protocol == 1 else "01005e000001")
                        if args.role == "ap" and group:
                            a3 = bytes.fromhex("0180c2000003" if protocol == 1 else "01005e000001")
                        elif fc & 0x100 and protocol == 1:
                            a3 = a1
                        da = a3 if fc & 0x100 else a1
                        sa = a4 if fc & 0x300 == 0x300 else a3 if fc & 0x200 else a2
                        material = rng.randbytes(8)
                        mic = michael(material, da + sa + bytes([tid,0,0,0]) + data)
                        foreign_da = bytes.fromhex("01005e000009") if group else bytes([10,1,2,3,4,5])
                        foreign_mic = michael(material, foreign_da + sa + bytes([tid,0,0,0]) + data)
                        definitions.append(f"static const uint8_t payload_{index}[] = {literal(data)};")
                        key_group = group and args.role == "sta"
                        destination = [0, 1, 2, 3, 4, 5, 6, 255][index % 8] if args.role == "ap" and protocol != 1 else 255
                        rows.append("{" + f"{fc},{length},{tid},{keyid},{int(key_group)},{protocol},{index % 7},{index % 2},"
                                    + ",".join(literal(v) for v in [a1,a2,a3,a4,da,sa,material,mic,foreign_da,foreign_mic])
                                    + f",0,{destination},payload_{index}" + "}")
        assert len(rows) == (560 if args.role == "ap" else 490)
        (work / "vectors.h").write_text("\n".join(definitions) + "\nstatic const struct Profile profiles[] = {\n"
                                       + ",\n".join(rows) + "\n};\n")
        return len(rows)

    try:
        expected_qemu_sha = "4b288a5a52c1eb1878c76487a135e97270c3813836c998896640e5b123bb75f9"
        actual_qemu_sha = sha(qemu)
        if actual_qemu_sha != expected_qemu_sha:
            raise ValueError(
                f"QEMU SHA-256 mismatch for {qemu}: "
                f"expected {expected_qemu_sha}, got {actual_qemu_sha}")
        report["inputs"] = {str(p): sha(p) for p in [
            Path(__file__), c_source, obj, system, qemu,
            ROOT / "tools/test_wifi_michael.py", ROOT / "tools/wifi_rx_protected_oracle.S",
            ROOT / "tools/check_wifi_tx_confirmation_oracle.py",
            ROOT / "tools/wifi_console_format_probe.ld"]}
        profile_count = vectors()
        if not 0 <= args.limit <= profile_count:
            raise ValueError(
                f"profile limit must be 0..{profile_count} for "
                f"{args.role} {args.corpus}; got {args.limit}")
        tested_profiles = args.limit or profile_count
        data, named, symbols = elf32(obj)
        defined = {name for name, _, s in symbols if s[3] & 15 == 2 and s[5] not in [0,0xfff1,0xfff2]}
        keep = {"rxu_cntrl_frame_handle", "rxu_cntrl_machdr_len_get", "rxu_cntrl_protected_handle",
                "mfp_is_robust_frame",
                "rxu_cntrl_check_pn", "replay_counter_validate", "michael_block",
                "me_mic_init", "me_mic_calc", "me_mic_end", "rxu_cntrl_desc_prepare", "co_list_push_back"}
        if args.role == "ap":
            keep.add("apm_handle_eapol_input")
        assert keep <= defined
        prefixes = ["rxMacHeaderLen__", "rxuPnFresh__", "rxuCopyFrameBytes__", "rxuPortAllows__",
                    "rxuAmsduValid__", "rxCopyAddr__", "rxSnapIsRfc1042__", "rxSnapPrefixIs__",
                    "rxSnapTraceLo__", "rxSnapTraceHi__", "rxSnapIsBridgeTunnel__",
                    "rxuTraceProtectedSlot__", "rxuProtectedKey__", "pointerAddrU32__",
                    "lmacGateHalfword__", "contains__"]
        keep |= {name for name in defined if any(name.startswith(prefix) for prefix in prefixes)}
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
                if s[1] not in [4,9] or s[7] not in retained: continue
                for at in range(s[4], s[4] + s[5], s[9]):
                    info = struct.unpack_from("<I", data, at + 4)[0]
                    index = symbols[info >> 8][2][5]
                    if 0 < index < 0xff00:
                        assert not by_index[index][0].startswith(".text.") or index in previous
                        retained.add(index)
            if retained == previous: break
        selected = [by_index[i][0] for i in sorted(retained)]
        selected += [name for name, (_, s) in named.items() if s[1] in [4,9] and s[7] in retained]
        extracted = work / "pipeline.o"
        run(["/opt/homebrew/opt/llvm/bin/llvm-objcopy", "--keep-symbols=" + str(names),
             *["--only-section=" + name for name in selected], metadata_only, extracted])
        original, actual = section_hashes(obj), section_hashes(extracted)
        assert set(actual) == {".text." + name for name in keep}
        assert all(original[name] == digest for name, digest in actual.items())
        report["retained_text_sections_unchanged"] = actual
        report["retained_data_sections"] = [by_index[i][0] for i in sorted(retained) if not by_index[i][0].startswith(".text.")]
        owners = set(actual) | set(report["retained_data_sections"])
        relocations = elf_relocations(obj, owners)
        assert relocations == elf_relocations(extracted, owners)
        assert len(relocations[".text.rxu_cntrl_frame_handle"]) > 800
        report["relocations_unchanged"] = {name: len(entries) for name, entries in relocations.items()}
        report["relocations_sha256"] = hashlib.sha256(json.dumps(relocations, sort_keys=True).encode()).hexdigest()
        _, _, symbols = elf32(extracted)
        undefined = {name for name, _, s in symbols if s[5] == 0 and name}
        _, _, sys_symbols = elf32(system)
        system_defined = {name for name, _, s in sys_symbols if s[3] & 15 == 2 and s[5] != 0}
        patterns = {"STATION_CURRENT": "rxStationCurrent__", "MPDU_HEADER": "rxMpduHeader__",
                    "UPLOAD_GENERATION": "rxUploadGeneration__", "UPLOAD_CURRENT": "rxUploadCurrent__",
                    "KEY_CURRENT": "rxKeyCurrent__", "TRANSFER": "rxTransferFrame__",
                    "ERROR_FLAG": "nimInErrorMode__"}
        bindings = {}
        for macro, prefix_name in patterns.items():
            matches = [name for name in undefined if name.startswith(prefix_name)]
            assert len(matches) == 1, (macro, matches)
            bindings[macro] = matches[0]
        special = set(bindings.values()) | system_defined | {
            "ke_state_get", "nimZeroMem", "nimCopyMem", "memcpy", "memset", "memcmp",
            "g_bl_ops_funcs", "ke_evt_set", "sm_handle_eapol_input", "ke_msg_alloc", "ke_msg_send",
            "hal_machw_search_addr"}
        aliases = []
        for index, name in enumerate(sorted(undefined - special)):
            target = "diagnostic_model" if name.startswith(("nimFwDbg", "nimFwTrace", "nimFwConnectTrace")) else "unexpected_model"
            if target == "unexpected_model":
                aliases.append(f'uintptr_t stub_{index}(void) __asm__("{name}"); '
                               f'uintptr_t stub_{index}(void) {{ unexpected = {index+1}; return 0; }}')
            else:
                aliases.append(f'uintptr_t stub_{index}(void) __asm__("{name}") __attribute__((alias("{target}")));')
        (work / "bindings.h").write_text("".join(f'#define {k} "{v}"\n' for k,v in bindings.items()) + "\n".join(aliases) + "\n")
        report["bindings"] = bindings
        report["unexpected_callee_aliases"] = [name for name in sorted(undefined - special)
            if not name.startswith(("nimFwDbg", "nimFwTrace", "nimFwConnectTrace"))]
        report["profiles"] = tested_profiles
        if args.corpus == "amsdu":
            report["aggregate_admission_cases"] = tested_profiles * 128
        if args.role == "ap":
            eapol_profiles = sum(i % 5 == 1 for i in range(tested_profiles))
            if args.corpus == "amsdu":
                eapol_profiles = 0
            report["ap_wrapper_guard_cases"] = eapol_profiles * 20
            report["vendor_wrapper_comparisons"] = eapol_profiles * 4
            report["plaintext_eapol_cases"] = eapol_profiles * 48
        flags = ["-march=rv32imafc_zicsr", "-mabi=ilp32f", "-Os", "-fno-builtin", "-ffunction-sections", "-fdata-sections"]
        fault = ["none", "key", "chain", "counter", "packet", "destination", "context", "aggregate"].index(args.fault)
        run(["riscv64-unknown-elf-gcc", *flags, "-Wall", "-Wextra", "-Werror", "-I", work,
             f"-DPROFILE_COUNT={tested_profiles}", f"-DFIXTURE_FAULT={fault}", f"-DAP_MODE={int(args.role == 'ap')}",
             f"-DAMSDU_MODE={int(args.corpus == 'amsdu')}",
             "-c", c_source, "-o", work / "probe.o"])
        run(["riscv64-unknown-elf-gcc", *flags, "-Dwifi_rx_protected_probe_main=wifi_pipeline_probe_main",
             "-Dwifi_rx_protected_probe_report=wifi_pipeline_probe_report",
             "-Dwifi_rx_protected_trap_report=wifi_pipeline_trap_report",
             "-c", "tools/wifi_rx_protected_oracle.S", "-o", work / "start.o"])
        elf = work / "probe.elf"
        vendor_objects = []
        if args.role == "ap":
            archive = args.archive.resolve()
            assert sha(archive) == ARCHIVE_SHA256
            report["inputs"][str(archive)] = sha(archive)
            raw, prefixed, vendor = [work / name for name in ["apm.o", "prefixed-apm.o", "vendor-apm.o"]]
            raw.write_bytes(subprocess.check_output(["riscv64-unknown-elf-ar", "p", str(archive), "apm.o"]))
            run(["riscv64-unknown-elf-objcopy", "--prefix-symbols=vendor_", raw, prefixed])
            run(["riscv64-unknown-elf-objcopy", "--redefine-sym=vendor_apm_env=apm_env",
                 "--redefine-sym=vendor_sta_info_tab=sta_info_tab", "--redefine-sym=vendor_wpa_cbs=wpa_cbs",
                 prefixed, vendor])
            vendor_sections = section_hashes(raw)
            assert vendor_sections == section_hashes(prefixed) == section_hashes(vendor)
            report["vendor_text_sections_unchanged"] = vendor_sections
            vendor_objects.append(vendor)
        run(["riscv64-unknown-elf-gcc", *flags[:2], "-nostdlib", "-nostartfiles", "-static", "-Wl,--gc-sections",
             "-T", "tools/wifi_console_format_probe.ld", work / "start.o", work / "probe.o",
             extracted, system, *vendor_objects, "-lgcc", "-o", elf])
        report["elf_sha256"] = sha(elf)
        metadata = json.loads(run(["rabin2", "-sj", obj], "nim-symbols.json"))["symbols"]
        roots = [s for s in metadata if s["type"] == "FUNC" and s["name"] in keep]
        run(["r2", "-q", "-e", "scr.color=0", "-e", "scr.utf8=0", "-e", "bin.relocs.apply=true", "-c",
             "; ".join(f'pD {s["size"]} @ {s["vaddr"]}' for s in roots), obj], "nim-r2.txt")
        run(["/opt/homebrew/opt/llvm/bin/llvm-objdump", "-dr", "--no-show-raw-insn",
             "--mattr=+xtheadmemidx,+xtheadbb,+xtheadba,+xtheadmac,+xtheadmempair,+xtheadcondmov",
             *["--section=.text." + name for name in sorted(keep)], obj], "nim-llvm.txt")
        output = run([qemu, "-machine", "virt", "-cpu", "e907fdp", "-m", "32M", "-smp", "1", "-bios", "none",
                      "-nographic", "-monitor", "none", "-nic", "none", "-kernel", elf], "qemu.log", False)
        code = report["commands"][-1]["exit_code"]
        result = parse_result(output, code, tested_profiles, args.fault, args.role, args.corpus)
        report.update(result)
        if not (result["passed"] or result["control_rejected"]):
            raise ValueError("RX pipeline result did not satisfy the selected profile/control contract")
        print(output, end="")
    except Exception as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report.get("passed") or report.get("control_rejected") else 1


if __name__ == "__main__":
    raise SystemExit(main())
