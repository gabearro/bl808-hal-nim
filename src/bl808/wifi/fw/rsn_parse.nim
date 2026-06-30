const
  WifiIeIdRsn* = 48'u8
  WifiAuthMaskPsk* = 0x0002'u32
  WifiAuthMaskPskSha256* = 0x0100'u32
  WifiAuthMaskSae* = 0x0400'u32
  WifiKeyMgmtNone* = 0'u32
  WifiKeyMgmtPsk* = 2'u32
  WifiKeyMgmtPskSha256* = 256'u32
  WifiKeyMgmtSae* = 1024'u32

proc wifiIeFindBounded*(buf: pointer; bufLen: uint32; ieId: uint8): pointer =
  ## Bounds-checked IE walker for host/device paths that consume untrusted
  ## beacon/probe-response bytes. Malformed trailing IEs are treated as absent.
  if buf == nil:
    return nil
  var pos = cast[uint](buf)
  let start = pos
  let endPos = start + bufLen.uint
  if endPos < start:
    return nil
  while pos + 2'u <= endPos:
    let ie = cast[ptr UncheckedArray[uint8]](pos)
    let totalLen = 2'u + ie[1].uint
    if pos + totalLen < pos or pos + totalLen > endPos:
      return nil
    if ie[0] == ieId:
      return cast[pointer](pos)
    pos += totalLen
  return nil

proc wifiVendorIeFindBounded*(buf: pointer; bufLen: uint32; oui: pointer;
                              ouiLen: uint8): pointer =
  ## Bounds-checked vendor IE walker. The OUI comparison is only attempted
  ## when the vendor IE payload is long enough for the requested OUI.
  if buf == nil or oui == nil:
    return nil
  var pos = cast[uint](buf)
  let start = pos
  let endPos = start + bufLen.uint
  if endPos < start:
    return nil
  let target = cast[ptr UncheckedArray[uint8]](oui)
  while pos + 2'u <= endPos:
    let ie = cast[ptr UncheckedArray[uint8]](pos)
    let payloadLen = ie[1].uint
    let totalLen = 2'u + payloadLen
    if pos + totalLen < pos or pos + totalLen > endPos:
      return nil
    if ie[0] == 0xDD'u8 and payloadLen >= ouiLen.uint:
      var match = true
      for idx in 0'u8 ..< ouiLen:
        if ie[2'u + idx.uint] != target[idx]:
          match = false
          break
      if match:
        return cast[pointer](pos)
    pos += totalLen
  return nil

proc readLe16Bounded(bytes: ptr UncheckedArray[uint8]; offset: uint32): uint16
    {.inline.} =
  bytes[offset].uint16 or (bytes[offset + 1].uint16 shl 8)

proc wifiRsnAuthMaskFromIe*(rsnIe: pointer; availableLen: uint32): uint32 =
  ## Extract AKM capabilities from a complete RSN IE. Returns 0 for absent,
  ## truncated, or unsupported AKM suites.
  if rsnIe == nil or availableLen < 2'u32:
    return 0
  let rsn = cast[ptr UncheckedArray[uint8]](rsnIe)
  let rsnLen = rsn[1].uint32
  if rsnLen + 2'u32 < rsnLen or rsnLen + 2'u32 > availableLen:
    return 0
  var offset = 2'u32
  if rsnLen < 10'u32:
    return 0
  offset += 2'u32 # version
  offset += 4'u32 # group cipher suite
  if offset + 2'u32 > rsnLen + 2'u32:
    return 0
  let pairwiseCount = readLe16Bounded(rsn, offset).uint32
  offset += 2'u32
  let pairwiseBytes = pairwiseCount * 4'u32
  if pairwiseCount != 0 and pairwiseBytes div pairwiseCount != 4'u32:
    return 0
  if offset + pairwiseBytes < offset or offset + pairwiseBytes > rsnLen + 2'u32:
    return 0
  offset += pairwiseBytes
  if offset + 2'u32 > rsnLen + 2'u32:
    return 0
  let akmCount = readLe16Bounded(rsn, offset).uint32
  offset += 2'u32
  var authMask = 0'u32
  for _ in 0'u32 ..< akmCount:
    if offset + 4'u32 > rsnLen + 2'u32:
      return authMask
    if rsn[offset] == 0x00'u8 and rsn[offset + 1] == 0x0F'u8 and
        rsn[offset + 2] == 0xAC'u8:
      case rsn[offset + 3]
      of 0x02'u8:
        authMask = authMask or WifiAuthMaskPsk
      of 0x06'u8:
        authMask = authMask or WifiAuthMaskPskSha256
      of 0x08'u8:
        authMask = authMask or WifiAuthMaskSae
      else:
        discard
    offset += 4'u32
  return authMask

proc wifiRsnAuthMaskFromIeBuffer*(ieStart: pointer; ieLen: uint32): uint32 =
  let rsnIe = wifiIeFindBounded(ieStart, ieLen, WifiIeIdRsn)
  if rsnIe == nil:
    return 0
  let start = cast[uint](ieStart)
  let rsnPos = cast[uint](rsnIe)
  if rsnPos < start or rsnPos > start + ieLen.uint:
    return 0
  let available = (start + ieLen.uint - rsnPos).uint32
  return wifiRsnAuthMaskFromIe(rsnIe, available)

proc wifiPreferredKeyMgmtFromMask*(authMask: uint32; pmfCapable = false): uint32 =
  ## Pick the key-management mode for our current supplicant path. Prefer PSK
  ## over SAE on transition-mode APs because the WPA2-PSK path uses open-system
  ## 802.11 authentication and is the only path currently validated on device.
  if (authMask and WifiAuthMaskPsk) != 0:
    return WifiKeyMgmtPsk
  if (authMask and WifiAuthMaskPskSha256) != 0:
    return WifiKeyMgmtPskSha256
  if (authMask and WifiAuthMaskSae) != 0:
    return WifiKeyMgmtSae
  return WifiKeyMgmtNone

proc wifiDot11AuthTypeFromKeyMgmt*(keyMgmt: uint32): uint8 =
  ## ConnectInfo.authType is the 802.11 auth algorithm: 0=open system, 3=SAE.
  if keyMgmt == WifiKeyMgmtSae: 3'u8 else: 0'u8
