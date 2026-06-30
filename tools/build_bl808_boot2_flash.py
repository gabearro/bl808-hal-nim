#!/usr/bin/env python3

import argparse
import hashlib
import inspect
import struct
import zlib
from pathlib import Path


BOOTHEADER_SIZE = 352
FW_BOOTINFO_SIZE = 0x1000
PT_TABLE_SIZE = 596
PT_MAGIC = 0x54504642
BOOTHEADER_MAGIC_BFNP = 0x504E4642
BOOTHEADER_FLASH_CFG_MAGIC = 0x47464346
BOOTHEADER_PCLOCK_MAGIC = 0x47464350
BOOTHEADER_FLAGS_OFFSET = 0x80
BOOTHEADER_GROUP_OFFSET = 0x84
BOOTHEADER_CPU_CFG_BASE = 0x0B0
BOOTHEADER_CPU_CFG_SIZE = 24
BOOTHEADER_PT0_OFFSET = 0x0F4
BOOTHEADER_PT1_OFFSET = 0x0F8
BOOTHEADER_CRC_OFFSET = 0x15C
BOOTHEADER_BOOTCFG_OFFSET = 0x080
BOOTHEADER_HASH_OFFSET = BOOTHEADER_BOOTCFG_OFFSET + 16
BOOTHEADER_M0_BOOT_ENTRY_OFFSET = 0x0C0
BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET = 0x0BC
BOOTCFG_IMG_LEN_COUNT_OFFSET = BOOTHEADER_BOOTCFG_OFFSET + 12
BOOTCFG_NO_SEGMENT_MASK = 1 << 8
SEGMENT_HEADER_SIZE = 16

FLASH_OFFSET_BOOT2 = 0x000000
FLASH_OFFSET_PT0 = 0x00E000
FLASH_OFFSET_PT1 = 0x00F000
FLASH_OFFSET_FW = 0x010000
FLASH_OFFSET_LP = 0x020000
FLASH_OFFSET_D0 = 0x100000
FLASH_XIP_BASE = 0x58000000
FLASH_XIP_SIZE = 0x04000000
M0_CACHED_RAM_BASE = 0x62020000
M0_UNCACHED_RAM_BASE = 0x22020000
M0_RAM_ALIAS_SIZE = 0x00038000


def bootheader_crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def patch_boot_header(
    image: bytes,
    *,
    pt0_offset: int,
    pt1_offset: int,
) -> bytes:
    if len(image) < BOOTHEADER_SIZE:
        raise ValueError("boot image is smaller than a BL808 boot header")

    header = bytearray(image[:BOOTHEADER_SIZE])
    magic = struct.unpack_from("<I", header, 0x00)[0]
    flash_cfg_magic = struct.unpack_from("<I", header, 0x08)[0]
    if magic != BOOTHEADER_MAGIC_BFNP or flash_cfg_magic != BOOTHEADER_FLASH_CFG_MAGIC:
        raise ValueError("boot image does not start with a BL808 BFNP header")

    if struct.unpack_from("<I", header, 0x64)[0] != BOOTHEADER_PCLOCK_MAGIC:
        raise ValueError("boot image header does not contain a BL808 PCFG block")

    struct.pack_into("<I", header, BOOTHEADER_PT0_OFFSET, pt0_offset)
    struct.pack_into("<I", header, BOOTHEADER_PT1_OFFSET, pt1_offset)
    struct.pack_into("<I", header, BOOTHEADER_CRC_OFFSET,
                     bootheader_crc32(header[:BOOTHEADER_CRC_OFFSET]))

    return bytes(header) + image[BOOTHEADER_SIZE:]


def find_default_fw_bootinfo_template() -> Path | None:
    try:
        import bflb_iot_tool
    except Exception:
        return None

    template = (
        Path(inspect.getfile(bflb_iot_tool)).parent
        / "chips"
        / "bl808"
        / "img_create_iot"
        / "bootinfo.bin"
    )
    if template.exists():
        return template
    return None


def is_flash_xip_address(address: int) -> bool:
    return FLASH_XIP_BASE <= address < FLASH_XIP_BASE + FLASH_XIP_SIZE


def m0_segment_load_address(entry: int) -> int:
    if M0_CACHED_RAM_BASE <= entry < M0_CACHED_RAM_BASE + M0_RAM_ALIAS_SIZE:
        return M0_UNCACHED_RAM_BASE + (entry - M0_CACHED_RAM_BASE)
    return entry


def build_bl808_segment(load_address: int, payload: bytes) -> bytes:
    padded_payload = payload + (b"\x00" * ((-len(payload)) % 16))
    header = bytearray(SEGMENT_HEADER_SIZE - 4)
    struct.pack_into(
        "<III",
        header,
        0,
        load_address,
        len(padded_payload),
        bootheader_crc32(padded_payload),
    )
    return bytes(header) + bootheader_crc32(header).to_bytes(4, "little") + padded_payload


def build_fw_image(
    raw_fw: bytes,
    template_path: Path | None,
    *,
    m0_boot_entry: int | None = None,
) -> bytes:
    if len(raw_fw) >= 12:
        magic, _, flash_cfg_magic = struct.unpack_from("<III", raw_fw)
        if magic == BOOTHEADER_MAGIC_BFNP and flash_cfg_magic == BOOTHEADER_FLASH_CFG_MAGIC:
            return raw_fw

    if template_path is None:
        template_path = find_default_fw_bootinfo_template()
    if template_path is None:
        raise ValueError(
            "raw FW image needs a BL808 bootinfo template; install bflb-iot-tool "
            "or pass --fw-bootinfo-template"
        )

    bootinfo = bytearray(template_path.read_bytes())
    if len(bootinfo) > FW_BOOTINFO_SIZE:
        raise ValueError(f"FW bootinfo template is larger than 0x1000: {template_path}")
    magic, _, flash_cfg_magic = struct.unpack_from("<III", bootinfo)
    if magic != BOOTHEADER_MAGIC_BFNP or flash_cfg_magic != BOOTHEADER_FLASH_CFG_MAGIC:
        raise ValueError(f"FW bootinfo template is not a BL808 BFNP header: {template_path}")

    if m0_boot_entry is not None and not is_flash_xip_address(m0_boot_entry):
        load_address = m0_segment_load_address(m0_boot_entry)
        fw_body = build_bl808_segment(load_address, raw_fw)
        bootcfg = int.from_bytes(
            bootinfo[BOOTHEADER_BOOTCFG_OFFSET:BOOTHEADER_BOOTCFG_OFFSET + 4],
            "little",
        )
        bootcfg &= ~BOOTCFG_NO_SEGMENT_MASK
        bootinfo[BOOTHEADER_BOOTCFG_OFFSET:BOOTHEADER_BOOTCFG_OFFSET + 4] = (
            bootcfg.to_bytes(4, "little")
        )
        bootinfo[BOOTCFG_IMG_LEN_COUNT_OFFSET:BOOTCFG_IMG_LEN_COUNT_OFFSET + 4] = (
            (1).to_bytes(4, "little")
        )
        bootinfo[BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET:
                 BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET + 4] = (
            load_address.to_bytes(4, "little")
        )
    else:
        fw_body = raw_fw + (b"\x00" * ((-len(raw_fw)) % 16))
        bootinfo[BOOTCFG_IMG_LEN_COUNT_OFFSET:BOOTCFG_IMG_LEN_COUNT_OFFSET + 4] = (
            len(fw_body).to_bytes(4, "little")
        )
        if m0_boot_entry is not None:
            bootinfo[BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET:
                     BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET + 4] = (
                (m0_boot_entry - FLASH_XIP_BASE).to_bytes(4, "little")
            )
    if m0_boot_entry is not None:
        bootinfo[BOOTHEADER_M0_BOOT_ENTRY_OFFSET:
                 BOOTHEADER_M0_BOOT_ENTRY_OFFSET + 4] = (
            m0_boot_entry.to_bytes(4, "little")
        )
    bootinfo[BOOTHEADER_HASH_OFFSET:BOOTHEADER_HASH_OFFSET + 32] = (
        hashlib.sha256(fw_body).digest()
    )
    struct.pack_into(
        "<I",
        bootinfo,
        BOOTHEADER_CRC_OFFSET,
        bootheader_crc32(bootinfo[:BOOTHEADER_CRC_OFFSET]),
    )
    return bytes(bootinfo) + (b"\xFF" * (FW_BOOTINFO_SIZE - len(bootinfo))) + fw_body


def build_partition_table(*, age: int, fw_start: int, fw_max_len: int) -> bytes:
    table = bytearray(b"\xFF" * PT_TABLE_SIZE)
    struct.pack_into("<IHHI", table, 0x00, PT_MAGIC, 0, 1, age)

    entry_base = 0x10
    table[entry_base + 0] = 0
    table[entry_base + 1] = 0
    table[entry_base + 2] = 0
    table[entry_base + 3:entry_base + 12] = b"FW\x00\x00\x00\x00\x00\x00\x00"
    struct.pack_into("<II", table, entry_base + 12, fw_start, 0)
    struct.pack_into("<II", table, entry_base + 20, fw_max_len, 0)
    struct.pack_into("<II", table, entry_base + 28, fw_max_len, 0)

    struct.pack_into("<I", table, 0x0C, bootheader_crc32(table[:0x0C]))
    entries_end = entry_base + 36
    struct.pack_into("<I", table, entries_end,
                     bootheader_crc32(table[0x10:entries_end]))
    return bytes(table)


def write_blob(flash: bytearray, offset: int, payload: bytes, label: str) -> None:
    end = offset + len(payload)
    if end > len(flash):
        raise ValueError(f"{label} at 0x{offset:06x} exceeds flash size")
    flash[offset:end] = payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a BL808 boot2-style flash image for QEMU"
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--boot2", required=True, type=Path,
                        help="boot2_bl808_release_v8.1.1.bin or similar")
    parser.add_argument("--fw", required=True, type=Path,
                        help="Primary M0 firmware .bin, raw or with a BL808 FW header")
    parser.add_argument("--fw-bootinfo-template", type=Path,
                        help="BL808 bootinfo.bin template used when --fw is raw")
    parser.add_argument("--m0-boot-entry", type=lambda s: int(s, 0),
                        help="Override the M0 boot-entry word in generated FW bootinfo")
    parser.add_argument("--lp", type=Path,
                        help="Optional LP firmware .bin placed at 0x20000")
    parser.add_argument("--d0", type=Path,
                        help="Optional D0 firmware .bin placed at 0x100000")
    parser.add_argument("--flash-size", type=lambda s: int(s, 0),
                        default=0x400000,
                        help="Total flash image size in bytes, default 0x400000")
    parser.add_argument("--compact", action="store_true",
                        help="Trim output to the last written byte instead of padding to --flash-size")
    parser.add_argument("--fw-offset", type=lambda s: int(s, 0),
                        default=FLASH_OFFSET_FW,
                        help="FW partition start address, default 0x10000")
    parser.add_argument("--fw-max-len", type=lambda s: int(s, 0),
                        default=0xF0000,
                        help="FW partition max length, default 0xF0000")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    boot2 = patch_boot_header(
        args.boot2.read_bytes(),
        pt0_offset=FLASH_OFFSET_PT0,
        pt1_offset=FLASH_OFFSET_PT1,
    )
    fw = build_fw_image(
        args.fw.read_bytes(),
        args.fw_bootinfo_template,
        m0_boot_entry=args.m0_boot_entry,
    )
    pt = build_partition_table(age=1, fw_start=args.fw_offset,
                               fw_max_len=args.fw_max_len)
    lp = args.lp.read_bytes() if args.lp else None
    d0 = args.d0.read_bytes() if args.d0 else None

    flash_size = args.flash_size
    if args.compact:
        flash_size = max(
            FLASH_OFFSET_BOOT2 + len(boot2),
            FLASH_OFFSET_PT0 + len(pt),
            FLASH_OFFSET_PT1 + len(pt),
            args.fw_offset + len(fw),
            FLASH_OFFSET_LP + len(lp) if lp else 0,
            FLASH_OFFSET_D0 + len(d0) if d0 else 0,
        )

    flash = bytearray(b"\xFF" * flash_size)

    write_blob(flash, FLASH_OFFSET_BOOT2, boot2, "boot2")
    write_blob(flash, FLASH_OFFSET_PT0, pt, "partition table 0")
    write_blob(flash, FLASH_OFFSET_PT1, pt, "partition table 1")
    write_blob(flash, args.fw_offset, fw, "FW image")

    if lp:
        write_blob(flash, FLASH_OFFSET_LP, lp, "LP image")

    if d0:
        write_blob(flash, FLASH_OFFSET_D0, d0, "D0 image")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(flash)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
