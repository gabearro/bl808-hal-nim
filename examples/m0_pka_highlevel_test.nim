## M0 high-level PKA wrapper test.
##
## This focuses on exported ECDSA/ECDH/DSA wrappers that sit above the low-level
## PKA command bindings.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/pka

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

proc line(s: string) =
  discard console.sendLine(s)

proc check(label: string, ok: bool) =
  if ok:
    discard console.sendString("[PASS] ")
  else:
    discard console.sendString("[FAIL] ")
  discard console.sendLine(label)

proc printHex(label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)
  discard console.sendLine("")

proc equalWords(a: ptr uint32, b: ptr uint32, words: int): bool =
  let aa = cast[ptr UncheckedArray[uint32]](a)
  let bb = cast[ptr UncheckedArray[uint32]](b)
  for i in 0 ..< words:
    if aa[i] != bb[i]:
      return false
  true

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  line("")
  line("=== BL808 PKA High-Level Test ===")

  var lowA = [1'u32, 0]
  var lowB = [2'u32, 0]
  var lowOut = [0'u32, 0]
  var lowDev = BflbDevice(name: nil, regBase: 0x20004000'u32)
  bflb_pka_init(addr lowDev)
  bflb_pka_write(addr lowDev, 0, PkaRegSize8, addr lowA[0], 2, 0)
  bflb_pka_write(addr lowDev, 1, PkaRegSize8, addr lowB[0], 2, 0)
  bflb_pka_ladd(addr lowDev, 0, PkaRegSize8, 2, PkaRegSize8, 1, PkaRegSize8, 1)
  bflb_pka_read(addr lowDev, 2, PkaRegSize8, addr lowOut[0], 2)
  printHex("[INFO] ladd=", lowOut[0])
  check("pka low-level ladd", lowOut[0] == 3)

  var s32Out: array[8, uint32]
  bflb_pka_write(addr lowDev, 5, PkaRegSize32, addr secp256r1Gx[0], 8, 0)
  bflb_pka_read(addr lowDev, 5, PkaRegSize32, addr s32Out[0], 8)
  printHex("[INFO] s32read0=", s32Out[0])
  check("pka s32 write/read", equalWords(addr s32Out[0], addr secp256r1Gx[0], 8))

  var gxMontExpected = [
    0x765F9018'u32, 0xC65537A5'u32, 0x2B73FB79'u32, 0x10256277'u32,
    0xFC95BA75'u32, 0x01B6ED5F'u32, 0xD430E779'u32, 0x3C14A918'u32
  ]
  s32Out = [0'u32, 0, 0, 0, 0, 0, 0, 0]
  bflb_pka_write(addr lowDev, 0, PkaRegSize32, addr secp256r1P[0], 8, 0)
  bflb_pka_write(addr lowDev, 1, PkaRegSize32, addr secp256r1PrimeN_P[0], 8, 0)
  bflb_pka_gf2mont(addr lowDev, 5, PkaRegSize32, 5, PkaRegSize32,
                   7, PkaRegSize64, 0, PkaRegSize32, 256)
  bflb_pka_read(addr lowDev, 5, PkaRegSize32, addr s32Out[0], 8)
  printHex("[INFO] gf2mont0=", s32Out[0])
  printHex("[INFO] gf2mont7=", s32Out[7])
  check("pka gf2mont gx", equalWords(addr s32Out[0], addr gxMontExpected[0], 8))

  s32Out = [0'u32, 0, 0, 0, 0, 0, 0, 0]
  bflb_pka_write(addr lowDev, 5, PkaRegSize32, addr secp256r1Gx[0], 8, 0)
  bflb_pka_movdat(addr lowDev, 5, PkaRegSize32, 2, PkaRegSize32, 1)
  bflb_pka_read(addr lowDev, 2, PkaRegSize32, addr s32Out[0], 8)
  printHex("[INFO] movdat0=", s32Out[0])
  check("pka s32 movdat", equalWords(addr s32Out[0], addr secp256r1Gx[0], 8))

  var zSeed = [
    0x00000000'u32, 0xFEFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32,
    0xFFFFFFFF'u32, 0x00000000'u32, 0x00000000'u32, 0x01000000'u32
  ]
  s32Out = [0'u32, 0, 0, 0, 0, 0, 0, 0]
  bflb_pka_write(addr lowDev, 3, PkaRegSize32, addr zSeed[0], 8, 0)
  bflb_pka_movdat(addr lowDev, 3, PkaRegSize32, 7, PkaRegSize32, 1)
  bflb_pka_clir(addr lowDev, 7, PkaRegSize64, 8, 1)
  bflb_pka_read(addr lowDev, 7, PkaRegSize32, addr s32Out[0], 8)
  printHex("[INFO] z2init0=", s32Out[0])
  printHex("[INFO] z2init7=", s32Out[7])
  check("pka z2 low half after clir", equalWords(addr s32Out[0], addr zSeed[0], 8))

  bflb_pka_deinit(addr lowDev)

  var ecdsa: BflbEcdsa
  check("ecdsa init", bflb_sec_ecdsa_init(addr ecdsa, EcpSecp256r1) == 0)
  var unsupportedEcdsa: BflbEcdsa
  check("ecdsa unsupported curve rejected",
    bflb_sec_ecdsa_init(addr unsupportedEcdsa, EcpSecp256k1) != 0)
  var priv = [0'u32, 0, 0, 0, 0, 0, 0, 0x01000000'u32]
  var pubX: array[8, uint32]
  var pubY: array[8, uint32]
  line("[STEP] ecdsa public")
  let ecdsaPubRc = bflb_sec_ecdsa_get_public_key(addr ecdsa, addr priv[0], addr pubX[0], addr pubY[0])
  check("ecdsa public", ecdsaPubRc == 0)
  printHex("[INFO] pubX0=", pubX[0])
  printHex("[INFO] pubY0=", pubY[0])
  check("ecdsa public matches generator",
    equalWords(addr pubX[0], addr secp256r1Gx[0], 8) and
    equalWords(addr pubY[0], addr secp256r1Gy[0], 8))
  line("[STEP] ecdsa keygen")
  let ecdsaKeyRc = bflb_sec_ecdsa_get_private_key(addr ecdsa, addr priv[0])
  check("ecdsa private", ecdsaKeyRc == 0)
  var ecdh: BflbEcdh
  check("ecdh init", bflb_sec_ecdh_init(addr ecdh, EcpSecp256r1) == 0)
  var randomPubX: array[8, uint32]
  var randomPubY: array[8, uint32]
  line("[STEP] ecdh random private public")
  let randomPubRc =
    bflb_sec_ecdh_get_public_key(addr ecdh, addr priv[0],
                                 addr randomPubX[0], addr randomPubY[0])
  check("ecdh random private public", randomPubRc == 0)
  priv = [0'u32, 0, 0, 0, 0, 0, 0, 0x01000000'u32]

  var unsupportedEcdh: BflbEcdh
  check("ecdh unsupported curve rejected",
    bflb_sec_ecdh_init(addr unsupportedEcdh, EcpSecp384r1) != 0)
  var ecdhX: array[8, uint32]
  var ecdhY: array[8, uint32]
  line("[STEP] ecdh public")
  let ecdhPubRc = bflb_sec_ecdh_get_public_key(addr ecdh, addr priv[0], addr ecdhX[0], addr ecdhY[0])
  check("ecdh public", ecdhPubRc == 0)
  var priv2 = [0'u32, 0, 0, 0, 0, 0, 0, 0x02000000'u32]
  var pub2XExpected = [
    0x187BF27C'u32, 0x7E4F038D'u32, 0x0338528A'u32, 0xC31AB504'u32,
    0xE26989C0'u32, 0x351BF277'u32, 0xFC480BA6'u32, 0x78996647'u32
  ]
  var pub2YExpected = [
    0x10557707'u32, 0x40D08EDB'u32, 0xC69A3D29'u32, 0xDB30749F'u32,
    0xE6AD7DBA'u32, 0x2982E93C'u32, 0x9DB7049E'u32, 0xD1737822'u32
  ]
  var pub2X: array[8, uint32]
  var pub2Y: array[8, uint32]
  line("[STEP] ecdh scalar 2")
  let pub2Rc = bflb_sec_ecdh_get_public_key(addr ecdh, addr priv2[0], addr pub2X[0], addr pub2Y[0])
  check("ecdh scalar 2", pub2Rc == 0)
  printHex("[INFO] pub2X0=", pub2X[0])
  printHex("[INFO] pub2Y0=", pub2Y[0])
  check("ecdh scalar 2 matches",
    equalWords(addr pub2X[0], addr pub2XExpected[0], 8) and
    equalWords(addr pub2Y[0], addr pub2YExpected[0], 8))
  var priv3 = [0'u32, 0, 0, 0, 0, 0, 0, 0x03000000'u32]
  var pub3XExpected = [
    0xD1E4CB5E'u32, 0x440A33A6'u32, 0x95EFF7C8'u32, 0x65F14B1D'u32,
    0x21B7C6E6'u32, 0x85A9ADEF'u32, 0x1B6641FB'u32, 0x6CFDE7C6'u32
  ]
  var pub3YExpected = [
    0x0C643487'u32, 0x7EFF9849'u32, 0xCE064B37'u32, 0xECA2641A'u32,
    0x36B02AD8'u32, 0x3DB84F38'u32, 0x27B1799A'u32, 0x32507DA2'u32
  ]
  var pub3X: array[8, uint32]
  var pub3Y: array[8, uint32]
  line("[STEP] ecdh scalar 3")
  let pub3Rc = bflb_sec_ecdh_get_public_key(addr ecdh, addr priv3[0], addr pub3X[0], addr pub3Y[0])
  check("ecdh scalar 3", pub3Rc == 0)
  printHex("[INFO] pub3X0=", pub3X[0])
  printHex("[INFO] pub3Y0=", pub3Y[0])
  check("ecdh scalar 3 matches",
    equalWords(addr pub3X[0], addr pub3XExpected[0], 8) and
    equalWords(addr pub3Y[0], addr pub3YExpected[0], 8))
  var fixedPriv = [
    0xD4F6493F'u32, 0x385FC5A3'u32, 0xE3B3C974'u32, 0x503F10D2'u32,
    0x7B60FF4A'u32, 0x99B740EB'u32, 0xA6B89958'u32, 0xBD1A3CCD'u32
  ]
  var fixedPubXExpected = [
    0xD203B020'u32, 0x2CBE97F2'u32, 0xA7832C5E'u32, 0xB9A5F9E9'u32,
    0x1191F4EF'u32, 0xDBFDF4AC'u32, 0x480103CC'u32, 0xE69D350E'u32
  ]
  var fixedPubYExpected = [
    0x499C80DC'u32, 0x6DEB2A65'u32, 0xBF9A3263'u32, 0x5C15525A'u32,
    0xC2456376'u32, 0x2430ED8F'u32, 0xD08E1C74'u32, 0x8BD28915'u32
  ]
  var fixedPubX: array[8, uint32]
  var fixedPubY: array[8, uint32]
  line("[STEP] ecdh fixed vector")
  let fixedPubRc = bflb_sec_ecdh_get_public_key(
    addr ecdh, addr fixedPriv[0], addr fixedPubX[0], addr fixedPubY[0])
  check("ecdh fixed public", fixedPubRc == 0)
  printHex("[INFO] fixedX0=", fixedPubX[0])
  printHex("[INFO] fixedX7=", fixedPubX[7])
  printHex("[INFO] fixedY0=", fixedPubY[0])
  printHex("[INFO] fixedY7=", fixedPubY[7])
  check("ecdh fixed public matches",
    equalWords(addr fixedPubX[0], addr fixedPubXExpected[0], 8) and
    equalWords(addr fixedPubY[0], addr fixedPubYExpected[0], 8))
  var ecdhSharedX: array[8, uint32]
  var ecdhSharedY: array[8, uint32]
  line("[STEP] ecdh scalar 384 wrapper")
  let ecdhScalarRc = bflb_sec_ecdh_get_scalar_point_384(
    addr ecdh, addr pubX[0], addr pubY[0], addr priv[0],
    addr ecdhSharedX[0], addr ecdhSharedY[0])
  check("ecdh scalar 384 wrapper", ecdhScalarRc == 0)

  var signK = [0'u32, 0, 0, 0, 0, 0, 0, 0x02000000'u32]
  var hash256 = [0'u32, 0, 0, 0, 0, 0, 0, 0x01000000'u32]
  var sigR: array[8, uint32]
  var sigS: array[8, uint32]
  var zero8 = [0'u32, 0, 0, 0, 0, 0, 0, 0]
  var sigRExpected = [
    0x187BF27C'u32, 0x7E4F038D'u32, 0x0338528A'u32, 0xC31AB504'u32,
    0xE26989C0'u32, 0x351BF277'u32, 0xFC480BA6'u32, 0x78996647'u32
  ]
  var sigSExpected = [
    0x8B3D79BE'u32, 0xBFA781C6'u32, 0x011C29C5'u32, 0x618D5A82'u32,
    0x4832B8BE'u32, 0xDDDC840F'u32, 0xDF89E24C'u32, 0x65DFE4A1'u32
  ]
  line("[STEP] ecdsa sign 384 wrapper")
  let sign384Rc = bflb_sec_ecdsa_sign_384(
    addr ecdsa, addr signK[0], addr hash256[0], 8,
    addr sigR[0], addr sigS[0])
  check("ecdsa sign 384 wrapper", sign384Rc == 0)
  check("ecdsa sign nonzero",
    (not equalWords(addr sigR[0], addr zero8[0], 8)) and
    (not equalWords(addr sigS[0], addr zero8[0], 8)))
  check("ecdsa sign vector matches",
    equalWords(addr sigR[0], addr sigRExpected[0], 8) and
    equalWords(addr sigS[0], addr sigSExpected[0], 8))
  let signedVerifyRc = bflb_sec_ecdsa_verify(
    addr ecdsa, addr hash256[0], 8, addr sigR[0], addr sigS[0])
  when defined(bl808PkaDebug):
    printHex("[INFO] verify_stage=", nim_pka_verify_stage)
    printHex("[INFO] verify_w0=", nim_pka_verify_w[0])
    printHex("[INFO] verify_w7=", nim_pka_verify_w[7])
    printHex("[INFO] verify_u10=", nim_pka_verify_u1[0])
    printHex("[INFO] verify_u17=", nim_pka_verify_u1[7])
    printHex("[INFO] verify_u20=", nim_pka_verify_u2[0])
    printHex("[INFO] verify_u27=", nim_pka_verify_u2[7])
    printHex("[INFO] verify_x0=", nim_pka_verify_xmod[0])
    printHex("[INFO] verify_x7=", nim_pka_verify_xmod[7])
    printHex("[INFO] verify_r0=", sigR[0])
    printHex("[INFO] verify_r7=", sigR[7])
  check("ecdsa sign verifies", signedVerifyRc == 0)
  hash256 = [0'u32, 0, 0, 0, 0, 0, 0, 0]
  sigR = secp256r1Gx
  sigS = secp256r1Gx
  line("[STEP] ecdsa verify 384 wrapper")
  let verify384Rc = bflb_sec_ecdsa_verify_384(
    addr ecdsa, addr hash256[0], 8, addr sigR[0], addr sigS[0])
  check("ecdsa verify 384 wrapper", verify384Rc == 0)

  var dsa: BflbDsa
  var n = [17'u32]
  var e = [1'u32]
  var d = [1'u32]
  var hash = [5'u32]
  var sig = [0'u32]
  check("dsa init", bflb_sec_dsa_init(addr dsa, 32) == 0)
  dsa.n = addr n[0]
  dsa.e = addr e[0]
  dsa.d = addr d[0]
  line("[STEP] dsa sign")
  let dsaSignRc = bflb_sec_dsa_sign(addr dsa, addr hash[0], 1, addr sig[0])
  printHex("[INFO] dsa sig=", sig[0])
  check("dsa sign", dsaSignRc == 0)
  line("[STEP] dsa verify")
  let dsaVerifyRc = bflb_sec_dsa_verify(addr dsa, addr hash[0], 1, addr sig[0])
  check("dsa verify", dsaVerifyRc == 0)

  line("=== Test Complete ===")
  while true:
    wfi()
