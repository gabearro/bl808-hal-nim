#!/usr/bin/env python3
"""Validate pure-Nim RF/PHY symbol provenance for BL808 builds."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


WIFI_RF_SYMBOLS = [
    "wl_init",
    "wl_cfg_get",
    "wl_rf_cfg_init",
    "wl_rmem_size_get",
    "wl_env_get",
    "rf_init",
    "rfc_init",
    "rfc_config_bandwidth",
    "rfc_config_channel",
    "modem_init_core",
    "modem_init",
    "modem_restore",
    "rf_dump_status",
    "phy_init",
    "phy_get_mac_freq",
    "phy_get_version",
    "phy_get_channel",
    "phy_mdm_isr",
    "phy_rc_isr",
    "phy_get_ntx",
    "phy_get_nss",
    "phy_get_nrx",
    "phy_get_bw",
    "phy_vht_supported",
    "phy_he_supported",
    "phy_uf_supported",
    "phy_uf_enable",
    "phy_ldpc_tx_supported",
    "phy_ldpc_rx_supported",
    "phy_bfmee_supported",
    "phy_bfmer_supported",
    "phy_mu_mimo_rx_supported",
    "phy_mu_mimo_tx_supported",
    "phy_get_rf_gain_idx",
    "phy_get_rf_gain_capab",
    "phy_get_antenna_set",
    "phy_switch_antenna_paths",
    "phy_get_channel_switch_dur",
    "phy_stop",
    "phy_mdm_reset",
    "phy_set_aid",
    "phy_set_group_id_info",
    "phy_update_power_table",
    "phy_set_channel",
    "phy_powroffset_set",
    "trpc_power_get",
    "trpc_update_power_11b",
    "trpc_update_power_11g",
    "trpc_update_power_11n",
    "trpc_update_power_11ac",
    "trpc_update_power_11ax",
    "trpc_update_power",
    "trpc_init",
    "trpc_get_default_power_idx",
    "trpc_get_power_idx",
    "rf_pri_init",
    "rf_pri_input_xtalfreq",
    "rf_pri_config_mode",
    "rf_pri_input_device_info",
    "rf_pri_update_param",
    "rf_pri_get_notch_param",
    "rf_pri_optimize",
    "rf_pri_set_channel_pwr_comp",
    "rf_pri_set_bandwidth",
    "rf_pri_get_vco_freq_cw",
    "rf_pri_get_vco_idac_cw",
]

FORBIDDEN_RF_ARCHIVE_MARKERS = [
    "src/bl808/librf_bl808.a",
    "librf_bl808.a",
    "build/bl_iot_sdk_b773b3f/components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a",
    "libbl606p_phyrf.a",
    "bl606p_phyrf",
]

BLE_RF_SYMBOLS = [
    "btble_rf_init",
    "ble_rf_init",
    "ble_rf_set_pwr_offset_table",
    "ble_rf_get_pwr_offset",
    "ble_rf_set_tx_channel",
    "rf_txpwr_dbm2cs",
    "rf_txpwr_cs2dbm",
    "rwip_wlcoex_set",
    "nim_ble_coex_wifi_tx_window_enter",
    "nim_ble_coex_wifi_tx_window_leave",
    "nim_ble_coex_wifi_rf_reclaim_needed",
]

HW_VALIDATION_OBJECTS = [
    ("wifi", "@pbl808@swifi_fw.nim.c.o", WIFI_RF_SYMBOLS),
    ("ble", "@pbl808@sblecontroller.nim.c.o", BLE_RF_SYMBOLS),
]


def inferred_hw_validation_labels(elf: Path) -> set[str]:
    """Infer which Nim RF provenance objects should exist for a hw test ELF."""
    test_name = elf.parent.name
    labels: set[str] = set()
    if "wifi" in test_name:
        labels.add("wifi")
    if "ble" in test_name:
        labels.add("ble")
    return labels


def nm(path: Path, *extra: str) -> str:
    return subprocess.check_output(
        ["riscv64-unknown-elf-nm", *extra, str(path)],
        text=True,
        errors="ignore",
    )


def defined_text_symbols(path: Path) -> set[str]:
    out: set[str] = set()
    for line in nm(path, "-g", "--defined-only").splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[-2] in {"T", "t"}:
            out.add(parts[-1])
    return out


def undefined_symbols(path: Path) -> set[str]:
    out: set[str] = set()
    for line in nm(path, "-u").splitlines():
        parts = line.split()
        if parts:
            out.add(parts[-1])
    return out


def require_existing(path: Path, label: str) -> None:
    if not path.exists():
        raise SystemExit(f"{label} not found: {path}")


def check_defined(path: Path, symbols: list[str], label: str) -> list[str]:
    have = defined_text_symbols(path)
    missing = [symbol for symbol in symbols if symbol not in have]
    if missing:
        print(f"{label}: missing defined text symbols: {', '.join(missing)}")
    else:
        print(f"{label}: defines {', '.join(symbols)}")
    return missing


def check_not_undefined(path: Path, symbols: list[str], label: str) -> list[str]:
    unresolved = undefined_symbols(path)
    bad = [symbol for symbol in symbols if symbol in unresolved]
    if bad:
        print(f"{label}: unresolved RF/PHY symbols: {', '.join(bad)}")
    else:
        print(f"{label}: no unresolved RF/PHY symbols")
    return bad


def check_elf_defined(
    path: Path, symbols: list[str], label: str, required: bool
) -> list[str]:
    have = defined_text_symbols(path)
    present = [symbol for symbol in symbols if symbol in have]
    missing = [symbol for symbol in symbols if symbol not in have]
    if present:
        print(f"{label}: defines retained RF/PHY symbols: {', '.join(present)}")
    if missing:
        print(f"{label}: RF/PHY symbols not retained in ELF: {', '.join(missing)}")
    return missing if required else []


def check_build_log(path: Path) -> list[str]:
    text = path.read_text(errors="ignore")
    found = [marker for marker in FORBIDDEN_RF_ARCHIVE_MARKERS if marker in text]
    if found:
        print(f"{path}: forbidden RF archive reference: {', '.join(found)}")
    else:
        print(f"{path}: no forbidden BL808 RF archive references")
    return found


def check_link_map(path: Path) -> list[str]:
    """Reject RF archive members actually extracted into the final link."""
    failures: list[str] = []
    for line in path.read_text(errors="ignore").splitlines():
        stripped = line.strip()
        for marker in FORBIDDEN_RF_ARCHIVE_MARKERS:
            if marker not in stripped:
                continue
            if ".a(" not in stripped or ")" not in stripped:
                continue
            failures.append(stripped)
            print(f"{path}: forbidden RF archive member in link map: {stripped}")
    if not failures:
        print(f"{path}: no RF archive members extracted in link map")
    return failures


THEAD_MATTR = (
    "+xtheadba,+xtheadbb,+xtheadbs,+xtheadcmo,+xtheadcondmov,"
    "+xtheadfmemidx,+xtheadmac,+xtheadmemidx,+xtheadmempair,+xtheadsync"
)


def llvm_objdump_cmd() -> str:
    env_cmd = os.environ.get("LLVM_OBJDUMP")
    if env_cmd:
        return env_cmd
    return (
        shutil.which("llvm-objdump")
        or "/opt/homebrew/opt/llvm/bin/llvm-objdump"
    )


def check_wifi_phy_memory_init(archive: Path) -> list[str]:
    """Validate WiFi PHY memory init uses AGC RAM only, not BLE LDPC RAM."""
    failures: list[str] = []
    symbols = subprocess.check_output(
        ["riscv64-unknown-elf-objdump", "-t", str(archive)],
        text=True,
        errors="ignore",
    ).lower()
    if "agcmem" not in symbols:
        print(f"{archive}: missing agcmem symbol")
        failures.append(f"{archive}:missing-agcmem")
    if "ldpcmem" in symbols:
        print(f"{archive}: unexpected WiFi ldpcmem symbol")
        failures.append(f"{archive}:unexpected-ldpcmem-symbol")

    objdump = llvm_objdump_cmd()
    disasm = subprocess.check_output(
        [objdump, "-dr", f"--mattr={THEAD_MATTR}", str(archive)],
        text=True,
        errors="ignore",
    ).lower()
    if "agcmem-0x24c0a000" not in disasm:
        print(f"{archive}: missing phy_init AGC copy relocation to 0x24C0A000")
        failures.append(f"{archive}:missing-agcmem-copy")
    if "24c09000" in disasm:
        print(f"{archive}: unexpected WiFi LDPC RAM reference 0x24C09000")
        failures.append(f"{archive}:unexpected-ldpc-ram-reference")
    if not failures:
        print(f"{archive}: WiFi PHY memory init uses agcmem and no LDPC RAM path")
    return failures


def check_wifi_object_phy_memory_init(obj: Path) -> list[str]:
    """Validate the pure-Nim WiFi object copies AGC RAM and has no LDPC RAM load."""
    failures: list[str] = []
    symbols = subprocess.check_output(
        ["riscv64-unknown-elf-objdump", "-t", str(obj)],
        text=True,
        errors="ignore",
    ).lower()
    if "agcmem" not in symbols:
        print(f"{obj}: missing Nim agcmem symbol")
        failures.append(f"{obj}:missing-nim-agcmem")
    if "ldpcmem" in symbols:
        print(f"{obj}: unexpected Nim ldpcmem symbol")
        failures.append(f"{obj}:unexpected-nim-ldpcmem-symbol")

    objdump = llvm_objdump_cmd()
    disasm = subprocess.check_output(
        [objdump, "-dr", f"--mattr={THEAD_MATTR}", str(obj)],
        text=True,
        errors="ignore",
    ).lower()
    if "copyagcmemory" not in disasm or "agcmem" not in disasm or "24c0a" not in disasm:
        print(f"{obj}: missing Nim AGC copy evidence to 0x24C0A000")
        failures.append(f"{obj}:missing-nim-agcmem-copy")
    if "24c09" in disasm:
        print(f"{obj}: unexpected Nim WiFi LDPC RAM reference 0x24C09000")
        failures.append(f"{obj}:unexpected-nim-ldpc-ram-reference")
    if not failures:
        print(f"{obj}: Nim WiFi PHY memory init copies agcmem and has no LDPC RAM path")
    return failures


def hw_validation_nimcache_object(elf: Path, object_name: str) -> Path | None:
    parts = elf.parts
    for index in range(0, len(parts) - 2):
        if parts[index] == "bin" and parts[index + 2] == "kernel.elf":
            work_dir = Path(*parts[:index])
            test_name = parts[index + 1]
            return work_dir / "nimcache" / test_name / "kernel" / object_name
    return None


def add_hw_validation_test_inputs(
    test_name: str, work_dir: Path, args: argparse.Namespace
) -> None:
    """Expand a hw-validation test name into its provenance artifacts."""
    elf = work_dir / "bin" / test_name / "kernel.elf"
    args.elf.append(elf)

    link_map = elf.with_suffix(".map")
    if link_map.exists() and link_map not in args.link_map:
        args.link_map.append(link_map)

    build_log = work_dir / "logs" / f"{test_name}.kernel.build.log"
    if build_log.exists() and build_log not in args.build_log:
        args.build_log.append(build_log)


def check_hw_validation_nimcache_objects(
    elf: Path,
    require: bool,
    require_labels: set[str],
    infer_required: bool,
    check_wifi_phy_memory: bool,
) -> list[str]:
    failures: list[str] = []
    inferred_labels = inferred_hw_validation_labels(elf) if infer_required else set()
    for label, object_name, symbols in HW_VALIDATION_OBJECTS:
        label_required = require or label in require_labels or label in inferred_labels
        obj = hw_validation_nimcache_object(elf, object_name)
        if obj is None:
            if label_required:
                print(f"{elf}: cannot infer hw-validation {label} object path")
                failures.append(f"{elf}:missing-path:{label}")
            continue
        if not obj.exists():
            if label_required:
                print(f"{elf}: missing hw-validation {label} object: {obj}")
                failures.append(f"{elf}:missing-object:{label}")
            continue
        missing = check_defined(obj, symbols, f"{elf} {label}-nimcache-object")
        failures.extend(f"{obj}:missing:{symbol}" for symbol in missing)
        if label == "wifi" and check_wifi_phy_memory:
            failures.extend(check_wifi_object_phy_memory_init(obj))
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wifi-object", type=Path)
    parser.add_argument("--ble-object", type=Path)
    parser.add_argument("--rf-archive", type=Path)
    parser.add_argument("--build-log", type=Path, action="append", default=[])
    parser.add_argument("--link-map", type=Path, action="append", default=[])
    parser.add_argument("--elf", type=Path, action="append", default=[])
    parser.add_argument(
        "--hw-validation-test",
        action="append",
        default=[],
        help=(
            "expand build/hw-validation artifacts for a test name: "
            "bin/<test>/kernel.elf, kernel.map, kernel build log, and "
            "inferred Nim cache objects"
        ),
    )
    parser.add_argument(
        "--hw-validation-work-dir",
        type=Path,
        default=Path("build/hw-validation"),
        help="work directory used with --hw-validation-test",
    )
    parser.add_argument(
        "--check-wifi-phy-memory-init",
        action="store_true",
        help=(
            "with --rf-archive, prove WiFi phy_init copies agcmem to "
            "0x24C0A000 and does not reference ldpcmem/0x24C09000"
        ),
    )
    parser.add_argument(
        "--require-elf-symbols",
        action="store_true",
        help="fail if any converted WiFi or BLE RF/PHY symbol is not defined in each ELF",
    )
    parser.add_argument(
        "--require-wifi-elf-symbols",
        action="store_true",
        help="fail if any converted WiFi RF/PHY symbol is not defined in each ELF",
    )
    parser.add_argument(
        "--require-ble-elf-symbols",
        action="store_true",
        help="fail if any converted BLE/coex RF symbol is not defined in each ELF",
    )
    parser.add_argument(
        "--check-hw-validation-nimcache-objects",
        action="store_true",
        help=(
            "for build/hw-validation/bin/<test>/kernel.elf inputs, also prove "
            "the matching Nim cache objects define converted RF/PHY symbols"
        ),
    )
    parser.add_argument(
        "--require-hw-validation-nimcache-objects",
        action="store_true",
        help=(
            "fail when a build/hw-validation ELF has no matching Nim cache "
            "object for the RF/PHY provenance check"
        ),
    )
    parser.add_argument(
        "--require-hw-validation-wifi-nimcache-object",
        action="store_true",
        help="fail when a build/hw-validation ELF has no matching wifi_fw Nim cache object",
    )
    parser.add_argument(
        "--require-hw-validation-ble-nimcache-object",
        action="store_true",
        help="fail when a build/hw-validation ELF has no matching blecontroller Nim cache object",
    )
    parser.add_argument(
        "--infer-hw-validation-nimcache-objects",
        action="store_true",
        help=(
            "for build/hw-validation ELF names, require wifi objects for wifi "
            "tests, ble objects for ble tests, and both for coex tests"
        ),
    )
    args = parser.parse_args()

    if args.hw_validation_test:
        args.check_hw_validation_nimcache_objects = True
        args.infer_hw_validation_nimcache_objects = True
        for test_name in args.hw_validation_test:
            add_hw_validation_test_inputs(
                test_name, args.hw_validation_work_dir, args)

    failures: list[str] = []
    required_hw_labels: set[str] = set()
    if args.require_hw_validation_wifi_nimcache_object:
        required_hw_labels.add("wifi")
    if args.require_hw_validation_ble_nimcache_object:
        required_hw_labels.add("ble")

    if (
        args.wifi_object is None
        and args.ble_object is None
        and args.rf_archive is None
        and not args.hw_validation_test
        and not args.elf
        and not args.build_log
        and not args.link_map
    ):
        parser.error(
            "provide --wifi-object, --ble-object, --rf-archive, --elf, "
            "--hw-validation-test, --build-log, or --link-map"
        )

    if args.wifi_object is not None:
        require_existing(args.wifi_object, "WiFi object")
        missing = check_defined(args.wifi_object, WIFI_RF_SYMBOLS, "wifi-object")
        failures.extend(f"wifi-object:{symbol}" for symbol in missing)
        if args.check_wifi_phy_memory_init:
            failures.extend(check_wifi_object_phy_memory_init(args.wifi_object))

    if args.ble_object is not None:
        require_existing(args.ble_object, "BLE object")
        missing = check_defined(args.ble_object, BLE_RF_SYMBOLS, "ble-object")
        failures.extend(f"ble-object:{symbol}" for symbol in missing)

    if args.rf_archive is not None:
        require_existing(args.rf_archive, "RF archive")
        if args.check_wifi_phy_memory_init:
            failures.extend(check_wifi_phy_memory_init(args.rf_archive))

    for elf in args.elf:
        require_existing(elf, "ELF")
        label = str(elf)
        required_symbols: list[str] = []
        if args.require_elf_symbols or args.require_wifi_elf_symbols:
            required_symbols.extend(WIFI_RF_SYMBOLS)
        if args.require_elf_symbols or args.require_ble_elf_symbols:
            required_symbols.extend(BLE_RF_SYMBOLS)
        check_elf_defined(
            elf,
            WIFI_RF_SYMBOLS + BLE_RF_SYMBOLS,
            label,
            False,
        )
        if required_symbols:
            missing_required = check_elf_defined(
                elf,
                required_symbols,
                f"{label} required",
                True,
            )
            failures.extend(f"{elf}:missing:{symbol}" for symbol in missing_required)
        bad = check_not_undefined(elf, WIFI_RF_SYMBOLS + BLE_RF_SYMBOLS, label)
        failures.extend(f"{elf}:{symbol}" for symbol in bad)
        if (
            args.check_hw_validation_nimcache_objects
            or args.require_hw_validation_nimcache_objects
            or args.infer_hw_validation_nimcache_objects
        ):
            failures.extend(
                check_hw_validation_nimcache_objects(
                    elf,
                    args.require_hw_validation_nimcache_objects,
                    required_hw_labels,
                    args.infer_hw_validation_nimcache_objects,
                    args.check_wifi_phy_memory_init,
                )
            )

    for log in args.build_log:
        require_existing(log, "build log")
        found = check_build_log(log)
        failures.extend(f"{log}:{marker}" for marker in found)

    for link_map in args.link_map:
        require_existing(link_map, "link map")
        found = check_link_map(link_map)
        failures.extend(f"{link_map}:{line}" for line in found)

    if failures:
        print("FAIL:", ", ".join(failures))
        return 1
    print("PASS: RF/PHY symbol provenance checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
