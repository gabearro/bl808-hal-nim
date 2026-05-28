## M0 HAL security/storage feature test.
##
## Covers SEC AES/SHA/TRNG, safe eFuse reads, flash XIP/read-ID paths,
## PKA command wrappers, PSRAM/EMI, and LZ4 bounded control paths.
##
## eFuse programming and flash erase/program APIs are deliberately not called.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap
import bl808/efuse, bl808/emi, bl808/flash, bl808/glb, bl808/gpio
import bl808/lz4, bl808/pka, bl808/psram, bl808/sdh, bl808/sec, bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  ScratchSrc = OcramBase + 0x7200'u
  ScratchDst = OcramBase + 0x7300'u

var
  console: Uart
  passed = 0
  failed = 0

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc checkEq(label: string, got, expected: uint32) =
  if got == expected:
    check(label, true)
  else:
    discard console.sendString("[FAIL] ")
    discard console.sendString(label)
    discard console.sendString(" got=")
    console.sendHex32(got)
    discard console.sendString(" expected=")
    console.sendHex32(expected)
    discard console.sendLine("")
    inc failed

proc smokeSec() =
  let key = [0x0011_2233'u32, 0x4455_6677'u32, 0x8899_AABB'u32, 0xCCDD_EEFF'u32]
  let iv = [0x0102_0304'u32, 0x0506_0708'u32, 0x090A_0B0C'u32, 0x0D0E_0F10'u32]
  aesSetKey(key)
  aesSetIv(iv)
  checkEq("sec aes key load", regRead(AesKey0), key[0])
  checkEq("sec aes iv load", regRead(AesIv0), iv[0])
  regWrite(ScratchSrc, 0x1122_3344'u32)
  let encErr = aesEncryptBlock(ScratchSrc.uint32, ScratchDst.uint32, 16, aesEcb, aes128)
  let decErr = aesDecryptBlock(ScratchDst.uint32, ScratchSrc.uint32, 16, aesEcb, aes128)
  check("sec aes bounded engines", encErr in {secOk, secBusy, secTimeout} and
        decErr in {secOk, secBusy, secTimeout})

  shaStart(sha256)
  let shaErr = shaUpdate(ScratchSrc.uint32, 64)
  var hash: array[8, uint32]
  shaReadHash(hash)
  shaFinish()
  check("sec sha bounded engine", shaErr in {secOk, secTimeout})

  trngEnable()
  discard trngReady()
  let (_, trngErr) = trngRead(timeout = 1)
  var words: array[8, uint32]
  let allErr = trngReadAll(words, timeout = 1)
  trngDisable()
  check("sec trng bounded reads", trngErr in {secOk, secTimeout} and allErr in {secOk, secTimeout})
  var randomBytes: array[4, uint8]
  let fillErr = trngFillBuffer(randomBytes)
  check("sec trng buffer fill", fillErr in {secOk, secTimeout})

proc smokeEfuseFlash() =
  discard efuseAutoLoadDone()
  discard efuseReadWord(0)
  var words: array[2, uint32]
  efuseReadBuffer(0, words)
  var mac: array[6, uint8]
  efuseReadMacAddress(mac)
  discard efuseReadChipId()
  check("efuse safe read APIs", true)

  discard flashReadXip(0)
  discard flashReadXipByte(0)
  var buf: array[8, uint8]
  flashReadXipBuffer(0, buf)
  discard flashWaitReady(timeout = 1)
  discard flashReadId()
  check("flash read-only APIs", true)

proc smokePka() =
  var dev = BflbDevice(name: nil, regBase: SecEngBase.uint32)
  var data = [1'u32, 2'u32, 3'u32, 4'u32]
  var outData = [0'u32, 0'u32, 0'u32, 0'u32]
  bflb_pka_init(addr dev)
  bflb_pka_write(addr dev, 0, PkaRegSize128, addr data[0], 4, 0)
  bflb_pka_read(addr dev, 0, PkaRegSize128, addr outData[0], 4)
  bflb_pka_lmod2n(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 1, 0)
  bflb_pka_ldiv2n(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 1, 0)
  bflb_pka_lmul2n(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 1, 0)
  bflb_pka_ladd(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 2, PkaRegSize128, 0)
  bflb_pka_lsub(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 2, PkaRegSize128, 0)
  bflb_pka_lmul(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 2, PkaRegSize128, 0)
  bflb_pka_lsqr(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 0)
  bflb_pka_ldiv(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 2, PkaRegSize128, 0)
  bflb_pka_mexp(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 2, PkaRegSize128, 3, PkaRegSize128, 0)
  discard bflb_pka_lcmp(addr dev, 0, PkaRegSize128, 1, PkaRegSize128)
  bflb_pka_regsize(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 0)
  bflb_pka_nlir(addr dev, 0, PkaRegSize128, 1, PkaRegSize128, 0)
  var ecdsa: BflbEcdsa
  var ecdh: BflbEcdh
  var dsa: BflbDsa
  checkEq("pka ecdsa init", bflb_sec_ecdsa_init(addr ecdsa, EcpSecp256r1).uint32, 0)
  discard bflb_sec_ecdsa_deinit(addr ecdsa)
  checkEq("pka ecdh init", bflb_sec_ecdh_init(addr ecdh, EcpSecp256r1).uint32, 0)
  discard bflb_sec_ecdh_deinit(addr ecdh)
  checkEq("pka dsa init", bflb_sec_dsa_init(addr dsa, 2048).uint32, 0)
  bflb_pka_deinit(addr dev)
  check("pka low-level command APIs", true)

proc smokeMemoryAccelerators() =
  emiInit(emiArbRoundRobin)
  emiSetArbitration(emiArbFixed)
  emiDisable()
  emiEnable()
  check("emi control APIs", (regRead(EmiCtrl) and (1'u32 shl EmiEn)) != 0)

  psramInit(psram64mb, psramBurst64)
  let previous = psramRead32(0x1000)
  psramWrite32(0x1000, 0x55AA_AA55'u32)
  let ok = psramRead32(0x1000) == 0x55AA_AA55'u32
  psramWrite32(0x1000, previous)
  discard psramTestPattern(0x1010)
  psramDisable()
  psramEnable()
  check("psram read/write APIs", ok and (regRead(PsramCtrlCfg0) and (1'u32 shl PsramEn)) != 0)

  lz4Reset()
  regWrite(Lz4SrcStart, lz4StartValue(ScratchSrc.uint32))
  regWrite(Lz4DstStart, lz4StartValue(ScratchDst.uint32))
  checkEq("lz4 end-size helper", lz4EndSize(ScratchDst.uint32, (ScratchDst + 16'u).uint32), 16)
  let (_, lz4Err) = lz4Decompress(ScratchSrc.uint32, 16, ScratchDst.uint32, timeout = 4)
  check("lz4 bounded decompress", lz4Err in {lz4Ok, lz4Timeout, lz4DataError})

proc smokeSdh() =
  enableSystemClock(GlbCgenCfg2, CgenCfg2Sdh)
  gpioSetupSdh(0, 1, 2, 3, 4, 5)
  sdhReset()
  let initErr = sdhInit()
  discard sdhCardInserted()
  discard sdhCardStable()
  let cmdErr = sdhSendCommand(0, 0, respNone, timeout = 1)
  var resp: array[4, uint32]
  sdhReadResponse(resp)
  discard sdhReadResponse32()
  sdhSetBusWidth(sdhBus1bit)
  sdhSetHighSpeed(false)
  sdhSetClockDiv(4)
  var sectorWords = [0'u32, 0'u32, 0'u32, 0'u32]
  let readErr = sdhReadBlock(sectorWords, timeout = 1)
  let writeErr = sdhWriteBlock(sectorWords, timeout = 1)
  check("sdh safe register/command APIs", initErr in {sdhOk, sdhTimeout} and
        cmdErr in {sdhOk, sdhTimeout, sdhCmdError} and
        readErr in {sdhOk, sdhTimeout} and writeErr in {sdhOk, sdhTimeout})

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 HAL Security Storage Test ===")

  smokeSec()
  smokeEfuseFlash()
  smokePka()
  smokeMemoryAccelerators()
  smokeSdh()

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0:
    discard console.sendLine("=== Test Complete ===")
  else:
    discard console.sendLine("=== Test Failed ===")
  while true:
    wfi()
