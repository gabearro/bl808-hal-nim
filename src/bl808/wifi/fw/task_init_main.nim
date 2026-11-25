# ###########################################################################
#  KE Task Descriptor Table Initialization
#  Populates keTaskDescs[] with dispatch table pointers and state variable
#  pointers, matching the blob's static TASK_DESC rodata table.
#  Must be called before any ke_state_set/ke_task_schedule operations.
# ###########################################################################

proc ke_task_init*() {.exportc, cdecl.} =
  ## Initialize the kernel task descriptor table.
  ## Blob equivalent: static TASK_DESC rodata in ke_task.o (0xa0 bytes, 10 entries).
  ## Each entry: {stateTable, defaultHandler, statePtr, stateCount:u16, instanceCount:u16}
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
  keEnvEventField()[] != 0

proc wifiKernelTimerPendingWork(): bool {.inline.} =
  # Lookahead is for dispatched timer handlers, not unposted poll fallbacks.
  keTimerExpired(cast[ptr KeTimerEntry](keTimerQueue.first), fromPoll = true)

proc wifiMmTimerPendingWork(): bool {.inline.} =
  mmTimerExpired(mm_timer_list.first, fromPoll = true)

proc wifiMessagePendingWork(): bool {.inline.} =
  keMsgQueueSent.first != nil or keSavedReschedMask != 0

proc wifiResetEventPending(): bool {.inline.} =
  (keEnvEventField()[] and KE_EVT_RESET) != 0

proc wifiMainHasPendingWork(): bool =
  wifiEventPendingWork() or wifiKernelTimerPendingWork() or
    wifiMmTimerPendingWork() or wifiMessagePendingWork() or
    smBssNeedsService() or smCleanupNeedsService() or smActivationNeedsService()

proc wifiUpdateMacPlCtrl() {.inline.} =
  ## arch_main.o:wifi_main samples the bit once per step before sleep scheduling.
  let tslo = macTimeNow()
  var ctrl = regRead(MAC_PL_CTRL_REG)
  if (tslo and 0x00080000'u32) != 0:
    ctrl = ctrl or 0x01'u32
  else:
    ctrl = ctrl and not 0x01'u32
  regWrite(MAC_PL_CTRL_REG, ctrl)

proc wifiStepEnter(): bool =
  ## The firmware is one thread in the blob and is never reentered. Here a
  ## host callback that a handler runs synchronously (a confirmation to
  ## TASK_API, a log or OS hook) can poll the firmware again through
  ## osSleepUs or an OS wait. A step is one firmware entry from the host
  ## side: the main service step or the facade's TX service. While one runs,
  ## no other starts; the refused poll still services MAC interrupts
  ## (bl808WifiBackendPollMacIrq), as the trap would.
  if wifiStepActive:
    when defined(bl808WifiOpCheck): inc nimFwDbgNestedPump
    return false
  wifiStepActive = true
  true

proc wifiStepLeave() = wifiStepActive = false

proc wifi_nimfw_step_active*(): bool {.exportc, cdecl.} =
  ## The host poll skips firmware dispatch while this is true.
  wifiStepActive

proc wifiWaitForWorkIfIdle(blockWhenIdle, hasWork: bool): bool =
  result = hasWork
  if blockWhenIdle and not result:
    # No handler is running while the step waits for the host, so the
    # host's wait may poll the firmware.
    wifiStepLeave()
    ipc_emb_wait()
    discard wifiStepEnter()
    result = wifiMainHasPendingWork()

proc wifiDispatchScheduledEvent(): bool =
  let pending = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    var events = keEnvEventField()[]
    # Compare against a single bit to exclude all equal or higher priorities.
    # A recovered event is local to this dispatch, not a latched IRQ.
    if events < KE_EVT_MM_TIMER and wifiMmTimerPendingWork():
      events = events or KE_EVT_MM_TIMER
    elif events < KE_EVT_KE_TIMER and wifiKernelTimerPendingWork():
      events = events or KE_EVT_KE_TIMER
    elif events < KE_EVT_KE_MESSAGE and wifiMessagePendingWork():
      events = events or KE_EVT_KE_MESSAGE
    events
  if pending == 0: return false
  keDispatchEvent(pending)
  true

proc wifiDrainScheduledWork(): bool =
  if wifiResetEventPending(): return wifiDispatchScheduledEvent()
  template serviceWhen(ready, service: untyped) =
    if ready:
      # An earlier service or IRQ can post reset before the next callback.
      if wifiResetEventPending():
        if wifiDispatchScheduledEvent(): result = true
        return
      service
      result = true
  serviceWhen(smActivationNeedsService(), smActivationService())
  serviceWhen(smBssNeedsService(), smBssService())
  serviceWhen(smCleanupNeedsService(), smCleanupService())
  if wifiDispatchScheduledEvent(): result = true

proc wifi_nimfw_service_tx*(count: uint32) {.exportc, cdecl.} =
  ## The facade's TX service: postponed STA frames, then `count` rounds of
  ## the TX trigger and the frame confirmation event, as one step.
  if not wifiStepEnter(): return
  defer: wifiStepLeave()
  discard wifi_nimfw_service_sta_postponed(count)
  for _ in 0'u32 ..< count:
    txl_transmit_trigger()
    txl_frame_evt()

proc wifiMainServiceStep(blockWhenIdle = false): bool =
  ## Run one WiFi firmware service iteration.
  ##
  ## The blob's wifi_main blocks in the idle wait primitive because host and
  ## embedded firmware run independently. In this pure Nim port, CPS callers can
  ## drive WiFi and BLE from one scheduler, so they must use the nonblocking
  ## form and let the scheduler decide when to sleep.
  if not wifiStepEnter(): return false
  defer: wifiStepLeave()
  wifiUpdateMacPlCtrl()
  bl_sleep_schedule()
  if napScheduleState == BlNapWaking: return false

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

proc wifi_pm_wake_pending*(): bool {.exportc, cdecl.} =
  napScheduleState == BlNapWaking

proc wifiMainLog(sourceLine: cint; message: cstring) {.noinline.} =
  let logFn = cast[proc(level: uint32; tag, file: cstring; line: cint;
                        format: cstring) {.cdecl, varargs.}](blOpsFunc(204))
  if logFn != nil:
    logFn(2, nil, "arch_main.c", sourceLine, message)

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

  wifiMainLog(268, "[WF] Running Wi-Fi FW thread...\r\n")

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
  if wifi_hosal_rf_turn_on() != 0:
    wifiMainLog(286, "RF power-on failed\r\n")
    return
  wifiRfCoreInit(40000000'u32)
  if not wifiRfCoreReady():
    wifiMainLog(286, "RF initialization failed\r\n")
    return
  wifiMainLog(286, "Done\r\n")

  # The vendor enables this control bit before initializing MPIF/MAC/IPC.
  let bcsReg = MACHW_BCN_STATUS_REG
  var bcs = regRead(bcsReg)
  bcs = bcs or 0x01'u32
  regWrite(bcsReg, bcs)

  # MPIF clock + system controller init
  mpif_clk_init()
  sysctrl_init()

  # Interrupt and IPC init
  intc_init()

  wifiMainLog(295, "Configure IPC...\r\n")
  ipc_emb_init()
  if ipcEmbEnv == nil:
    wifiMainLog(297, "IPC initialization failed\r\n")
    return
  wifiMainLog(297, "Done\r\n")

  # Platform init — bl_init calls mm_init which initializes all subsystems
  wifiMainLog(299, "Configure MAC...\r\n")
  if not bl_init():
    wifiMainLog(301, "MAC initialization failed\r\n")
    return
  wifiMainLog(301, "Done\r\n")

  discard bl_pm_ops_register()
  wifiMainLog(315, "Starting loop...\r\n")

  # Configure BCN registers (blob: BCN_STATUS_REG sequence)
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

  # Main event loop (blob .L23 at offset 0x1BC)
  # .L23: read MACHW_TIMLO; and 0x80000;
  #   if set: read MAC_PL_CTRL; ori 1 (enable clock)
  #   if clear: read MAC_PL_CTRL; andi ~1 (disable clock)
  # .L28: write MAC_PL_CTRL; call bl_sleep_schedule;
  #   load ke_env event field; if == 0: call ipc_emb_wait;
  #   call ke_evt_schedule; j .L23
  while true:
    discard wifiMainServiceBlockingIdle()
