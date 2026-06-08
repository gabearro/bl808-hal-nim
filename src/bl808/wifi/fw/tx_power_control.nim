# ###########################################################################
#                  TPC: TX Power Control
# ###########################################################################

proc tpc_update_tx_power*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Update TX power (262 bytes in blob, 87 instrs).
  ## From blob: gets power table via bl_tpc_power_table_get, then runs
  ## bl_pwr_find on three 8-byte groups (11b, 11g, 11n) to find the
  ## rate with the highest power. Calls trpc_get_default_power_idx twice
  ## (once for overall best, once for 11b best) to update PHY state, then
  ## programs MACHW_TX_POWER_REG with fixed power indices 0x40 and 0x48.
  ##
  ## Stack layout from blob (sp+8..sp+13, 6 bytes):
  ##   sp[8]  = 11b best power value
  ##   sp[9]  = 11b best index (bl_pwr_find result)
  ##   sp[10] = 11b rate type (always 0)
  ##   sp[11] = overall best power (across groups 1,2)
  ##   sp[12] = overall best index
  ##   sp[13] = overall best type (1=11g, 2=11n)

  # Clear the 6-byte result buffer
  var resultBuf {.noinit.}: array[6, uint8]
  discard c_memset(addr resultBuf[0], 0, 6.csize_t)

  # Get the full power table (24 rate bytes + 14 channel offset bytes)
  var powerTable {.noinit.}: array[38, int8]
  bl_tpc_power_table_get(addr powerTable)

  # Group 0 (11b, rate entries 0..7):
  var workBuf {.noinit.}: array[8, int8]
  discard c_memcpy(addr workBuf[0], addr powerTable[0], 8.csize_t)
  let idx0 = bl_pwr_find(addr workBuf[0], 8)
  let pwr0 = cast[uint8](workBuf[idx0])
  resultBuf[0] = pwr0          # 11b best power
  resultBuf[1] = cast[uint8](idx0) # 11b best index
  resultBuf[2] = 0             # 11b type = 0

  # Group 1 (11g, rate entries 8..15):
  discard c_memcpy(addr workBuf[0], addr powerTable[8], 8.csize_t)
  let idx1 = bl_pwr_find(addr workBuf[0], 8)
  let pwr1 = cast[uint8](workBuf[idx1])
  if cast[int8](pwr1) > cast[int8](resultBuf[3]):  # blob: bge signed
    resultBuf[3] = pwr1          # overall best power
    resultBuf[5] = 1             # type = 11g
    resultBuf[4] = cast[uint8](idx1) # overall best index

  # Group 2 (11n, rate entries 16..23):
  discard c_memcpy(addr workBuf[0], addr powerTable[16], 8.csize_t)
  let idx2 = bl_pwr_find(addr workBuf[0], 8)
  let pwr2 = cast[uint8](workBuf[idx2])
  if cast[int8](pwr2) > cast[int8](resultBuf[3]):  # blob: bge signed
    resultBuf[3] = pwr2          # overall best power
    resultBuf[5] = 2             # type = 11n
    resultBuf[4] = cast[uint8](idx2) # overall best index

  let bestIdx = resultBuf[4]     # overall best index
  let bestType = resultBuf[5]    # overall best type

  # Call trpc_get_default_power_idx for overall best rate (side effects in PHY)
  discard trpc_get_default_power_idx(bestType.uint32, bestIdx)

  # Program MACHW_TX_POWER_REG bits[7:0] = 0x40
  var regVal = regRead(MACHW_TX_POWER_REG)
  regVal = (regVal and 0xFFFFFF00'u32) or 0x40'u32
  regWrite(MACHW_TX_POWER_REG, regVal)

  # Call trpc_get_default_power_idx for 11b best rate (side effects in PHY)
  let bestIdx11b = resultBuf[1]
  let type11b = resultBuf[2]     # always 0
  discard trpc_get_default_power_idx(type11b.uint32, bestIdx11b)

  # Program MACHW_TX_POWER_REG bits[15:8] = 0x48
  regVal = regRead(MACHW_TX_POWER_REG)
  regVal = (regVal and 0xFFFF00FF'u32) or 0x4800'u32
  regWrite(MACHW_TX_POWER_REG, regVal)

proc tpc_get_vif_tx_power*(vifIdx: uint8): int8 {.exportc, cdecl.} =
  ## Get TX power for a VIF.
  ## From blob (4 instrs): reads MACHW_TX_POWER_REG, returns low byte.
  ## The low byte of this register holds the current TX power level.
  let val = regRead(MACHW_TX_POWER_REG)
  return cast[int8](val and 0xFF)

proc tpc_update_vif_tx_power*(vifEntry: pointer, txPowerElem: pointer, rateParam: pointer) {.exportc, cdecl.} =
  ## Update VIF TX power (168 bytes in blob, 58 instrs).
  ##
  ## Blob ABI: a0=vifEntry, a1=txPowerElem (ptr to i8 power), a2=rateParam.
  ## Flow:
  ##   1. lb a4, 0(a1). If == 127, return (sentinel: no update).
  ##   2. Save old power from vif[89]. Call phy_get_rf_gain_idx(a1, a2).
  ##   3. Read new power from a1[0], clamp to vif[90] (max_power).
  ##   4. Store new to vif[89]. If changed: walk STA list at vif[340],
  ##      set bit 4 in STA[334] (RC flags).
  ##   5. If chanCtxt at vif[64] exists: call chan_update_tx_power,
  ##      chan_is_on_channel, tail-call tpc_update_tx_power.
  let powerVal = cast[ptr int8](txPowerElem)[]
  if powerVal == 127:
    return  # sentinel: no power configured

  let vif = vifChannelAt(vifEntry)
  let oldPower = vif.txPower

  # Call phy_get_rf_gain_idx to convert power to RF gain index
  phy_get_rf_gain_idx(txPowerElem, rateParam)

  # Reload power (may have been modified by phy_get_rf_gain_idx)
  var newPower = cast[ptr int8](txPowerElem)[]
  let maxPower = vif.maxTxPower

  # Store new power to VIF entry
  vif.txPower = newPower

  # Clamp to max_power if exceeded
  if newPower > maxPower:
    cast[ptr int8](txPowerElem)[] = maxPower
    # Re-run phy_get_rf_gain_idx with clamped value
    phy_get_rf_gain_idx(txPowerElem, rateParam)

  # Reload final power
  newPower = cast[ptr int8](txPowerElem)[]
  if newPower == oldPower:
    return  # no change

  # Walk the VIF postponed-STA list and mark rate control for recomputation.
  var staNode = vif.postponedStaHead
  while staNode != nil:
    let sta = staInfoAt(staNode)
    sta.mmFlagsBytes[0] = sta.mmFlagsBytes[0] or 0x10
    staNode = cast[pointer](sta.link.next)

  # Check if VIF has a channel context
  let chanCtxt = vif.chanCtxt
  if chanCtxt == nil:
    return

  # Blob: chan_update_tx_power(chanCtxt) — a0 = channel context pointer
  let chanUpdateFn = cast[proc(ctxt: pointer) {.cdecl.}](chan_update_tx_power)
  chanUpdateFn(chanCtxt)

  # Blob: chan_is_on_channel(vifEntry) — a0 = VIF entry pointer
  let chanOnFn = cast[proc(vif: pointer): bool {.cdecl.}](chan_is_on_channel)
  if not chanOnFn(vifEntry):
    return

  # On-channel: tail-call tpc_update_tx_power with chanCtxt[12] power
  let chanCtxt2 = vif.chanCtxt  # reload
  tpc_update_tx_power(chanCtxtAt(chanCtxt2).channel.txPower)

proc tpc_get_vif_tx_power_vs_rate*(vifIdx: uint8, rate: uint32): int8 {.exportc, cdecl.} =
  ## Get TX power for a specific rate on a VIF (40 bytes in blob, 14 instrs).
  ## From blob:
  ##   1. zext.b a5, a0; andi a1, a0, 0x7F  -> extract rate byte and rate index
  ##   2. Custom .insn divides rate by 128 to get rateGroup
  ##   3. If rateGroup != 0 (HT/VHT rate): a0=2, tail-call trpc_get_default_power_idx
  ##   4. If (a5 & 0x7C) != 0 (11g rate): a1 -= 4, zext.b, a0=1
  ##   5. Tail-call trpc_get_default_power_idx(rateType, adjustedRateIdx)
  ##
  ## This classifies the rate into legacy-11b (type 0), legacy-11g (type 1),
  ## or HT/VHT (type 2) and dispatches to trpc_get_default_power_idx.
  let rateByte = (rate and 0xFF).uint8
  let rateIdx = (rate and 0x7F).uint8  # 7-bit rate index
  let rateGroup = rateByte div 128     # custom insn divides by group size

  # Blob tail-calls trpc_get_default_power_idx from a single site.
  var rateType: uint8
  var adjIdx: uint8 = rateIdx
  if rateGroup != 0:
    rateType = 2                       # HT/VHT
  elif (rateByte and 0x7C) != 0:
    rateType = 1                       # 11g
    adjIdx = ((rateIdx - 4) and 0xFF).uint8
  else:
    rateType = 0                       # 11b
  return trpc_get_default_power_idx(rateType, adjIdx)

proc tpc_update_frame_tx_power*(env: pointer, frameDesc: pointer) {.exportc, cdecl.} =
  ## Update TX power for a specific frame.
  ## From blob (13 instrs):
  ##   1. lw a5, 112(frameDesc)   -> a5 = frameDesc->txdesc (offset 112)
  ##   2. lw s0, 40(a5)           -> s0 = txdesc->rateCtrl (offset 40)
  ##   3. lw a0, 20(s0)           -> a0 = rateCtrl->rate (offset 20)
  ##   4. call tpc_get_vif_tx_power_vs_rate(rate)
  ##   5. sw a0, 36(s0)           -> rateCtrl->txPower = result (offset 36)
  if frameDesc == nil: return
  let txdesc = hostTxDescAt(frameDesc).hwDesc
  if txdesc == nil: return
  let rateCtrl = hostTxHwDescAt(txdesc).chainedThd
  if rateCtrl == nil: return
  let rateCtrlView = hostTxRateTemplateAt(rateCtrl)
  let rate = rateCtrlView.rateWord
  let txPower = tpc_get_vif_tx_power_vs_rate(0, rate)
  rateCtrlView.txPower = txPower.int32

  ## bl_tpc_power_table_get forward declaration already at line 1209

proc bl_tpc_update_power_table*(powerTable: ptr array[38, int8]) {.exportc, cdecl.} =
  ## Update the full TX power table.
  ## From blob (22 instrs):
  ##   1. Calls trpc_update_power to update the first 24 bytes (rate part)
  ##   2. Scales remaining 14 bytes (channel offsets) by 4 into int8_t[14]
  ##   3. Calls phy_powroffset_set(scaledOffsets)
  proc phy_powroffset_set(powerOffset: ptr int8) {.importc, cdecl.}
  trpc_update_power(powerTable)
  var scaled {.noinit.}: array[14, int8]
  for i in 0 ..< 14:
    let offset = powerTable[24 + i]
    tpcChannelOffsetTable[i] = offset
    tpcPowerTable[24 + i] = offset
    scaled[i] = cast[int8](offset.int32 * 4'i32)
  phy_powroffset_set(addr scaled[0])

proc bl_tpc_update_power_table_rate*(powerTable: ptr array[24, int8]) {.exportc, cdecl.} =
  ## Update per-rate TX power table (blob: tail-call to trpc_update_power).
  trpc_update_power(powerTable)

proc bl_tpc_update_power_table_channel_offset*(powerTable: ptr array[38, int8]) {.exportc, cdecl.} =
  ## Update only the channel-offset portion of a TX power table.
  ##
  ## The vendor ABI names this as a channel-offset update, but DWARF and
  ## disassembly show the argument is the full int8_t power table and offsets
  ## are read from bytes 24..37. The PHY hook receives those offsets scaled by
  ## four in an int8_t[14] scratch buffer.
  proc phy_powroffset_set(powerOffset: ptr int8) {.importc, cdecl.}
  type PrintfFn = proc(fmt: cstring) {.cdecl, varargs.}

  let printFn = cast[PrintfFn](blOpsFunc(4))
  var scaled {.noinit.}: array[14, int8]
  for i in 0 ..< 14:
    let offset = powerTable[24 + i]
    let phyOffset = offset.int32 * 4'i32
    tpcChannelOffsetTable[i] = offset
    tpcPowerTable[24 + i] = offset
    scaled[i] = cast[int8](phyOffset)
    if printFn != nil:
      printFn(cstring"pwr chan[%d] offset:%d\r\n", i.cint, phyOffset.cint)
  if printFn != nil:
    printFn(cstring"dynamic update channel offset\r\n")
  phy_powroffset_set(addr scaled[0])

proc bl_tpc_update_power_rate_11b*(powerTable: ptr array[4, int8]) {.exportc, cdecl.} =
  ## Update 11b per-rate TX power (blob: tail-call to trpc_update_power_11b).
  trpc_update_power_11b(powerTable)

proc bl_tpc_update_power_rate_11g*(powerTable: ptr array[8, int8]) {.exportc, cdecl.} =
  ## Update 11g per-rate TX power (blob: tail-call to trpc_update_power_11g).
  trpc_update_power_11g(powerTable)

proc bl_tpc_update_power_rate_11n*(powerTable: ptr array[8, int8]) {.exportc, cdecl.} =
  ## Update 11n per-rate TX power (blob: tail-call to trpc_update_power_11n).
  trpc_update_power_11n(powerTable)

proc bl_tpc_power_table_get*(powerTable: ptr array[38, int8]) {.exportc, cdecl.} =
  ## Get the current TX power table (15 instrs in blob).
  ## From blob: calls trpc_power_get to fill the first 24 bytes (rate data),
  ## then loops from index 24 to 37 copying channel offset bytes.
  # Get rate data from TRPC (fills first 24 bytes)
  trpc_power_get(powerTable)
  # Copy channel offset table (bytes 24..37)
  for i in 0 ..< 14:
    powerTable[24 + i] = tpcChannelOffsetTable[i]

