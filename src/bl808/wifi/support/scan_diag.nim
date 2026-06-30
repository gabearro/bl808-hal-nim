proc scanDiagReset() = zero(addr scanDiag[0], sizeof(scanDiag).uint)

proc scanCacheReset() =
  zero(addr scanCache[0], sizeof(scanCache).uint)
  scanCacheSelectedSlot = -1

proc scannedBssidIsSpecific(bssid: pointer): bool =
  if bssid == nil:
    return false
  if (loadU8(bssid, 0) and 1'u8) != 0:
    return false
  var bssidAllZero = true
  var bssidAllFf = true
  for bssidByteIndex in 0 ..< 6:
    let bssidByte = loadU8(bssid, bssidByteIndex.uint)
    if bssidByte != 0'u8:
      bssidAllZero = false
    if bssidByte != 0xff'u8:
      bssidAllFf = false
  not bssidAllZero and not bssidAllFf

proc ssidBytesMatch(cachedSsid: ptr array[33, uint8]; cachedSsidLen: uint8;
                    requestedSsid: cstring; requestedSsidLen: csize_t): bool =
  if requestedSsid == nil or cachedSsidLen.csize_t != requestedSsidLen:
    return false
  for ssidByteIndex in 0 ..< cachedSsidLen.int:
    if cachedSsid[][ssidByteIndex] != cast[ptr UncheckedArray[uint8]](requestedSsid)[ssidByteIndex]:
      return false
  true

proc packBssidLo(bssid: ptr array[6, uint8]): uint32 =
  bssid[][0].uint32 or (bssid[][1].uint32 shl 8) or
    (bssid[][2].uint32 shl 16) or (bssid[][3].uint32 shl 24)

proc packBssidHi(bssid: ptr array[6, uint8]): uint32 =
  bssid[][4].uint32 or (bssid[][5].uint32 shl 8)

proc sameBssid(a: ptr array[6, uint8]; b: pointer): bool =
  if b == nil:
    return false
  for bssidByteIndex in 0 ..< 6:
    if a[][bssidByteIndex] != loadU8(b, bssidByteIndex.uint):
      return false
  true

proc scanCacheFailureLookup(bssid: pointer): uint8 =
  if bssid == nil:
    return 0
  for failureSlot in 0 ..< scanCacheFailureUsed.len:
    if scanCacheFailureUsed[failureSlot] != 0 and
        sameBssid(addr scanCacheFailureBssid[failureSlot], bssid):
      return scanCacheFailureCount[failureSlot]
  0

proc scanCacheFailureRecord(bssid: ptr array[6, uint8]; success: bool): uint8 =
  var selectedFailureSlot = -1
  var emptyFailureSlot = -1
  var weakestFailureSlot = 0
  var weakestFailureCount = uint8.high
  for failureSlot in 0 ..< scanCacheFailureUsed.len:
    if scanCacheFailureUsed[failureSlot] == 0:
      if emptyFailureSlot < 0:
        emptyFailureSlot = failureSlot
      continue
    var matches = true
    for bssidByteIndex in 0 ..< 6:
      if scanCacheFailureBssid[failureSlot][bssidByteIndex] != bssid[][bssidByteIndex]:
        matches = false
    if matches:
      selectedFailureSlot = failureSlot
      break
    if scanCacheFailureCount[failureSlot] < weakestFailureCount:
      weakestFailureCount = scanCacheFailureCount[failureSlot]
      weakestFailureSlot = failureSlot

  if selectedFailureSlot < 0:
    selectedFailureSlot = if emptyFailureSlot >= 0: emptyFailureSlot else: weakestFailureSlot
    scanCacheFailureUsed[selectedFailureSlot] = 1
    copyMem(addr scanCacheFailureBssid[selectedFailureSlot][0], addr bssid[][0], 6)

  if success:
    scanCacheFailureCount[selectedFailureSlot] = 0
  elif scanCacheFailureCount[selectedFailureSlot] < uint8.high:
    inc scanCacheFailureCount[selectedFailureSlot]
  scanCacheFailureCount[selectedFailureSlot]

proc scanCacheStore(ind: pointer) =
  if ind == nil:
    return
  let ssidLength = loadI32(ind, WifiBeaconSsidLenOff)
  let scannedChannel = loadU8(ind, WifiBeaconChannelOff)
  let scannedBssid = ptrAt(ind, WifiBeaconBssidOff)
  let supportedChannelCount = bl_msg_get_channel_nums()
  if ssidLength <= 0 or ssidLength > 32 or scannedChannel == 0'u8 or
      supportedChannelCount <= 0 or scannedChannel.cint > supportedChannelCount or
      not scannedBssidIsSpecific(scannedBssid):
    return

  var selectedScanCacheSlot = -1
  var weakestScanCacheSlot = -1
  var weakestScanCacheRssi = 128
  for scanCacheSlotIndex in 0 ..< scanCache.len:
    if scanCache[scanCacheSlotIndex].used != 0:
      var sameBssid = true
      for bssidByteIndex in 0 ..< 6:
        if scanCache[scanCacheSlotIndex].bssid[bssidByteIndex] !=
            loadU8(scannedBssid, bssidByteIndex.uint):
          sameBssid = false
      var sameSsid = scanCache[scanCacheSlotIndex].ssidLen == ssidLength.uint8
      if sameSsid:
        for ssidByteIndex in 0 ..< ssidLength:
          if scanCache[scanCacheSlotIndex].ssid[ssidByteIndex] !=
              loadU8(ind, WifiBeaconSsidOff + ssidByteIndex.uint):
            sameSsid = false
      if sameSsid and sameBssid:
        selectedScanCacheSlot = scanCacheSlotIndex
        break
      if scanCache[scanCacheSlotIndex].rssi.int < weakestScanCacheRssi:
        weakestScanCacheRssi = scanCache[scanCacheSlotIndex].rssi.int
        weakestScanCacheSlot = scanCacheSlotIndex
    elif selectedScanCacheSlot < 0:
      selectedScanCacheSlot = scanCacheSlotIndex

  if selectedScanCacheSlot < 0:
    selectedScanCacheSlot = weakestScanCacheSlot
  if selectedScanCacheSlot < 0:
    return

  let scannedRssi = loadI8(ind, WifiBeaconRssiOff)
  var preservedFailCount = scanCacheFailureLookup(scannedBssid)
  if scanCache[selectedScanCacheSlot].used != 0 and
      scannedRssi < scanCache[selectedScanCacheSlot].rssi:
    var sameBssid = true
    for bssidByteIndex in 0 ..< 6:
      if scanCache[selectedScanCacheSlot].bssid[bssidByteIndex] !=
          loadU8(scannedBssid, bssidByteIndex.uint):
        sameBssid = false
    if sameBssid:
      return
  if scanCache[selectedScanCacheSlot].used != 0:
    var sameBssid = true
    for bssidByteIndex in 0 ..< 6:
      if scanCache[selectedScanCacheSlot].bssid[bssidByteIndex] !=
          loadU8(scannedBssid, bssidByteIndex.uint):
        sameBssid = false
    if sameBssid:
      preservedFailCount = scanCache[selectedScanCacheSlot].failCount

  zero(addr scanCache[selectedScanCacheSlot], sizeof(ScanCacheItem).uint)
  scanCache[selectedScanCacheSlot].used = 1
  scanCache[selectedScanCacheSlot].failCount = preservedFailCount
  scanCache[selectedScanCacheSlot].ssidLen = ssidLength.uint8
  copyMem(addr scanCache[selectedScanCacheSlot].ssid[0],
          ptrAt(ind, WifiBeaconSsidOff), ssidLength.uint)
  copyMem(addr scanCache[selectedScanCacheSlot].bssid[0], scannedBssid, 6)
  scanCache[selectedScanCacheSlot].channel = scannedChannel
  scanCache[selectedScanCacheSlot].rssi = scannedRssi
  scanCache[selectedScanCacheSlot].auth = loadU8(ind, WifiBeaconAuthOff)
  scanCache[selectedScanCacheSlot].cipher = loadU8(ind, WifiBeaconCipherOff)

proc scanCacheFind(ssid: cstring; ssidLen: csize_t; requestedBssid: ptr uint8;
                   requestedChannel: uint8;
                   selectedBssidOut: ptr array[6, uint8];
                   selectedChannelOut: ptr uint8;
                   selectedRssiOut: ptr int8): bool =
  inc nimfwDbgScanCacheFind
  let requireRequestedBssid = scannedBssidIsSpecific(requestedBssid)
  var bestScanCacheSlot = -1
  var bestScanCacheScore = -1000
  var candidateCount = 0'u32
  for scanCacheSlotIndex in 0 ..< scanCache.len:
    if scanCache[scanCacheSlotIndex].used == 0:
      continue
    if requestedChannel != 0'u8 and
        scanCache[scanCacheSlotIndex].channel != requestedChannel:
      continue
    if requireRequestedBssid:
      var requestedBssidMatches = true
      for bssidByteIndex in 0 ..< 6:
        if scanCache[scanCacheSlotIndex].bssid[bssidByteIndex] !=
            cast[ptr UncheckedArray[uint8]](requestedBssid)[bssidByteIndex]:
          requestedBssidMatches = false
      if not requestedBssidMatches:
        continue
    if not ssidBytesMatch(addr scanCache[scanCacheSlotIndex].ssid,
                          scanCache[scanCacheSlotIndex].ssidLen,
                          ssid, ssidLen):
      continue
    inc candidateCount
    let failurePenalty = scanCache[scanCacheSlotIndex].failCount.int * 24
    let score = scanCache[scanCacheSlotIndex].rssi.int - failurePenalty
    if score > bestScanCacheScore:
      bestScanCacheScore = score
      bestScanCacheSlot = scanCacheSlotIndex

  nimfwDbgScanCacheCandidates = candidateCount
  if bestScanCacheSlot < 0:
    scanCacheSelectedSlot = -1
    nimfwDbgScanCacheSelectedSlot = 0xffffffff'u32
    nimfwDbgScanCacheSelectedMeta = 0
    nimfwDbgScanCacheSelectedBssidLo = 0
    nimfwDbgScanCacheSelectedBssidHi = 0
    return false
  inc nimfwDbgScanCacheHit
  scanCacheSelectedSlot = bestScanCacheSlot
  copyMem(addr selectedBssidOut[][0], addr scanCache[bestScanCacheSlot].bssid[0], 6)
  selectedChannelOut[] = scanCache[bestScanCacheSlot].channel
  selectedRssiOut[] = scanCache[bestScanCacheSlot].rssi
  nimfwDbgScanCacheSelectedSlot = bestScanCacheSlot.uint32
  nimfwDbgScanCacheSelectedMeta =
    scanCache[bestScanCacheSlot].channel.uint32 or
    (cast[uint8](scanCache[bestScanCacheSlot].rssi).uint32 shl 8) or
    (scanCache[bestScanCacheSlot].auth.uint32 shl 16) or
    (scanCache[bestScanCacheSlot].cipher.uint32 shl 24)
  nimfwDbgScanCacheSelectedBssidLo =
    packBssidLo(addr scanCache[bestScanCacheSlot].bssid)
  nimfwDbgScanCacheSelectedBssidHi =
    packBssidHi(addr scanCache[bestScanCacheSlot].bssid)
  true

proc scanCacheRecordConnectResult(success: bool) =
  if scanCacheSelectedSlot < 0 or scanCacheSelectedSlot >= scanCache.len:
    return
  if scanCache[scanCacheSelectedSlot].used == 0:
    return
  if success:
    scanCache[scanCacheSelectedSlot].failCount = 0
    discard scanCacheFailureRecord(addr scanCache[scanCacheSelectedSlot].bssid, success)
    return
  scanCache[scanCacheSelectedSlot].failCount =
    scanCacheFailureRecord(addr scanCache[scanCacheSelectedSlot].bssid, success)
  inc nimfwDbgScanCacheFailureMarks
  nimfwDbgScanCacheFailureCount = scanCache[scanCacheSelectedSlot].failCount.uint32
  nimfwDbgScanCacheSelectedMeta =
    scanCache[scanCacheSelectedSlot].channel.uint32 or
    (cast[uint8](scanCache[scanCacheSelectedSlot].rssi).uint32 shl 8) or
    (scanCache[scanCacheSelectedSlot].auth.uint32 shl 16) or
    (scanCache[scanCacheSelectedSlot].cipher.uint32 shl 24)

proc scanDiagStore(ind: pointer) =
  if ind == nil: return
  let ssidLength = loadI32(ind, WifiBeaconSsidLenOff)
  if ssidLength < 0 or ssidLength > 32: return
  let scanDiagRingSlot = (scanItemCount mod VendorScanDiagMax.uint32).int
  zero(addr scanDiag[scanDiagRingSlot], sizeof(ScanDiagItem).uint)
  scanDiag[scanDiagRingSlot].used = 1
  scanDiag[scanDiagRingSlot].ssidLen = ssidLength.uint8
  if ssidLength > 0:
    copyMem(addr scanDiag[scanDiagRingSlot].ssid[0], ptrAt(ind, WifiBeaconSsidOff), ssidLength.uint)
  copyMem(addr scanDiag[scanDiagRingSlot].bssid[0], ptrAt(ind, WifiBeaconBssidOff), 6)
  scanDiag[scanDiagRingSlot].channel = loadU8(ind, WifiBeaconChannelOff)
  scanDiag[scanDiagRingSlot].rssi = loadI8(ind, WifiBeaconRssiOff)
  scanDiag[scanDiagRingSlot].auth = loadU8(ind, WifiBeaconAuthOff)
  scanDiag[scanDiagRingSlot].cipher = loadU8(ind, WifiBeaconCipherOff)

proc bl808_wifi_backend_scan_diag_count*(): uint32 {.exportc, cdecl.} =
  if scanItemCount < VendorScanDiagMax.uint32: scanItemCount else: VendorScanDiagMax.uint32

proc bl808_wifi_backend_scan_diag_get*(index: uint32; ssidLen, ssid, channel: pointer;
                                      rssi, auth, cipher, bssid: pointer): cint {.exportc, cdecl.} =
  if index >= bl808_wifi_backend_scan_diag_count(): return -1
  let start = if scanItemCount > VendorScanDiagMax.uint32: scanItemCount mod VendorScanDiagMax.uint32 else: 0'u32
  let requestedScanDiagSlot = ((start + index) mod VendorScanDiagMax.uint32).int
  if scanDiag[requestedScanDiagSlot].used == 0: return -1
  if ssidLen != nil: cast[ptr uint8](ssidLen)[] = scanDiag[requestedScanDiagSlot].ssidLen
  if ssid != nil: copyMem(ssid, addr scanDiag[requestedScanDiagSlot].ssid[0], scanDiag[requestedScanDiagSlot].ssid.len.uint)
  if channel != nil: cast[ptr uint8](channel)[] = scanDiag[requestedScanDiagSlot].channel
  if rssi != nil: cast[ptr int8](rssi)[] = scanDiag[requestedScanDiagSlot].rssi
  if auth != nil: cast[ptr uint8](auth)[] = scanDiag[requestedScanDiagSlot].auth
  if cipher != nil: cast[ptr uint8](cipher)[] = scanDiag[requestedScanDiagSlot].cipher
  if bssid != nil: copyMem(bssid, addr scanDiag[requestedScanDiagSlot].bssid[0], scanDiag[requestedScanDiagSlot].bssid.len.uint)
  0

proc wifiChannelToFreq(channel: uint8): uint16 =
  if channel >= 1 and channel <= 13: uint16(2407 + channel.uint16 * 5)
  elif channel == 14: 2484'u16
  else: 0'u16
