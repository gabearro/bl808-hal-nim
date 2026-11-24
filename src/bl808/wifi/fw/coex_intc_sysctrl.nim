# ###########################################################################
#                  Coexistence (coex_*)
# ###########################################################################

type CoexDumpLogFn = proc(level: uint32; tag, file: cstring; line: cint;
                           format: cstring) {.cdecl, varargs.}

proc coexDumpHeader(line: cint; message: cstring) {.noinline.} =
  let logFn = cast[CoexDumpLogFn](blOpsFunc(204))
  if logFn != nil:
    logFn(2, nil, "arch_main.c", line, message)

proc coexDumpRegister(line: cint; value: uint32) {.noinline.} =
  let logFn = cast[CoexDumpLogFn](blOpsFunc(204))
  if logFn != nil:
    logFn(2, nil, "arch_main.c", line, "value is %08lx\r\n", value.culong)

proc coexDumpField(line: cint; format: cstring; value: uint32) {.noinline.} =
  let logFn = cast[CoexDumpLogFn](blOpsFunc(204))
  if logFn != nil:
    logFn(2, nil, "arch_main.c", line, format, value.cuint)

proc coex_dump_pta*() {.exportc, cdecl.} =
  coexDumpHeader(400, "=============    Coex PTA: enable==================\r\n")
  coexDumpRegister(363, ptaCoexControl())
  let reg = ptaCoexControl()
  coexDumpField(382, "abortrxwhentx is %u\r\n", (reg shr 20) and 1)
  coexDumpField(383, "swwlanrxabort is %u\r\n", (reg shr 19) and 1)
  coexDumpField(384, "swwlantxabort is %u\r\n", (reg shr 18) and 1)
  coexDumpField(385, "swbtrxabort is %u\r\n", (reg shr 17) and 1)
  coexDumpField(386, "swbttxabort is %u\r\n", (reg shr 16) and 1)
  coexDumpField(387, "chanmargin is %u\r\n", (reg shr 8) and 0x3F)
  coexDumpField(388, "wlanptimode is %u\r\n", (reg shr 7) and 1)
  coexDumpField(389, "bteventmask is %u\r\n", (reg shr 6) and 1)
  coexDumpField(390, "chanenable is %u\r\n", (reg shr 5) and 1)
  coexDumpField(391, "ptienable is %u\r\n", (reg shr 4) and 1)
  coexDumpField(392, "nosimrx is %u\r\n", (reg shr 3) and 1)
  coexDumpField(393, "nosimtx is %u\r\n", (reg shr 2) and 1)
  coexDumpField(394, "basicpriority is %u\r\n", (reg shr 1) and 1)
  coexDumpField(395, "ptaenable is %u\r\n", reg and 1)

proc coex_dump_wifi*() {.exportc, cdecl.} =
  coexDumpHeader(513, "=============    Coex WiFi: cntl==================\r\n")
  coexDumpRegister(421, wlanCoexControl())
  let control = wlanCoexControl()
  coexDumpField(439, "coexforcewlanpti is %u\r\n", control shr 28)
  coexDumpField(440, "coexforcewlanptitoggle is %u\r\n", (control shr 27) and 1)
  coexDumpField(441, "coexforcewlanchanbw is %u\r\n", (control shr 26) and 1)
  coexDumpField(442, "coexforcewlanrx is %u\r\n", (control shr 25) and 1)
  coexDumpField(443, "coexforcewlantx is %u\r\n", (control shr 24) and 1)
  coexDumpField(444, "coexwlanchanfreq is %u\r\n", (control shr 16) and 0x7F)
  coexDumpField(445, "coexwlanchanoffset is %u\r\n", (control shr 12) and 1)
  coexDumpField(446, "coexautoptiadjincr is %u\r\n", (control shr 6) and 3)
  coexDumpField(447, "coexautoptiadjenable is %u\r\n", (control shr 5) and 1)
  coexDumpField(448, "coexforceenable is %u\r\n", (control shr 4) and 1)
  coexDumpField(449, "coexpostponetxenable is %u\r\n", (control shr 3) and 1)
  coexDumpField(450, "coexphyrxabortenable is %u\r\n", (control shr 2) and 1)
  coexDumpField(451, "coexphytxabortenable is %u\r\n", (control shr 1) and 1)
  coexDumpField(452, "coexenable is %u\r\n", control and 1)

  coexDumpHeader(515, "=============    Coex WiFi: pti==================\r\n")
  coexDumpRegister(466, wlanCoexPti())
  let pti = wlanCoexPti()
  coexDumpField(470, "coexptibcndata is %u\r\n", pti shr 28)
  coexDumpField(471, "coexptibkdata is %u\r\n", (pti shr 24) and 0xF)
  coexDumpField(472, "coexptibedata is %u\r\n", (pti shr 20) and 0xF)
  coexDumpField(473, "coexptividata is %u\r\n", (pti shr 16) and 0xF)
  coexDumpField(474, "coexptivodata is %u\r\n", (pti shr 12) and 0xF)
  coexDumpField(475, "coexptimgt is %u\r\n", (pti shr 8) and 0xF)
  coexDumpField(476, "coexpticntl is %u\r\n", (pti shr 4) and 0xF)
  coexDumpField(477, "coexptiack is %u\r\n", pti and 0xF)

  coexDumpHeader(517, "=============    Coex WiFi: status==================\r\n")
  coexDumpRegister(490, wlanCoexStatus())
  let status = wlanCoexStatus()
  coexDumpField(502, "coexwlanptistate is %u\r\n", (status shr 8) and 0xF)
  coexDumpField(503, "coexwlanptitogglestate is %u\r\n", (status shr 5) and 1)
  coexDumpField(504, "coexwlanchanbwstate is %u\r\n", (status shr 4) and 1)
  coexDumpField(505, "coexwlanrxstate is %u\r\n", (status shr 3) and 1)
  coexDumpField(506, "coexwlantxstate is %u\r\n", (status shr 2) and 1)
  coexDumpField(507, "coexwlanrxabortstate is %u\r\n", (status shr 1) and 1)
  coexDumpField(508, "coexwlantxabortstate is %u\r\n", status and 1)

proc coex_wifi_rf_forece_enable*(enable: bool) {.exportc, cdecl.} =
  ## Force enable/disable WiFi RF.
  discard

proc coex_wifi_pti_forece_enable*(enable: bool) {.exportc, cdecl.} =
  ## Preserve the vendor's separate priority, force, and request writes.
  if enable:
    wlanCoexWriteControl((wlanCoexControl() and 0x0FFFFFFF'u32) or 0xF0000000'u32)
    wlanCoexWriteControl(wlanCoexControl() or 0x10'u32)
  else:
    wlanCoexWriteControl(wlanCoexControl() and not 0x10'u32)

  let requestState = wlanCoexControl()
  var coexControl = wlanCoexControl() and not 0x04000000'u32
  if (requestState and 0x08000000'u32) == 0:
    coexControl = coexControl or 0x04000000'u32
  wlanCoexWriteControl(coexControl)

proc coex_wifi_pta_forece_enable*(enable: bool) {.exportc, cdecl.} =
  ## Account for the previous state before recording the new state and time.
  type
    GetTickFn = proc(): uint32 {.cdecl.}
    SleepFn = proc(milliseconds: clong): cint {.cdecl.}
    LogFn = proc(level: uint32; tag, file: cstring; line: cint;
                 format: cstring) {.cdecl, varargs.}
  let curState = coexPtaAutoControl
  let newVal = enable.uint32
  if curState == newVal:
    return
  if curState == 0:
    let now = cast[GetTickFn](blOpsFunc(200))()
    let elapsed = now - coexPtaTimestamp
    pds_slept_time += elapsed
    let logFn = cast[LogFn](blOpsFunc(204))
    let reportTime = cast[GetTickFn](blOpsFunc(200))()
    if logFn != nil:
      logFn(2, nil, "arch_main.c", 588, "[COEX] BLE Usage %ldms\r\n",
            cast[int32](reportTime - coexPtaTimestamp).clong)
  elif curState == 1:
    let now = cast[GetTickFn](blOpsFunc(200))()
    let elapsed = now - coexPtaTimestamp
    pds_woken_time += elapsed
    let savedMstatus = irqSave()
    let napDuration = bl_nap_calculate()
    irqRestore(savedMstatus)
    if napDuration > 1000:
      wifi_hosal_rf_turn_on(nil)
      let sleepFn = cast[SleepFn](blOpsFunc(28))
      discard sleepFn((napDuration div 1000).clong)
      wifi_hosal_rf_turn_off(nil)
    let logFn = cast[LogFn](blOpsFunc(204))
    let reportTime = cast[GetTickFn](blOpsFunc(200))()
    if logFn != nil:
      logFn(2, nil, "arch_main.c", 610, "[COEX] Wi-Fi Usage %ldms\r\n",
            cast[int32](reportTime - coexPtaTimestamp).clong)
  elif curState == high(uint32):
    let logFn = cast[LogFn](blOpsFunc(204))
    if logFn != nil:
      logFn(2, nil, "arch_main.c", 614,
            "[COEX] Skip report for the first time\r\n")
  coexPtaAutoControl = newVal
  coexPtaTimestamp = cast[GetTickFn](blOpsFunc(200))()

proc coex_pta_force_autocontrol_set*(mode: uint32): uint32 {.exportc, cdecl.} =
  ## Set PTA auto-control mode (254 bytes in blob, 104 instrs).
  ## Dispatches on a0 value (0, 1, 2) to configure PTA coex registers.
  ## Mode 0: Disable PTA - WiFi always on
  ## Mode 1: WiFi-priority PTA
  ## Mode 2: BT-priority PTA
  let enableVal = mode

  if enableVal == 1:
    # Mode 1: WiFi-priority PTA
    ptaCoexClear()
    ptaCoexUpdateControl(not 1'u32, 0'u32)
    ptaCoexUpdateControl(0xFFF7FFFF'u32, 0'u32)
    ptaCoexUpdateControl(0xFFFBFFFF'u32, 0'u32)
    ptaCoexUpdateControl(0xFFFDFFFF'u32, 0x00020000'u32)
    ptaCoexUpdateControl(0xFFFEFFFF'u32, 0x00010000'u32)

  elif enableVal == 2:
    # Mode 2: BT-priority PTA
    ptaCoexClear()
    ptaCoexUpdateControl(not 1'u32, 0'u32)
    ptaCoexUpdateControl(0xFFF7FFFF'u32, 0x00080000'u32)
    ptaCoexUpdateControl(0xFFFBFFFF'u32, 0x00040000'u32)
    ptaCoexUpdateControl(0xFFFDFFFF'u32, 0'u32)
    ptaCoexUpdateControl(0xFFFEFFFF'u32, 0'u32)

  else:
    # Mode 0 (default): Disable PTA auto-control - WiFi always on
    ptaCoexClear()
    wlanCoexWriteControl(wlanCoexControl() and not 1'u32)
    ptaCoexUpdateControl(0xFFFDFFFF'u32, 0'u32)
    ptaCoexUpdateControl(0xFFFEFFFF'u32, 0'u32)
    ptaCoexUpdateControl(0xFFF7FFFF'u32, 0'u32)
    ptaCoexUpdateControl(0xFFFBFFFF'u32, 0'u32)
    # Set WiFi always-on bits: bit 4 (auto), bit 1 (priority), bit 0 (enable)
    ptaCoexUpdateControl(not 0'u32, 0x10'u32)
    ptaCoexUpdateControl(not 0'u32, 0x02'u32)
    ptaCoexUpdateControl(not 0'u32, 0x01'u32)
    # Re-enable MAC HW
    wlanCoexWriteControl(wlanCoexControl() or 0x01'u32)
  0'u32

# ###########################################################################
#                  Interrupt Controller (intc_*)
# ###########################################################################

proc intc_enable_irq*(irqNum: uint32) {.exportc, cdecl, noinline.} =
  ## Enable one WiFi platform interrupt source.
  ##
  ## Vendor intc_enable_irq does not touch the CPU CLIC. It writes a source bit
  ## into the WiFi platform interrupt enable registers at 0x24910010/14/...
  ## The parent CPU interrupt is enabled by the host support glue.
  let bank = irqNum shr 5
  let sourceEnableBit = 1'u32 shl (irqNum and 31'u32)
  regWrite(0x24910010'u + bank.uint * 4'u, sourceEnableBit)

proc intc_handlers_init() =
  ## Populate the MAC platform IRQ dispatch table from the vendor
  ## .rodata.intc_irq_handlers layout.
  for irqHandlerSlotIndex in 0 ..< intc_handler_tab.len:
    intc_handler_tab[irqHandlerSlotIndex] = nil

  intc_handler_tab[10] = cast[pointer](phy_mdm_isr)
  intc_handler_tab[11] = cast[pointer](phy_rc_isr)
  for spuriousIrqSlotIndex in 24 .. 39:
    intc_handler_tab[spuriousIrqSlotIndex] = cast[pointer](intc_spurious)
  intc_handler_tab[50] = cast[pointer](rxl_timer_int_handler)
  intc_handler_tab[51] = cast[pointer](intc_spurious)
  intc_handler_tab[52] = cast[pointer](rxl_timer_int_handler)
  intc_handler_tab[53] = cast[pointer](txl_transmit_trigger)
  intc_handler_tab[54] = cast[pointer](hal_machw_gen_handler)
  intc_handler_tab[55] = cast[pointer](intc_spurious)
  intc_handler_tab[60] = cast[pointer](intc_spurious)
  intc_handler_tab[61] = cast[pointer](ipc_emb_msg_irq)
  intc_handler_tab[62] = cast[pointer](ipc_emb_cfmback_irq)
  intc_handler_tab[63] = cast[pointer](ipc_emb_tx_irq)

proc intc_init*() {.exportc, cdecl.} =
  ## Initialize interrupt controller: enable all WiFi-related IRQs.
  ## From blob: calls intc_enable_irq for 19 IRQ numbers covering
  ## WiFi IPC, MAC gen/port/trigger, timer, misc, and other peripherals.
  intc_handlers_init()
  intc_enable_irq(63)   # IPC TX
  intc_enable_irq(62)   # IPC confirmation callback
  intc_enable_irq(61)   # IPC message
  intc_enable_irq(24)   # Spurious handler range
  intc_enable_irq(25)
  intc_enable_irq(26)
  intc_enable_irq(27)
  intc_enable_irq(28)
  intc_enable_irq(29)
  intc_enable_irq(30)
  intc_enable_irq(31)
  intc_enable_irq(32)
  intc_enable_irq(55)   # Spurious handler
  intc_enable_irq(53)   # TX transmit trigger
  intc_enable_irq(50)   # RX timer
  intc_enable_irq(52)   # RX timer
  intc_enable_irq(54)   # MAC hardware general handler
  intc_enable_irq(10)   # PHY modem ISR
  intc_enable_irq(11)   # PHY RC ISR

proc intc_spurious*() {.exportc, cdecl.} =
  ## Handle spurious interrupt (7 instrs in blob).
  ## Calls assert_err with file "intc.c" and line 51.
  assert_err("intc.c", "intc.c", 51)

# ###########################################################################
#                  System Controller
# ###########################################################################

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sysctrl_init(void);".}
proc sysctrl_init*() {.exportc, cdecl.} =
  ## Initialize system controller for WiFi subsystem (10 instrs).
  ## From blob: writes 0x8000000C to MAC_PL_BASE+0x68 (diagnostic control reg).
  ## Then reads MAC_PL_BASE+0xE0 (clock gate register), ORs with 0x1FF00
  ## (enable clocks for all WiFi submodules), writes back.
  ## Also initializes ke_task descriptor table (blob: static TASK_DESC rodata).
  let macPlBase = MAC_PL_BASE
  # Write diagnostic control
  regWrite(macPlBase + 0x68'u, 0x8000000C'u32)
  # Enable WiFi submodule clocks
  var clockGate = regRead(macPlBase + 0xE0'u)
  clockGate = clockGate or 0x1FF00'u32
  regWrite(macPlBase + 0xE0'u, clockGate)
  wifi_fw_runtime_init()
  # The vendor blob links TASK_DESC as static rodata.  The Nim reimplementation
  # builds the same table in BSS, so populate it during system init.
  ke_task_init()

# ###########################################################################
#              TASK HANDLER FUNCTIONS (message dispatch)
# ###########################################################################
# These are the ke_msg handler functions referenced by task descriptor tables.
# They receive a message pointer (param) containing the message payload.
