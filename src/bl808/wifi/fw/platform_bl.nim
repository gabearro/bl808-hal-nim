# ###########################################################################
#                  PLATFORM INTEGRATION (bl_*)
# ###########################################################################

proc bl_supplicant_init() {.importc: "bl_supplicant_init", cdecl.}
  ## External: initializes WPA supplicant layer.

proc bl_init*(): bool {.exportc, cdecl, discardable.} =
  ## Initialize platform layer (60 bytes in blob).
  ## From blob: stores fw_nap_chain addr to fw_nap_chain_ptr (.LANCHOR1),
  ## clears bl_env[1], then calls me_init → mm_init → ke_init → bl_supplicant_init.
  fw_nap_chain_ptr = cast[pointer](addr fw_nap_chain[0])
  bl_env[1] = 0
  nimFwTrace("[WIFI-NIMFW] me_init begin")
  me_init()
  nimFwTrace("[WIFI-NIMFW] me_init done")
  nimFwTrace("[WIFI-NIMFW] mm_init begin")
  if not mm_init(): return false
  nimFwTrace("[WIFI-NIMFW] mm_init done")
  nimFwTrace("[WIFI-NIMFW] ke_init begin")
  ke_init()
  nimFwTrace("[WIFI-NIMFW] ke_init done")
  nimFwTrace("[WIFI-NIMFW] bl_supplicant_init begin")
  bl_supplicant_init()
  nimFwTrace("[WIFI-NIMFW] bl_supplicant_init done")
  true

proc bl_reset_evt*() {.exportc, cdecl.} =
  ## Handle reset event. Blob sequence inside IRQ-disabled critical section:
  ##   ke_evt_clear(0x80000000)
  ##   hal_machw_reset()
  ##   rxl_reset(); txl_reset(); mm_reset()
  ##   vif_mgmt_reset()
  ##   ke_evt_clear(0x04000000)
  ## Restore mstatus.MIE only if it was set on entry.
  let saved = irqSave()
  defer: irqRestore(saved)
  if not waitMacSoftResetClear(): return
  ke_evt_clear(0x80000000'u32)
  if not hal_machw_reset(): return
  if not rxl_reset(): return
  if not txl_reset(): return
  mm_reset()
  vif_mgmt_reset()
  apmResumeHaltRollback()
  ke_evt_clear(0x04000000'u32)
  # A timed-out MM reset request may be saved even when MM was already idle.
  discard ke_reschedule_saved_messages(TASK_MM)

proc bl_irq_handler*() {.exportc, cdecl.} =
  ## Main WiFi interrupt handler. Blob sequence:
  ##   ipc_host_disable_irq_e2a()
  ##   ke_evt_set(0x80)            # IPC_EMB event bit
  ##   ipc_emb_notify()            # tail call
  ipc_host_disable_irq_e2a()
  ke_evt_set(0x80'u32)
  ipc_emb_notify(0'u32)

proc wifiMainHasPendingWork(): bool

{.emit: "__attribute__((optimize(\"crossjumping\"))) void bl_sleep_schedule(void);".}
proc bl_sleep_schedule*() {.exportc, cdecl.} =
  ## Sleep requires enabled/idle PS state and no on-channel VIF flags.
  ## Keep the pure-Nim pending-work guard before the vendor PM/VIF decision.
  let pmState = wifi_hosal_pm_state_run()
  var newState: uint32

  if wifiMainHasPendingWork():
    newState = 0
  elif pmState != 0:
    napScheduleState = 0
    newState = 0
  else:
    newState = 0
    let ps = psEnvView()
    if ps.enabled != 0 and ps.statusFlags == 0:
      var node = cast[pointer](vifMgmtEnvView().activeList.first)
      while node != nil:
        let vif = vifChannelAt(node)
        if chan_is_on_channel(node) and vif.flags != 0:
          break
        node = vif.next
      if node == nil:
        newState = 1

  # Compare with current state (.L65)
  if napScheduleState == newState:
    return

  if newState != 0:
    # Transitioning to sleep: pm_post_event(1, 0, &result)
    var result: uint32 = 0
    wifi_hosal_pm_post_event(1, 0, addr result)
    if result == 0:
      # Sleep allowed: pm_post_event(1, 1, 0) then store state
      wifi_hosal_pm_post_event(1, 1, nil)
    else:
      # Sleep denied: pm_post_event(2, 0, &result) then exit
      wifi_hosal_pm_post_event(2, 0, addr result)
      return
  else:
    # Transitioning to awake (.L72): pm_post_event(2, 1, 0) then (2, 2, 0)
    wifi_hosal_pm_post_event(2, 1, nil)
    wifi_hosal_pm_post_event(2, 2, nil)

  napScheduleState = newState

proc bl_nap_calculate*(): uint32 {.exportc, cdecl.} =
  ## Return the minimum vendor nap interval across enabled timer slots 0..8.
  let activeMask = regRead(MACHW_INTC_BASE + 0x08C'u)
  var minRemaining: uint32 = 0xFFFFFFFF'u32

  for machwTimerSlotIndex in 0'u32 ..< 9'u32:
    if (activeMask and (1'u32 shl machwTimerSlotIndex)) != 0:
      let target = regRead(MACHW_BASE + 0x128'u + machwTimerSlotIndex * 4)
      let current = regRead(MACHW_TIMLO_REG)
      # The vendor uses this second unsigned interval for past/equal targets.
      let remaining = if current < target: target - current
                      else: current - target - 1'u32
      if remaining < minRemaining:
        minRemaining = remaining

  return minRemaining

proc bl_nap_call*() {.exportc, cdecl.} =
  ## Execute nap (light sleep).
  ## From blob (2 instrs): li a0,0; ret -- returns 0 (no-op / nap disabled).
  ## Intentionally empty: blob is a no-op that returns 0.
  return

# Forward declarations for notifier chain functions (defined later)
proc notifier_chain_regsiter*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.}
proc notifier_chain_regsiter_fromCritical*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.}
proc notifier_chain_unregsiter*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.}
proc notifier_chain_unregsiter_fromCritical*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.}
proc notifier_chain_call*(chain: ptr CoList, event: uint32, data: pointer) {.exportc, cdecl.}
proc notifier_chain_call_fromeCritical*(chain: ptr CoList, event: uint32, data: pointer) {.exportc, cdecl.}

proc bl_nap_hook_register*(hook: pointer) {.exportc, cdecl.} =
  ## Register a nap hook (30 bytes in blob).
  ## Blob: notifier_chain_regsiter(&napHookChain, hook)
  let chain = cast[ptr CoList](addr fw_nap_chain_ptr)
  notifier_chain_regsiter(chain, cast[ptr CoListHdr](hook))

proc bl_nap_hook_unregister*(hook: pointer) {.exportc, cdecl.} =
  ## Unregister a nap hook (30 bytes in blob).
  ## Blob: notifier_chain_unregsiter(&napHookChain, hook)
  let chain = cast[ptr CoList](addr fw_nap_chain_ptr)
  notifier_chain_unregsiter(chain, cast[ptr CoListHdr](hook))

proc bl_nap_hook_call*(event: uint32, data: pointer) {.exportc, cdecl.} =
  ## Call nap hooks (32 bytes in blob).
  ## Blob: notifier_chain_call(&napHookChain, a0, a1)
  let chain = cast[ptr CoList](addr fw_nap_chain_ptr)
  notifier_chain_call(chain, event, data)

proc bl_nap_hook_register_fromCritical*(hook: pointer) {.exportc, cdecl.} =
  ## Register nap hook from critical section (30 bytes in blob).
  ## Blob: notifier_chain_regsiter_fromCritical(&napHookChain, hook)
  let chain = cast[ptr CoList](addr fw_nap_chain_ptr)
  notifier_chain_regsiter_fromCritical(chain, cast[ptr CoListHdr](hook))

proc bl_nap_hook_unregister_fromCritical*(hook: pointer) {.exportc, cdecl.} =
  ## Unregister nap hook from critical section (30 bytes in blob).
  ## Blob: notifier_chain_unregsiter_fromCritical(&napHookChain, hook)
  let chain = cast[ptr CoList](addr fw_nap_chain_ptr)
  notifier_chain_unregsiter_fromCritical(chain, cast[ptr CoListHdr](hook))

proc bl_nap_hook_call_fromCritical*(event: uint32, data: pointer) {.exportc, cdecl.} =
  ## Call nap hooks from critical section (32 bytes in blob).
  ## Blob: notifier_chain_call_fromeCritical(&napHookChain, a0, a1)
  ## Note: blob shifts args: a0→a1 (event), a1→a2 (data), loads chain→a0
  let chain = cast[ptr CoList](addr fw_nap_chain_ptr)
  notifier_chain_call_fromeCritical(chain, event, data)

proc pmWaitMacIdle(argument: pointer): cint {.cdecl.} =
  discard argument
  cast[cint](wait_mac_goto_idle())

proc pmSetMacDoze(argument: pointer): cint {.cdecl.} =
  discard argument
  cast[cint](set_mac_to_doze())

proc pmWakePre(argument: pointer): cint {.cdecl.} =
  discard argument
  cast[cint](wakeup_from_doze_pre())

proc pmWaitMacPrestate(argument: pointer): cint {.cdecl.} =
  discard argument
  cast[cint](wait_mac_goto_prestate())

proc pmWakeDone(argument: pointer): cint {.cdecl.} =
  discard argument
  cast[cint](wakeup_from_doze_done())

proc pmRecoverMac(argument: pointer): cint {.cdecl.} =
  discard argument
  cast[cint](mac_recovery())

proc pmCheckForcedSleep(argument: pointer): cint {.cdecl.} =
  discard argument
  pm_force_sleep_check().cint

proc pmSetCoexMode(argument: pointer): cint {.cdecl.} =
  coex_pta_force_autocontrol_set(cast[uint](argument).uint32)
  0

proc pmRestoreChannel(argument: pointer): cint {.cdecl.} =
  rfc_channel_ops(cast[uint](argument).uint32)
  0

proc pmBleRf(argument: pointer): cint {.cdecl.} =
  ble_rf_ops(cast[uint](argument).uint32)
  0

proc bl_pm_ops_register*(ops: pointer) {.exportc, cdecl.} =
  ## Preserve the vendor's event/code/capability/priority order and contexts.
  ## Internal operations use adapters for the PM int(void *) callback ABI.
  proc wifi_hosal_pm_event_register(event: cint; code, capBit: uint32;
      priority: uint16; callback, argument: pointer; enable: cint): cint
      {.importc, cdecl, discardable.}
  discard ops
  napSleepActive = 1
  wifi_hosal_pm_event_register(1, 0, 2, 13, cast[pointer](pmWaitMacIdle), nil, 1)
  wifi_hosal_pm_event_register(1, 1, 16, 20, cast[pointer](pmSetCoexMode), cast[pointer](2'u), 1)
  wifi_hosal_pm_event_register(1, 1, 4, 125, cast[pointer](pmSetMacDoze), nil, 1)
  wifi_hosal_pm_event_register(1, 1, 8, 150, cast[pointer](wifi_hosal_rf_turn_off), nil, 1)
  wifi_hosal_pm_event_register(2, 2, 16, 5, cast[pointer](pmSetCoexMode), cast[pointer](1'u), 1)
  wifi_hosal_pm_event_register(2, 2, 8, 10, cast[pointer](wifi_hosal_rf_turn_on), nil, 1)
  wifi_hosal_pm_event_register(2, 2, 8, 11, cast[pointer](pmRestoreChannel), nil, 1)
  wifi_hosal_pm_event_register(2, 2, 4, 34, cast[pointer](pmWakePre), nil, 1)
  wifi_hosal_pm_event_register(2, 2, 2, 36, cast[pointer](pmWaitMacPrestate), nil, 1)
  wifi_hosal_pm_event_register(2, 2, 4, 140, cast[pointer](pmWakeDone), nil, 1)
  wifi_hosal_pm_event_register(2, 0, 2, 60, cast[pointer](pmRecoverMac), nil, 0)
  wifi_hosal_pm_event_register(4, 0, 32, 20, cast[pointer](pmCheckForcedSleep), nil, 1)
  wifi_hosal_pm_event_register(4, 1, 2, 8, cast[pointer](wifi_hosal_rf_turn_on), nil, 0)
  wifi_hosal_pm_event_register(4, 1, 2, 18, cast[pointer](pmRestoreChannel), nil, 0)
  wifi_hosal_pm_event_register(3, 0, 4, 100, cast[pointer](wifi_hosal_rf_turn_on), nil, 0)
  wifi_hosal_pm_event_register(3, 0, 4, 123, cast[pointer](pmRestoreChannel), nil, 0)
  wifi_hosal_pm_event_register(0, 3, 16, 35, cast[pointer](pmSetCoexMode), nil, 1)
  wifi_hosal_pm_event_register(5, 0, 8, 10, cast[pointer](pmBleRf), cast[pointer](1'u), 1)
  wifi_hosal_pm_event_register(5, 1, 8, 20, cast[pointer](pmBleRf), nil, 1)

proc bl_pti_reset*() {.exportc, cdecl.} =
  ## Reset Priority Traffic Indication (PTA coexistence).
  ## Not found in objdump (possibly in separate coex object file).
  ## From 63-instruction description and coex_pta_force_autocontrol_set patterns:
  ##   Resets all PTA priority registers at COEX_BASE (0x44920000) and
  ##   MACHW_BCN_STATUS_REG area (0x44B00400) to default coexistence state.
  ##
  ## Registers manipulated (from coex module patterns):
  ##   COEX_BASE + 0x004: PTA control register - clear/set priority bits
  ##   COEX_BASE + 0x428: PTA force control register - clear to 0
  ##   MACHW_BASE + 0x400: BCN/PTA status register - clear/set enable bit
  let coexBase = COEX_BASE
  let machwPtaReg = MACHW_BASE + 0x400'u

  # Clear PTA force control register
  regWrite(coexBase + 0x428'u, 0)

  # Reset PTA control bits in COEX_CTRL_REG (offset 0x004):
  # Clear bits: 0 (enable), 1 (WiFi priority), 4 (force),
  #             16 (ext priority), 17 (band sel), 18 (override), 19 (alt mode)
  var ctrlVal = regRead(coexBase + 0x004'u)
  ctrlVal = ctrlVal and not 0x000F0013'u32  # Clear control bits
  ctrlVal = ctrlVal or 0x00000012'u32       # Set default: bit1=WiFi priority, bit4=enable
  regWrite(coexBase + 0x004'u, ctrlVal)

  # Reset MACHW PTA/BCN status register
  var ptaVal = regRead(machwPtaReg)
  ptaVal = ptaVal and not 0x00000001'u32    # Clear enable bit
  regWrite(machwPtaReg, ptaVal)

  # Re-enable with defaults
  ptaVal = regRead(machwPtaReg)
  ptaVal = ptaVal or 0x00000001'u32         # Set enable bit
  regWrite(machwPtaReg, ptaVal)

proc bl_wifi_timer_arm*(timer: pointer, delayMs: uint32) {.exportc, cdecl.} =
  ## Arm a WiFi timer.
  ## From blob (7 instrs): reads MAC timestamp, converts delay from ms to MAC ticks
  ## (multiply by 1000), adds to timestamp for absolute target time,
  ## tail-calls mm_timer_set(timer, targetTime).
  let macTime = macTimeNow()
  let delayTicks = delayMs * 1000'u32  # 1MHz MAC clock: 1000 ticks per ms
  let targetTime = macTime + delayTicks
  mm_timer_set(timer, targetTime)

proc bl_wifi_timer_disarm*(timer: pointer) {.exportc, cdecl.} =
  ## Disarm a WiFi timer.
  ## From blob (2 instrs): tail-call to mm_timer_clear(timer).
  mm_timer_clear(timer)

proc bl_wifi_timer_done*(timer: pointer): bool {.exportc, cdecl.} =
  ## Check if a WiFi timer has expired.
  return true

proc bl_wifi_timer_setfn*(timer: pointer, fn: pointer) {.exportc, cdecl.} =
  ## Set timer callback function (3 instrs).
  ## From blob: sw a1,4(a0); sw a2,8(a0); ret
  ## Stores fn (a1) at timer+4 and the third C arg (a2, callback context) at timer+8.
  let t = cast[uint](timer)
  cast[ptr pointer](t + 4)[] = fn
  # Capture and store the third C arg (a2) at timer+8
  var cbArg: pointer
  {.emit: ["asm volatile(\"mv %0, a2\" : \"=r\"(", cbArg, ") );"].}
  cast[ptr pointer](t + 8)[] = cbArg

# BL WiFi WPA/security callbacks
proc bl_wifi_register_wpa_cb_internal*(cb: pointer) {.exportc, cdecl.} =
  ## Register WPA callback.
  ## From blob (4 instrs): stores cb to wpa_cbs global, returns 0.
  wpa_cbs = cb

proc bl_wifi_unregister_wpa_cb_internal*() {.exportc, cdecl.} =
  ## Unregister WPA callback.
  ## From blob (4 instrs): stores nil to wpa_cbs global, returns 0.
  wpa_cbs = nil

proc bl_wifi_set_appie_internal*(vifIdx: uint8, ieType: uint8, ie: pointer, ieLen: uint16) {.exportc, cdecl.} =
  ## Set application IE for frames.
  ## From blob (36 instrs):
  ##   ieType==0: calls internal assoc IE handler(vifIdx, ie, ieLen&0xFF)
  ##   ieType==1: stores ie/ieLen into beacon extra IE globals (max 170 bytes)
  ##   ieType==2: stores ie/ieLen into probe response extra IE globals (max 50 bytes)
  ## Returns 0 on success, -1 on invalid length (return in a0).
  if ieType == 0:
    # Forward to WPA/RSN IE handler (blob: mm_set_wpa_rsn_ie(vifIdx, ie, len)).
    mm_set_wpa_rsn_ie(vifIdx, ie, (ieLen and 0xFF).uint8)
  elif ieType == 1:
    # Beacon extra IE: max 170 bytes
    if ieLen > 170:
      return
    appIeBeaconPtr = ie
    appIeBeaconLen = ieLen
  elif ieType == 2:
    # Probe response extra IE: max 50 bytes
    if ieLen > 50:
      return
    appIeProbeRespPtr = ie
    appIeProbeRespLen = ieLen

proc bl_wifi_unset_appie_internal*(vifIdx: uint8, ieType: uint8) {.exportc, cdecl.} =
  ## Unset application IE.
  ## From blob (6 instrs): tail-calls bl_wifi_set_appie_internal(vifIdx, ieType, nil, 0).
  bl_wifi_set_appie_internal(vifIdx, ieType, nil, 0)

type
  SupplicantKeyOwner = object
    vif, station, role: uint8
    trackedStation: bool
    vifEpoch, stationEpoch: uint32
    macAddr: array[6, uint8]

proc captureSupplicantKeyOwner(vifIdx, staIdx, role: uint8;
                              trackStation: bool; owner: var SupplicantKeyOwner): bool =
  if vifIdx >= MAX_VIFS.uint8:
    return false
  let vif = vifChannelForIdx(vifIdx)
  if vif.vifType != role:
    return false
  owner = SupplicantKeyOwner(vif: vifIdx, station: staIdx, role: role,
    trackedStation: trackStation, vifEpoch: rxVifEpochs[vifIdx])
  if trackStation:
    if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
      return false
    let sta = staInfoForIdx(staIdx)
    if sta.instNbr != vifIdx or
        (staIdx < STA_MGMT_FREE_STAS.uint8 and sta.valid == 0) or
        (staIdx >= STA_MGMT_FREE_STAS.uint8 and
          staIdx != STA_MGMT_FREE_STAS.uint8 + vifIdx):
      return false
    owner.stationEpoch = staDeleteEpoch(staIdx)
    owner.macAddr = sta.macAddr
  true

proc supplicantKeyOwnerCurrent(owner: SupplicantKeyOwner): bool =
  if rxVifEpochs[owner.vif] != owner.vifEpoch or
      vifChannelForIdx(owner.vif).vifType != owner.role:
    return false
  if owner.trackedStation:
    let sta = staInfoForIdx(owner.station)
    if sta.instNbr != owner.vif or sta.macAddr != owner.macAddr or
        staDeleteEpoch(owner.station) != owner.stationEpoch or
        (owner.station < STA_MGMT_FREE_STAS.uint8 and sta.valid == 0):
      return false
  true

proc supplicantKeyLengthValid(alg: uint32; keyLen: csize_t): bool =
  case alg
  of 1: keyLen == 5
  of 2: keyLen == 32
  of 3: keyLen == 16
  of 5: keyLen == 13
  of 6: keyLen == 5 or keyLen == 13
  else: false

proc setKey(vifIdx: uint8, a1Byte: uint8, keyIdxOrPairwise: uint8,
            macAddr: pointer, macLen: csize_t,
            keyData: pointer, keyLen: csize_t, pairwise: bool): uint8
  {.exportc: "set_key_constprop0_nim", noinline.} =
  ## The vendor's eighth argument and descriptor byte 55 are the pairwise flag.
  if vifIdx >= MAX_VIFS.uint8 or keyIdxOrPairwise > 3 or
      (pairwise and a1Byte >= STA_INFO_TAB_ENTRIES.uint8) or
      keyLen notin [5.csize_t, 13.csize_t, 16.csize_t, 32.csize_t] or
      macLen > 8 or keyData == nil or (macLen != 0 and macAddr == nil):
    return 0xFF
  let saved = irqSave()
  defer: irqRestore(saved)
  var request: SupplicantKeyParamView
  let keyDescriptor = addr request
  keyDescriptor.keyIdx = vifIdx
  keyDescriptor.keyType = if pairwise: a1Byte else: 0xFF'u8
  keyDescriptor.pairwise = pairwise.uint8
  keyDescriptor.addrIdx = keyIdxOrPairwise
  if macLen != 0:
    discard c_memcpy(addr keyDescriptor.macAddr[0], macAddr, macLen)
    keyDescriptor.macLen = macLen.uint8
  keyDescriptor.keyLen = keyLen.uint8
  discard c_memcpy(addr keyDescriptor.keyData[0], keyData, keyLen)
  case keyLen
  of 16: keyDescriptor.translatedCipher = 2
  of 32:
    let tkip = supplicantTkipKeyData(keyDescriptor)
    let micTx = tkip.micTx
    tkip.micTx = tkip.micRx
    tkip.micRx = micTx
    keyDescriptor.translatedCipher = 1
  of 13: keyDescriptor.translatedCipher = 3
  else: keyDescriptor.translatedCipher = 0
  nimFwDbgSetKey0 = keyDescriptor.addrIdx.uint32 or (keyDescriptor.keyType.uint32 shl 8) or
    (keyDescriptor.keyLen.uint32 shl 16) or (keyDescriptor.macLen.uint32 shl 24)
  nimFwDbgSetKey1 = keyDescriptor.translatedCipher.uint32 or (keyDescriptor.keyIdx.uint32 shl 8) or
    (keyDescriptor.spp.uint32 shl 16) or (keyDescriptor.pairwise.uint32 shl 24)
  nimFwDbgSetKey2 = pointerAddrU32(keyData)
  nimFwDbgSetKey3 = pointerAddrU32(macAddr)
  mm_sec_machwkey_wr(keyDescriptor)

proc bl_wifi_set_ap_key_internal*(vifIdx, staIdx: uint8, alg: uint32,
    keyIdx: int32, keyData: pointer, keyLen: csize_t,
    pairwise: bool): cint {.exportc, cdecl.} =
  ## Matches supplicant_api.h; ALG_NONE, not a group key, selects deletion.
  let saved = irqSave()
  defer: irqRestore(saved)
  var owner: SupplicantKeyOwner
  if not captureSupplicantKeyOwner(vifIdx, staIdx, VIF_TYPE_AP,
      pairwise or alg == 0, owner):
    return -1
  if alg == 0:
    if not mmDeleteSecurityKey(staIdx + 8'u8):
      return -1
  else:
    if keyIdx < 0 or keyIdx > 3 or not supplicantKeyLengthValid(alg, keyLen):
      return -1
    let hardwareIndex = setKey(vifIdx, staIdx, keyIdx.uint8,
      nil, 0, keyData, keyLen, pairwise)
    if hardwareIndex == 0xFF:
      return -1
  if not supplicantKeyOwnerCurrent(owner):
    return -1
  let logFn = getLogFunc(204)
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      1, nil, "supplicant_api.c", 192,
      "bl_wifi_set_ap_key_internal: vif_idx %u, sta_idx %u, alg %u, key_idx %u, key_len %u, pairwise %d\r\n",
      vifIdx.cuint, staIdx.cuint, alg.cuint, cast[cuint](keyIdx),
      cast[cuint](keyLen), pairwise.cint)
  if not supplicantKeyOwnerCurrent(owner):
    return -1
  0

proc bl_wifi_set_sta_key_internal*(vifIdx: uint8, staIdx: uint8, alg: uint32,
    keyIdx: int32, setTx: int32, seqData: pointer, seqLen: csize_t,
    keyData: pointer, keyLen: csize_t, pairwise: bool): cint {.exportc, cdecl.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  var owner: SupplicantKeyOwner
  if keyIdx < 0 or keyIdx > 3 or not supplicantKeyLengthValid(alg, keyLen) or
      not captureSupplicantKeyOwner(vifIdx, staIdx, VIF_TYPE_STA, true, owner):
    return -1
  var hardwareIndex = setKey(vifIdx, staIdx, keyIdx.uint8,
    seqData, seqLen, keyData, keyLen, pairwise)
  if hardwareIndex == 0xFF or not supplicantKeyOwnerCurrent(owner):
    return -1
  let keyType = if pairwise: 0'u32 else: 1'u32
  if sm_get_set_machwkey_index(0, vifIdx.uint32, addr hardwareIndex, keyType) != 0 or
      not supplicantKeyOwnerCurrent(owner):
    return -1
  let logFn = getLogFunc(204)
  if logFn != nil:
    let writeLog = cast[proc(level: uint32; tag, file: cstring; line: cint;
                            format: cstring) {.cdecl, varargs.}](logFn)
    writeLog(1, nil, "supplicant_api.c", 211,
      "bl_wifi_set_sta_key_internal: vif_idx %u, sta_idx %u\r\n",
      vifIdx.cuint, staIdx.cuint)
    if not supplicantKeyOwnerCurrent(owner): return -1
    writeLog(1, nil, "supplicant_api.c", 212,
      "\t alg %u, key_idx %u, set_tx %d, key_len %lu, pairwise %d\r\n",
      alg.cuint, cast[cuint](keyIdx), setTx.cint, keyLen.culong, pairwise.cint)
    if not supplicantKeyOwnerCurrent(owner): return -1
    writeLog(1, nil, "supplicant_api.c", 213, "hw_key_idx: %u\r\n", hardwareIndex.cuint)
  if not supplicantKeyOwnerCurrent(owner):
    return -1
  0

proc bl_wifi_set_igtk_internal*(vifIdx, staIdx: uint8, keyIdx: uint16,
    pn, keyData: pointer): cint {.exportc, cdecl.} =
  ## IGTK uses the dedicated two-slot BIP table and a six-byte receive PN.
  let saved = irqSave()
  defer: irqRestore(saved)
  var owner: SupplicantKeyOwner
  if keyIdx notin [4'u16, 5'u16] or pn == nil or keyData == nil or
      not captureSupplicantKeyOwner(vifIdx, staIdx, VIF_TYPE_STA, true, owner):
    return -1
  var request: MachwKeyWriteParamView
  let req = addr request
  req.keyType = 0xFF
  req.cipherType = 5
  req.keyIdx = vifIdx
  req.addrIdx = keyIdx.uint8
  req.keyLen = 16
  req.macLen = 6
  discard c_memcpy(addr req.keyWords[0], keyData, 16.csize_t)
  discard c_memcpy(addr req.macAddr[0], pn, 6.csize_t)
  var hardwareIndex = mm_sec_machwkey_wr(req)
  if hardwareIndex == 0xFF or not supplicantKeyOwnerCurrent(owner):
    return -1
  if sm_get_set_machwkey_index(0, vifIdx.uint32, addr hardwareIndex, 2) != 0 or
      not supplicantKeyOwnerCurrent(owner):
    return -1
  let logFn = getLogFunc(204)
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      1, nil, "supplicant_api.c", 237,
      "%s: vif_idx %u, sta_idx %u, key_idx %u, hw_key_idx %u\r\n",
      cstring("bl_wifi_set_igtk_internal"), vifIdx.cuint, staIdx.cuint,
      keyIdx.cuint, hardwareIndex.cuint)
  if not supplicantKeyOwnerCurrent(owner):
    return -1
  0

proc bl_wifi_get_sta_gtk*(vifIdx: uint8, keyBuf: pointer, outputBuf: pointer): cint {.exportc, cdecl.} =
  ## Return the complete GTK in the byte order supplied to setKey.
  ## The hardware table contains only the temporal key, not TKIP's MIC keys.
  if vifIdx >= MAX_VIFS.uint8 or keyBuf == nil or outputBuf == nil:
    return -1
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  var keyIdx = 0xFF'u8
  let rc = sm_get_set_machwkey_index(1'u32, vifIdx.uint32, cast[pointer](addr keyIdx), 1'u32)
  if rc != 0'u8 or keyIdx >= (MAX_VIFS * 4).uint8 or keyIdx shr 2 != vifIdx:
    return -1
  let vif = vifChannelForIdx(vifIdx)
  let keyId = keyIdx and 3
  let key = vifKeySlot(vif, keyId.uint)
  let index = rxMgtKeyIndex(key)
  if index < 0: return -1
  let epoch = rxVifEpochs[vifIdx]
  let revision = rxKeyLastChanged[index]
  let clock = rxKeyRevision
  let cipher = key.cipherType
  let selected = vifKeySlotPtr(vif, keyId.uint)
  template current(): bool =
    rxVifEpochs[vifIdx] == epoch and rxKeyRevision >= clock and
      rxKeyLastChanged[index] == revision and key.installed != 0 and
      key.cipherType == cipher and key.keyIdx == keyIdx and key.staIdx == keyId and
      vifKeyPointers(vif).defaultKeyPtr == selected
  if not current(): return -1
  let length = case cipher
    of 0: 5
    of 1: 32
    of 2: 16
    of 3: 13
    else: 0
  if length == 0: return -1
  let micKeys = key.keyMaterial
  var entry: MmSecurityReadback
  if not mmReadSecurityEntry(keyIdx, entry) or not current():
    return -1
  var bytes: array[32, uint8]
  for i in 0 ..< min(length, 16):
    bytes[i] = ((entry.words[i div 4] shr ((i mod 4) * 8)) and 255).uint8
  if cipher == 1:
    # setKey swaps the two eight-byte MIC keys before firmware installation.
    for i in 0 ..< 8:
      bytes[16 + i] = micKeys[8 + i]
      bytes[24 + i] = micKeys[i]
  discard c_memcpy(keyBuf, addr bytes[0], length.csize_t)
  if not current():
    return -1
  cast[ptr uint8](outputBuf)[] = length.uint8
  return 0

proc bl_wifi_ap_deauth_internal*(vifIdx, staIdx: uint8, reason: uint32): cint {.exportc, cdecl.} =
  ## Matches supplicant_api.h: int(uint8_t, uint8_t, uint32_t).
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      1, nil, "supplicant_api.c", 22,
      "bl_wifi_ap_deauth_internal: vif_idx %u, sta_idx %u, reason %lu\r\n",
      vifIdx.cuint, staIdx.cuint, reason.culong)
  if apm_sta_remove(vifIdx, staIdx, WLAN_FW_APM_DEAUTH_BY_AUTHENTICATOR.uint16,
                    (reason and 0xFFFF'u32).uint16): 0 else: -1

proc bl_wifi_auth_done_internal*(staIdx: uint8; reasonCode: uint16): bool {.exportc, cdecl.} =
  ## Vendor supplicant ABI: bool(uint8_t sta_idx, uint16_t reason_code).
  if staIdx.int >= STA_INFO_TAB_ENTRIES:
    return false
  let logFn = getLogFunc(204)
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      1, nil, "supplicant_api.c", 29,
      "bl_wifi_auth_done_internal: sta_idx %u, reason_code %u\r\n",
      staIdx.cuint, reasonCode.cuint)
  if reasonCode == 0'u16:
    let vifIdx = staInfoForIdx(staIdx).instNbr
    if vifIdx.int < MAX_VIFS:
      nimFwWpaPendingMask = nimFwWpaPendingMask and
        (not (1'u32 shl vifIdx.uint32))
      vifChannelForIdx(vifIdx).probeCount = 0
  sm_handle_supplicant_result(staIdx, reasonCode)
  return true

proc bl_wifi_get_assoc_bssid_internal*(vifIdx: uint8, output: pointer): cint {.exportc, cdecl.} =
  ## Get associated BSSID.
  ## From blob (19 instrs):
  ##   Calls vif_mgmt_get_vif(vifIdx) to get the VIF entry.
  ##   If nil, returns -1. Otherwise, copies 6 bytes (BSSID) from
  ##   vifEntry + 380 (0x17C) to output, returns 0.
  let vifEntry = vif_mgmt_get_vif(vifIdx)
  if vifEntry == nil:
    return -1
  let vif = vifChannelAt(vifEntry)
  discard c_memcpy(output, addr vif.bssid[0], 6.csize_t)
  return 0

proc bl_wifi_get_hostap_private_internal*(): pointer {.exportc, cdecl.} =
  ## Get hostapd private data.
  ## From blob (2 instrs): tail-calls apm_get_hostapd_ctx().
  return apm_get_hostapd_ctx()

proc bl_wifi_get_wps_status_internal*(): uint8 {.exportc, cdecl.} =
  ## Get WPS status.
  ## From blob (3 instrs): loads wpsStatus global byte, returns it.
  return wpsStatus

proc bl_wifi_set_wps_cb_internal*(cb: pointer) {.exportc, cdecl.} =
  ## Set WPS callback.
  ## From blob (4 instrs): stores cb to wps_cbs global, returns 0.
  wps_cbs = cb

proc bl_wifi_set_wps_status_internal*(status: uint8) {.exportc, cdecl.} =
  ## Set WPS status.
  ## From blob (3 instrs): stores a0 to wpsStatus global byte, returns.
  wpsStatus = status

proc bl_wifi_wpa_ptk_init_done_internal*(staIdx: uint8): bool {.exportc, cdecl.} =
  ## Vendor bool(uint8_t sta_idx): log, then mark that AP station ready.
  inc nimFwDbgPtkInitDone
  if staIdx.int >= STA_INFO_TAB_ENTRIES:
    return false
  let logFn = getLogFunc(204)
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      1, nil, "supplicant_api.c", 99,
      "bl_wifi_wpa_ptk_init_done_internal: sta_idx %u\r\n", staIdx.cuint)
  apm_handle_auth_done(cast[pointer](staIdx.uint))
  true

proc bl_wifi_skip_supp_pmkcaching*(): bool {.exportc, cdecl.} =
  ## Check if PMK caching should be skipped.
  return false

proc bl_wifi_sta_is_ap_notify_completed_rsne_internal*(): bool {.exportc, cdecl.} =
  ## Vendor blob returns constant true. The supplicant uses this to decide
  ## whether to include the complete RSNE in association and EAPOL M2.
  return true

proc bl_wifi_sta_is_running_internal*(): bool {.exportc, cdecl.} =
  ## Vendor blob returns constant true.
  return true

proc bl_wifi_sta_set_reset_param_internal*(param: pointer) {.exportc, cdecl.} =
  ## Set reset parameters for STA.
  ## From blob (2 instrs): li a0,0; ret -- always returns 0 (success).
  discard  # void return; blob returns 0 in a0 for C ABI

proc bl_wifi_sta_update_ap_info_internal*(param: pointer) {.exportc, cdecl.} =
  ## Update AP info.
  ## From blob (2 instrs): li a0,1; ret -- always returns 1 (success).
  discard  # void return; blob returns 1 in a0 for C ABI
