## M0 client for LP IPC register probing.
##
## Keeps JTAG on M0, releases LP from WRAM, then asks LP over IPC to read a
## register table. This confirms LP's own bus-visible values without switching
## the external JTAG pin mux away from M0.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap
import bl808/ipc
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/cps
import bl808/kernel/ipcbridge
import bl808/kernel/sched

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

  RpcTagRead32 = 0x40'u16
  RpcTimeoutMs = 1_000'u64

  LpStatusAddr = XramBase + 0x2EC0'u
  LpStageAddr = XramBase + 0x2EC4'u
  LpHeartbeatAddr = XramBase + 0x2EC8'u
  LpLastReadAddr = XramBase + 0x2ECC'u
  LpLastReadValueAddr = XramBase + 0x2ED0'u
  LpAliveMarker = 0x1EC0_E902'u32

  GlbParmCfg0 = GlbBase + 0x510'u
  GlbSwrstCfg2 = GlbBase + 0x548'u
  GlbCgenCfg0 = GlbBase + 0x580'u
  GlbCgenCfg1 = GlbBase + 0x584'u
  GlbCgenCfg2 = GlbBase + 0x588'u
  GpioConfigBase = GlbBase + 0x8C4'u
  PdsCpuCoreCfg0 = PdsBase + 0x110'u
  PdsCpuCoreCfg8 = PdsBase + 0x130'u
  PdsCpuCoreCfg13 = PdsBase + 0x144'u
  SecDbgStatus = SecDbgBase + 0x18'u
  EfCfg0 = EfCtrlBase + 0x0'u

type ProbeReg = object
  name: string
  address: uint

const ProbeRegs = [
  ProbeReg(name: "CORE_ID", address: CoreIdAddr),
  ProbeReg(name: "GLB_PARM_CFG0", address: GlbParmCfg0),
  ProbeReg(name: "GLB_SWRST_CFG2", address: GlbSwrstCfg2),
  ProbeReg(name: "GLB_CGEN_CFG0", address: GlbCgenCfg0),
  ProbeReg(name: "GLB_CGEN_CFG1", address: GlbCgenCfg1),
  ProbeReg(name: "GLB_CGEN_CFG2", address: GlbCgenCfg2),
  ProbeReg(name: "PDS_CPU_CORE_CFG0", address: PdsCpuCoreCfg0),
  ProbeReg(name: "PDS_CPU_CORE_CFG8", address: PdsCpuCoreCfg8),
  ProbeReg(name: "PDS_CPU_CORE_CFG13", address: PdsCpuCoreCfg13),
  ProbeReg(name: "GPIO2_CFG", address: GpioConfigBase + 2'u * 4'u),
  ProbeReg(name: "GPIO3_CFG", address: GpioConfigBase + 3'u * 4'u),
  ProbeReg(name: "GPIO4_CFG", address: GpioConfigBase + 4'u * 4'u),
  ProbeReg(name: "GPIO5_CFG", address: GpioConfigBase + 5'u * 4'u),
  ProbeReg(name: "GPIO6_CFG", address: GpioConfigBase + 6'u * 4'u),
  ProbeReg(name: "GPIO7_CFG", address: GpioConfigBase + 7'u * 4'u),
  ProbeReg(name: "GPIO12_CFG", address: GpioConfigBase + 12'u * 4'u),
  ProbeReg(name: "GPIO13_CFG", address: GpioConfigBase + 13'u * 4'u),
  ProbeReg(name: "SEC_DBG_STATUS", address: SecDbgStatus),
  ProbeReg(name: "EF_CFG0", address: EfCfg0),
]

var console: Uart
var passed = 0
var failed = 0

proc printHex(label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)

proc printHexLine(label: string, value: uint32) =
  printHex(label, value)
  discard console.sendLine("")

proc printProbe(name: string, address: uint, m0Value, lpValue: uint32) =
  discard console.sendString("  ")
  discard console.sendString(name)
  discard console.sendString(" @ ")
  console.sendHex32(address.uint32)
  discard console.sendString("  m0=")
  console.sendHex32(m0Value)
  discard console.sendString("  lp=")
  console.sendHex32(lpValue)
  if m0Value == lpValue:
    discard console.sendLine("  [same]")
  else:
    discard console.sendLine("  [diff]")

proc sharedRead32(address: uint): uint32 =
  dcacheFlushAll()
  dcacheInvalidateAll()
  core.fence()
  regRead(address)

proc clearLpDiagnostics() =
  const addrs = [
    LpStatusAddr,
    LpStageAddr,
    LpHeartbeatAddr,
    LpLastReadAddr,
    LpLastReadValueAddr,
  ]
  for address in addrs:
    regWrite(address, 0)
  dcacheFlushAll()
  fenceIo()

proc runProbe(): CpsVoidFuture {.cps.} =
  discard console.sendLine("[M0] Waiting for LP IPC register server")
  var lpAlive = false
  for _ in 0 ..< 40:
    if sharedRead32(LpStatusAddr) == LpAliveMarker:
      lpAlive = true
      break
    await sleepMs(100)

  if not lpAlive:
    discard console.sendLine("[FAIL] LP IPC register server did not start")
    failed += 1
    return

  discard console.sendLine("[OK] LP IPC register server alive")
  passed += 1
  printHexLine("  lp_stage=", sharedRead32(LpStageAddr))
  printHexLine("  lp_heartbeat=", sharedRead32(LpHeartbeatAddr))

  discard console.sendLine("[M0] LP RPC register readback")
  for item in ProbeRegs:
    let m0Value = regRead(item.address)
    try:
      let lpValue = await ipcCallU32To(
        ipcLP, RpcTagRead32, item.address.uint32, timeoutMs = RpcTimeoutMs)
      printProbe(item.name, item.address, m0Value, lpValue)
      passed += 1
    except CatchableError:
      discard console.sendString("  ")
      discard console.sendString(item.name)
      discard console.sendLine("  [FAIL] RPC timeout/error")
      failed += 1

  printHexLine("  lp_last_read_addr=", sharedRead32(LpLastReadAddr))
  printHexLine("  lp_last_read_value=", sharedRead32(LpLastReadValueAddr))

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0:
    discard console.sendLine("=== LP IPC REG PROBE PASSED ===")
  else:
    discard console.sendLine("=== LP IPC REG PROBE FAILED ===")

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 LP IPC Register Probe (M0) ===")
  clearLpDiagnostics()

  heapInit()
  schedulerInit()
  ipcBridgeInit()

  discard console.sendLine("[M0] Releasing LP")
  mmPowerOn()
  releaseLP()

  discard runProbe()
  runScheduler()
