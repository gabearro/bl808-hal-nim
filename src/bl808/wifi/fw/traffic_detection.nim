# ###########################################################################
#                  TD: Time Domain (Traffic Detection)
# ###########################################################################

proc tdEntryForVif(vifIdx: uint8): ptr TdEntryView {.inline.} =
  cast[ptr TdEntryView](cast[uint](addr td_env[0]) +
    vifIdx.uint * sizeof(TdEntryView).uint)

proc td_init*() {.exportc, cdecl.} =
  ## Initialize time domain module — blob td.o:
  ##   td_reset(0)        ; resets VIF 0 (zero-clears its slot)
  ##   tail-call td_reset(1)  ; resets VIF 1 (and clears the full env)
  ## Previous Nim emitted a separate memset(td_env, 0, 88) that is not in
  ## blob's call graph — td_reset itself writes the fields it cares about.
  let printFn = cast[proc(format: cstring) {.cdecl, varargs.}](blOpsFunc(4))
  if printFn != nil:
    printFn("td_init\r\n")
  td_reset(0)
  td_reset(1)

proc td_start*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Start traffic detection for a VIF (106 bytes in blob, ~35 instrs).
  ## From blob: computes per-VIF block = td_env + vifIdx * 44.
  ## If active flag already set, returns. Otherwise reads MAC time,
  ## logs via platform ops, sets active, clears the TIM override, and arms
  ## the configured sampling interval without resetting traffic history.
  let td = tdEntryForVif(vifIdx)
  if td.active != 0:
    return  # already started
  let macTime = regRead(MACHW_TIMLO_REG)
  let printFn = cast[proc(format: cstring) {.cdecl, varargs.}](blOpsFunc(4))
  if printFn != nil:
    printFn("td_start idx=%d\r\n", vifIdx.cint)
  td.active = 1
  td.timTime = 0
  mm_timer_set(cast[pointer](td), macTime + blPsParamsView().trafficPeriod)

proc td_timer_end*(tdEntry: pointer) {.exportc, cdecl.}  # forward decl
proc td_timer_evt*(env: pointer) {.exportc, cdecl.} =
  ## Timer event callback for traffic detection (set as callback in td_reset).
  ## From blob: tail-calls td_timer_end with the environment pointer.
  td_timer_end(env)

proc td_reset*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Reset traffic detection for a VIF.
  ## From blob (52 instrs): computes per-VIF block = td_env + vifIdx * 44.
  ## If active (td[42] != 0), calls mm_timer_clear on the timer. Then memsets
  ## the 44-byte block to zero. Finally sets up: td[4]=td_timer_evt callback,
  ## td[8]=self pointer (env), td[40]=vifIdx.
  let td = tdEntryForVif(vifIdx)
  let printFn = cast[proc(format: cstring) {.cdecl, varargs.}](blOpsFunc(4))
  if printFn != nil:
    printFn("td_reset idx=%d\r\n", vifIdx.cint)
  # If timer is active, clear it
  if td.active != 0:
    mm_timer_clear(cast[pointer](td))
  # Zero the entire per-VIF block
  discard c_memset(cast[pointer](td), 0, sizeof(TdEntryView).csize_t)
  # Set up timer fields. Blob stores td_timer_end directly as the callback
  # (no wrapper) — Nim previously routed through a td_timer_evt stub that
  # tail-called td_timer_end, producing a pointless indirection.
  td.callback = cast[pointer](td_timer_end)
  td.env = cast[uint32](cast[uint](td))
  td.vifIdx = vifIdx

proc td_pck_ind*(vifIdx: uint8, staIdx: uint8, direction: uint32) {.exportc, cdecl.} =
  ## Packet indication for traffic detection.
  ## From blob (14 instrs): computes per-VIF block = td_env + vifIdx * 44.
  ## a1 carries STA index for the ABI but the blob callee ignores it.
  ## If a2 != 0, increments the counter at td[28]; otherwise td[24].
  discard staIdx
  let td = tdEntryForVif(vifIdx)
  if direction != 0:
    td.txCount = td.txCount + 1
  else:
    td.rxCount = td.rxCount + 1

proc td_pck_ps_ind*(vifIdx: uint8, direction: uint32) {.exportc, cdecl.} =
  ## PS packet indication for traffic detection.
  ## From blob (14 instrs): computes per-VIF block = td_env + vifIdx * 44.
  ## If direction != 0, increments td[36] (PS tx count).
  ## Otherwise increments td[32] (PS rx count).
  let td = tdEntryForVif(vifIdx)
  if direction != 0:
    td.psTxCount = td.psTxCount + 1
  else:
    td.psRxCount = td.psRxCount + 1

proc td_recovery_ind*() {.exportc, cdecl.} =
  ## Traffic recovery indication.
  discard

proc td_pack_tim_ind*(vifIdx: uint8) {.exportc, cdecl, noinline.} =
  ## Pack TIM indication for traffic detection.
  ## From blob (26 instrs): computes per-VIF block = td_env + vifIdx * 44.
  ## If active, schedule processing at the current MAC time. Then store the
  ## explicit TIM period, or the configured default, for confirmation use.
  ## noinline: blob calls this from ps_check_tbtt.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let td = tdEntryForVif(vifIdx)
  if td.active == 0:
    return
  # Read MAC time and set timer
  let macTime = regRead(MACHW_TIMLO_REG)
  mm_timer_set(cast[pointer](td), macTime)
  # Update the period: if tim_time (offset 20) is set, use it
  if td.timTime != 0:
    td.period = td.timTime
  else:
    td.period = blPsParamsView().timPeriod

proc td_set_tim_time*(vifIdx: uint8, timTime: uint32) {.exportc, cdecl.} =
  ## Set TIM update time for traffic detection.
  ## From blob (7 instrs): computes per-VIF block = td_env + vifIdx * 44.
  ## Stores timTime (a1) at td[20].
  tdEntryForVif(vifIdx).timTime = timTime

proc td_cfm_set_timer*(vifIdx: uint8, flag: uint32) {.exportc, cdecl.} =
  ## Set/clear confirmation timer for traffic detection (72 bytes in blob).
  ## From blob: computes per-VIF entry = td_env + vifIdx*44.
  ## If flag (a1) != 0: reads MAC time, adds period from td[16], calls mm_timer_set.
  ## Both paths: always clears td[16] (period consumed after use).
  let td = tdEntryForVif(vifIdx)
  if flag != 0:
    # Set timer: read MAC time, add period from td[16]
    let macTime = regRead(MACHW_TIMLO_REG)
    mm_timer_set(cast[pointer](td), macTime + td.period)
  # Always clear the period field (consumed)
  td.period = 0
