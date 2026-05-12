#!/usr/bin/env python3

import json
import sys
from pathlib import Path


ALLOWED_STATUS = {"native", "standin", "stub"}
ALLOWED_BACKEND_STATUS = {"functional", "reserved"}


def parse_hex(value: str) -> int:
    if not isinstance(value, str) or not value.startswith("0x"):
        raise ValueError(f"expected hex string, got {value!r}")
    return int(value, 16)


def collect_regions(entries, kind):
    regions = []
    names = set()
    for entry in entries:
        name = entry["name"]
        if name in names:
            raise ValueError(f"duplicate {kind} name: {name}")
        names.add(name)
        base = parse_hex(entry["base"])
        size = parse_hex(entry["size"])
        if size <= 0:
            raise ValueError(f"{kind} {name} must have non-zero size")
        regions.append((entry["space"], base, base + size, name))
    return names, regions


def assert_no_overlap(regions, kind):
    by_space = {}
    for space, start, end, name in regions:
        by_space.setdefault(space, []).append((start, end, name))

    for space, items in by_space.items():
        items.sort()
        prev_end = None
        prev_name = None
        for start, end, name in items:
            if prev_end is not None and start < prev_end:
                raise ValueError(
                    f"{kind} overlap in {space}: {prev_name} overlaps {name}"
                )
            prev_end = end
            prev_name = name


def main() -> int:
    manifest_path = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        Path(__file__).resolve().parent / "ref" / "bl808_manifest.json"
    )
    data = json.loads(manifest_path.read_text())

    if data.get("schema_version") != 1:
        raise ValueError("schema_version must be 1")

    memory_names, memory_regions = collect_regions(data["memory_regions"], "memory")
    peripheral_names, peripheral_regions = collect_regions(data["peripherals"], "peripheral")
    private_names, private_regions = collect_regions(data["private_buses"], "private bus")

    assert_no_overlap(memory_regions + peripheral_regions, "system-region")
    assert_no_overlap(private_regions, "private-bus")

    alias_names = set()
    for alias in data["aliases"]:
        name = alias["name"]
        if name in alias_names:
            raise ValueError(f"duplicate alias name: {name}")
        alias_names.add(name)
        parse_hex(alias["base"])
        parse_hex(alias["size"])
        if alias["target"] not in memory_names:
            raise ValueError(f"alias {name} targets unknown region {alias['target']}")

    populated = set(data["board"]["populated_peripherals"])
    unknown_populated = populated - peripheral_names
    if unknown_populated:
        raise ValueError(f"board populated_peripherals reference unknown entries: {sorted(unknown_populated)}")

    for prop, status in data["board"]["backend_properties"].items():
        if status not in ALLOWED_BACKEND_STATUS:
            raise ValueError(f"backend property {prop} has invalid status {status}")

    controllers = private_names
    for entry in data["peripherals"]:
        if entry["status"] not in ALLOWED_STATUS:
            raise ValueError(f"peripheral {entry['name']} has invalid status {entry['status']}")
    for entry in data["private_buses"]:
        if entry["status"] not in ALLOWED_STATUS:
            raise ValueError(f"private bus {entry['name']} has invalid status {entry['status']}")

    valid_sources = peripheral_names | memory_names | {"gpio", "wireless"}
    for irq in data["irq_map"]:
        if irq["source"] not in valid_sources:
            raise ValueError(f"irq source {irq['source']} is not declared")
        if irq["controller"] not in controllers:
            raise ValueError(f"irq controller {irq['controller']} is not declared")
        if not isinstance(irq["line"], int) or irq["line"] < 0:
            raise ValueError(f"irq line for {irq['source']} must be a non-negative integer")

    print(f"validated {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
