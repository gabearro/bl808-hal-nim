## Host fuzzer for WiFi VIF key-install policy.
##
## This targets the bug class where a valid supplicant key translation uses a
## cipher value the firmware does not classify consistently. In particular,
## 16-byte CCMP group keys arrive as cipher 2 on the set_key path, while some
## vendor-side paths/comments used cipher 5 for the same group-key role.
##
## Build/run:
##   nim c -r --skipParentCfg:on --skipUserCfg:on --checks:on tools/fuzz_wifi_key_install.nim

import ../src/bl808/wifi/fw/key_install_policy

type
  ReplayCounter = object
    pnLow: uint32
    pnHigh: uint32

  KeySlot = object
    replayCounters: array[8, ReplayCounter]
    staReplayCounters: array[8, ReplayCounter]
    pnLow: uint32
    pnHigh: uint32
    keyMaterial: array[16, uint8]
    cipherType: uint8
    staIdx: uint8
    keyIdx: uint8
    installed: uint8
    hasRxPn: uint8

  KeyPointers = object
    defaultKeyPtr: uint32
    groupKeyPtr: uint32

  KeyParam = object
    staIdx: uint8
    ccmpKeyMaterial: array[16, uint8]
    tkipKeyMaterial: array[16, uint8]
    pnLow: uint32
    pnHigh: uint32
    cipherType: uint8
    keySlot: uint8
    hasRxPn: uint8

var rngState = 0xC0DE_CAFE_5949_4649'u64

proc rnd(): uint32 =
  var x = rngState
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rngState = x
  (x and 0xFFFF_FFFF'u64).uint32

proc rndByte(): uint8 = uint8(rnd() and 0xFF'u32)

proc randomParam(): KeyParam =
  result.staIdx = uint8(rnd() mod 8)
  result.keySlot = uint8(rnd() mod 2)
  result.cipherType =
    case rnd() mod 12
    of 0: 0'u8
    of 1: 1'u8
    of 2: 2'u8
    of 3: 3'u8
    of 4: 5'u8
    else: rndByte()
  result.hasRxPn = uint8(rnd() and 1'u32)
  result.pnLow =
    if (rnd() mod 5) == 0: 0'u32
    else: rnd()
  result.pnHigh =
    if result.pnLow == 0'u32 and (rnd() mod 2) == 0: 0'u32
    else: rnd()
  for i in 0 ..< result.ccmpKeyMaterial.len:
    result.ccmpKeyMaterial[i] = rndByte()
    result.tkipKeyMaterial[i] = rndByte()

proc installKey(req: KeyParam; hwKeyIdx: uint8; slot: var KeySlot;
                ptrs: var KeyPointers) =
  slot = KeySlot()
  slot.keyIdx = hwKeyIdx
  slot.cipherType = req.cipherType
  slot.staIdx = req.staIdx
  slot.hasRxPn = req.hasRxPn

  case req.cipherType
  of 0, 3:
    slot.pnLow = rnd()
    slot.pnHigh = 0
  of 1:
    slot.pnLow = 0
    slot.pnHigh = 0
    slot.keyMaterial = req.tkipKeyMaterial
  of 2, 5:
    slot.pnLow = 0
    slot.pnHigh = 0
    slot.keyMaterial = req.ccmpKeyMaterial
  else:
    slot.pnLow = 0
    slot.pnHigh = 0

  if (req.pnLow or req.pnHigh) != 0'u32:
    if wifiCipherUsesGroupReplayPn(slot.cipherType, slot.hasRxPn):
      for i in 0 ..< slot.replayCounters.len:
        slot.replayCounters[i].pnLow = req.pnLow
        slot.replayCounters[i].pnHigh = req.pnHigh
    else:
      for i in 0 ..< slot.staReplayCounters.len:
        slot.staReplayCounters[i].pnLow = req.pnLow
        slot.staReplayCounters[i].pnHigh = req.pnHigh

  slot.installed = 1
  if wifiCipherIsCcmpGroup(slot.cipherType):
    ptrs.groupKeyPtr = 0x1000'u32
  else:
    ptrs.defaultKeyPtr = 0x1000'u32

proc checkInstall(req: KeyParam; slot: KeySlot; ptrs: KeyPointers) =
  let isCcmp = wifiCipherIsCcmpGroup(req.cipherType)
  doAssert wifiCipherIsCcmpGroup(2'u8)
  doAssert wifiCipherIsCcmpGroup(5'u8)
  doAssert not wifiCipherIsCcmpGroup(1'u8)

  if isCcmp:
    doAssert ptrs.groupKeyPtr != 0'u32,
      "CCMP cipher " & $req.cipherType & " did not install group key pointer"
    doAssert ptrs.defaultKeyPtr == 0'u32,
      "CCMP cipher " & $req.cipherType & " incorrectly installed default pointer"
    doAssert slot.keyMaterial == req.ccmpKeyMaterial,
      "CCMP cipher " & $req.cipherType & " did not copy CCMP material"
  else:
    doAssert ptrs.defaultKeyPtr != 0'u32,
      "non-CCMP cipher " & $req.cipherType & " did not install default pointer"
    doAssert ptrs.groupKeyPtr == 0'u32,
      "non-CCMP cipher " & $req.cipherType & " installed group pointer"

  if (req.pnLow or req.pnHigh) != 0'u32:
    let shouldUseGroupPn = wifiCipherUsesGroupReplayPn(req.cipherType, req.hasRxPn)
    for i in 0 ..< slot.replayCounters.len:
      if shouldUseGroupPn:
        doAssert slot.replayCounters[i].pnLow == req.pnLow
        doAssert slot.replayCounters[i].pnHigh == req.pnHigh
      else:
        doAssert slot.replayCounters[i].pnLow == 0'u32
        doAssert slot.replayCounters[i].pnHigh == 0'u32
        doAssert slot.staReplayCounters[i].pnLow == req.pnLow
        doAssert slot.staReplayCounters[i].pnHigh == req.pnHigh

proc checkRegressionCipher2GroupKey() =
  var req = KeyParam(cipherType: 2'u8, keySlot: 0'u8, hasRxPn: 1'u8,
                     pnLow: 0x0102_0304'u32, pnHigh: 0x0506_0708'u32)
  for i in 0 ..< req.ccmpKeyMaterial.len:
    req.ccmpKeyMaterial[i] = uint8(i + 0xA0)
  var slot: KeySlot
  var ptrs: KeyPointers
  installKey(req, 6'u8, slot, ptrs)
  checkInstall(req, slot, ptrs)

proc main() =
  checkRegressionCipher2GroupKey()

  var cases = 0
  for cipher in 0'u32 .. 255'u32:
    for hasRxPn in 0'u32 .. 1'u32:
      for pnCase in 0'u32 .. 2'u32:
        var req = randomParam()
        req.cipherType = uint8(cipher)
        req.hasRxPn = uint8(hasRxPn)
        case pnCase
        of 0:
          req.pnLow = 0
          req.pnHigh = 0
        of 1:
          req.pnLow = 1
          req.pnHigh = 0
        else:
          req.pnLow = 0xFFFF_FFF0'u32
          req.pnHigh = 7
        var slot: KeySlot
        var ptrs: KeyPointers
        installKey(req, uint8(rnd() and 0xFF'u32), slot, ptrs)
        checkInstall(req, slot, ptrs)
        inc cases

  for _ in 0 ..< 200_000:
    let req = randomParam()
    var slot: KeySlot
    var ptrs: KeyPointers
    installKey(req, rndByte(), slot, ptrs)
    checkInstall(req, slot, ptrs)
    inc cases

  echo "fuzz_wifi_key_install: ", cases,
       " cases, CCMP group-key policy stable"
  echo "PASS"

main()
