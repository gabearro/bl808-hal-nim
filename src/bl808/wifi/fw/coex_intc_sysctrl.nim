# ###########################################################################
#                  Coexistence (coex_*)
# ###########################################################################

proc coex_dump_pta*() {.exportc, cdecl.} =
  ## Dump PTA coexistence state (566 bytes in blob, 171 instrs).
  ## From blob: reads PTA register, extracts 16 bitfields via T-Head bexti,
  ## logs each via g_bl_ops_funcs[76] with line numbers 363..395.
  ## Blob reloads logFunc before each call.
  type LogV = proc(a0, a1: uint32, fmt: pointer, line: uint32, val: uint32) {.cdecl, varargs.}
  # Log header
  let lf0 = cast[LogV](getLogFunc(76)); if lf0 != nil: lf0(2, 0, nil, 400, 0)
  # Read PTA register, log full value
  var reg = ptaCoexControl()
  let lf1 = cast[LogV](getLogFunc(76)); if lf1 != nil: lf1(2, 0, nil, 363, reg)
  # Re-read and extract bitfields
  reg = ptaCoexControl()
  let lf2 = cast[LogV](getLogFunc(76)); if lf2 != nil: lf2(2, 0, nil, 382, reg shr 28)
  let lf3 = cast[LogV](getLogFunc(76)); if lf3 != nil: lf3(2, 0, nil, 383, (reg shr 24) and 0xF)
  let lf4 = cast[LogV](getLogFunc(76)); if lf4 != nil: lf4(2, 0, nil, 384, (reg shr 20) and 0xF)
  let lf5 = cast[LogV](getLogFunc(76)); if lf5 != nil: lf5(2, 0, nil, 385, (reg shr 16) and 0xF)
  let lf6 = cast[LogV](getLogFunc(76)); if lf6 != nil: lf6(2, 0, nil, 386, (reg shr 12) and 0xF)
  let lf7 = cast[LogV](getLogFunc(76)); if lf7 != nil: lf7(2, 0, nil, 387, (reg shr 8) and 0xF)
  let lf8 = cast[LogV](getLogFunc(76)); if lf8 != nil: lf8(2, 0, nil, 388, (reg shr 4) and 0xF)
  let lf9 = cast[LogV](getLogFunc(76)); if lf9 != nil: lf9(2, 0, nil, 389, (reg shr 3) and 0x1)
  let lf10 = cast[LogV](getLogFunc(76)); if lf10 != nil: lf10(2, 0, nil, 390, (reg shr 2) and 0x1)
  let lf11 = cast[LogV](getLogFunc(76)); if lf11 != nil: lf11(2, 0, nil, 391, (reg shr 1) and 0x1)
  let lf12 = cast[LogV](getLogFunc(76)); if lf12 != nil: lf12(2, 0, nil, 392, reg and 0x1)
  let lf13 = cast[LogV](getLogFunc(76)); if lf13 != nil: lf13(2, 0, nil, 393, reg and 0x3)
  let lf14 = cast[LogV](getLogFunc(76)); if lf14 != nil: lf14(2, 0, nil, 394, reg and 0x1)
  # Final: re-read register for bit 0
  let reg2 = ptaCoexControl()
  let lf15 = cast[LogV](getLogFunc(76)); if lf15 != nil: lf15(2, 0, nil, 395, reg2 and 0x1)

proc coex_dump_wifi*() {.exportc, cdecl.} =
  ## Dump WiFi coexistence state (1216 bytes in blob).
  ## Reads MAC HW registers at 0x24B00400/404/408, extracts bitfields,
  ## logs each via g_bl_ops_funcs[76]. Blob reloads logFunc before each call.
  type LogV = proc(a0, a1: uint32, fmt: pointer, line: uint32, val: uint32) {.cdecl, varargs.}
  # Header
  var lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 513, 0)
  # Reg0 full
  var reg0 = wlanCoexControl()
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 421, reg0)
  # Reg0 bitfields
  reg0 = wlanCoexControl()
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 439, reg0 shr 28)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 440, (reg0 shr 22) and 0x3F)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 441, (reg0 shr 18) and 0xF)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 442, (reg0 shr 14) and 0xF)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 443, (reg0 shr 10) and 0xF)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 444, (reg0 shr 6) and 0xF)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 445, (reg0 shr 4) and 0x3)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 446, (reg0 shr 3) and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 447, (reg0 shr 2) and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 448, (reg0 shr 1) and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 449, reg0 and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 450, reg0 and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 451, reg0 and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 452, reg0 and 0x1)
  # Header 2
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 515, 0)
  # Reg1 full
  var reg1 = wlanCoexPti()
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 466, reg1)
  # Reg1 bitfields
  reg1 = wlanCoexPti()
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 470, reg1 shr 28)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 471, (reg1 shr 22) and 0x3F)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 472, (reg1 shr 16) and 0x3F)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 473, (reg1 shr 12) and 0xF)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 474, (reg1 shr 8) and 0xF)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 475, (reg1 shr 4) and 0xF)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 476, (reg1 shr 3) and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 477, reg1 and 0xF)
  # Header 3
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 517, 0)
  # Reg2 full
  var reg2 = wlanCoexStatus()
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 490, reg2)
  # Reg2 bitfields
  reg2 = wlanCoexStatus()
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 502, (reg2 shr 4) and 0xF)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 503, (reg2 shr 2) and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 504, (reg2 shr 1) and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 505, reg2 and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 506, reg2 and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 507, reg2 and 0x1)
  lf = cast[LogV](getLogFunc(76)); if lf != nil: lf(2, 0, nil, 508, reg2 and 0x1)

proc coex_wifi_rf_forece_enable*(enable: bool) {.exportc, cdecl.} =
  ## Force enable/disable WiFi RF.
  discard

proc coex_wifi_pti_forece_enable*(enable: bool) {.exportc, cdecl.} =
  ## Force enable/disable WiFi PTI (Priority Traffic Indication) (30 instrs).
  ## From blob: if enable (a0 != 0):
  ##   Reads MACHW_BASE+0x400, clears bits [27:24], sets bits [27:24] to 0xF0000000,
  ##   sets bit 4 (0x10). Then reads MACHW_BASE+0x400 again.
  ## Common path (both enable/disable):
  ##   Reads MACHW_BASE+0x400, masks with 0xFBFFFFFF (clear bit 26),
  ##   shifts and ORs based on enable flag, writes back.
  if enable:
    var coexControl = wlanCoexControl()
    # Clear bits [27:24], set to 0xF (max priority)
    coexControl = coexControl and 0x0FFFFFFF'u32
    coexControl = coexControl or 0xF0000000'u32
    # Set bit 4 (force enable)
    coexControl = coexControl or 0x10'u32
    wlanCoexWriteControl(coexControl)
    # Re-read and set additional enable bits
    coexControl = wlanCoexControl()
    coexControl = coexControl or 0x10'u32
    wlanCoexWriteControl(coexControl)
  # Common: update auto-control bits
  var coexControl = wlanCoexControl()
  coexControl = coexControl and 0xFBFFFFFF'u32  # clear bit 26
  if not enable:
    # Clearing: restore auto-control
    coexControl = coexControl and (not 0x10'u32)  # clear force bit
  wlanCoexWriteControl(coexControl)

proc coex_wifi_pta_forece_enable*(enable: bool) {.exportc, cdecl.} =
  ## Force enable/disable WiFi PTA (Packet Traffic Arbitration).
  ## From blob (103 instrs): 3-way state dispatch on curState (0/1/-1).
  ## State 0->new: measure elapsed in accumulator, log line 588.
  ## State 1->new: measure elapsed, irq-save, call coex fn, if >1000 ticks
  ##   yield+log ms, log line 610.
  ## State -1->new: log line 614.
  ## Then unconditionally: store newState, save new timestamp.
  let curState = coexPtaAutoControl
  let newVal = cast[uint32](enable)
  if curState == newVal:
    return
  let getTimeFn = cast[proc(): uint32 {.cdecl.}](blOpsFunc(200))
  let logFn = cast[proc(a0, a1: uint32, file: pointer, line: uint32,
                        val: uint32) {.cdecl, varargs.}](blOpsFunc(204))
  if curState == 0:
    # Transition from disabled: accumulate elapsed time, log
    let now = getTimeFn()
    coexPtaAccum = coexPtaAccum - coexPtaTimestamp + now
    let now2 = getTimeFn()
    let elapsed = now2 - coexPtaTimestamp
    logFn(2, 0, nil, 588, elapsed)
  elif curState == 1:
    # Transition from enabled: measure elapsed, irq-save, call coex fn
    let now = getTimeFn()
    coexPtaAccum = coexPtaAccum - coexPtaTimestamp + now
    # Critical section: disable interrupts, call timing function
    let savedMstatus = irqSave()
    let ticks = getTimeFn()  # measure ticks in critical section
    irqRestore(savedMstatus)
    # If elapsed > 1000 ticks, yield and log duration in ms
    if ticks > 1000:
      let yieldFn = cast[proc(v: uint32) {.cdecl.}](blOpsFunc(28))
      yieldFn(0)
      let callFn = blOpsFunc(28)
      cast[proc(ms: uint32) {.cdecl.}](callFn)(ticks div 1000)
      let yieldFn2 = cast[proc(v: uint32) {.cdecl.}](blOpsFunc(28))
      yieldFn2(0)
    let now2 = getTimeFn()
    let elapsed2 = now2 - coexPtaTimestamp
    logFn(2, 0, nil, 610, elapsed2)
  elif cast[int32](curState) == -1:
    # Forced state: just log
    logFn(2, 0, nil, 614, 0)
  # Update state and save timestamp
  coexPtaAutoControl = newVal
  coexPtaTimestamp = getTimeFn()
  # Coexistence RF control (blob: bl_nap_calculate, wifi_hosal_rf_turn_on/off)
  # Call coex RF control functions directly (blob: bl_nap_calculate + rf_turn_on/off)
  {.emit: ["bl_nap_calculate();"].}
  if enable:
    {.emit: ["wifi_hosal_rf_turn_on();"].}
  else:
    {.emit: ["wifi_hosal_rf_turn_off();"].}

proc coex_pta_force_autocontrol_set*(mode: uint32) {.exportc, cdecl.} =
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
  intc_enable_irq(63)   # IPC public
  intc_enable_irq(62)   # MAC port trigger
  intc_enable_irq(61)   # MAC gen
  intc_enable_irq(24)   # Emac
  intc_enable_irq(25)   # GPADC DMA
  intc_enable_irq(26)   # Efuse
  intc_enable_irq(27)   # SPI0
  intc_enable_irq(28)   # UART0
  intc_enable_irq(29)   # UART1
  intc_enable_irq(30)   # UART2
  intc_enable_irq(31)   # GPIO DMA
  intc_enable_irq(32)   # I2C0
  intc_enable_irq(55)   # BZ PHY
  intc_enable_irq(53)   # BOR
  intc_enable_irq(50)   # PDS wakeup
  intc_enable_irq(52)   # HBN out1
  intc_enable_irq(54)   # WiFi
  intc_enable_irq(10)   # SecEng0
  intc_enable_irq(11)   # (SecEng0+1)

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
  wifi_fw_runtime_init()
  let macPlBase = MAC_PL_BASE
  # Write diagnostic control
  regWrite(macPlBase + 0x68'u, 0x8000000C'u32)
  # Enable WiFi submodule clocks
  var clockGate = regRead(macPlBase + 0xE0'u)
  clockGate = clockGate or 0x1FF00'u32
  regWrite(macPlBase + 0xE0'u, clockGate)
  # The vendor blob links TASK_DESC as static rodata.  The Nim reimplementation
  # builds the same table in BSS, so populate it during system init.
  ke_task_init()

# ###########################################################################
#              TASK HANDLER FUNCTIONS (message dispatch)
# ###########################################################################
# These are the ke_msg handler functions referenced by task descriptor tables.
# They receive a message pointer (param) containing the message payload.
