#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  cat <<'USAGE'
Usage:
  tools/validate_wifi_fw_objdump.sh <reference_libfirmware.a> <nim_obj_or_archive>

Examples:
  tools/validate_wifi_fw_objdump.sh /tmp/libfirmware_ad2a37.a /tmp/nimcache_wifi_fw_shim3/@pbl808@swifi_fw.nim.c.o
  tools/validate_wifi_fw_objdump.sh /tmp/libfirmware_ad2a37.a /tmp/libwifi_fw_nim.a

Optional RF/PHY provenance checks:
  VALIDATE_RF_ELF=/tmp/kernel.elf tools/validate_wifi_fw_objdump.sh <ref> <nim_obj>
  VALIDATE_RF_BUILD_LOG=build.log tools/validate_wifi_fw_objdump.sh <ref> <nim_obj>
  VALIDATE_RF_LINK_MAP=kernel.map tools/validate_wifi_fw_objdump.sh <ref> <nim_obj>
  VALIDATE_RF_REQUIRE_HW_NIMCACHE=1 VALIDATE_RF_ELF=build/hw-validation/bin/<test>/kernel.elf tools/validate_wifi_fw_objdump.sh <ref> <nim_obj>
  When src/bl808/librf_bl808.a is present, the RF provenance step also checks
  that WiFi phy_init copies agcmem to 0x24C0A000 and has no LDPC RAM path.
  When a hw-validation kernel.map exists beside VALIDATE_RF_ELF, the RF
  provenance step also rejects extracted RF archive members in the link map.
USAGE
  exit 2
fi

REF="$1"
NIM_BIN="$2"

LLVM_OBJDUMP="${LLVM_OBJDUMP:-}"
if [[ -z "$LLVM_OBJDUMP" ]]; then
  if command -v llvm-objdump >/dev/null 2>&1; then
    LLVM_OBJDUMP="$(command -v llvm-objdump)"
  elif [[ -x /opt/homebrew/opt/llvm/bin/llvm-objdump ]]; then
    LLVM_OBJDUMP=/opt/homebrew/opt/llvm/bin/llvm-objdump
  else
    echo "Missing required tool: llvm-objdump" >&2
    exit 1
  fi
fi

for tool in riscv64-unknown-elf-nm python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

if [[ ! -f "$REF" ]]; then
  echo "Reference archive not found: $REF" >&2
  exit 1
fi

if [[ ! -f "$NIM_BIN" ]]; then
  echo "Nim object/archive not found: $NIM_BIN" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REF_FUNCS="$TMP_DIR/ref_funcs.txt"
NIM_FUNCS="$TMP_DIR/nim_funcs.txt"

riscv64-unknown-elf-nm -g --defined-only "$REF" \
  | awk '/^[0-9a-fA-F]+ T /{print $3}' \
  | sort -u > "$REF_FUNCS"

riscv64-unknown-elf-nm -g --defined-only "$NIM_BIN" \
  | awk '/^[0-9a-fA-F]+ T /{print $3}' \
  | sort -u > "$NIM_FUNCS"

echo "Reference funcs: $(wc -l < "$REF_FUNCS" | tr -d ' ')"
echo "Nim funcs:       $(wc -l < "$NIM_FUNCS" | tr -d ' ')"
echo "Common funcs:    $(comm -12 "$REF_FUNCS" "$NIM_FUNCS" | wc -l | tr -d ' ')"
echo "Missing in Nim:  $(comm -23 "$REF_FUNCS" "$NIM_FUNCS" | wc -l | tr -d ' ')"
echo "Extra in Nim:    $(comm -23 "$NIM_FUNCS" "$REF_FUNCS" | wc -l | tr -d ' ')"

if [[ "$(comm -23 "$NIM_FUNCS" "$REF_FUNCS" | wc -l | tr -d ' ')" -gt 0 ]]; then
  echo ""
  echo "Extra symbols in Nim (first 20):"
  comm -23 "$NIM_FUNCS" "$REF_FUNCS" | sed -n '1,20p'
fi

python3 - "$REF" "$NIM_BIN" "$REF_FUNCS" "$NIM_FUNCS" "$LLVM_OBJDUMP" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

ref = sys.argv[1]
nim = sys.argv[2]
ref_funcs = set(Path(sys.argv[3]).read_text().split())
nim_funcs = set(Path(sys.argv[4]).read_text().split())
llvm_objdump = sys.argv[5]
common = sorted(ref_funcs & nim_funcs)

THEAD_MATTR = (
    "+xtheadba,+xtheadbb,+xtheadbs,+xtheadcmo,+xtheadcondmov,"
    "+xtheadfmemidx,+xtheadmac,+xtheadmemidx,+xtheadmempair,+xtheadsync"
)

def parse_objdump(path: str):
    txt = subprocess.check_output(
        [llvm_objdump, "-d", f"--mattr={THEAD_MATTR}", path],
        text=True,
        errors="ignore",
    )
    fn = None
    out = {}
    for line in txt.splitlines():
        m = re.match(r"^([0-9a-fA-F]+) <([^>]+)>:$", line.strip())
        if m:
            fn = m.group(2)
            out.setdefault(fn, {"bytes": [], "mnem": []})
            continue
        if fn is None:
            continue
        m = re.match(r"^\s*[0-9a-fA-F]+:\s*([0-9a-fA-F]+)\s+([.A-Za-z0-9_]+)", line)
        if m:
            out[fn]["bytes"].append(m.group(1).lower())
            out[fn]["mnem"].append(m.group(2))
    return out

ref_dis = parse_objdump(ref)
nim_dis = parse_objdump(nim)

checked = []
byte_eq = []
mnem_eq = []
for f in common:
    if f in ref_dis and f in nim_dis:
        checked.append(f)
        if ref_dis[f]["bytes"] == nim_dis[f]["bytes"]:
            byte_eq.append(f)
        if ref_dis[f]["mnem"] == nim_dis[f]["mnem"]:
            mnem_eq.append(f)

print("")
print(f"Functions with disassembly in both files: {len(checked)}")
print(f"Byte-identical functions:                {len(byte_eq)}")
print(f"Mnemonic-identical functions:            {len(mnem_eq)}")

if len(byte_eq) > 0:
    print("Byte-identical examples:", ", ".join(byte_eq[:10]))
if len(mnem_eq) > 0:
    print("Mnemonic-identical examples:", ", ".join(mnem_eq[:10]))

if len(byte_eq) != len(checked):
    print("")
    print("Top length deltas (ref_instrs vs nim_instrs):")
    deltas = []
    for f in checked:
        rl = len(ref_dis[f]["bytes"])
        nl = len(nim_dis[f]["bytes"])
        deltas.append((abs(rl - nl), f, rl, nl))
    deltas.sort(reverse=True)
    for d, f, rl, nl in deltas[:10]:
        print(f"  {f}: {rl} vs {nl} (delta {d})")
PY

if [[ -f tools/validate_rf_symbol_provenance.py ]]; then
  RF_ARGS=(--wifi-object "$NIM_BIN")
  if [[ -f src/bl808/librf_bl808.a ]]; then
    RF_ARGS+=(--rf-archive src/bl808/librf_bl808.a --check-wifi-phy-memory-init)
  fi
  if [[ -n "${VALIDATE_RF_ELF:-}" ]]; then
    RF_ARGS+=(--elf "$VALIDATE_RF_ELF" --check-hw-validation-nimcache-objects)
    inferred_map="${VALIDATE_RF_ELF%.elf}.map"
    if [[ -f "$inferred_map" ]]; then
      RF_ARGS+=(--link-map "$inferred_map")
    fi
    if [[ -n "${VALIDATE_RF_REQUIRE_HW_NIMCACHE:-}" ]]; then
      RF_ARGS+=(--require-hw-validation-wifi-nimcache-object)
    fi
  fi
  if [[ -n "${VALIDATE_RF_BUILD_LOG:-}" ]]; then
    RF_ARGS+=(--build-log "$VALIDATE_RF_BUILD_LOG")
  fi
  if [[ -n "${VALIDATE_RF_LINK_MAP:-}" ]]; then
    RF_ARGS+=(--link-map "$VALIDATE_RF_LINK_MAP")
  fi
  echo ""
  echo "RF/PHY symbol provenance:"
  python3 tools/validate_rf_symbol_provenance.py "${RF_ARGS[@]}"
fi
