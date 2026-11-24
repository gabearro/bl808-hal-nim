"""Exercise the BL808 supplicant entropy ABI with scripted TRNG outcomes."""

import json
from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program

ROOT = Path(__file__).resolve().parents[1]
RANDOM = ROOT / "src/bl808/wifi/support/runtime_facade_parts/random.nim"

PLATFORM = r"""
type SecError = enum secOk, secBusy, secTimeout
var interruptsEnabled: bool
var calls, enters, exits: int
var failAt: int
var failure: SecError

proc osEnterCritical(): uint32 =
  inc enters
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false

proc osExitCritical(saved: uint32) =
  doAssert not interruptsEnabled
  inc exits
  interruptsEnabled = saved == 8

proc trngReadAll(words: var array[8, uint32]): SecError =
  doAssert not interruptsEnabled
  inc calls
  if calls == failAt: return failure
  for i in 0 ..< words.len:
    words[i] = 0x03020100'u32 + (i.uint32 * 0x04040404'u32) +
      (calls.uint32 * 0x20202020'u32)
  secOk

proc zero(dst: pointer; length: uint) = zeroMem(dst, length.int)
"""

CHECKS = r"""
proc reset(irqEnabled: bool) =
  interruptsEnabled = irqEnabled
  calls = 0
  enters = 0
  exits = 0
  failAt = 0

const Canary = 0xa5'u8
var buf: array[68, uint8]

reset(true)
doAssert os_get_random(nil, 0) == 0
doAssert os_get_random(nil, 1) == -1
doAssert os_get_random(addr buf[0], high(csize_t)) == -1
doAssert calls == 0 and enters == 0 and exits == 0 and interruptsEnabled

for irqEnabled in [true, false]:
  for length in [1, 3, 4, 31, 32, 33, 65]:
    reset(irqEnabled)
    for b in buf.mitems: b = Canary
    doAssert os_get_random(addr buf[1], length.csize_t) == 0
    for i in 0 ..< length:
      doAssert buf[1 + i] == (0x20 + i).uint8, "bytes from consecutive TRNG blocks"
    doAssert buf[0] == Canary and buf[1 + length] == Canary
    doAssert calls == (length + 31) div 32
    doAssert enters == calls and exits == calls
    doAssert interruptsEnabled == irqEnabled

  for err in [secBusy, secTimeout]:
    for stop in [1, 2, 3]:
      reset(irqEnabled)
      failAt = stop
      failure = err
      for b in buf.mitems: b = Canary
      doAssert os_get_random(addr buf[1], 65) == -1
      for i in 1 .. 65: doAssert buf[i] == 0
      doAssert buf[0] == Canary and buf[66] == Canary
      doAssert calls == stop and enters == stop and exits == stop
      doAssert interruptsEnabled == irqEnabled

reset(true)
when cpuEndian == littleEndian:
  doAssert os_random() == 0x23222120.culong
else:
  doAssert os_random() == 0x20212223.culong
failAt = 2
failure = secBusy
doAssert os_random() == 0
doAssert calls == 2 and enters == 2 and exits == 2 and interruptsEnabled
"""


@pytest.mark.parametrize("mode", ["checked", "firmware", "asan"])
def test_supplicant_entropy_abi(tmp_path, mode):
    run_program(tmp_path, mode, PLATFORM + RANDOM.read_text() + CHECKS)


def test_validation_does_not_dump_wpa_key_material():
    example = (ROOT / "examples/m0_wifi_hal_test.nim").read_text()
    for field in ("pmk", "kck", "mic_kck", "snonce", "anonce", "prf_data", "m2", "mic_out"):
        assert f'"[CRYPTO] {field}=' not in example

    manifest = json.loads((ROOT / "tools/hardware_validation.json").read_text())
    for test in manifest["tests"]:
        for command in test.get("jtag_snapshot", []):
            for field in ("crypto_pmk", "crypto_kck", "crypto_snonce", "crypto_anonce",
                          "crypto_prf_data", "mic_kck", "mic_computed", "m2_buf"):
                assert f"{{sym:nimfw_dbg_{field}}}" not in command
