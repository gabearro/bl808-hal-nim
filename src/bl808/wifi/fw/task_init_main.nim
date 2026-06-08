# ###########################################################################
#  KE Task Descriptor Table Initialization
#  Populates keTaskDescs[] with dispatch table pointers and state variable
#  pointers, matching the blob's static TASK_DESC rodata table.
#  Must be called before any ke_state_set/ke_task_schedule operations.
# ###########################################################################

proc ke_task_init*() {.exportc, cdecl.} =
  ## Initialize the kernel task descriptor table.
  ## Blob equivalent: static TASK_DESC rodata in ke_task.o (0xa0 bytes, 10 entries).
  ## Each entry: {stateTable, defaultHandler, statePtr, reserved:u16, stateCount:u16}
  let taskSpecs = [
    KeTaskInitSpec(taskId: TASK_MM,
                   stateTable: cast[pointer](addr mm_state_handler),
                   defaultHandler: cast[pointer](addr mm_default_handler),
                   statePtr: addr keTaskStateMm,
                   stateCount: MmStateCount),
    KeTaskInitSpec(taskId: TASK_SCAN,
                   stateTable: nil,
                   defaultHandler: cast[pointer](addr scan_default_handler),
                   statePtr: addr keTaskStateScan,
                   stateCount: ScanStateCount),
    KeTaskInitSpec(taskId: TASK_SCANU,
                   stateTable: cast[pointer](addr scanu_state_handler),
                   defaultHandler: cast[pointer](addr scanu_default_handler),
                   statePtr: addr keTaskStateScanu,
                   stateCount: ScanuStateCount),
    KeTaskInitSpec(taskId: TASK_ME,
                   stateTable: nil,
                   defaultHandler: cast[pointer](addr me_default_handler),
                   statePtr: addr keTaskStateMe,
                   stateCount: MeStateCount),
    KeTaskInitSpec(taskId: TASK_SM,
                   stateTable: nil,
                   defaultHandler: cast[pointer](addr sm_default_handler),
                   statePtr: addr keTaskStateSm,
                   stateCount: SmStateCount),
    KeTaskInitSpec(taskId: TASK_APM,
                   stateTable: nil,
                   defaultHandler: cast[pointer](addr apm_default_handler),
                   statePtr: addr keTaskStateApm,
                   stateCount: ApmStateCount),
    KeTaskInitSpec(taskId: TASK_BAM,
                   stateTable: nil,
                   defaultHandler: cast[pointer](addr bam_default_handler),
                   statePtr: addr keTaskStateBam,
                   stateCount: BamStateCount),
    KeTaskInitSpec(taskId: TASK_CFG,
                   stateTable: nil,
                   defaultHandler: cast[pointer](addr cfg_default_handler),
                   statePtr: addr keTaskStateCfg,
                   stateCount: CfgStateCount),
  ]

  for spec in taskSpecs:
    configureKeTaskDesc(spec)

# ###########################################################################
#                  WiFi Main Entry Point
# ###########################################################################

proc wifiEventPendingWork(): bool {.inline.} =
  keEvtField != 0

proc wifiKernelTimerPendingWork(): bool {.inline.} =
  keTimerExpired(cast[ptr KeTimerEntry](keTimerQueue.first))

proc wifiMmTimerPendingWork(): bool {.inline.} =
  mmTimerExpired(mm_timer_list.first)

proc wifiMessagePendingWork(): bool {.inline.} =
  keMsgQueueSent.first != nil or keSavedReschedTask != TASK_NONE

proc wifiMessageEventPending(): bool {.inline.} =
  (keEvtField and KE_EVT_KE_MESSAGE) != 0

proc wifiHiddenMessagePendingWork(): bool {.inline.} =
  wifiMessagePendingWork() and not wifiMessageEventPending()

proc wifiMainHasPendingWork(): bool =
  wifiEventPendingWork() or wifiKernelTimerPendingWork() or
    wifiMmTimerPendingWork() or wifiMessagePendingWork()

proc wifiUpdateMacPlCtrl() {.inline.} =
  let tslo = macTimeNow()
  var ctrl = regRead(MAC_PL_CTRL_REG)
  if (tslo and 0x00080000'u32) != 0:
    ctrl = ctrl or 0x01'u32
  else:
    ctrl = ctrl and not 0x01'u32
  regWrite(MAC_PL_CTRL_REG, ctrl)

proc wifiWaitForWorkIfIdle(blockWhenIdle, hasWork: bool): bool =
  result = hasWork
  if blockWhenIdle and not result:
    ipc_emb_wait()
    result = wifiMainHasPendingWork()

proc wifiDrainScheduledWork(): bool =
  if wifiKernelTimerPendingWork():
    result = true
    ke_timer_schedule()
  if wifiMmTimerPendingWork():
    result = true
    mm_timer_schedule()
  if wifiEventPendingWork():
    result = true
  ke_evt_schedule()
  if wifiHiddenMessagePendingWork():
    result = true
    ke_task_schedule()

proc wifiMainServiceStep(blockWhenIdle = false): bool =
  ## Run one WiFi firmware service iteration.
  ##
  ## The blob's wifi_main blocks in the idle wait primitive because host and
  ## embedded firmware run independently. In this pure Nim port, CPS callers can
  ## drive WiFi and BLE from one scheduler, so they must use the nonblocking
  ## form and let the scheduler decide when to sleep.
  wifiUpdateMacPlCtrl()
  bl_sleep_schedule()

  result = wifiWaitForWorkIfIdle(blockWhenIdle, wifiMainHasPendingWork())

  if wifiDrainScheduledWork():
    result = true

proc wifiMainServiceNonblocking(): bool =
  wifiMainServiceStep()

proc wifiMainServiceBlockingIdle(): bool =
  wifiMainServiceStep(blockWhenIdle = true)

proc wifi_main_service_step*(blockWhenIdle: uint8 = 0'u8) {.exportc, cdecl.} =
  discard wifiMainServiceStep(blockWhenIdle != 0'u8)

proc wifi_main_poll_once*() {.exportc, cdecl.} =
  discard wifiMainServiceNonblocking()

proc wifi_main*(param: pointer) {.exportc, cdecl.} =
  ## WiFi firmware main entry point (157 instructions in blob).
  ## Blob call sequence (from relocations):
  ##   1. arch_delay_us (x2) — INTC clock toggle with delays
  ##   2. wifi_hosal_rf_turn_on — RF power on
  ##   3. rf_init — RF calibration/initialization
  ##   4. mpif_clk_init — MPIF clock initialization
  ##   5. sysctrl_init — system controller + ke_task_init
  ##   6. intc_init — interrupt controller init
  ##   7. ipc_emb_init — IPC embedded init
  ##   8. bl_init — platform init (calls mm_init -> all subsystem inits)
  ##   9. bl_pm_ops_register — register PM ops
  ##  10. bl_sleep_schedule — initial sleep scheduling
  ##  11. ipc_emb_wait — IPC sync barrier (wait for host ready)
  ##  12. ke_evt_schedule — main event loop

  # Toggle INTC clock enable with delays (blob: arch_delay_us x2)
  let saved = irqSave()
  var pend = regRead(INTC_PEND_REG)
  pend = pend or 0x10'u32
  regWrite(INTC_PEND_REG, pend)
  arch_delay_us(100)
  pend = regRead(INTC_PEND_REG)
  pend = pend and not 0x10'u32
  regWrite(INTC_PEND_REG, pend)
  arch_delay_us(100)
  irqRestore(saved)

  # RF initialization (external platform functions)
  wifi_hosal_rf_turn_on()
  wifiRfCoreInit(40000000'u32)

  # Keep the init sequence linear so GCC doesn't clone the function around
  # per-call logFn==nil checks (previously produced two bl_init /
  # ipc_emb_init call sites in the output). The log calls are guarded by
  # a single logFn != nil block that wraps them all, so both paths are
  # exit-only rather than interleaved with real init calls.
  let logFn = getLogFunc(4)

  # MPIF clock + system controller init
  mpif_clk_init()
  sysctrl_init()

  # Interrupt and IPC init
  intc_init()

  ipc_emb_init()

  # Platform init — bl_init calls mm_init which initializes all subsystems
  bl_init()

  if logFn != nil:
    logFn(2, 0, nil, 286)
    logFn(2, 0, nil, 295)
    logFn(2, 0, nil, 297)
    logFn(2, 0, nil, 299)
    logFn(2, 0, nil, 301)
    logFn(2, 0, nil, 315)

  # Configure BCN registers (blob: BCN_STATUS_REG sequence)
  let bcsReg = MACHW_BCN_STATUS_REG
  var bcs = regRead(bcsReg)
  bcs = bcs or 0x01'u32
  regWrite(bcsReg, bcs)
  regWrite(bcsReg + 4, 0x0024F037'u32)
  bcs = regRead(bcsReg)
  bcs = bcs or 0x01'u32
  regWrite(bcsReg, bcs)
  bcs = regRead(bcsReg)
  bcs = bcs and not 0x01'u32
  regWrite(bcsReg, bcs)
  regWrite(bcsReg, 0x68'u32)
  bcs = regRead(bcsReg)
  bcs = bcs or 0x01'u32
  regWrite(bcsReg, bcs)
  bcs = regRead(bcsReg)
  bcs = bcs and not 0x20'u32
  regWrite(bcsReg, bcs)

  # COEX PTA control
  regWrite(COEX_CTRL_REG, 0x5010001F'u32)

  # Register PM ops. Blob registers PM ops once and then drops straight
  # into the event loop; the previous Nim code duplicated bl_sleep_schedule
  # and ipc_emb_wait both before and inside the loop, which doubled the
  # pre-steady-state work (and also doubled the wake-from-IPC window).
  bl_pm_ops_register(nil)

  # Main event loop (blob .L23 at offset 0x1BC)
  # .L23: read MACHW_TIMLO; and 0x80000;
  #   if set: read MAC_PL_CTRL; ori 1 (enable clock)
  #   if clear: read MAC_PL_CTRL; andi ~1 (disable clock)
  # .L28: write MAC_PL_CTRL; call bl_sleep_schedule;
  #   load keEvtField; if == 0: call ipc_emb_wait;
  #   call ke_evt_schedule; j .L23
  while true:
    discard wifiMainServiceBlockingIdle()
