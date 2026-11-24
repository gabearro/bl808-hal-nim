"""Host replay of BL808 demo rf_pri_rccal / rf_pri_rccal.part.0."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type


NATIVE = RF.with_name("rf_bl808_rccal.nim")
ALL = 0xFFFFFFFF
# Offsets from 0x20001000; HBN+0x30 is 0x2000f030. CAL denotes buffer+8.
CAL = 0x10008
SNAPSHOT = (4, 0x2C, 0x1C, 0x30, 0xB8, 0xC0, 0xC4, 0xE030, 0x84, 0x8C,
            0x600, 0x60C, 0x618, 0x61C, 0x48, 0x20C, 0x214, 0x218, 0x23C,
            0x240, 0x244, 0xF0, 0x64, 0x58, 0x220, 0x70, 0xA4)


class Trace:
    def __init__(self, seed):
        self.seed = seed
        self.memory = {}
        self.events = []

    def read(self, addr):
        value = self.memory.setdefault(addr, ((addr * 0x1234567) ^ self.seed) & ALL)
        self.events.append(("R", addr, value))
        return value

    def write(self, addr, value):
        self.memory[addr] = value & ALL
        self.events.append(("W", addr, value & ALL))

    def put(self, addr, keep, bits):
        self.write(addr, (self.read(addr) & keep) | bits)

    def dfe(self):
        self.put(0x220, 0xFFFFFE7F, 0)
        self.put(0x220, 0xFFFFE7FF, 0x1082)
        self.put(0x220, 0xFFFFFFEF, 0x100)

    def tone(self, reference):
        self.put(0x48, 0xFFFF8CFF, 0x3100 if reference else 0x6200)
        self.put(0x20C, 0xFC00FFFF, 0x30000 if reference else 0xB50000)
        self.put(0x214, 0x3FFFFF, 0)
        self.put(0x218, 0x3FFFFF, 0xC0000000)
        if reference:
            self.put(0x214, 0xFFFFF800, 255)
            self.put(0x218, 0xFFFFF800, 255)
        self.put(0x20C, 0x7FFFFFFF, 0)
        self.put(0x20C, ALL, 0x80000000)
        self.dfe()
        self.put(0x618, 0xFFF00000, 0xC00 if reference else 0x2D400)

    def sample(self, i, q=None):
        self.put(0x618, 0xDFEFFFFF, 0)
        if q is None:
            self.put(0x61C, 0xFFFF, 0x04000000)
        self.put(0x618, ALL, 0x20000000 if q is None else 0x20100000)
        self.memory[0x618] &= ~0x10000000
        self.read(0x618)
        self.memory[0x618] |= 0x10000000
        self.read(0x618)
        for offset, sample in [(0x620, i), (0x624, q)]:
            if sample is not None:
                self.memory[offset] = ((sample & 65535) << 9) | 0xAA000155
                self.read(offset)
        self.put(0x618, 0xDFEFFFFF, 0)

    def publish(self):
        # Deliberately unequal live result lanes, independent of the last probe.
        self.memory[0x80] = (self.memory[0x80] & 0xC0FFC0FF) | 0x17002C00
        lanes = self.read(0x80)
        self.put(CAL, 0xFFFFFFC0, (lanes >> 24) & 63)
        self.put(CAL, 0xFFFC0FFF, ((lanes >> 8) & 63) << 12)
        self.put(CAL, 0xFFFFF03F, (self.read(CAL) & 63) << 6)
        self.put(CAL, 0xFF03FFFF, ((self.read(CAL) >> 12) & 63) << 18)
        code = self.read(CAL) & 63
        self.put(0x80, 0xC0FFC0FF, code * 0x01000100)
        code = (self.read(CAL) >> 6) & 63
        self.put(0x80, 0xFFC0FFC0, code * 0x00010001)
        for _ in range(4):
            self.read(CAL)


def run_vector(t, case):
    supported = case != "disabled"
    t.memory[0x20] = (t.seed & ~0x400) | (0x400 if supported else 0)
    t.read(0x20)
    if not supported:
        t.put(0x14, 0xFFF3FFFF, 0)
        return
    if case == "no-buffer":
        return
    t.put(0x14, 0xFFF3FFFF, 0x40000)
    saved = [t.read(addr) for addr in SNAPSHOT]
    t.put(4, 0xFFFFFFFD, 0)
    t.write(0x2C, 0)
    t.put(0x30, ALL, 2)
    t.put(0x30, 0x2DF8F8FF, 0x2DF87800)
    t.events.append(("D", 0, 0))
    t.dfe()
    t.put(0x220, 0xFFFFFF9F, 0)
    t.put(0x220, ALL, 0x21)
    t.put(0x220, ALL, 0x40)
    t.put(0x84, 0xFFFCFFFF, 0)
    t.put(0x84, 0xFCFFFFFF, 0x02000000)
    t.put(0x8C, ALL, 0x1000)
    t.put(0x1C, ALL, 0x800)
    t.put(0x60C, 0xFFFFFBFF, 0)
    t.put(0x60C, ALL, 0x04000000)
    t.tone(True)
    t.sample(123)
    ref = (-32768, -32768) if case == "walk-low" else (0, -100)
    t.sample(*ref)
    target = int(sum(v * v for v in ref) * 0.81)
    t.tone(False)

    def probe(code, above):
        # +0x3c4 / +0x482: no narrowing, even outside 0..63.
        t.put(0x80, 0xC0FFC0FF, (code << 24) | (code << 8))
        low = (30000, 0) if ref[0] else (0, -90)  # equality takes the low branch
        pair = (-32768, -32768) if above else low
        t.sample(*pair)
        assert (sum(v*v for v in pair) > target) == above

    code = 0
    for step in (32, 16, 8, 4, 2, 1):
        above = case == "walk-high" or (case.startswith("lock") and step in (16, 2))
        probe(code + step, above)
        if above:
            code += step
    # Explicit terminating histories, and 63-measurement exhaustion on either side.
    fine = {"lock-5": [True, False, True], "lock-10": [True, True, False, True, False],
            "walk-low": [False] * 63, "walk-high": [True] * 63}[case]
    for above in fine:
        probe(code, above)
        code += 1 if above else -1
    t.publish()
    for addr, value in zip(SNAPSHOT, saved):
        t.write(addr, value)
    t.put(0x8C, 0xFFFFEFFF, 0)
    if case.startswith("lock"):
        t.put(0x14, ALL, 0xC0000)
    else:
        t.put(0x14, 0xFFF3FFFF, 0x80000)
    return target


def harness():
    rf = RF.read_text()
    code = object_type(rf, "RfRegBlock") + object_type(rf, "RfDfeInitBlock")
    for name in ("RfRccalModeMask", "RfRccalStartMode", "RfRccalDoneMode",
                 "RfRccalFailMode", "RfRccalCapabilityMask", "RfRccalCodeMask",
                 "RfCalibRccalReplayWordIndex", "RfMeasureRccalTriggerMask",
                 "RfMeasureStartMask", "RfMeasureReadyMask", "RfRccalWaitLimit"):
        code += "const " + next(s.strip() for s in rf.splitlines() if s.startswith(f"  {name} = ")) + "\n"
    code += r'''
import std/strutils
var
  rf: RfRegBlock
  dfe: RfDfeInitBlock
  records: array[3, uint32]
  rfCalibDataGlobal: pointer
  events: seq[string]
  pos: int
  nim_wifi_rf_pri_rccal_count, nim_wifi_rf_rccal_wait_timeout_count: uint32
  nim_wifi_rf_last_rccal_code, nim_wifi_rf_last_rccal_power: uint32
  nim_wifi_rf_last_rccal_baseline, nim_wifi_rf_last_rccal_target: uint32
  nim_wifi_rf_rccal_search_log, nim_wifi_rf_rccal_power_log: array[32, uint32]
proc rfRegs(): ptr RfRegBlock = addr rf
proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr dfe
proc offset(p: ptr uint32): int =
  if p == addr dfe.hbnCtrl30: return 0xE030
  if p == addr records[2]: return 0x10008
  cast[int](p) - cast[int](addr rf)
proc take(kind: string; off: int): uint32 =
  doAssert pos < events.len, "unexpected " & kind & " at " & toHex(off)
  let parts = events[pos].splitWhitespace
  doAssert parts[0] == kind and parseHexInt(parts[1]) == off,
    "event " & $pos & ": expected " & events[pos] & ", got " & kind & " " & toHex(off)
  inc pos
  uint32(parseHexInt(parts[2]))
proc volatileLoad(p: ptr uint32): uint32 = take("R", offset(p))
proc volatileStore(p: ptr uint32; v: uint32) =
  let wanted = take("W", offset(p))
  doAssert wanted == v, "event " & $(pos-1) & ": expected " & toHex(wanted) & ", got " & toHex(v)
proc updateReg32(p: ptr uint32; keep, bits: uint32) =
  volatileStore(p, (volatileLoad(p) and keep) or bits)
proc waitBl808RfCalUs(us: uint32) = doAssert take("D", 0) == us
'''
    for name in ("programRfPriModeRegisters", "startRfPriTxDfeForCal",
                 "signedRfPowerMeasurement", "squareRfSample", "saturatingRfUint32",
                 "waitRfRccalMeasurementReady", "sampleRfRccalPower", "logRfRccalSearch"):
        code += procedure(rf, name)
    code += RF.with_name("rf_bl808_calibration_snapshot.nim").read_text()
    return code + f'include "{NATIVE}"\n' + r'''
proc replay(path: string; storage, ran: bool; target: uint32) =
  events = readFile(path).strip.splitLines
  pos = 0
  nim_wifi_rf_pri_rccal_count = 0
  rfCalibDataGlobal = if storage: addr records[0] else: nil
  runBl808Rccal()
  doAssert pos == events.len, "missing event " & $pos
  doAssert nim_wifi_rf_pri_rccal_count == ran.uint32
  if ran: doAssert nim_wifi_rf_last_rccal_target == target
'''


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_native_rccal_trace(tmp_path: Path, mode: str) -> None:
    code = harness()
    for seed in (0, ALL):
        for case in ("disabled", "no-buffer", "lock-5", "lock-10", "walk-low", "walk-high"):
            trace = Trace(seed)
            target = run_vector(trace, case)
            path = tmp_path / f"{case}-{seed:x}.trace"
            path.write_text("".join(f"{k} {a:x} {v:08x}\n" for k, a, v in trace.events))
            storage = str(case != "no-buffer").lower()
            ran = str(target is not None).lower()
            code += f'replay("{path}", {storage}, {ran}, {target or 0}\'u32)\n'
    run_program(tmp_path, mode, code)
