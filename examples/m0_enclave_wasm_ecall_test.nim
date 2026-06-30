## Enclave U-mode ecall test for flash-backed WASM invocation.
##
## Installs a compact WASM program into the managed flash slot, locks the
## enclave partition, drops to U-mode, and invokes the program through the real
## ecall service boundary.

import bl808/startup, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/umode
import bl808/enclave/enclave, bl808/enclave/partition, bl808/enclave/vault
import bl808/enclave/abi, bl808/enclave/services
import bl808/kernel/alloc
import bl808/panicoverride
import bl808/wasm_control
import bl808/wasm_slot_smoke

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  SharedAddr = 0x6202F000'u
  SvcReportInvoke = 0xAA'u32
  SvcReportManage = 0xAB'u32
  UModeManagedSlot = 3'u32

var
  console: Uart
  sawInvokeReport = false
  sawManageReport = false
  sawFailure = false

proc line(s: string) = discard console.sendLine(s)

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)

proc maybeFinish() =
  if sawInvokeReport and sawManageReport:
    if sawFailure:
      line("=== Test Failed ===")
    else:
      line("=== Test Complete ===")

proc ecallDispatch(frame: ptr EcallFrame) {.nimcall.} =
  if frame.a0 == SvcReportInvoke:
    check("U-mode invoked WASM through enclave ecall", frame.a1 == 1)
    sawInvokeReport = true
    if frame.a1 != 1:
      sawFailure = true
    maybeFinish()
    frame.a0 = 0
    frame.a1 = 0
  elif frame.a0 == SvcReportManage:
    check("U-mode managed WASM slot through enclave ecall", frame.a1 == 1)
    sawManageReport = true
    if frame.a1 != 1:
      sawFailure = true
    maybeFinish()
    frame.a0 = 0
    frame.a1 = 0
  else:
    let buf = cast[ptr UncheckedArray[uint8]](SharedAddr)
    let (st, resp) = enclaveDispatch(
      callerUmodeAppCtx(),
      toSvcId(frame.a0),
      frame.a1.int,
      buf,
      4096,
    )
    frame.a0 = st.uint32
    frame.a1 = resp.uint32

proc uEcall(svc, reqLen: uint32): tuple[status, rlen: uint32] =
  var st = svc
  var rl = reqLen
  {.emit: """
    register unsigned long a0 asm("a0") = `st`;
    register unsigned long a1 asm("a1") = `rl`;
    __asm__ volatile("ecall" : "+r"(a0), "+r"(a1) :: "memory");
    `st` = a0; `rl` = a1;
  """.}
  (st, rl)

proc putInstallReq(buf: ptr UncheckedArray[uint8], slot: uint32): uint32 =
  wrU32(buf, 0, slot)
  wrU32(buf, 4, 9'u32)
  wrU32(buf, 8, 0'u32)
  wrU32(buf, 12, WasmSlotAddModule.len.uint32)
  for i in 0 ..< WasmSlotAddModule.len:
    buf[16 + i] = WasmSlotAddModule[i]
  (16 + WasmSlotAddModule.len).uint32

proc putInvokeReq(buf: ptr UncheckedArray[uint8], slot: uint32,
                  a, b: int32): uint32 =
  let exportName = "add"
  wrU32(buf, 0, slot)
  wrU32(buf, 4, exportName.len.uint32)
  wrU32(buf, 8, 2)
  wrU32(buf, 12, cast[uint32](a))
  wrU32(buf, 16, cast[uint32](b))
  for i in 0 ..< exportName.len:
    buf[20 + i] = exportName[i].uint8
  (20 + exportName.len).uint32

proc invokeAddViaEcall(buf: ptr UncheckedArray[uint8], slot: uint32,
                       a, b: int32): bool =
  let reqLen = putInvokeReq(buf, slot, a, b)
  let r = uEcall(svcWasmInvokeI32.uint32, reqLen)
  r.status == svcOk.uint32 and r.rlen == 16 and
    rdU32(buf, 0) == wasmControlOk.ord.uint32 and
    cast[int32](rdU32(buf, 12)) == 42'i32

proc umodeApp() {.exportc: "umode_app", cdecl.} =
  let buf = cast[ptr UncheckedArray[uint8]](SharedAddr)
  let caps = uEcall(svcWasmCapabilities.uint32, 0)
  let capsOk =
    caps.status == svcOk.uint32 and caps.rlen == 32 and
    rdU32(buf, 0) == wasmCoreM0.ord.uint32 and
    rdU32(buf, 4) == 1'u32 and
    rdU32(buf, 8) == 1'u32 and
    rdU32(buf, 12) == 1'u32 and
    rdU32(buf, 16) == 1'u32 and
    rdU32(buf, 20) == 1'u32 and
    rdU32(buf, 24) == 0'u32 and
    rdU32(buf, 28) == 0'u32

  let invokeOk = capsOk and invokeAddViaEcall(buf, WasmSlotSmokeSlot, 18'i32, 24'i32)
  discard uEcall(SvcReportInvoke, if invokeOk: 1'u32 else: 0'u32)

  let installLen = putInstallReq(buf, UModeManagedSlot)
  let install = uEcall(svcWasmInstallBytes.uint32, installLen)
  let installOk =
    install.status == svcOk.uint32 and install.rlen == 16 and
    rdU32(buf, 0) == wasmControlOk.ord.uint32 and
    cast[int32](rdU32(buf, 12)) == UModeManagedSlot.int32

  let managedInvokeOk =
    installOk and invokeAddViaEcall(buf, UModeManagedSlot, 20'i32, 22'i32)

  wrU32(buf, 0, UModeManagedSlot)
  let unload = uEcall(svcWasmUnloadSlot.uint32, 4)
  let unloadOk =
    unload.status == svcOk.uint32 and unload.rlen == 16 and
    rdU32(buf, 0) == wasmControlOk.ord.uint32 and
    cast[int32](rdU32(buf, 12)) == UModeManagedSlot.int32

  discard uEcall(SvcReportManage,
                 if installOk and managedInvokeOk and unloadOk: 1'u32 else: 0'u32)
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}

proc umodeAppAddr(): uint =
  {.emit: "`result` = (NU)(&umode_app);".}

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone),
    ConsoleClkHz)

  line("")
  line("=== BL808 Enclave WASM Ecall Test ===")

  let installStatus = installWasmSlotSmoke()
  check("installed WASM slot for U-mode ecall", installStatus == WasmSlotSmokeOk)
  if installStatus != WasmSlotSmokeOk:
    line("=== Test Failed ===")
    while true: wfi()

  let ok = enclaveInit(defaultPartition(lock = true), rkSoftDev)
  check("enclaveInit with LOCKED partition", ok)
  if not ok:
    line("=== Test Failed ===")
    while true: wfi()

  enclaveSetEcallDispatch(ecallDispatch)
  line("[M0] partition locked; entering WASM U-mode...")
  enclaveRunUmode(umodeAppAddr())
