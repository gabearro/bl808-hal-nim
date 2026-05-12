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
  bflb_pka_deinit(addr lowDev)
  printHex("[INFO] ladd=", lowOut[0])
  check("pka low-level ladd", lowOut[0] == 3)

  var ecdsa: BflbEcdsa
  check("ecdsa init", bflb_sec_ecdsa_init(addr ecdsa, EcpSecp256r1) == 0)
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
  priv = [0'u32, 0, 0, 0, 0, 0, 0, 0x01000000'u32]

  var ecdh: BflbEcdh
  check("ecdh init", bflb_sec_ecdh_init(addr ecdh, EcpSecp256r1) == 0)
  var ecdhX: array[8, uint32]
  var ecdhY: array[8, uint32]
  line("[STEP] ecdh public")
  let ecdhPubRc = bflb_sec_ecdh_get_public_key(addr ecdh, addr priv[0], addr ecdhX[0], addr ecdhY[0])
  check("ecdh public", ecdhPubRc == 0)
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
  line("[STEP] ecdsa sign 384 wrapper")
  let sign384Rc = bflb_sec_ecdsa_sign_384(
    addr ecdsa, addr signK[0], addr hash256[0], 8,
    addr sigR[0], addr sigS[0])
  check("ecdsa sign 384 wrapper", sign384Rc == 0)
  check("ecdsa sign nonzero",
    (not equalWords(addr sigR[0], addr zero8[0], 8)) and
    (not equalWords(addr sigS[0], addr zero8[0], 8)))
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
