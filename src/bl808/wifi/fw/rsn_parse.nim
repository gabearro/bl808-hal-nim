const
  WifiIeIdRsn* = 48'u8
  WifiAuthMaskPsk* = 0x0002'u32
  WifiAuthMaskPskSha256* = 0x0100'u32
  WifiAuthMaskSae* = 0x0400'u32
  WifiKeyMgmtNone* = 0'u32
  WifiKeyMgmtPsk* = 2'u32
  WifiKeyMgmtPskSha256* = 256'u32
  WifiKeyMgmtSae* = 1024'u32

type WifiRsnAkmInfo* = object
  authMask*: uint32
  ccmpGroup*: bool
  ccmpPairwise*: bool
  pmfCapable*: bool
  pmfRequired*: bool
  bipCmac128*: bool

proc wifiIeFindBounded*(buf: pointer; bufLen: uint32; ieId: uint8): pointer =
  ## Bounds-checked IE walker for host/device paths that consume untrusted
  ## beacon/probe-response bytes. Malformed trailing IEs are treated as absent.
  if buf == nil:
    return nil
  var pos = cast[uint](buf)
  if bufLen.uint > high(uint) - pos:
    return nil
  var remaining = bufLen.uint
  while remaining >= 2:
    let ie = cast[ptr UncheckedArray[uint8]](pos)
    let totalLen = 2'u + ie[1].uint
    if totalLen > remaining:
      return nil
    if ie[0] == ieId:
      return cast[pointer](pos)
    pos += totalLen
    remaining -= totalLen
  return nil

proc wifiVendorIeFindBounded*(buf: pointer; bufLen: uint32; oui: pointer;
                              ouiLen: uint8): pointer =
  ## Bounds-checked vendor IE walker. The OUI comparison is only attempted
  ## when the vendor IE payload is long enough for the requested OUI.
  if buf == nil or oui == nil:
    return nil
  var pos = cast[uint](buf)
  if bufLen.uint > high(uint) - pos:
    return nil
  var remaining = bufLen.uint
  let target = cast[ptr UncheckedArray[uint8]](oui)
  while remaining >= 2:
    let ie = cast[ptr UncheckedArray[uint8]](pos)
    let payloadLen = ie[1].uint
    let totalLen = 2'u + payloadLen
    if totalLen > remaining:
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
    remaining -= totalLen
  return nil

proc readLe16Bounded(bytes: ptr UncheckedArray[uint8]; offset: uint32): uint16
    {.inline.} =
  bytes[offset].uint16 or (bytes[offset + 1].uint16 shl 8)

proc wifiRsnAkmInfoFromIe*(rsnIe: pointer; availableLen: uint32): WifiRsnAkmInfo =
  ## Extract AKM and PMF capabilities from a complete RSN IE.
  if rsnIe == nil or availableLen < 2'u32:
    return
  if availableLen.uint > high(uint) - cast[uint](rsnIe):
    return
  let rsn = cast[ptr UncheckedArray[uint8]](rsnIe)
  if rsn[0] != WifiIeIdRsn:
    return
  let rsnLen = rsn[1].uint32
  if rsnLen + 2'u32 < rsnLen or rsnLen + 2'u32 > availableLen:
    return
  var offset = 2'u32
  if rsnLen < 10'u32:
    return
  if readLe16Bounded(rsn, offset) != 1'u16:
    return
  offset += 2'u32 # version
  let ccmpGroup = rsn[offset] == 0x00'u8 and
    rsn[offset + 1'u32] == 0x0F'u8 and
    rsn[offset + 2'u32] == 0xAC'u8 and
    rsn[offset + 3'u32] == 0x04'u8
  offset += 4'u32 # group cipher suite
  if offset + 2'u32 > rsnLen + 2'u32:
    return
  let pairwiseCount = readLe16Bounded(rsn, offset).uint32
  offset += 2'u32
  if pairwiseCount == 0:
    return
  let pairwiseBytes = pairwiseCount * 4'u32
  if pairwiseCount != 0 and pairwiseBytes div pairwiseCount != 4'u32:
    return
  if offset + pairwiseBytes < offset or offset + pairwiseBytes > rsnLen + 2'u32:
    return
  var ccmpPairwise = false
  for pairwiseIndex in 0'u32 ..< pairwiseCount:
    let suiteOffset = offset + pairwiseIndex * 4'u32
    if rsn[suiteOffset] == 0x00'u8 and
        rsn[suiteOffset + 1'u32] == 0x0F'u8 and
        rsn[suiteOffset + 2'u32] == 0xAC'u8 and
        rsn[suiteOffset + 3'u32] == 0x04'u8:
      ccmpPairwise = true
  offset += pairwiseBytes
  if offset + 2'u32 > rsnLen + 2'u32:
    return
  let akmCount = readLe16Bounded(rsn, offset).uint32
  offset += 2'u32
  if akmCount == 0:
    return
  if akmCount > (rsnLen + 2'u32 - offset) div 4'u32:
    return
  var authMask = 0'u32
  for _ in 0'u32 ..< akmCount:
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
  var remaining = rsnLen + 2'u32 - offset
  if remaining == 1'u32:
    return
  var pmfCapable = false
  var pmfRequired = false
  var bipCmac128 = true
  if remaining >= 2'u32:
    let caps = readLe16Bounded(rsn, offset)
    pmfCapable = (caps and 0x80'u16) != 0
    pmfRequired = (caps and 0x40'u16) != 0
    if pmfRequired and not pmfCapable:
      return
    offset += 2'u32
    remaining -= 2'u32
  if remaining != 0:
    if remaining < 2'u32:
      return
    let pmkidCount = readLe16Bounded(rsn, offset).uint32
    offset += 2'u32
    remaining -= 2'u32
    if pmkidCount > remaining div 16'u32:
      return
    offset += pmkidCount * 16'u32
    remaining = rsnLen + 2'u32 - offset
    if remaining != 0 and remaining != 4'u32:
      return
    if remaining == 4'u32:
      bipCmac128 = rsn[offset] == 0x00'u8 and
        rsn[offset + 1'u32] == 0x0F'u8 and
        rsn[offset + 2'u32] == 0xAC'u8 and
        rsn[offset + 3'u32] == 0x06'u8
  result.authMask = authMask
  result.ccmpGroup = ccmpGroup
  result.ccmpPairwise = ccmpPairwise
  result.pmfCapable = pmfCapable
  result.pmfRequired = pmfRequired
  result.bipCmac128 = bipCmac128

proc wifiRsnAuthMaskFromIe*(rsnIe: pointer; availableLen: uint32): uint32 =
  wifiRsnAkmInfoFromIe(rsnIe, availableLen).authMask

proc wifiRsnAkmInfoFromIeBuffer*(ieStart: pointer; ieLen: uint32): WifiRsnAkmInfo =
  let rsnIe = wifiIeFindBounded(ieStart, ieLen, WifiIeIdRsn)
  if rsnIe == nil:
    return
  let start = cast[uint](ieStart)
  let rsnPos = cast[uint](rsnIe)
  if rsnPos < start or rsnPos - start > ieLen.uint:
    return
  let available = (ieLen.uint - (rsnPos - start)).uint32
  wifiRsnAkmInfoFromIe(rsnIe, available)

proc wifiRsnAuthMaskFromIeBuffer*(ieStart: pointer; ieLen: uint32): uint32 =
  wifiRsnAkmInfoFromIeBuffer(ieStart, ieLen).authMask

proc wifiPreferredKeyMgmtFromMask*(authMask: uint32; pmfCapable = false;
                                   pmfRequired = false): uint32 =
  ## Match the scan firmware's PMF-dependent AKM preference.
  if pmfCapable or pmfRequired:
    if (authMask and WifiAuthMaskSae) != 0:
      return WifiKeyMgmtSae
    if (authMask and WifiAuthMaskPskSha256) != 0:
      return WifiKeyMgmtPskSha256
    if pmfRequired:
      return WifiKeyMgmtNone
  if (authMask and WifiAuthMaskPskSha256) != 0:
    return WifiKeyMgmtPskSha256
  if (authMask and WifiAuthMaskPsk) != 0:
    return WifiKeyMgmtPsk
  return WifiKeyMgmtNone

proc wifiDot11AuthTypeFromKeyMgmt*(keyMgmt: uint32): uint8 =
  ## ConnectInfo.authType is the 802.11 auth algorithm: 0=open system, 3=SAE.
  if keyMgmt == WifiKeyMgmtSae: 3'u8 else: 0'u8
