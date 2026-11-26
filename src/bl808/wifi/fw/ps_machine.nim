# Power save's transitions (ps.o) as one machine.
#
# A transition changes the station's power-management state and tells the AP
# of each active STA VIF on its channel with a null frame:
#
#   psExplicit  MM_SET_PS_MODE_REQ (ps_set_mode): PS off (mode 0), static
#               (1) or dynamic (2).
#   psSleep     dynamic PS (DPSM) sleeps once traffic stops
#               (ps_dpsm_update(0)).
#   psWake      DPSM wakes when traffic starts (ps_dpsm_update(1)).
#
# psStart begins a transition, a new operation (op.nim), and psFinish is its
# only end: it commits the transition (ps_disable_cfm_handle for a wake or PS
# off, ps_enable_cfm_handle otherwise), answers the MM request an explicit
# transition holds (psHold; in place, or with the reply ME reserved for its
# own request, so the answer needs no allocation) and releases the MM
# requests saved behind it. psCancel drops a transition unanswered (MM reset,
# ME reset, ke_flush). A TX reset ends nothing. At most one transition is
# live: ps_dpsm_update starts none while one is, and
# mm_set_ps_mode_req_handler saves a request until PS is idle, so ps_set_mode
# never parks a mode (ps.flags bit 4 stays clear). ps.flags bits 1 (a wake is
# live) and 2 (a sleep is live) are set by psStart and cleared by psFinish
# and psCancel.
#
# A transition counts the null frames it sent (ps.pendingCount), plus one
# while it is still sending them, and ends when the count reaches zero
# (psCount). Each frame carries the transition's stamp as its confirmation
# argument; a confirmation with another stamp belongs to an ended transition
# and changes nothing. A confirmation counts whatever its status: received,
# flushed by a TX reset, aged out or released unsent. Only a frame sent
# without an ACK is first sent again (ps_check_tx_status.part.0, up to half
# the retry limit), and its replacement then counts instead. A sleep also has
# the TX-null timer, armed with the stamp before its first frame is sent; its
# expiry ends the sleep as if every frame were confirmed. Wake frames carry
# no confirmation, so a wake ends where it starts.
#
# Nothing a transition calls ends it early: a confirmation that arrives while
# frames are still being sent cannot bring the count to zero, and the timer,
# the cancels and new transitions run only from the kernel loop. So the
# senders and the confirmations need no re-check.
#
# The MAC's PM bit (0x24B0004C bit 2) is PS's to choose (psApplyPm, also
# mirrored as statusFlags bit 3, set while PS wants it clear: the nap gate of
# bl_sleep_schedule). A scan or ROC dwell holds it at 0 (psDwellBegin,
# statusFlags bit 1, psDwell); PS's choice is then only recorded, and the
# dwell's end applies it (psDwellEnd). The channel scheduler's departure
# sets it to 1 for the protection null it sends every active STA VIF and, on
# the way home, clears it again and sends the wake null while PS is awake
# (psAwake). So the departure and the way home tell the AP PS's state, and a
# transition sends no null frame during a dwell: the MAC would mark it PM=0.
# A dwell starts after a forced idle has flushed TX, so none is out either.

type
  PsKind = enum
    psIdle, psExplicit, psSleep, psWake

  PsOwner = object
    op: Op
    kind: PsKind
    request: pointer    ## psExplicit: the MM_SET_PS_MODE_REQ it answers at its end
    vif: MmVifIdentity  ## the VIF of the last frame sent: the TX-null timer ends with it
    pm: bool            ## PS's PM bit (psApplyPm)

var psOwn {.wifiCtrl.}: PsOwner

proc psStart(kind: PsKind): uint32 =
  ## Begin a transition while PS is idle and return its stamp. The count
  ## holds one for the sender until it is done (psCount).
  let ps = psEnvView()
  psOwn.kind = kind
  ps.pendingCount = 1
  case kind
  of psWake: ps.flags = ps.flags or 0x02'u8
  of psSleep: ps.flags = ps.flags or 0x04'u8
  else: discard
  opGo(psOwn.op)

proc psHold(request: pointer) =
  ## Hold `request` (MM_SET_PS_MODE_REQ) for the explicit transition that
  ## starts next (ps_set_mode); its end answers it.
  psOwn.request = request

proc psSend(vifEntry, callback: pointer; stamp: uint32) =
  ## Send the live transition's null frame to `vifEntry`'s AP, counted until
  ## its confirmation. A refused frame gets none and is not counted.
  let ps = psEnvView()
  inc ps.pendingCount
  if txl_frame_send_null_frame(vifChannelAt(vifEntry).staIdx, callback, stamp) != 0:
    dec ps.pendingCount
  else:
    psOwn.vif = mmCaptureVif(vifEntry)

proc psAnswer(request: pointer) =
  ## Answer MM_SET_PS_MODE_REQ: ME's request with the reply ME reserved for
  ## it, any other in place (the request becomes its MM_SET_PS_MODE_CFM), so
  ## the answer needs no allocation.
  let reply =
    if request == meControlCommand: ke_msg_alloc_reply(request, MM_SET_PS_MODE_CFM, 0)
    else: nil
  if reply != nil:
    ke_msg_free(keMsgHdrFromPayload(request))
    ke_msg_send(reply)
    return
  let header = keMsgHdrFromPayload(request)
  header.paramLen = 0
  ke_msg_forward_and_change_id(request, MM_SET_PS_MODE_CFM, header.srcId, header.destId)

proc psFinish(vifEntry: pointer): uint32 {.discardable.} =
  ## The only end of a transition: commit it, with `vifEntry` (the VIF of
  ## the frame confirmed last, or nil) as the VIF the commit updates; answer
  ## its request; release the MM requests saved behind it. Returns the wake's
  ## traffic-detection handoff (ps_disable_cfm_handle).
  let ps = psEnvView()
  mm_timer_clear(psTxNullTimer())
  ps.pendingCount = 0
  ps.flags = ps.flags and not 0x06'u8
  opFinish(psOwn.op)
  # The commits read the kind: a wake or an explicit off, a sleep or an
  # explicit on.
  if psOwn.kind == psWake or (psOwn.kind == psExplicit and not psOwn.pm):
    result = ps_disable_cfm_handle(vifEntry)
  else:
    ps_enable_cfm_handle(vifEntry)
  let request = psOwn.request
  psOwn.kind = psIdle
  psOwn.request = nil
  if request != nil: psAnswer(request)
  discard ke_reschedule_saved_messages(TASK_MM)

proc psCount(vifEntry: pointer): uint32 {.discardable.} =
  ## One of the live transition's frames is confirmed (`vifEntry` is its
  ## VIF), or its sender is done with the count it held: end it at zero.
  let ps = psEnvView()
  dec ps.pendingCount
  if ps.pendingCount == 0: psFinish(vifEntry) else: 0

proc psCancel() =
  ## Drop the live transition unanswered: MM_RESET_REQ, ME's reset of its
  ## exchange, or ke_flush. Its request is freed and the MM requests saved
  ## behind it are released; the PM bit stays as the transition set it.
  ## ME's own request is dropped through meControlReset, which forgets it
  ## first; every reset runs ME's before PS's (me_init then mm_init,
  ## ke_flush), so ME never keeps a freed request.
  if psOwn.kind == psIdle: return
  let ps = psEnvView()
  let request = psOwn.request
  mm_timer_clear(psTxNullTimer())
  ps.pendingCount = 0
  ps.flags = ps.flags and not 0x06'u8
  opFinish(psOwn.op)
  psOwn.kind = psIdle
  psOwn.request = nil
  if request != nil: ke_msg_free(keMsgHdrFromPayload(request))
  discard ke_reschedule_saved_messages(TASK_MM)

proc psReset() =
  ## MM_RESET_REQ (ps_init): drop the live transition; PS is off and its PM
  ## bit clear.
  psCancel()
  psOwn.pm = false

proc psFrameVif(): pointer =
  ## The VIF of the null frame whose confirmation is running.
  let scope = txActiveFrameCallback
  if scope == nil or scope.vif >= MAX_VIFS.uint8: nil
  else: cast[pointer](vifChannelForIdx(scope.vif))

proc psConfirm(env: pointer; status: uint32; callback: pointer) =
  ## A null frame's confirmation (ps_enable_cfm, ps_disable_cfm). One sent
  ## without an ACK is sent again first while retries remain; any other, or
  ## a failed retry, counts.
  const TxDone = 0x80000000'u32
  const TxAcked = 0x00800000'u32
  if not opCurrent(psOwn.op, opEnvStamp(env)): return
  let vifEntry = psFrameVif()
  if (status and (TxDone or TxAcked)) == TxDone and vifEntry != nil and
      ps_check_tx_status_part0_nim(vifEntry, callback) == 0:
    return
  psCount(vifEntry)

proc psDwell(): bool =
  ## A scan or ROC dwell holds the PM bit at 0 (statusFlags bit 1).
  (psEnvView().statusFlags and 2'u32) != 0

proc psApplyPm(pm: bool) =
  ## PS's choice of the PM bit: recorded, mirrored in statusFlags bit 3 (set
  ## while PS is awake) and written unless a scan or ROC dwell holds the bit.
  let ps = psEnvView()
  psOwn.pm = pm
  # The MAC idle interrupt clears statusFlags bit 2.
  let saved = irqSave()
  ps.statusFlags =
    if pm: ps.statusFlags and not 8'u32 else: ps.statusFlags or 8'u32
  irqRestore(saved)
  if not psDwell(): blmac_pwr_mgt_setf(pm.uint32)

proc psDwellBegin() =
  ## A scan or ROC dwell reaches its channel (chan_pre_switch_channel): it
  ## holds the PM bit at 0 until it ends.
  let ps = psEnvView()
  let saved = irqSave()
  ps.statusFlags = ps.statusFlags or 2'u32
  irqRestore(saved)
  blmac_pwr_mgt_setf(0)

proc psDwellEnd() =
  ## The dwell ends (chanCtxtOpEvent): the PM bit is PS's again, as PS last
  ## chose it. The blob restores the value saved when the dwell began, which a
  ## DPSM decision taken during the dwell then contradicts.
  let ps = psEnvView()
  let saved = irqSave()
  ps.statusFlags = ps.statusFlags and not 2'u32
  irqRestore(saved)
  blmac_pwr_mgt_setf(psOwn.pm.uint32)

proc psAwake(): bool =
  ## PS has chosen the PM bit clear: the AP is told the station is awake.
  not psOwn.pm
