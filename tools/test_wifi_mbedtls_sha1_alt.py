"""Exercise the SHA-1 lease on mock MMIO and the alternate Mbed TLS ABI."""

import hashlib
from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


LEASE_MMIO = r'''
{.pragma: shaHot.}

type
  Sha1State = array[5, uint32]
  Sha1Block = array[16, uint32]
  Sha1Context = object
    state: Sha1State
  ShaLink = object
    control, source: uint32
    digest: array[16, uint32]

const
  ShaControl = 0x20004000'u
  ShaLinkAddress = ShaControl + 0x50'u
  ShaBusy = 1'u32 shl 0
  ShaTrigger = 1'u32 shl 1
  ShaMode1 = 2'u32 shl 2
  ShaEnable = 1'u32 shl 5
  ShaContinue = 1'u32 shl 6
  ShaDone = 1'u32 shl 8
  ShaClearDone = 1'u32 shl 9
  ShaSignalDone = 1'u32 shl 10
  ShaMaskIrq = 1'u32 shl 11
  ShaLinkMode = 1'u32 shl 15
  ShaOneBlock = 1'u32 shl 16
  ShaPollLimit = 16
  ClicMtimeBase = 0xE000BFF8'u
  MockActive = ShaEnable or ShaLinkMode or ShaMaskIrq
  MockOriginalControl = ShaMode1
  MockOriginalLink = 0x22031230'u32
  MockBudget = 100'u32
  MockSeed = [0x01234567'u32, 0x89ABCDEF'u32, 0x76543210'u32,
              0xFEDCBA98'u32, 0xA5A55A5A'u32]

var
  shaDescriptor {.align: 16.}: ShaLink
  shaBlock {.align: 16.}: Sha1Block
  mockControlValue = MockOriginalControl
  mockLinkValue = MockOriginalLink
  mockClock = 1000'u32
  mockWrites: seq[tuple[address: uint, value: uint32]]
  mockShaReads, mockLinkReads: int
  mockStarted, mockCompleted, mockAcknowledged, mockPolls: int
  mockTimeoutAt: int
  mockBusyTimeout, mockInFlight, mockDonePending: bool
  mockIrqsEnabled = true
  mockExpectTriggerIrqs = true
  mockDescriptorAtTrigger: ShaLink
  mockBlockAtTrigger: Sha1Block
  mockWritesAtTrigger: int

proc shaLeaseIrqSave(): uint32 =
  result = if mockIrqsEnabled: 8'u32 else: 0'u32
  mockIrqsEnabled = false

proc shaLeaseIrqRestore(saved: uint32) = mockIrqsEnabled = (saved and 8) != 0
proc fenceIo() = discard

proc dmaVisible(address, size: uint): bool =
  (address == cast[uint](addr shaDescriptor) and size == sizeof(shaDescriptor).uint) or
    (address == cast[uint](addr shaBlock) and size == sizeof(shaBlock).uint)

proc mockDmaWord(address: uint): bool =
  let descriptor = cast[uint](addr shaDescriptor)
  let source = cast[uint](addr shaBlock)
  (address and 3) == 0 and
    ((address >= descriptor and address < descriptor + sizeof(shaDescriptor).uint) or
     (address >= source and address < source + sizeof(shaBlock).uint))

proc regRead(address: uint): uint32 =
  case address
  of ClicMtimeBase:
    inc mockClock
    mockClock
  of ShaLinkAddress:
    inc mockShaReads
    inc mockLinkReads
    mockLinkValue
  of ShaControl:
    inc mockShaReads
    if mockInFlight:
      inc mockPolls
      if mockStarted == mockTimeoutAt:
        if mockBusyTimeout: return mockControlValue or ShaBusy
        mockInFlight = false
        return mockControlValue
      if mockPolls == 1:
        return mockControlValue or ShaBusy
      if mockPolls == 2:
        return mockControlValue or ShaBusy or ShaDone
      mockInFlight = false
      mockDonePending = true
      inc mockCompleted
      for i in 0 ..< 5:
        shaDescriptor.digest[i] = 0x10203040'u32 + ((i + mockStarted).uint32 shl 24)
    mockControlValue or (if mockDonePending: ShaDone else: 0'u32)
  else:
    doAssert mockDmaWord(address), "unexpected MMIO read: " & $address
    doAssert not mockInFlight and mockStarted > 0 and mockCompleted == mockStarted,
      "DMA read before block completion"
    inc mockShaReads
    cast[ptr uint32](address)[]

proc regWrite(address: uint; value: uint32) =
  doAssert not mockInFlight, "MMIO write before DMA went idle"
  mockWrites.add((address, value))
  case address
  of ShaLinkAddress: mockLinkValue = value
  of ShaControl:
    if (value and ShaClearDone) != 0 and mockDonePending:
      mockDonePending = false
      inc mockAcknowledged
    if (value and ShaTrigger) != 0:
      doAssert not mockDonePending, "trigger with completion still pending"
      doAssert mockIrqsEnabled == mockExpectTriggerIrqs, "unexpected trigger IRQ state"
      doAssert mockLinkValue == cast[uint32](cast[uint](addr shaDescriptor))
      doAssert shaDescriptor.source == cast[uint32](cast[uint](addr shaBlock))
      inc mockStarted
      mockPolls = 0
      mockInFlight = true
      mockDescriptorAtTrigger = shaDescriptor
      mockBlockAtTrigger = shaBlock
      mockWritesAtTrigger = mockWrites.len
    mockControlValue = value and not (ShaTrigger or ShaClearDone or ShaBusy or ShaDone)
  else:
    doAssert mockDmaWord(address), "unexpected MMIO write: " & $address
    doAssert value == 0, "DMA scrub must zero the buffer"
    cast[ptr uint32](address)[] = value
'''


def run_lease_program(tmp_path: Path, checks: str) -> None:
    wifi = ROOT / "src/bl808/wifi"
    alt = (wifi / "mbedtls_sha1_alt.nim").read_text()
    helpers = "\n".join(
        procedure(alt, name).partition("\nwhen ")[0]
        for name in ("byteSwap", "loadShaBlock", "clearShaDmaWords")
    )
    run_program(
        tmp_path, "checked", LEASE_MMIO + helpers
        + f'\ninclude "{wifi / "mbedtls_sha1_lease.nim"}"\n'
        + r'''
proc checkAcquired() =
  doAssert mockWrites == @[
    (ShaLinkAddress, cast[uint32](cast[uint](addr shaDescriptor))),
    (ShaControl, MockActive),
  ]
  doAssert shaDescriptor.control == (ShaMode1 or ShaContinue or ShaSignalDone or ShaOneBlock)

proc checkReleased(previousWrites: int) =
  doAssert mockControlValue == MockOriginalControl
  doAssert mockLinkValue == MockOriginalLink
  doAssert shaDescriptor == default(ShaLink)
  doAssert shaBlock == default(Sha1Block)
  let writes = mockWrites[previousWrites .. ^1]
  doAssert writes.len == 2 + 18 + 16
  doAssert (ShaControl, MockOriginalControl) in writes
  doAssert (ShaLinkAddress, MockOriginalLink) in writes
  for (base, words) in [(cast[uint](addr shaDescriptor), 18),
                         (cast[uint](addr shaBlock), 16)]:
    for i in 0 ..< words:
      doAssert (base + 4'u * i.uint, 0'u32) in writes
''' + checks,
    )


def test_sha_lease_rejects_invalid_acquisition(tmp_path: Path) -> None:
    run_lease_program(tmp_path, r'''
var owner: Sha1Context
doAssert not acquireShaLease(nil, mockClock, MockBudget)
doAssert not acquireShaLease(addr owner, mockClock, 0)
doAssert not acquireShaLease(addr owner, mockClock - MockBudget, MockBudget)
for flag in [ShaBusy, ShaEnable, ShaDone]:
  mockControlValue = MockOriginalControl or flag
  doAssert not acquireShaLease(addr owner, mockClock, MockBudget)
doAssert mockWrites.len == 0
doAssert mockIrqsEnabled
mockControlValue = MockOriginalControl
doAssert acquireShaLease(addr owner, mockClock, MockBudget)
checkAcquired()
doAssert releaseShaLease(addr owner)
checkReleased(2)
''')


def test_sha_lease_configures_once_and_checks_owner_before_each_block(tmp_path: Path) -> None:
    run_lease_program(tmp_path, r'''
var owner, other: Sha1Context
var state = MockSeed
var data: array[65, uint8]
for i in 0 ..< data.len: data[i] = i.uint8
doAssert acquireShaLease(addr owner, mockClock, MockBudget)
checkAcquired()
let reads = mockShaReads
let descriptor = shaDescriptor
let buffer = shaBlock
doAssert not acquireShaLease(addr other, mockClock, MockBudget)
doAssert not leasedShaBlock(addr other, state, addr data[1])
doAssert not releaseShaLease(addr other)
doAssert state == MockSeed
doAssert mockShaReads == reads
doAssert shaDescriptor == descriptor and shaBlock == buffer
checkAcquired()

var expected = state
for blockNumber in 1 .. 2:
  doAssert leasedShaBlock(addr owner, state, addr data[1])
  doAssert mockStarted == blockNumber and mockCompleted == blockNumber
  doAssert mockAcknowledged == blockNumber and mockPolls >= 3
  let blockWrites = 2 * blockNumber
  doAssert mockWrites[blockWrites .. ^1] == @[
    (ShaControl, MockActive or ShaTrigger),
    (ShaControl, MockActive or ShaClearDone),
  ]
  doAssert mockBlockAtTrigger[0] == 0x04030201'u32
  for i in 0 ..< state.len:
    doAssert mockDescriptorAtTrigger.digest[i] == byteSwap(expected[i])
    expected[i] = 0x40302010'u32 + (blockNumber + i).uint32
  doAssert state == expected
  doAssert shaBlock == mockBlockAtTrigger

doAssert mockLinkReads == 1
doAssert releaseShaLease(addr owner)
checkReleased(6)
doAssert mockIrqsEnabled
doAssert not releaseShaLease(addr owner)
checkReleased(6)
''')


def test_sha_lease_budget_expiry_across_timer_wrap(tmp_path: Path) -> None:
    run_lease_program(tmp_path, r'''
var owner: Sha1Context
var state = MockSeed
var data: array[64, uint8]
let start = 0xffff_fff0'u32
mockClock = start
doAssert acquireShaLease(addr owner, start, MockBudget)
doAssert leasedShaBlock(addr owner, state, addr data[0])
let before = state
let writes = mockWrites.len
mockClock = start + MockBudget
doAssert not leasedShaBlock(addr owner, state, addr data[0])
doAssert state == before and mockWrites.len == writes and mockStarted == 1
doAssert releaseShaLease(addr owner)
checkReleased(writes)
''')


@pytest.mark.parametrize("busy", [True, False], ids=["busy-quarantine", "idle-cleanup"])
def test_sha_lease_timeout_preserves_state(tmp_path: Path, busy: bool) -> None:
    run_lease_program(tmp_path, f"\nmockBusyTimeout = {str(busy).lower()}\n" + r'''
var owner, other: Sha1Context
var state = MockSeed
var data: array[64, uint8]
data[0] = 1
doAssert acquireShaLease(addr owner, mockClock, MockBudget)
checkAcquired()
mockTimeoutAt = 1
doAssert not leasedShaBlock(addr owner, state, addr data[0])
doAssert state == MockSeed
doAssert mockStarted == 1 and mockCompleted == 0 and mockAcknowledged == 0
doAssert mockPolls > 0

if mockBusyTimeout:
  let writes = mockWritesAtTrigger
  data[0] = 2
  doAssert not leasedShaBlock(addr owner, state, addr data[0])
  doAssert mockWrites.len == writes
  # Let DMA go idle before release so release cannot discover BUSY itself.
  mockInFlight = false
  mockControlValue = MockOriginalControl
  mockLinkValue = MockOriginalLink
  doAssert not leasedShaBlock(addr owner, state, addr data[0])
  doAssert not releaseShaLease(addr owner)
  doAssert not acquireShaLease(addr other, mockClock, MockBudget)
  doAssert mockWrites.len == writes
  doAssert shaDescriptor == mockDescriptorAtTrigger
  doAssert shaBlock == mockBlockAtTrigger
  doAssert state == MockSeed
else:
  let writes = mockWrites.len
  doAssert releaseShaLease(addr owner)
  checkReleased(writes)
doAssert mockIrqsEnabled
''')


def test_sha_dma_words_preserve_unaligned_input_and_wipe_bounds(tmp_path: Path) -> None:
    alt = (ROOT / "src/bl808/wifi/mbedtls_sha1_alt.nim").read_text()
    helpers = procedure(alt, "loadShaBlock") + procedure(alt, "clearShaDmaWords")
    run_program(tmp_path, "checked", r'''
type Sha1Block = array[16, uint32]
var scratch: array[36, uint32]
var writes: int
proc regWrite(address: uint; value: uint32) =
  let begin = cast[uint](addr scratch[0])
  doAssert address >= begin and address < begin + sizeof(scratch).uint
  doAssert (address and 3) == 0
  scratch[((address - begin) div 4).int] = value
  inc writes
''' + helpers + r'''
var data: array[68, uint8]
var destination: Sha1Block
for i in 0 ..< data.len: data[i] = ((i * 37 + 240) and 255).uint8
for offset in 0 ..< 4:
  loadShaBlock(destination, addr data[offset])
  for i in 0 ..< 64:
    doAssert ((destination[i div 4] shr (8 * (i mod 4))) and 255).uint8 == data[i + offset]

for word in scratch.mitems: word = 0xA5A5A5A5'u32
clearShaDmaWords(cast[uint](addr scratch[1]), 18)
clearShaDmaWords(cast[uint](addr scratch[19]), 16)
doAssert writes == 34
doAssert scratch[0] == 0xA5A5A5A5'u32 and scratch[^1] == 0xA5A5A5A5'u32
for i in 1 .. 34: doAssert scratch[i] == 0
''')


def run_unleased_program(tmp_path: Path, checks: str) -> None:
    alt = (ROOT / "src/bl808/wifi/mbedtls_sha1_alt.nim").read_text()
    helpers = "\n".join(
        procedure(alt, name).partition("\nwhen ")[0]
        for name in ("byteSwap", "loadShaBlock", "clearShaDmaWords", "hardwareProcess")
    )
    run_program(tmp_path, "checked", LEASE_MMIO + r'''
type ShaBlockResult = enum
  shaBlockFault, shaBlockDeferred, shaBlockDone
const MeasureUnleasedShaBlocks = false
var shaBackend: array[4, uint32]
proc csrReadMstatus(): uint32 = (if mockIrqsEnabled: 8'u32 else: 0'u32)
proc disableInterrupts() = mockIrqsEnabled = false
proc enableInterrupts() = mockIrqsEnabled = true
''' + helpers + checks)


def test_sha_unleased_defers_without_touching_busy_engine(tmp_path: Path) -> None:
    run_unleased_program(tmp_path, r'''
var state = MockSeed
var data: array[64, uint8]
for flag in [ShaBusy, ShaEnable, ShaDone]:
  mockControlValue = MockOriginalControl or flag
  doAssert hardwareProcess(state, addr data[0]) == shaBlockDeferred
  doAssert state == MockSeed
  doAssert mockWrites.len == 0 and mockLinkReads == 0 and mockStarted == 0
  doAssert shaBackend[3] == 0 and mockIrqsEnabled
''')


@pytest.mark.parametrize("busy", [True, False], ids=["busy-quarantine", "idle-cleanup"])
def test_sha_unleased_timeout_is_not_deferral(tmp_path: Path, busy: bool) -> None:
    run_unleased_program(tmp_path, f"\nmockBusyTimeout = {str(busy).lower()}\n" + r'''
mockExpectTriggerIrqs = false
mockTimeoutAt = 1
var state = MockSeed
var data: array[64, uint8]
data[0] = 1
doAssert hardwareProcess(state, addr data[0]) == shaBlockFault
doAssert shaBackend[3] == 1 and state == MockSeed and mockIrqsEnabled
doAssert mockStarted == 1 and mockCompleted == 0
if mockBusyTimeout:
  doAssert mockInFlight and mockWrites.len == mockWritesAtTrigger
  doAssert shaDescriptor == mockDescriptorAtTrigger and shaBlock == mockBlockAtTrigger
else:
  doAssert mockControlValue == MockOriginalControl and mockLinkValue == MockOriginalLink
  doAssert shaDescriptor == default(ShaLink) and shaBlock == default(Sha1Block)
''')


def test_mbedtls_sha1_alt_preserves_backend_and_fallback_state(tmp_path: Path) -> None:
    mbedtls = ROOT / "vendor/mbedtls"
    nim = shutil.which("nim")
    if not nim or not (mbedtls / "library/sha1.c").is_file():
        pytest.skip("alternate provider vectors require Nim and the vendored Mbed TLS")
    wifi = ROOT / "src/bl808/wifi"
    alt = (wifi / "mbedtls_sha1_alt.nim").read_text()
    source = tmp_path / "sha1_provider.nim"
    expected = ", ".join(f"{byte}'u8" for byte in hashlib.sha1(b"B" * 80).digest())
    source.write_text(
        "import bl808/mbedtls/build  # include paths and the BL808 configuration\n"
        f'{{.compile: "{wifi}/mbedtls_sha1_software.c".}}\n'
        f'{{.compile: "{mbedtls}/library/sha1.c".}}\n'
        f'{{.compile: "{mbedtls}/library/platform.c".}}\n'
        f'{{.compile: "{mbedtls}/library/platform_util.c".}}\n'
        + r'''
type
  Sha1State = array[5, uint32]
  Sha1Context {.importc: "mbedtls_sha1_context", header: "<mbedtls/sha1.h>".} = object
    state: Sha1State
  ShaBlockResult = enum
    shaBlockFault, shaBlockDeferred, shaBlockDone
var shaBackend: array[4, uint32]
var injectFailureAt, deferFirst, deferLast, simulatedCalls: int
{.pragma: shaEntry.}
proc softwareProcess(ctx: ptr Sha1Context; data: ptr uint8): cint
  {.importc: "bl808_software_sha1_process", cdecl.}
proc hardwareProcess(state: var Sha1State; data: ptr uint8): ShaBlockResult =
  inc simulatedCalls
  if simulatedCalls == injectFailureAt:
    state[0] = 0xdeadbeef'u32
    return shaBlockFault
  if simulatedCalls in deferFirst .. deferLast:
    return shaBlockDeferred
  var context: Sha1Context
  context.state = state
  if softwareProcess(addr context, data) != 0: return shaBlockFault
  state = context.state
  shaBlockDone
proc sha1(data: ptr uint8; length: csize_t; digest: ptr uint8): cint
  {.importc: "mbedtls_sha1", cdecl, header: "<mbedtls/sha1.h>".}
'''
        + procedure(alt, "probeShaBackend").partition("\nwhen ")[0]
        + procedure(alt, "mbedtlsSha1Process")
        + f"\nconst expected = [{expected}]\n"
        + r'''
var input: array[80, uint8]
for byte in input.mitems: byte = 'B'.uint8
var digest: array[20, uint8]
for (faultAt, busyFirst, busyLast, backend, hw, sw) in [
    (0, 0, 0, 2, 2, 0), (1, 0, 0, 3, 0, 2), (3, 0, 0, 3, 1, 1),
    (0, 1, 2, 0, 0, 2), (0, 3, 3, 2, 1, 1)]:
  shaBackend = default(typeof(shaBackend))
  injectFailureAt = faultAt
  deferFirst = busyFirst
  deferLast = busyLast
  simulatedCalls = 0
  doAssert sha1(addr input[0], input.len.csize_t, addr digest[0]) == 0
  doAssert digest == expected
  doAssert shaBackend == [backend.uint32, hw.uint32, sw.uint32, 0'u32]
  if busyFirst > 0:
    # The next digest uses hardware again; a deferred probe must be retried.
    doAssert sha1(addr input[0], input.len.csize_t, addr digest[0]) == 0
    doAssert digest == expected
    doAssert shaBackend == [2'u32, (hw + 2).uint32, sw.uint32, 0'u32]
  if faultAt > 0:
    let calls = simulatedCalls
    doAssert sha1(addr input[0], input.len.csize_t, addr digest[0]) == 0
    doAssert digest == expected and simulatedCalls == calls
    doAssert shaBackend == [3'u32, hw.uint32, (sw + 2).uint32, 0'u32]
'''
    )
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg", "--skipProjCfg", "--skipUserCfg",
         "--assertions:on", "--passC:-DMBEDTLS_SHA1_PROCESS_ALT",
         f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}", str(source)],
        capture_output=True, text=True, timeout=60, cwd=ROOT,
    )
    assert result.returncode == 0, result.stdout + result.stderr
