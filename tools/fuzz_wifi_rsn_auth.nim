## Host fuzzer for WiFi RSN AKM parsing used by the station connect path.
##
## Build/run:
##   nim c -r --skipParentCfg:on --skipUserCfg:on --checks:on tools/fuzz_wifi_rsn_auth.nim

import ../src/bl808/wifi/fw/rsn_parse

var rngState: uint64 = 0x9E3779B97F4A7C15'u64

proc rnd(): uint32 =
  var x = rngState
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rngState = x
  (x and 0xFFFFFFFF'u64).uint32

proc rndByte(): uint8 =
  (rnd() and 0xFF'u32).uint8

proc ptrFor(buf: var seq[uint8]): pointer =
  if buf.len == 0: nil else: addr buf[0]

proc putLe16(buf: var seq[uint8]; off: int; value: uint16) =
  buf[off] = (value and 0xFF'u16).uint8
  buf[off + 1] = ((value shr 8) and 0xFF'u16).uint8

proc validRsnIe(akms: openArray[uint8]): seq[uint8] =
  result = @[
    WifiIeIdRsn, 0,             # id, len patched below
    0x01'u8, 0x00'u8,           # version
    0x00'u8, 0x0F'u8, 0xAC'u8, 0x04'u8, # group CCMP
    0x01'u8, 0x00'u8,           # pairwise count
    0x00'u8, 0x0F'u8, 0xAC'u8, 0x04'u8  # pairwise CCMP
  ]
  let akmCountOffset = result.len
  result.setLen(result.len + 2)
  putLe16(result, akmCountOffset, akms.len.uint16)
  for akm in akms:
    result.add 0x00'u8
    result.add 0x0F'u8
    result.add 0xAC'u8
    result.add akm
  result[1] = (result.len - 2).uint8

proc checkMask(buf: var seq[uint8]; expected: uint32) =
  let mask = wifiRsnAuthMaskFromIeBuffer(ptrFor(buf), buf.len.uint32)
  doAssert mask == expected, "unexpected RSN mask: got=" & $mask &
    " expected=" & $expected & " len=" & $buf.len

proc checkDecision(mask: uint32; keyMgmt: uint32; authType: uint8) =
  let selected = wifiPreferredKeyMgmtFromMask(mask)
  doAssert selected == keyMgmt, "unexpected key mgmt: got=" & $selected &
    " expected=" & $keyMgmt & " mask=" & $mask
  let dot11 = wifiDot11AuthTypeFromKeyMgmt(selected)
  doAssert dot11 == authType, "unexpected 802.11 auth type: got=" & $dot11 &
    " expected=" & $authType & " mask=" & $mask

proc checkFinders(buf: var seq[uint8]) =
  let wpaOui = [0x00'u8, 0x50'u8, 0xF2'u8, 0x01'u8]
  discard wifiIeFindBounded(ptrFor(buf), buf.len.uint32, WifiIeIdRsn)
  discard wifiVendorIeFindBounded(ptrFor(buf), buf.len.uint32,
                                  unsafeAddr wpaOui[0], 4)

proc main() =
  var iters = 0

  var psk = validRsnIe([0x02'u8])
  checkMask(psk, WifiAuthMaskPsk)
  checkDecision(WifiAuthMaskPsk, WifiKeyMgmtPsk, 0)

  var sae = validRsnIe([0x08'u8])
  checkMask(sae, WifiAuthMaskSae)
  checkDecision(WifiAuthMaskSae, WifiKeyMgmtSae, 3)

  var transition = validRsnIe([0x02'u8, 0x08'u8])
  checkMask(transition, WifiAuthMaskPsk or WifiAuthMaskSae)
  checkDecision(WifiAuthMaskPsk or WifiAuthMaskSae, WifiKeyMgmtPsk, 0)

  var prefixed = @[0'u8, 3'u8, 1'u8, 2'u8, 3'u8]
  prefixed.add transition
  checkMask(prefixed, WifiAuthMaskPsk or WifiAuthMaskSae)

  var pskSha256 = validRsnIe([0x06'u8])
  checkMask(pskSha256, WifiAuthMaskPskSha256)
  checkDecision(WifiAuthMaskPskSha256, WifiKeyMgmtPskSha256, 0)

  for trial in 0 ..< 200_000:
    let n = (rnd() mod 321).int
    var buf = newSeq[uint8](n)
    for i in 0 ..< n:
      buf[i] = rndByte()
    let mask = wifiRsnAuthMaskFromIeBuffer(ptrFor(buf), buf.len.uint32)
    checkFinders(buf)
    discard wifiDot11AuthTypeFromKeyMgmt(wifiPreferredKeyMgmtFromMask(mask))
    doAssert (mask and not (WifiAuthMaskPsk or WifiAuthMaskPskSha256 or
        WifiAuthMaskSae)) == 0,
      "unknown auth bits from random input: " & $mask
    inc iters

  for cut in 0 .. transition.len:
    var truncated = transition
    truncated.setLen(cut)
    discard wifiRsnAuthMaskFromIeBuffer(ptrFor(truncated), truncated.len.uint32)
    checkFinders(truncated)
    inc iters

  echo "fuzz_wifi_rsn_auth: ", iters, " iterations, no OOB / no invalid mask"
  echo "PASS"

main()
