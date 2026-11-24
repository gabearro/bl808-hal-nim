"""Exercise the resident anchor's real receive path with scripted transport I/O."""

from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "examples/m0_usb_uart_flash_anchor.nim").read_text()


def block(start: str, stop: str) -> str:
    return SOURCE[SOURCE.index(start):SOURCE.index(stop)]


PLATFORM = """
type Uart = object
var clock = 0'u32
var configuration = 0'u32
var usbIn, uartIn: seq[uint8]
var events: seq[uint8]
var advance: proc ()
var spins: int
proc anchorNow(): uint32 = clock
proc usbConfigurationEpoch(): uint32 = configuration
proc tryRecvByte(_: Uart): (uint8, bool) =
  if uartIn.len == 0: return (0'u8, false)
  result = (uartIn[0], true)
  uartIn.delete(0)
proc deliverConsolePinByte(b: uint8) = discard
proc pushAppRx(channel: int, b: uint8): bool = true
proc openBridge(channel: int, baud: uint32) = discard
proc closeBridge(channel: int) = discard
proc announceMuxChannels() = discard
proc sendBanner() = discard
proc trySendMux(kind, channel: uint8, payload: openArray[uint8]): bool =
  doAssert channel == 0 and payload.len == 0
  events.add kind
  true
proc spin() =
  inc spins
  doAssert spins < 10_000, "receive failed to make progress"
  inc clock, 10_000
  if advance != nil: advance()
  if usbIn.len != 0:
    let b = usbIn[0]
    usbIn.delete(0)
    feedMux(b)
"""


SCENARIOS = """
proc frame(kind: uint8, data: openArray[uint8]): seq[uint8] =
  @[MuxMagic0, MuxMagic1, kind, 0'u8, data.len.uint8] & @data

proc addWord(data: var seq[uint8], value: uint32) =
  for i in 0 ..< 4: data.add ((value shr (i * 8)) and 0xFF).uint8

proc request(command, address, length: uint32): seq[uint8] =
  result = @FlashPrefix
  result.addWord(command)
  result.addWord(address)
  result.addWord(length)
  result.addWord(headerChecksum(command, address, length))

proc feed(data: openArray[uint8]) =
  for b in data: feedMux(b)

let ping = request(CmdPing, 123, 0)
var write = request(CmdWriteVerify, 0x1000, 4)
let payload = [1'u8, 2, 3, 4]
var expected = 0'u32
for b in payload: expected = (expected shl 5) xor b.uint32
write.addWord(expected)
write.add payload

var req: Request
clock = uint32.high - 100_000
feed(frame(MuxData, write.toOpenArray(0, write.high - 1)))
doAssert not recvRequest(req), "truncated payload was admitted"
abortFlashReceive()
doAssert not flashBusy and usbNeedsOpen and events == @[MuxUnregister]
feed(frame(MuxData, ping))  # Stale stream cannot supply data to a new command.
doAssert anchorHead == anchorTail
uartIn = ping
doAssert recvRequest(req) and req.command == CmdPing and activeTransport == viaUart
flashBusy = false

feed(frame(MuxOpen, []))
feed(frame(MuxData, write))
doAssert recvRequest(req) and req.command == CmdWriteVerify and activeTransport == viaUsb
doAssert req.payloadChecksum == expected and checksum(req.length) == expected
flashBusy = false

# Reopening the mux aborts an in-progress command even without a bus reset.
feed(frame(MuxData, write.toOpenArray(0, write.high - 1)))
advance = proc () =
  if not flashBusy: return
  advance = nil
  feed(frame(MuxOpen, []))
  feed(frame(MuxData, ping))
doAssert not recvRequest(req)
abortFlashReceive()
doAssert recvRequest(req) and req.command == CmdPing and req.address == 123
flashBusy = false
doAssert events == @[MuxUnregister]

# A reset observed by the USB driver invalidates the current request early.
feed(frame(MuxData, write.toOpenArray(0, 9)))
advance = proc () =
  if not flashBusy: return
  advance = nil
  inc configuration
let start = clock
doAssert not recvRequest(req) and clock - start < FlashRxGapUs
abortFlashReceive()

# Raw UART also yields when a writer disappears inside its header.
uartIn = ping[0 .. 9]
doAssert not recvRequest(req)
abortFlashReceive()
doAssert not flashBusy
uartIn = ping
doAssert recvRequest(req) and req.command == CmdPing
"""


def test_resident_flash_receive_recovers(tmp_path):
    constants = block("const\n", "type\n")
    types = block("type\n", "var\n")
    state = block("  usbWasConfigured =", "  serviceDivider:")
    source = tmp_path / "usb_anchor_flash_receive.nim"
    source.write_text(
        constants + "const UsbAnchorConsoleChannel = 3'u8\n"
        + types + "proc feedMux(b: uint8)\n" + PLATFORM
        + "var\n  console: Uart\n  dataBuf: array[DataMax, uint8]\n"
        + "  activeTransport = viaUart\n  flashBusy, appConsoleRegistered: bool\n"
        + "  uartRole: array[3, PortRole]\n  uartPorts: array[3, Uart]\n"
        + state + "\nproc sendByte(_: Uart, b: uint8): bool = true\n"
        + block("proc tryRecvAnchorUsb", "proc startPhysicalUart")
        + block("proc resetUsbInput", "proc service() =")
        + block("proc recvFlashByte", "proc eraseRange")
        + block("proc abortFlashReceive", "proc prepareForSoftReboot")
        + SCENARIOS
    )
    nim = shutil.which("nim")
    assert nim, "Nim is required to test the resident USB anchor parser"
    subprocess.run(
        [nim, "c", "-r", "--hints:off", "--skipProjCfg", "--skipParentCfg",
         "--skipUserCfg", f"--nimcache:{tmp_path / 'cache'}", str(source)],
        check=True, cwd=tmp_path,
    )
