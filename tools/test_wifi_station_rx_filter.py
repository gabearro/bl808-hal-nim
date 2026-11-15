"""Keep station TX builders from replacing the installed MAC/RX configuration."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_station_tx_build import program_source


def replace_once(source: str, old: str, new: str) -> str:
    assert source.count(old) == 1
    return source.replace(old, new, 1)


def source() -> str:
    sm = (FW / "scan_station_ap_me.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    code = "import std/tables\n" + program_source()
    code = replace_once(code, "  MACHW_BASE = 0'u", "  MACHW_BASE = 0x24B00000'u")
    code = replace_once(code, "  MACHW_RX_CNTRL_REG = 0x60'u",
                        "  MACHW_RX_CNTRL_REG = MACHW_BASE + 0x60'u\n"
                        "  MACHW_STATUS_REG = MACHW_BASE + 0x4C'u")
    code = replace_once(code, "  SCAN_ACTIVE_RX_FILTER_BITS = 0x10'u32",
                        "  SCAN_ACTIVE_RX_FILTER_BITS = 0x2200'u32\n"
                        "  SCAN_PASSIVE_RX_FILTER_BITS = 0x2000'u32\n"
                        "  SCAN_EDCA_RX_FILTER_CLEAR_MASK = 0xFFFFDDFF'u32")
    code = replace_once(code, "    rxFilterExtra, rxFilterBase: uint32",
                        "    rxFilterExtra, rxFilterBase, rxPromiscUploadFlag: uint32")
    code = replace_once(code, "var\n  sm: SmEnv", "type\n"
                        "  VifChannelView = Vif\n  MacAddrView = MacAddress\n"
                        "var\n  registers = initTable[uint, uint32]()\n"
                        "  writes: seq[tuple[address: uint, value: uint32]]\n  sm: SmEnv")
    code = replace_once(code, "proc regWrite(p: uint; value: uint32) = discard",
                        "proc regWrite(p: uint; value: uint32) =\n"
                        "  registers[p] = value\n  writes.add((p, value))")
    code = replace_once(code, "proc regRead(p: uint): uint32 = 0",
                        "proc regRead(p: uint): uint32 = registers.getOrDefault(p)")
    code = replace_once(code, "proc lowLe(p: ptr MacAddress): uint32 = 0",
                        procedure(layout, "lowLe"))
    code = replace_once(code, "proc highLe(p: ptr MacAddress): uint16 = 0",
                        procedure(layout, "highLe"))
    default_mac = next(line for line in sm.splitlines() if line.startswith("const DefaultStaMacAddr ="))
    code = replace_once(code, "proc ensureVifMgmtMac(p: ptr Vif): pointer = addr p.macAddr[0]",
                        "proc mm_hw_info_set*(macAddr: pointer) {.exportc, cdecl.}\n"
                        "proc mm_rx_filter_set*() {.exportc, cdecl.}\n" + default_mac + "\n"
                        + procedure(sm, "ensureVifMgmtMac"))
    code = replace_once(code, "proc vifMgmtTxSa(p: ptr Vif): pointer = addr p.macAddr[0]",
                        procedure(sm, "vifMgmtTxSa"))
    code = replace_once(code, "proc mm_rx_filter_set() = observe(5)",
                        procedure(kernel, "mm_rx_filter_set") + procedure(kernel, "mm_hw_info_set"))
    code += "\nproc rfPriApplyWb03ScanRxLatches() = discard\n"
    code += "proc rfPhyTraceCheckpoint(phase: uint32) = discard\n"
    code += "proc nimFwScanRxFilterProbe() = discard\n"
    for name in ["scanChannelRxFilterBits", "applyScanChannelRxFilter", "clearScanEdcaRxFilter"]:
        code += procedure(tasks, name)
    return code + r'''
const AddressRegisters = [MACHW_BASE + 0x10'u, MACHW_BASE + 0x14'u,
  MACHW_BASE + 0x1C'u, MACHW_BASE + 0x20'u, MACHW_BASE + 0x24'u,
  MACHW_STATUS_REG, 0x24B080A4'u, 0x24B080A8'u]
proc setupRadio(base, extra, promiscuous: uint32) =
  mm = Mm(rxFilterBase: base, rxFilterExtra: extra, rxPromiscUploadFlag: promiscuous)
  registers.clear()
  for i, address in AddressRegisters: registers[address] = 0xABC01000'u32 + i.uint32
  registers[MACHW_RX_CNTRL_REG] = base or extra
  writes.setLen(0)
'''


CHECKS = r'''
for kind in 0..1:
  for base in [0x3503858C'u32, 0x3503A58C'u32, 0x3507858C'u32, 0x7FFFFFDE'u32]:
    for extra in [0'u32, 0x40000001'u32, 0x2200'u32]:
      for promiscuous in [0'u32, 1]:
        for missingMac in [false, true]:
          setup(kind)
          setupRadio(base, extra, promiscuous)
          if missingMac: vifs[1].macAddr = default(typeof(vifs[1].macAddr))
          var originalRegisters: array[8, uint32]
          for i, address in AddressRegisters: originalRegisters[i] = registers[address]
          perform(kind)
          doAssert pushes == 1 and failures == 0
          var expectedBase = base
          var expectedExtra = extra
          when defined(bl808WifiAuthHwWorkaround):
            if kind == 0:
              expectedBase = if promiscuous == 0: 0x3503858C'u32 else: 0x3503A58C'u32
              doAssert registers[MACHW_BASE + 0x10] == macAddrAt(addr vifs[1].macAddr[0]).lowLe
              doAssert registers[MACHW_BASE + 0x14] == macAddrAt(addr vifs[1].macAddr[0]).highLe
              doAssert registers[MACHW_BASE + 0x1C] == 0x100
              doAssert registers[MACHW_BASE + 0x20] == macAddrAt(addr vifs[1].bssid[0]).lowLe
              doAssert registers[MACHW_BASE + 0x24] == macAddrAt(addr vifs[1].bssid[0]).highLe
              doAssert registers[MACHW_STATUS_REG] == ((originalRegisters[5] and not 0x702'u32) or 1'u32)
              doAssert registers[0x24B080A4'u] == 0 and registers[0x24B080A8'u] == 0
            else:
              for i, address in AddressRegisters: doAssert registers[address] == originalRegisters[i]
          else:
            for i, address in AddressRegisters:
              doAssert registers[address] == originalRegisters[i], "frame builder replaced MAC configuration"
          when defined(bl808WifiAuthPromiscRx):
            expectedBase = 0x7FFFFFDE'u32
            if kind == 0: expectedExtra = extra or SCAN_ACTIVE_RX_FILTER_BITS
          doAssert mm.rxFilterBase == expectedBase, "frame builder replaced RX filter"
          doAssert mm.rxFilterExtra == expectedExtra, "frame builder restored scan-only flags"
          doAssert mm.rxPromiscUploadFlag == promiscuous
          doAssert registers[MACHW_RX_CNTRL_REG] == (expectedBase or expectedExtra)
          when not defined(bl808WifiAuthHwWorkaround) and not defined(bl808WifiAuthPromiscRx):
            doAssert writes.len == 0
          let hdr = hostTxDataHeader(activeFrame)
          doAssert hdr.addr1 == vifs[1].bssid and hdr.addr3 == vifs[1].bssid
          let expectedMac = if missingMac: DefaultStaMacAddr else: vifs[1].macAddr
          doAssert hdr.addr2 == expectedMac
          doAssert currentState == (if kind == 0: 6'u16 else: 8'u16) and timerDelay == 0x7D000
'''


def run(tmp_path: Path, mode: str, body: str, flags: tuple[str, ...] = ()) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "station_rx_filter.nim"
    path.write_text(source() + body)
    modes = {
        "checked": [],
        "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"],
        "forced_trace": ["-d:bl808WifiForceAuthAssocPush", "-d:bl808WifiConnectTrace"],
    }
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", f"--path:{ROOT / 'src'}", *modes[mode],
        *(f"-d:{flag}" for flag in flags), f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'check'}", str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "forced_trace"])
@pytest.mark.parametrize("flags", [(), ("bl808WifiAuthPromiscRx",), ("bl808WifiAuthHwWorkaround",),
                                   ("bl808WifiAuthPromiscRx", "bl808WifiAuthHwWorkaround")],
                         ids=["default", "rx", "mac", "combined"])
def test_station_rx_configuration(tmp_path: Path, mode: str, flags: tuple[str, ...]) -> None:
    run(tmp_path, mode, CHECKS, flags)


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "forced_trace"])
def test_completed_scan_filter_is_preserved(tmp_path: Path, mode: str) -> None:
    run(tmp_path, mode, r'''
for kind in 0..1:
  for passive in [0'u8, 1, 2, 3]:
    setup(kind)
    setupRadio(0x3503858C'u32, 0x00400001'u32, 0)
    applyScanChannelRxFilter(passive)
    clearScanEdcaRxFilter()
    let completed = mm
    let completedRegister = registers[MACHW_RX_CNTRL_REG]
    writes.setLen(0)
    perform(kind)
    doAssert pushes == 1 and failures == 0
    doAssert mm == completed, "connection builder changed completed scan's filter"
    doAssert registers[MACHW_RX_CNTRL_REG] == completedRegister and writes.len == 0
''')
