#!/usr/bin/env python3
"""B1 host cross-check: the eFuse provision plan is byte-exact.

Proves the HOST packer (sbtool.compute_provision_plan, used by `gen-efuse`)
emits the exact (word, or_mask) words a production burn would apply, against a
golden vector hand-computed from the ef_data_0 bit layout. The device-side
m0_efuse_provision_test asserts the SAME golden values for the Nim
computeProvisionPlan, so host tooling and device firmware are proven to agree.
Nothing here touches hardware or burns anything.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "secureboot"))
import sbtool  # noqa: E402

# Golden words (identical to examples/m0_efuse_provision_test.nim).
GOLD_CFG0 = 0x4F400010      # sboot(1<<4)|sedbg(1<<22)|jtag1(3<<24)|jtag0(3<<26)|dbg(4<<28)
GOLD_SW_USAGE = 0x00000200  # sign-mode ECC(2)<<8
GOLD_LOCK = 0x08020000      # rd slot0(1<<27) | wr slot0(1<<17)
GOLD_ALL_LOCK = (0xF << 27) | (0xF << 17)

failed = 0


def check(label, ok):
    global failed
    print(("[PASS] " if ok else "[FAIL] ") + label)
    if not ok:
        failed += 1


full = {
    "enable_secure_boot": True, "sign_mode": 2, "sf_aes_mode": 0,
    "disable_jtag": True, "disable_se_dbg": True,
    "lock_read": {0}, "lock_write": {0},
}
plan = sbtool.compute_provision_plan(full)

check("word indices cfg0=0 sw_usage0=23 lock=31",
      (sbtool.EF_WORD_CFG0, sbtool.EF_WORD_SW_USAGE0, sbtool.EF_WORD_LOCK) == (0, 23, 31))
check("cfg0 byte-exact (0x4F400010)", plan.get(0) == GOLD_CFG0)
check("sw_usage0 byte-exact (0x200)", plan.get(23) == GOLD_SW_USAGE)
check("lock word byte-exact (0x08020000)", plan.get(31) == GOLD_LOCK)
check("exactly 3 words written", len(plan) == 3)

empty = sbtool.compute_provision_plan({"sign_mode": 0})
check("empty spec -> no bits at all", empty == {})

allslots = sbtool.compute_provision_plan(
    {"sign_mode": 0, "lock_read": {0, 1, 2, 3}, "lock_write": {0, 1, 2, 3}})
check("all-slot lock byte-exact", allslots.get(31) == GOLD_ALL_LOCK)

# DevCube bin emission: word N's little-endian mask lands at byte offset N*4.
import io
data = bytearray(128 * 4)
for w, m in plan.items():
    data[w * 4:w * 4 + 4] = m.to_bytes(4, "little")
check("cfg0 lands at byte 0 little-endian",
      int.from_bytes(data[0:4], "little") == GOLD_CFG0)
check("sw_usage0 lands at byte 92 (0x5C)",
      int.from_bytes(data[92:96], "little") == GOLD_SW_USAGE)
check("lock lands at byte 124 (0x7C)",
      int.from_bytes(data[124:128], "little") == GOLD_LOCK)

if failed == 0:
    print("=== ALL PASS ===")
    sys.exit(0)
print(f"=== {failed} FAILED ===")
sys.exit(1)
