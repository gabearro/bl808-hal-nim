"""Check firmware startup ordering and callback ABI against arch_main.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
import std/[tables, strutils]
const
  INTC_PEND_REG = 0x40000010'u
  MACHW_BCN_STATUS_REG = 0x24B00400'u
  COEX_CTRL_REG = 0x24920004'u
type
  StopService = object of CatchableError
  LegacyLogFn = proc(level, severity: uint32; file: pointer;
                     line: uint32) {.cdecl, varargs.}
var
  registers: Table[uint, uint32]
  writes: seq[tuple[address: uint, value: uint32]]
  steps: seq[string]
  messages: seq[tuple[line: cint, message: string]]
  interrupts, incomingIrq, loggerEnabled, blReady: bool
  logLookups, serviceCalls: int
  onInit: proc(name: string)
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and file == cstring("arch_main.c")
  doAssert format != nil and interrupts == incomingIrq
  var output: array[96, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size > 0 and size < output.len.cint
  messages.add((line, $cast[cstring](addr output[0])))
  steps.add("log:" & $line)
proc wrongPrintf(format: cstring) {.cdecl, varargs.} =
  doAssert false, "structured startup log used the printf slot"
proc blOpsFunc(slot: int): pointer =
  case slot
  of 204:
    inc logLookups
    if loggerEnabled: cast[pointer](logger) else: nil
  of 4: (if loggerEnabled: cast[pointer](wrongPrintf) else: nil)
  else: raiseAssert "unexpected operation slot"
proc getLogFunc(slot: int): LegacyLogFn = cast[LegacyLogFn](blOpsFunc(slot))
proc irqSave(): uint32 =
  steps.add("lock")
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) =
  interrupts = (saved and 8) != 0
  steps.add("restore")
proc regRead(address: uint): uint32 = registers.getOrDefault(address)
proc regWrite(address: uint; value: uint32) =
  registers[address] = value
  writes.add((address, value))
  case address
  of INTC_PEND_REG: steps.add("intc")
  of MACHW_BCN_STATUS_REG: steps.add("control")
  of MACHW_BCN_STATUS_REG + 4: steps.add("timing")
  of COEX_CTRL_REG: steps.add("coex")
  else: raiseAssert "unexpected register"
proc arch_delay_us(delay: uint32) =
  doAssert delay == 100 and not interrupts
  steps.add("delay")
proc note(name: string) =
  doAssert interrupts == incomingIrq
  steps.add(name)
  if onInit != nil: onInit(name)
proc wifi_hosal_rf_turn_on() = note("rf-on")
proc wifiRfCoreInit(frequency: uint32) =
  doAssert frequency == 40000000
  note("rf-init")
proc mpif_clk_init() = note("mpif")
proc sysctrl_init() = note("sysctrl")
proc intc_init() = note("intc-init")
proc ipc_emb_init() = note("ipc")
proc bl_init(): bool {.discardable.} =
  note("bl")
  blReady
proc bl_pm_ops_register(argument: pointer) =
  doAssert argument == nil
  note("pm")
proc wifiMainServiceBlockingIdle(): bool =
  doAssert interrupts == incomingIrq
  steps.add("service")
  inc serviceCalls
  if serviceCalls == 3: raise newException(StopService, "end fixture")
  true
proc setup(irq, logging: bool; initial: uint32) =
  registers.clear()
  registers[INTC_PEND_REG] = initial
  registers[MACHW_BCN_STATUS_REG] = 0xA4
  writes.setLen(0)
  steps.setLen(0)
  messages.setLen(0)
  interrupts = irq
  incomingIrq = irq
  loggerEnabled = logging
  blReady = true
  logLookups = 0
  serviceCalls = 0
  onInit = nil
let expectedMessages = @[
  (268.cint, "[WF] Running Wi-Fi FW thread...\r\n"),
  (286.cint, "Done\r\n"),
  (295.cint, "Configure IPC...\r\n"),
  (297.cint, "Done\r\n"),
  (299.cint, "Configure MAC...\r\n"),
  (301.cint, "Done\r\n"),
  (315.cint, "Starting loop...\r\n")]
let expectedSteps = @[
  "log:268", "lock", "intc", "delay", "intc", "delay", "restore",
  "rf-on", "rf-init", "log:286", "control", "mpif", "sysctrl", "intc-init",
  "log:295", "ipc", "log:297", "log:299", "bl", "log:301", "pm", "log:315",
  "timing", "control", "control", "control", "control", "control", "coex",
  "service", "service", "service"]
proc expectedWrites(initial: uint32): seq[tuple[address: uint, value: uint32]] =
  @[
    (INTC_PEND_REG, initial or 0x10'u32),
    (INTC_PEND_REG, initial and not 0x10'u32),
    (MACHW_BCN_STATUS_REG, 0xA5'u32),
    (MACHW_BCN_STATUS_REG + 4, 0x0024F037'u32),
    (MACHW_BCN_STATUS_REG, 0xA5'u32),
    (MACHW_BCN_STATUS_REG, 0xA4'u32),
    (MACHW_BCN_STATUS_REG, 0x68'u32),
    (MACHW_BCN_STATUS_REG, 0x69'u32),
    (MACHW_BCN_STATUS_REG, 0x49'u32),
    (COEX_CTRL_REG, 0x5010001F'u32)]
proc checkRegisters(initial: uint32) =
  doAssert writes == expectedWrites(initial)
  doAssert registers[INTC_PEND_REG] == (initial and not 0x10'u32)
  doAssert registers[MACHW_BCN_STATUS_REG] == 0x49
  doAssert serviceCalls == 3 and interrupts == incomingIrq
'''


def source() -> str:
    text = (FW / "task_init_main.nim").read_text()
    code = PLATFORM
    if "proc wifiMainLog(" in text:
        code += procedure(text, "wifiMainLog")
    code += procedure(text, "wifi_main")
    return code + r'''
proc runStartup() =
  var stopped = false
  try: wifi_main(nil)
  except StopService: stopped = true
  doAssert stopped
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_startup_log_abi_and_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for initial in [0xA5A50121'u32, 0xA5A50131'u32]:
    setup(irq, true, initial)
    runStartup()
    doAssert messages == expectedMessages
    doAssert steps == expectedSteps
    doAssert logLookups == 7
    checkRegisters(initial)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_startup_without_logger(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  setup(irq, false, 0xA5A50121'u32)
  runStartup()
  var expected: seq[string]
  for step in expectedSteps:
    if not step.startsWith("log:"): expected.add(step)
  doAssert steps == expected and messages.len == 0
  doAssert logLookups == 7
  checkRegisters(0xA5A50121'u32)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_startup_reloads_logger_between_stages(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  setup(irq, true, 0xA5A50121'u32)
  onInit = proc(name: string) =
    if name == "intc-init": loggerEnabled = false
    elif name == "ipc": loggerEnabled = true
  runStartup()
  var expected: seq[string]
  for step in expectedSteps:
    if step != "log:295": expected.add(step)
  doAssert steps == expected
  doAssert messages == expectedMessages[0 .. 1] & expectedMessages[3 .. ^1]
  doAssert logLookups == 7
  checkRegisters(0xA5A50121'u32)
''')


def backend_source() -> str:
    path = FW.parent / "support/backend_startup.nim"
    code = PLATFORM + r'''
const
  IntcPend = INTC_PEND_REG.uint32
  BcnStatus = MACHW_BCN_STATUS_REG.uint32
  CoexCtrl = COEX_CTRL_REG.uint32
var fwStarted: bool
proc regRead32(address: uint32): uint32 = regRead(address.uint)
proc regWrite32(address, value: uint32) = regWrite(address.uint, value)
proc osEnterCritical(): uint32 = irqSave()
proc osExitCritical(saved: uint32) = irqRestore(saved)
proc bl808WifiBackendTrace(message: cstring) = discard
proc setupBlOps() = note("setup-ops")
proc setupHosal() = note("setup-hosal")
proc bl808WifiBackendPrepareWirelessDomain(forceReset: bool) =
  doAssert forceReset
  note("domain-reset")
proc bl_wifi_clock_enable(): cint =
  note("clock-enable")
  0
proc wifi_hosal_rf_turn_on(argument: pointer): cint =
  doAssert argument == nil
  wifi_hosal_rf_turn_on()
  0
proc bl808WifiBackendApplyHighPowerProfile() = note("power-profile")
proc bl808WifiBackendClearEmbIpc() = note("clear-embedded")
proc bl808WifiBackendClearHostIpc() = note("clear-host")
proc bl_pm_ops_register() = bl_pm_ops_register(nil)
''' + procedure(path.read_text(), "bl808WifiBackendFwStart")
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_backend_startup_control_and_idempotence(tmp_path: Path, mode: str) -> None:
    code = backend_source()
    run_program(tmp_path, mode, code + r'''
for irq in [false, true]:
  for initial in [0xA5A50121'u32, 0xA5A50131'u32]:
    setup(irq, false, initial)
    fwStarted = false
    onInit = proc(name: string) =
      if name == "mpif":
        doAssert (registers[MACHW_BCN_STATUS_REG] and 1) != 0,
          "initial MAC control bit was not enabled before MPIF"
    bl808WifiBackendFwStart()
    doAssert steps == @[
      "setup-ops", "setup-hosal", "domain-reset", "clock-enable",
      "lock", "intc", "delay", "intc", "delay", "restore", "rf-on", "rf-init",
      "control", "power-profile", "mpif", "sysctrl", "intc-init", "ipc",
      "clear-embedded", "clear-host", "bl", "pm", "timing", "control",
      "control", "control", "control", "control", "coex"]
    doAssert writes == expectedWrites(initial)
    doAssert fwStarted and interrupts == irq
    let previousSteps = steps
    let previousWrites = writes
    bl808WifiBackendFwStart()
    doAssert steps == previousSteps and writes == previousWrites
    doAssert messages.len == 0 and logLookups == 0
''')
