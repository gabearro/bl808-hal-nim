# ###########################################################################
#                  PLATFORM INTEGRATION (bl_*)
# ###########################################################################

proc bl_supplicant_init() {.importc: "bl_supplicant_init", cdecl.}
  ## External: initializes WPA supplicant layer.

proc bl_init*() {.exportc, cdecl.} =
  ## Initialize platform layer (60 bytes in blob).
  ## From blob: stores fw_nap_chain addr to fw_nap_chain_ptr (.LANCHOR1),
  ## clears bl_env[1], then calls me_init → mm_init → ke_init → bl_supplicant_init.
  fw_nap_chain_ptr = cast[pointer](addr fw_nap_chain[0])
  bl_env[1] = 0
  nimFwTrace("[WIFI-NIMFW] me_init begin")
  me_init()
  nimFwTrace("[WIFI-NIMFW] me_init done")
  nimFwTrace("[WIFI-NIMFW] mm_init begin")
  mm_init()
  nimFwTrace("[WIFI-NIMFW] mm_init done")
  nimFwTrace("[WIFI-NIMFW] ke_init begin")
  ke_init()
  nimFwTrace("[WIFI-NIMFW] ke_init done")
  nimFwTrace("[WIFI-NIMFW] bl_supplicant_init begin")
  bl_supplicant_init()
  nimFwTrace("[WIFI-NIMFW] bl_supplicant_init done")

proc bl_reset_evt*() {.exportc, cdecl.} =
  ## Handle reset event. Blob sequence inside IRQ-disabled critical section:
  ##   ke_evt_clear(0x80000000)
  ##   hal_machw_reset()
  ##   rxl_reset(); txl_reset(); mm_reset()
  ##   vif_mgmt_reset()
  ##   ke_evt_clear(0x04000000)
  ## Restore mstatus.MIE only if it was set on entry.
  let saved = irqSave()
  ke_evt_clear(0x80000000'u32)
  hal_machw_reset()
  rxl_reset()
  txl_reset()
  mm_reset()
  vif_mgmt_reset()
  ke_evt_clear(0x04000000'u32)
  irqRestore(saved)

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
  ## Schedule sleep check (68 instrs in blob).
  ## Blob calls: wifi_hosal_pm_state_run, chan_is_on_channel,
  ## wifi_hosal_pm_post_event (4 instances). Walks vif_mgmt_env+8 list.
  ##
  ## Flow:
  ##   1. wifi_hosal_pm_state_run() -> if nonzero: clear napScheduleState, s0=0
  ##   2. If zero: check ps_env[0] flag byte, walk vif_mgmt_env+8 list
  ##      calling chan_is_on_channel per VIF. If any is on-channel with next!=nil,
  ##      skip sleep. If all VIFs off-channel, s0=1.
  ##   3. Compare napScheduleState with s0. If same, exit.
  ##   4. If s0!=0 (sleep): wifi_hosal_pm_post_event(1,0,&result),
  ##      if result==0: pm_post_event(1,1,0), store state
  ##      if result!=0: pm_post_event(2,0,&result), exit
  ##   5. If s0==0 (wake): pm_post_event(2,1,0) then pm_post_event(2,2,0), store state
  let pmState = wifi_hosal_pm_state_run()
  var newState: uint32

  if wifiMainHasPendingWork():
    newState = 0
  elif pmState != 0:
    # Can sleep: clear state
    napScheduleState = 0
    newState = 0
  else:
    newState = 0  # default: stay awake (s0 = a0 = 0)
    # Check ps_env[0] flag byte
    if psEnvView().enabled != 0:
      # Check vif_mgmt_env+8 linked list for next ptr (offset 4)
      let env = vifMgmtEnvView()
      let firstNode = cast[pointer](env.freeList.last)
      if firstNode == nil:
        # Walk VIF list (vif_mgmt_env+8) calling chan_is_on_channel per node
        var node = cast[pointer](env.activeList.first)
        while node != nil:
          let nodeU = cast[uint](node)
          if chan_is_on_channel(cast[pointer](nodeU)):
            # VIF is on channel - check if it has a next pointer
            let nextPtr = cast[ptr pointer](nodeU + 4)[]
            if nextPtr != nil:
              break  # on-channel VIF with pending work blocks sleep
          node = cast[ptr pointer](nodeU)[]  # next = node[0]
        if node == nil:
          newState = 1  # all VIFs checked, none blocking -> can sleep

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
  ## Calculate nap duration.
  ## From blob (25 instrs):
  ##   Reads the active timer bitmask from MACHW_INTC_IRQ_STAT_REG (0x44B0808C).
  ##   For each of up to 9 timer slots, if the corresponding bit is set:
  ##     1. Read absolute timer target for that slot (from MACHW_BASE + 0x128 region)
  ##     2. Read current MAC timestamp from MACHW_TIMLO_REG (0x44B00120)
  ##     3. Compute remaining = target - current
  ##     4. Track minimum remaining time across all active timers
  ##   Returns the minimum remaining nap duration, or 0xFFFFFFFF if no timers active.
  let activeMask = regRead(MACHW_INTC_BASE + 0x08C'u)  # Active timer bitmask
  var minRemaining: uint32 = 0xFFFFFFFF'u32

  for machwTimerSlotIndex in 0'u32 ..< 9'u32:
    if (activeMask and (1'u32 shl machwTimerSlotIndex)) != 0:
      # Read absolute timer target for this MACHW timer slot.
      # Timer targets are at MACHW_BASE + 0x128 + slot*4 (inferred from blob).
      let target = regRead(MACHW_BASE + 0x128'u + machwTimerSlotIndex * 4)
      let current = regRead(MACHW_TIMLO_REG)
      if current < target:
        let remaining = target - current
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

proc bl_pm_ops_register*(ops: pointer) {.exportc, cdecl.} =
  ## Register power management ops (564 bytes, 196 instrs in blob).
  ## From blob (bl.o): calls wifi_hosal_pm_event_register 19 times in sequence
  ## with different parameters. Each call registers a PM callback for a specific
  ## WiFi power management event type. The 19 registrations cover:
  ##   idle/doze, scan, auth, assoc, channel switch, PS, TX, beacon, etc.
  ## Since wifi_hosal_pm_event_register is a platform callback provided by
  ## the host SDK (not part of the firmware blob itself), we call through
  ## the g_bl_ops_funcs function table.
  ##
  ## From disasm: 19 sequential calls to wifi_hosal_pm_event_register with
  ## args (type: a0, group: a1, size: a2, event_id: a3, callback: a4, flags: a5, enable: a6).
  ## The callbacks are: wait_mac_goto_idle, coex_pta_force_autocontrol_set,
  ## set_mac_to_doze, wifi_hosal_rf_turn_off/on, rfc_channel_ops,
  ## wakeup_from_doze_pre/done, wait_mac_goto_prestate, mac_recovery,
  ## pm_force_sleep_check, ble_rf_ops.
  ##
  ## We register through the platform PM registration function if available.
  ## If the platform doesn't provide it, this is effectively a no-op.
  # The PM registration function may be at a platform-specific offset.
  # In the blob, this is a direct relocation to wifi_hosal_pm_event_register.
  # Since we can't resolve that relocation, we store the registration table
  # so the platform layer can pick it up later.
  #
  # The 19 registrations in order from blob disassembly:
  # 1. wait_mac_goto_idle: type=1, group=0, size=2, event=13, flags=0, enable=1
  # 2. coex_pta_force_autocontrol_set: type=1, group=1, size=16, event=20, flags=1, enable=1
  # 3. set_mac_to_doze: type=1, group=1, size=4, event=125, flags=0, enable=1
  # 4. wifi_hosal_rf_turn_off: type=1, group=1, size=8, event=150, flags=0, enable=1
  # 5. coex_pta_force_autocontrol_set: type=2, group=2, size=16, event=5, flags=1, enable=1
  # 6. wifi_hosal_rf_turn_on: type=2, group=2, size=8, event=10, flags=0, enable=1
  # 7. rfc_channel_ops: type=2, group=2, size=8, event=11, flags=0, enable=1
  # 8. wakeup_from_doze_pre: type=2, group=2, size=4, event=34, flags=0, enable=1
  # 9. wait_mac_goto_prestate: type=2, group=2, size=2, event=36, flags=0, enable=1
  # 10. wakeup_from_doze_done: type=2, group=2, size=4, event=140, flags=0, enable=1
  # 11. mac_recovery: type=2, group=0, size=2, event=60, flags=0, enable=0
  # 12. pm_force_sleep_check: type=4, group=0, size=32, event=20, flags=0, enable=1
  # 13. wifi_hosal_rf_turn_on: type=4, group=1, size=2, event=8, flags=0, enable=0
  # 14. rfc_channel_ops: type=4, group=1, size=2, event=18, flags=0, enable=0
  # 15. wifi_hosal_rf_turn_on: type=3, group=0, size=4, event=100, flags=0, enable=0
  # 16. rfc_channel_ops: type=3, group=0, size=4, event=123, flags=0, enable=0
  # 17. coex_pta_force_autocontrol_set: type=0, group=3, size=16, event=35, flags=2, enable=1
  # 18. ble_rf_ops: type=5, group=0, size=8, event=10, flags=0, enable=1
  # 19. ble_rf_ops: type=5, group=1, size=8, event=20, flags=0, enable=1
  #
  # Call wifi_hosal_pm_event_register for each PM event.
  # The registration function is an external platform symbol.
  # Each call: register(type, group, size, event_id, callback_ptr, flags, enable)
  type PmRegFn = proc(typ: uint32, group: uint32, size: uint32, eventId: uint32,
                      callback: pointer, flags: uint32, enable: uint32) {.cdecl.}
  proc wifi_hosal_pm_event_register(typ: uint32, group: uint32, size: uint32,
      eventId: uint32, callback: pointer, flags: uint32,
      enable: uint32) {.importc, cdecl.}

  # Activate sleep management (enables hook-walking in bl_sleep_schedule)
  napSleepActive = 1

  # 1. wait_mac_goto_idle
  wifi_hosal_pm_event_register(1, 0, 2, 13, cast[pointer](wait_mac_goto_idle), 0, 1)
  # 2. coex_pta_force_autocontrol_set (doze entry)
  wifi_hosal_pm_event_register(1, 1, 16, 20, cast[pointer](coex_pta_force_autocontrol_set), 2, 1)
  # 3. set_mac_to_doze
  wifi_hosal_pm_event_register(1, 1, 4, 125, cast[pointer](set_mac_to_doze), 0, 1)
  # 4. wifi_hosal_rf_turn_off (via ble_rf_ops or similar)
  wifi_hosal_pm_event_register(1, 1, 8, 150, cast[pointer](ble_rf_ops), 0, 1)
  # 5. coex_pta_force_autocontrol_set (wake entry)
  wifi_hosal_pm_event_register(2, 2, 16, 5, cast[pointer](coex_pta_force_autocontrol_set), 1, 1)
  # 6. wifi_hosal_rf_turn_on
  wifi_hosal_pm_event_register(2, 2, 8, 10, cast[pointer](ble_rf_ops), 0, 1)
  # 7. rfc_channel_ops
  wifi_hosal_pm_event_register(2, 2, 8, 11, cast[pointer](rfc_channel_ops), 0, 1)
  # 8. wakeup_from_doze_pre
  wifi_hosal_pm_event_register(2, 2, 4, 34, cast[pointer](wakeup_from_doze_pre), 0, 1)
  # 9. wait_mac_goto_prestate
  wifi_hosal_pm_event_register(2, 2, 2, 36, cast[pointer](wait_mac_goto_prestate), 0, 1)
  # 10. wakeup_from_doze_done
  wifi_hosal_pm_event_register(2, 2, 4, 140, cast[pointer](wakeup_from_doze_done), 0, 1)
  # 11. mac_recovery
  wifi_hosal_pm_event_register(2, 0, 2, 60, cast[pointer](mac_recovery), 0, 0)
  # 12. pm_force_sleep_check
  wifi_hosal_pm_event_register(4, 0, 32, 20, cast[pointer](pm_force_sleep_check), 0, 1)
  # 13. wifi_hosal_rf_turn_on (power domain 4, group 1)
  wifi_hosal_pm_event_register(4, 1, 2, 8, cast[pointer](ble_rf_ops), 0, 0)
  # 14. rfc_channel_ops (power domain 4, group 1)
  wifi_hosal_pm_event_register(4, 1, 2, 18, cast[pointer](rfc_channel_ops), 0, 0)
  # 15. wifi_hosal_rf_turn_on (power domain 3)
  wifi_hosal_pm_event_register(3, 0, 4, 100, cast[pointer](ble_rf_ops), 0, 0)
  # 16. rfc_channel_ops (power domain 3)
  wifi_hosal_pm_event_register(3, 0, 4, 123, cast[pointer](rfc_channel_ops), 0, 0)
  # 17. coex_pta_force_autocontrol_set (ble coex)
  wifi_hosal_pm_event_register(0, 3, 16, 35, cast[pointer](coex_pta_force_autocontrol_set), 2, 1)
  # 18. ble_rf_ops (BLE domain entry)
  wifi_hosal_pm_event_register(5, 0, 8, 10, cast[pointer](ble_rf_ops), 1, 1)
  # 19. ble_rf_ops (BLE domain exit)
  wifi_hosal_pm_event_register(5, 1, 8, 20, cast[pointer](ble_rf_ops), 0, 1)

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

proc setKey(vifIdx: uint8, a1Byte: uint8, keyIdxOrPairwise: uint8,
            macAddr: pointer, macLen: uint8,
            keyData: pointer, keyLen: uint8, alg: uint8,
            pairwise: bool)
  {.exportc: "set_key_constprop0_nim", noinline.} =
  ## Blob `set_key.constprop.0` — shared AP/STA key-struct builder.
  ## Builds the 56-byte HW-key descriptor at a stack buffer and tail-calls
  ## mm_sec_machwkey_wr. ABI matches blob exactly:
  ##   +0   = keyIdxOrPairwise        (a2 in blob)
  ##   +1   = a1Byte (or 0xFF when cipher==0)
  ##   +4   = keyLen
  ##   +8   = keyData memcpy (keyLen bytes)
  ##   +40  = macLen           — only if macAddr != NULL
  ##   +44  = macAddr memcpy   — only if macAddr != NULL
  ##   +52  = translated cipher (16→2, 32→1, 13→3, 5→0, else raw)
  ##   +53  = vifIdx
  ##   +55  = caller-requested cipher
  var keyDescriptorBuffer {.noinit.}: array[56, uint8]
  discard c_memset(addr keyDescriptorBuffer[0], 0, 56.csize_t)
  let keyDescriptor = cast[ptr SupplicantKeyParamView](addr keyDescriptorBuffer[0])
  keyDescriptor.keyIdx = vifIdx
  keyDescriptor.keyType = if pairwise: a1Byte else: 0xFF'u8
  keyDescriptor.requestedCipher = alg
  if alg == 0:
    keyDescriptor.keyType = 0xFF'u8
  keyDescriptor.addrIdx = keyIdxOrPairwise
  if macAddr != nil:
    discard c_memcpy(addr keyDescriptor.macAddr[0], macAddr, macLen.csize_t)
    keyDescriptor.macLen = macLen
  keyDescriptor.keyLen = keyLen
  discard c_memcpy(addr keyDescriptor.keyData[0], keyData, keyLen.csize_t)
  if keyLen == 16:
    # Vendor set_key translates 16-byte temporal keys to cipher 2. The VIF
    # key table handles the group-vs-pairwise distinction separately from the
    # hardware cipher selector.
    keyDescriptor.translatedCipher = 2'u8
  elif keyLen == 32:
    # TKIP: swap MIC key halves at descriptor[24..31] and descriptor[32..39].
    let tkip = supplicantTkipKeyData(keyDescriptor)
    let micTx = tkip.micTx
    tkip.micTx = tkip.micRx
    tkip.micRx = micTx
    keyDescriptor.translatedCipher = 1  # TKIP
  elif keyLen == 13:
    keyDescriptor.translatedCipher = 3  # WEP-104
  elif keyLen == 5:
    keyDescriptor.translatedCipher = 0  # WEP-40
  nimFwDbgSetKey0 = keyDescriptor.addrIdx.uint32 or (keyDescriptor.keyType.uint32 shl 8) or
    (keyDescriptor.keyLen.uint32 shl 16) or (keyDescriptor.macLen.uint32 shl 24)
  nimFwDbgSetKey1 = keyDescriptor.translatedCipher.uint32 or (keyDescriptor.keyIdx.uint32 shl 8) or
    (keyDescriptor.spp.uint32 shl 16) or (keyDescriptor.requestedCipher.uint32 shl 24)
  nimFwDbgSetKey2 = pointerAddrU32(keyData)
  nimFwDbgSetKey3 = pointerAddrU32(macAddr)
  mm_sec_machwkey_wr(addr keyDescriptorBuffer[0])

proc bl_wifi_set_ap_key_internal*(param: pointer) {.exportc, cdecl.} =
  ## Set AP encryption key (59 instructions in blob).
  ##
  ## Blob ABI: a0=vifIdx, a1=macAddr/staIdx, a2=pairwise, a3=keyIdx,
  ##   a4=keyData(ptr), a5=keyLen, a6=cipher. Nim receives a0 as `param`.
  ##
  ## Flow:
  ##   1. Log via g_bl_ops_funcs[204] at line 192.
  ##   2. If pairwise == 0: group key -- call mm_sec_machwkey_del((a1+8) & 0xFF).
  ##   3. If pairwise != 0: pairwise key -- build key struct, call mm_sec_machwkey_wr.
  ##   4. Return 0.
  let vifIdxU8 = (cast[uint32](param) and 0xFF).uint8

  # Best-effort capture of caller's registers a1..a6
  var macAddr_arg: uint32
  var pairwise_arg: uint32
  var keyIdx_arg: uint32
  var keyData_arg: pointer
  var keyLen_arg: uint32
  var cipher_arg: uint32
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", macAddr_arg, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a2\" : \"=r\"(", pairwise_arg, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a3\" : \"=r\"(", keyIdx_arg, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a4\" : \"=r\"(", keyData_arg, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a5\" : \"=r\"(", keyLen_arg, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a6\" : \"=r\"(", cipher_arg, ") );"].}

  # Log entry via g_bl_ops_funcs[204]
  let logFn = getLogFunc(204)
  if logFn != nil:
    logFn(1, 0, nil, 192, vifIdxU8.uint32, macAddr_arg, pairwise_arg)

  if pairwise_arg == 0:
    # Group key: delete old HW key entry
    mm_sec_machwkey_del(((macAddr_arg + 8) and 0xFF).uint8)
  else:
    # Pairwise key: AP path passes no macAddr (a3=0 in blob); a1Byte is the
    # low byte of macAddr_arg, keyIdxOrPairwise = keyIdx.
    setKey(vifIdxU8,
           (macAddr_arg and 0xFF).uint8,   # a1Byte
           keyIdx_arg.uint8,                # keyIdxOrPairwise (blob AP: keyIdx)
           nil, 0'u8,                       # macAddr=NULL, macLen=0
           keyData_arg, keyLen_arg.uint8,   # keyData, keyLen
           cipher_arg.uint8,                # cipher
           true)                            # AP pairwise path

proc bl_wifi_set_sta_key_internal*(vifIdx: uint8, staIdx: uint8, alg: uint32,
    keyIdx: int32, setTx: int32, seqData: pointer, seqLen: csize_t,
    keyData: pointer, keyLen: csize_t, pairwise: bool): cint {.exportc, cdecl.} =
  ## Set STA encryption key (83 instrs).
  ## Blob call: set_key.constprop.0(vifIdx, staIdx, keyIdx, seq, seqLen,
  ##                                keyData, keyLen, pairwise),
  ##            sm_get_set_machwkey_index(0, vifIdx, &status, keyType).
  discard setTx
  let pairwiseByte = if pairwise: 1'u8 else: 0'u8
  setKey(vifIdx,
         staIdx,                        # a1Byte = STA index / key type
         keyIdx.uint8,                  # key index / VIF key slot selector
         seqData, seqLen.uint8,         # replay counter / PN seed
         keyData, keyLen.uint8,         # keyData, keyLen
         alg.uint8,                     # WPA algorithm enum
         pairwise)                      # pairwise vs default/group key path
  # Blob: sm_get_set_machwkey_index(0, vifIdx, &status_byte, keyType)
  var statusByte: uint8 = 0
  let keyType: uint32 = if pairwiseByte == 0: 1 else: 0
  discard sm_get_set_machwkey_index(0, vifIdx.uint32,
    cast[pointer](addr statusByte), keyType)
  # Log the operation via g_bl_ops_funcs[204]
  let logFnPtr = getLogFunc(204)
  if logFnPtr != nil:
    let logFn = cast[PlatformLogFunc](logFnPtr)
    logFn(1, 0, nil, 211, vifIdx.uint32, pairwiseByte.uint32)
    logFn(1, 0, nil, 212, keyLen.uint32, keyIdx.uint32, alg)
    logFn(1, 0, nil, 213)
  return 0

proc bl_wifi_set_igtk_internal*(vifIdx: uint8, macAddr: pointer, keyIdx: uint8,
    keyData: pointer, keyLen: uint8) {.exportc, cdecl.} =
  ## Set IGTK (Integrity Group Temporal Key) for PMF (69 instrs).
  ## Called from host driver to install the IGTK for 802.11w (PMF).
  ## Assembly trace:
  ##   Builds a 56-byte key parameter struct on stack:
  ##     [41] = 0xFF (broadcast index)
  ##     [92] = 5 (key type = IGTK)
  ##     [93] = vifIdx
  ##     [40] = keyIdx
  ##     [44] = 16 (key length)
  ##     [80] = 6 (address type)
  ##     [48..63] = 16-byte key data (from keyData via memcpy)
  ##     [84..89] = 6-byte MAC address (from macAddr via memcpy)
  ##   Calls mm_sec_machwkey_wr(stack_buf) to write IGTK to HW.
  ##   Then calls mm_sec_machwaddr_wr with address setup.
  ##   Logs via g_bl_ops_funcs[204], returns 0.
  var keyBuf {.noinit.}: array[96, uint8]
  let stack = cast[ptr IgtkKeyWriteStackView](addr keyBuf[0])
  let req = addr stack.req
  # Clear buffer
  discard c_memset(cast[pointer](req), 0, sizeof(MachwKeyWriteParamView).csize_t)
  # Set up key parameters
  req.keyType = 0xFF'u8  # broadcast
  req.cipherType = 5     # IGTK type
  req.keyIdx = vifIdx
  req.addrIdx = keyIdx
  req.keyLen = 16        # 16-byte key
  # Copy 16-byte key data
  discard c_memcpy(addr req.keyWords[0], keyData, 16.csize_t)
  # Set address type and copy MAC address
  req.macLen = 6
  discard c_memcpy(addr req.macAddr[0], macAddr, 6.csize_t)
  # Write IGTK to MAC HW
  mm_sec_machwkey_wr(cast[pointer](req))
  # Get/set MAC HW key index (blob: sm_get_set_machwkey_index)
  let resultByte = stack.resultByte
  discard sm_get_set_machwkey_index(0, vifIdx.uint32, cast[pointer](req), 5)
  # Log the operation
  let logFnPtr = getLogFunc(204)
  if logFnPtr != nil:
    let logFn = cast[PlatformLogFunc](logFnPtr)
    logFn(1, 0, nil, 237)

proc bl_wifi_get_sta_gtk*(vifIdx: uint8, keyBuf: pointer, outputBuf: pointer): cint {.exportc, cdecl.} =
  ## Get STA GTK (Group Temporal Key). Blob (25 instrs):
  ##   rc = sm_get_set_machwkey_index(getFlag=1, vifIdx, &keyIdx, keyType=1)
  ##   if rc != 0: return -1
  ##   return mm_sec_machwkey_get(keyIdx, keyBuf, outputBuf)
  var keyIdx {.noinit.}: uint8
  let rc = sm_get_set_machwkey_index(1'u32, vifIdx.uint32, cast[pointer](addr keyIdx), 1'u32)
  if rc != 0'u8:
    return -1
  discard mm_sec_machwkey_get(keyIdx, keyBuf, outputBuf)
  return 0

proc bl_wifi_ap_deauth_internal*(staAddr: pointer, reason: uint16) {.exportc, cdecl.} =
  ## Send deauth to a station in AP mode (86 bytes in blob, 28 instrs).
  ## Blob ABI: a0=staIdx, a1=macAddr, a2=reason.
  ## Flow: log at line 22 via g_bl_ops_funcs[0xCC], then call apm_sta_remove(a0, a1, 6).
  var macAddr {.noinit.}: pointer
  var reasonCode {.noinit.}: uint16
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", macAddr, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a2\" : \"=r\"(", reasonCode, ") );"].}
  # Log via g_bl_ops_funcs[0xCC] (offset 204)
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    type LP = proc(a0, a1: uint32, fmt: pointer, line: uint32, p1, p2, p3: uint32) {.cdecl, varargs.}
    cast[LP](logFn)(1, 0, nil, 22, cast[uint32](staAddr), cast[uint32](macAddr), reasonCode.uint32)
  # Blob: tail-call apm_sta_remove(a0=staAddr, a1=macAddr, a2=6)
  # apm_sta_remove Nim signature: (vifEntry, staIdx, macAddr, reason)
  # but blob passes (a0, a1, 6) — ABI mismatch handled by Nim's cdecl
  let removeFn = cast[proc(a0, a1: pointer, a2: uint32) {.cdecl.}](apm_sta_remove)
  removeFn(staAddr, macAddr, 6)

proc bl_wifi_auth_done_internal*(param: pointer): uint32 {.exportc, cdecl.} =
  ## Notify auth completion (72b in blob).
  ## Blob ABI: a0=staAddr, a1=status.
  ## Logs at line 29 with (a0, a1), calls apm_handle_auth_done(a0, a1), returns 1.
  var status {.noinit.}: pointer
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", status, ") );"].}
  let logFn = getLogFunc(204)
  if logFn != nil:
    cast[proc(a0: uint32, a1: uint32, fmtStr: pointer, line: uint32,
              fileStr: pointer, p0: pointer, p1: pointer) {.cdecl.}](logFn)(
      1, 0, nil, 29, nil, param, status)
  # Blob calls sm_handle_supplicant_result(a0=staAddr, a1=status)
  let staIdx = encodedArgU8(param)
  let statusCode = encodedArgU8(status)
  if statusCode == 0'u8:
    let vifIdx = staInfoForIdx(staIdx).instNbr
    if vifIdx < 8'u8:
      nimFwWpaPendingMask = nimFwWpaPendingMask and
        (not (1'u32 shl vifIdx.uint32))
      vifChannelForIdx(vifIdx).probeCount = 0
  sm_handle_supplicant_result(encodedArgU8(param), encodedArgU8(status))
  return 1

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

proc bl_wifi_wpa_ptk_init_done_internal*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Notify PTK init done.
  ## From blob (23 instrs):
  ##   1. Loads log function from g_bl_ops_funcs and calls it with
  ##      (level=1, severity=0, file_str, line=99, format_str, vifIdx)
  ##   2. Calls sm_connect_ind(0, 0) to signal successful connection
  ##   3. Returns 1
  ## The log call uses the platform log function at g_bl_ops_funcs offset 0.
  inc nimFwDbgPtkInitDone
  if vifIdx < 8:
    nimFwWpaPendingMask = nimFwWpaPendingMask and (not (1'u32 shl vifIdx))
  let logFn = getLogFunc(0)
  if logFn != nil:
    logFn(1, 0, nil, 99)
  # Blob calls apm_handle_auth_done(vifIdx) for PTK init completion
  apm_handle_auth_done(cast[pointer](vifIdx.uint))

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
