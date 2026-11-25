"""Exercise VIF teardown across reentrant reset and replacement callbacks."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_ap_teardown import FW, ROOT, procedure
from test_wifi_beacon_lifetime import VIF_PLATFORM
from test_wifi_message_allocation import run_program


PLATFORM = VIF_PLATFORM.replace(
    "  retireHook: proc(vif: uint8)\n",
    "  retireHook: proc(vif: uint8)\n"
    "  prepareHook, timerHook, tdHook, hwResetHook: proc()\n",
).replace(
    "proc apmPrepareVifRemoval(i: uint8): bool = removalReady",
    "proc apmPrepareVifRemoval(i: uint8): bool =\n"
    "  doAssert not interrupts\n"
    "  if prepareHook != nil: prepareHook()\n"
    "  removalReady",
).replace(
    "proc mm_hw_ap_info_reset(i: uint8) = inc hwResets",
    "proc mm_hw_ap_info_reset(i: uint8) =\n"
    "  doAssert not interrupts\n"
    "  inc hwResets\n"
    "  if hwResetHook != nil: hwResetHook()",
).replace(
    "proc td_reset(i: uint8) = inc resets",
    "proc td_reset(i: uint8) =\n"
    "  doAssert not interrupts\n"
    "  inc resets\n"
    "  if tdHook != nil: tdHook()",
).replace(
    "proc mm_timer_clear(p: pointer) = inc clearedTimers",
    "proc mm_timer_clear(p: pointer) =\n"
    "  doAssert not interrupts\n"
    "  inc clearedTimers\n"
    "  if timerHook != nil: timerHook()",
)


REPLACEMENT_CHECKS = r'''
# A normal asynchronous AP stop invalidates RX but must keep MM removal saved.
for enabled in [false, true]:
  reset()
  interrupts = enabled
  rxVifEpochs = [21'u32, 42]
  vifs[0].vifType = VIF_TYPE_AP
  env.apCount = 1
  removalReady = false
  co_list_push_back(addr env.activeList, cast[ptr CoListHdr](addr vifs[0]))
  prepareHook = proc() = inc rxVifEpochs[0]
  doAssert not vif_mgmt_unregister(0)
  doAssert interrupts == enabled and env.apCount == 1
  doAssert env.activeList.first == cast[ptr CoListHdr](addr vifs[0])
  doAssert env.freeList.first == nil and vifs[0].vifType == VIF_TYPE_AP
  doAssert rxVifEpochs[0] == 22 and stops == 0 and clearedTimers == 0
prepareHook = nil

for removed in 0'u8 .. 1:
  for kind in [VIF_TYPE_STA, VIF_TYPE_AP]:
    for site in ["prepare", "retire", "teardown", "hw", "timer1", "timer2", "watchdog", "td"]:
      if kind != VIF_TYPE_AP and site in ["prepare", "hw"]: continue
      if kind != VIF_TYPE_STA and site == "watchdog": continue
      for enabled in [false, true]:
        reset()
        interrupts = enabled
        rxVifEpochs = [21'u32, 42]
        vifs[removed].vifType = kind
        if kind == VIF_TYPE_STA: env.staCount = 1
        else: env.apCount = 1
        co_list_push_back(addr env.activeList,
                          cast[ptr CoListHdr](addr vifs[removed]))
        var fired = false
        var replacementVifs: typeof(vifs)
        var replacementEnv: Env
        var replacementEpochs: typeof(rxVifEpochs)
        var afterResetTimers, afterResetTd: int
        var afterStops, afterDeinit, afterHw: int
        proc replace() =
          doAssert not fired
          fired = true
          retireHook = nil
          stopHook = nil
          deinitHook = nil
          prepareHook = nil
          timerHook = nil
          tdHook = nil
          hwResetHook = nil
          doAssert vif_mgmt_init()
          for index in 0'u8 .. 1:
            var assigned = 255'u8
            doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA,
                                      false, addr assigned) == 0
            doAssert assigned == index
            vifs[index].state = 71 + index
            vifs[index].currentBssid = [2'u8, 5, 8, 13, 21, 34]
          replacementVifs = vifs
          replacementEnv = env
          replacementEpochs = rxVifEpochs
          afterResetTimers = clearedTimers
          afterResetTd = resets
          afterStops = stops
          afterDeinit = deinitializations
          afterHw = hwResets
        if site == "prepare":
          prepareHook = replace
        elif site == "retire":
          retireHook = proc(index: uint8) =
            doAssert index == removed and not interrupts
            doAssert env.apCount == 0 and env.staCount == 0,
              "counts must be committed before TX callbacks"
            replace()
        elif site == "hw":
          hwResetHook = replace
        elif site in ["timer1", "timer2", "watchdog"]:
          let expectedClears = if site == "timer1": 1 elif site == "timer2": 2 else: 3
          timerHook = proc() =
            if clearedTimers == expectedClears: replace()
        elif site == "td":
          tdHook = replace
        elif kind == VIF_TYPE_STA:
          deinitHook = proc() =
            doAssert interrupts == enabled, "WPA callback IRQ state changed"
            replace()
        else:
          stopHook = replace
        doAssert vif_mgmt_unregister(removed)
        doAssert fired and interrupts == enabled
        doAssert vifs == replacementVifs, "stale VIF teardown overwrote replacement"
        doAssert env == replacementEnv, "stale VIF teardown changed replacement lists/counts"
        doAssert rxVifEpochs == replacementEpochs
        doAssert clearedTimers == afterResetTimers and resets == afterResetTd
        doAssert stops == afterStops and deinitializations == afterDeinit
        doAssert hwResets == afterHw

# Each part of the retirement identity independently prevents stale cleanup.
for change in 0 .. 3:
  reset()
  interrupts = true
  rxVifEpochs = [high(uint32), 17'u32]
  vifs[0].vifType = VIF_TYPE_STA
  vifs[0].state = 91
  env.staCount = 1
  co_list_push_back(addr env.activeList, cast[ptr CoListHdr](addr vifs[0]))
  var afterVifs: typeof(vifs)
  var afterEnv: Env
  retireHook = proc(index: uint8) =
    doAssert index == 0 and rxVifEpochs[0] == 0
    case change
    of 0: inc rxVifEpochs[0]
    of 1: vifs[0].vifType = VIF_TYPE_AP
    of 2:
      co_list_push_back(addr env.activeList, cast[ptr CoListHdr](addr vifs[0]))
      inc env.staCount
    else:
      co_list_push_back(addr env.freeList, cast[ptr CoListHdr](addr vifs[0]))
    afterVifs = vifs
    afterEnv = env
  doAssert vif_mgmt_unregister(0)
  doAssert interrupts and vifs == afterVifs and env == afterEnv
  doAssert deinitializations == 0 and clearedTimers == 0 and resets == 0
retireHook = nil

# A normal wrap to generation zero must still release the original entry.
reset()
rxVifEpochs = [high(uint32), 17'u32]
vifs[0].vifType = VIF_TYPE_STA
env.staCount = 1
co_list_push_back(addr env.activeList, cast[ptr CoListHdr](addr vifs[0]))
doAssert vif_mgmt_unregister(0)
doAssert rxVifEpochs[0] == 0 and vifs[0].vifType == 4
doAssert env.staCount == 0 and env.freeList.first == cast[ptr CoListHdr](addr vifs[0])

# Releasing the AP count must not release its shared beacon reservation early.
for removed in 0'u8 .. 1:
  reset()
  interrupts = true
  vifs[removed].vifType = VIF_TYPE_AP
  env.apCount = 1
  co_list_push_back(addr env.activeList, cast[ptr CoListHdr](addr vifs[removed]))
  co_list_push_back(addr env.freeList, cast[ptr CoListHdr](addr vifs[removed xor 1]))
  var observed = false
  retireHook = proc(index: uint8) =
    retireHook = nil
    doAssert index == removed and env.apCount == 0
    var assigned = 255'u8
    doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_AP, false, addr assigned) == 1
    doAssert assigned == 255 and hwSets == 0 and starts == 0
    observed = true
  doAssert vif_mgmt_unregister(removed) and observed
  doAssert stops == 1 and env.apCount == 0
  var assigned = 255'u8
  doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_AP, false, addr assigned) == 0
  doAssert assigned == (removed xor 1) and starts == 1 and env.apCount == 1
'''


def vif_lifetime_source(mutation: str | None = None,
                        platform: str = PLATFORM) -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    vif = (FW / "vif_management.nim").read_text()
    code = platform
    code += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    code += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    for name in ["co_list_init", "co_list_push_front", "co_list_push_back", "co_list_pop_front",
                 "co_list_extract", "co_list_find"]:
        code += procedure(kernel, name)
    for name in ["vif_mgmt_entry_init", "vif_mgmt_init", "vif_mgmt_register",
                 "vif_mgmt_unregister"]:
        body = procedure(vif, name)
        if name == "vif_mgmt_register" and mutation == "ap_reservation":
            old = ("  if vifType == VIF_TYPE_AP:\n"
                   "    # A detached AP still owns the shared beacon resources until reset.\n"
                   "    for index in 0'u8 ..< MAX_VIFS.uint8:\n"
                   "      if vifChannelForIdx(index).vifType == VIF_TYPE_AP:\n"
                   "        return 1\n")
            assert body.count(old) == 1
            body = body.replace(old, "")
        if name == "vif_mgmt_unregister" and mutation not in [None, "ap_reservation"]:
            if mutation == "epoch":
                old, new = "rxVifEpochs[vifIdx] == retiredEpoch", "true"
            elif mutation == "type":
                old, new = "vif.vifType == vifType", "true"
            elif mutation == "active":
                old = "not co_list_find(addr env.activeList, cast[ptr CoListHdr](vifEntry)) and"
                new = "true and"
            elif mutation == "free":
                old = "not co_list_find(addr env.freeList, cast[ptr CoListHdr](vifEntry))"
                new = "true"
            elif mutation == "prepare":
                old = ("    if rxVifEpochs[vifIdx] != entryEpoch or vif.vifType != vifType or\n"
                       "        not co_list_find(addr env.activeList, cast[ptr CoListHdr](vifEntry)):\n"
                       "      return true\n")
                new = ""
            elif mutation == "deferred":
                old = "    if not prepared:\n      return false\n"
                new = ""
            elif mutation == "counters":
                old = ("  if vifType == VIF_TYPE_STA:\n    dec env.staCount\n"
                       "  elif vifType == VIF_TYPE_AP:\n    dec env.apCount\n")
                assert body.count(old) == 1
                body = body.replace(old, "")
                old = "  rxInvalidateQuiescentVif(vifIdx, selected)\n"
                new = old + ("  if vifType == VIF_TYPE_STA:\n    dec env.staCount\n"
                             "  elif vifType == VIF_TYPE_AP:\n    dec env.apCount\n")
            elif mutation == "callback_irq":
                old, new = "        irqRestore(saved)\n", "        discard\n"
            else:
                call = {
                    "retire": "rxInvalidateQuiescentVif(vifIdx, selected)",
                    "hw": "mm_hw_ap_info_reset(0)",
                    "timer1": "mm_timer_clear(addr vif.tbttTimer)",
                    "timer2": "mm_timer_clear(addr vif.beaconTimeoutTimer)",
                    "watchdog": "mm_timer_clear(addr vif.keepAliveTimer)",
                    "td": "td_reset(vifIdx)",
                }.get(mutation)
                if mutation == "deinit":
                    old = "        if not current():\n          return true\n"
                    new = ""
                elif mutation == "stop":
                    old = ("      return false\n"
                           "    if not current():\n      return true\n\n"
                           "  if vifType == VIF_TYPE_AP and env.apCount == 0:")
                    new = ("      return false\n\n"
                           "  if vifType == VIF_TYPE_AP and env.apCount == 0:")
                else:
                    indent = "    " if mutation in ["stop", "hw", "watchdog"] else "  "
                    old = f"{indent}{call}\n{indent}if not current():\n{indent}  return true\n"
                    new = f"{indent}{call}\n"
            assert body.count(old) == 1, (mutation, old)
            body = body.replace(old, new)
        code += body
    return code


REGISTRATION_GUARDS = r'''
reset()
doAssert vif_mgmt_init()
let originalEnv = env
let originalVifs = vifs
for kind in [4'u8, 255'u8]:
  var assigned = 255'u8
  doAssert vif_mgmt_register(addr mac[0], kind, false, addr assigned) == 1
  doAssert assigned == 255 and env == originalEnv and vifs == originalVifs
  doAssert hwSets == 0 and starts == 0
var assigned = 255'u8
doAssert vif_mgmt_register(nil, VIF_TYPE_STA, false, addr assigned) == 1
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA, false, nil) == 1
doAssert assigned == 255 and env == originalEnv and vifs == originalVifs
doAssert hwSets == 0

var foreign: Vif
foreign.vifType = 4
env.freeList.first = cast[ptr CoListHdr](addr foreign)
env.freeList.last = env.freeList.first
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA, false, addr assigned) == 1
doAssert env.freeList.first == cast[ptr CoListHdr](addr foreign)
doAssert hwSets == 0 and assigned == 255

reset()
doAssert vif_mgmt_init()
vifs[0].vifType = VIF_TYPE_STA
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA, false, addr assigned) == 1
doAssert hwSets == 0 and assigned == 255

reset()
doAssert vif_mgmt_init()
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA, false, addr assigned) == 0
doAssert assigned == 0 and env.staCount == 1 and hwSets == 1

for kind in [1'u8, 3'u8]:
  reset()
  doAssert vif_mgmt_init()
  assigned = 255
  doAssert vif_mgmt_register(addr mac[0], kind, false, addr assigned) == 0
  doAssert assigned == 0 and vifs[0].vifType == kind
  doAssert env.staCount == 0 and env.apCount == 0 and hwSets == 1
  doAssert starts == 0 and env.activeList.first == cast[ptr CoListHdr](addr vifs[0])
  doAssert vif_mgmt_unregister(assigned)
  doAssert env.activeList.first == nil and vifs[0].vifType == 4
  doAssert env.staCount == 0 and env.apCount == 0
  doAssert stops == 0 and deinitializations == 0 and clearedTimers == 2
  doAssert resets == 1

# A failed queue halt must not consume a free entry or program the MAC/filter.
reset()
haltAllowed = true
doAssert vif_mgmt_init()
let beforeHaltEnv = env
let beforeHaltVifs = vifs
let beforeHaltEpochs = rxVifEpochs
haltAllowed = false
assigned = 255
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA, false, addr assigned) == 1
doAssert assigned == 255 and env == beforeHaltEnv and vifs == beforeHaltVifs
doAssert rxVifEpochs == beforeHaltEpochs and hwSets == 0
haltAllowed = true
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA, false, addr assigned) == 0
doAssert assigned == 0 and hwSets == 1
let beforeFilterEnv = env
let beforeFilterVifs = vifs
let beforeFilterEpochs = rxVifEpochs
mm.rxFilterExtra = 0xA0'u32
haltAllowed = false
assigned = 255
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA, false, addr assigned) == 1
doAssert assigned == 255 and env == beforeFilterEnv and vifs == beforeFilterVifs
doAssert rxVifEpochs == beforeFilterEpochs and mm.rxFilterExtra == 0xA0'u32
doAssert hwSets == 1
haltAllowed = true

# Retirement can synchronously reset the VIF table. Do not claim its new head.
reset()
doAssert vif_mgmt_init()
var didReset = false
retireHook = proc(index: uint8) =
  doAssert index == 0 and not didReset
  didReset = true
  retireHook = nil
  doAssert vif_mgmt_init()
assigned = 255
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA, false, addr assigned) == 1
doAssert didReset and assigned == 255 and hwSets == 0
doAssert env.activeList.first == nil
doAssert env.freeList.first == cast[ptr CoListHdr](addr vifs[0])
doAssert env.freeList.last == cast[ptr CoListHdr](addr vifs[1])
'''


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_vif_registration_guards_and_common_types(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, vif_lifetime_source() + REGISTRATION_GUARDS)


def test_vif_unregister_restores_single_ibss_or_mesh_filter(tmp_path: Path) -> None:
    platform = ("var rxControl, bssidLow, bssidHigh: uint32\n" + PLATFORM).replace(
        "proc regWrite(address: uint; value: uint32) = discard",
        "proc regWrite(address: uint; value: uint32) =\n"
        "  case address\n"
        "  of MACHW_RX_CNTRL_REG: rxControl = value\n"
        "  of MACHW_BASE + 0x020'u: bssidLow = value\n"
        "  of MACHW_BASE + 0x024'u: bssidHigh = value\n"
        "  else: discard",
    )
    checks = r'''
for removedKind in [VIF_TYPE_STA, VIF_TYPE_AP, 1'u8, 3'u8]:
  for remainingKind in [1'u8, 3'u8]:
    reset()
    mm = default(typeof(mm))
    rxControl = 0
    bssidLow = 0
    bssidHigh = 0
    doAssert vif_mgmt_init()
    var removed, remaining = 255'u8
    doAssert vif_mgmt_register(addr mac[0], removedKind, false, addr removed) == 0
    doAssert vif_mgmt_register(addr mac[0], remainingKind, false, addr remaining) == 0
    doAssert removed == 0 and remaining == 1
    doAssert (mm.rxFilterExtra and 16'u32) != 0
    vifs[remaining].currentBssid = [2'u8, 5, 8, 13, 21, 34]
    doAssert vif_mgmt_unregister(removed)
    doAssert env.activeList.first == cast[ptr CoListHdr](addr vifs[remaining])
    doAssert (mm.rxFilterExtra and 16'u32) == 0 and rxControl == mm.rxFilterBase
    doAssert bssidLow == 0x0D080502'u32 and bssidHigh == 0x2215'u32
'''
    run_program(tmp_path, "checked", vif_lifetime_source(platform=platform) + checks)


RETIREMENT_CHECKS = r'''
# vif_mgmt_unregister retires a STA VIF's ME mask bits and tells SM once,
# after its entry is freed, however it returns once the removal is
# committed. A removal refused before the commit, or of an AP VIF, does
# neither.
proc register(kind: uint8): uint8 =
  result = 255
  doAssert vif_mgmt_register(addr mac[0], kind, false, addr result) == 0
for kind in [VIF_TYPE_STA, VIF_TYPE_AP]:
  for exit in ["normal", "replaced_in_deinit", "refused"]:
    reset()
    doAssert vif_mgmt_init()
    let removed = register(kind)
    let other = register(VIF_TYPE_STA)
    doAssert removed == 0 and other == 1
    meMasks = (activeMask: 3'u32, psDisableMask: 3'u32)
    retiredStaVifs.setLen(0)
    case exit
    of "replaced_in_deinit":
      # A callback in the window changes the entry; the removal returns early.
      deinitHook = proc() = inc rxVifEpochs[removed]
    of "refused": haltAllowed = false
    else: discard
    let done = vif_mgmt_unregister(removed)
    haltAllowed = true
    doAssert done == (exit != "refused")
    if kind == VIF_TYPE_STA and exit != "refused":
      doAssert meMasks == (activeMask: 2'u32, psDisableMask: 2'u32)
      if exit == "normal": doAssert retiredStaVifs == @[(removed, 4'u8)]
      else: doAssert retiredStaVifs.len == 1 and retiredStaVifs[0].vif == removed
    else:
      doAssert meMasks == (activeMask: 3'u32, psDisableMask: 3'u32) and retiredStaVifs.len == 0
'''


@pytest.mark.parametrize("mutation", [None, "no_signal"])
def test_sta_vif_removal_tells_me_and_sm(tmp_path: Path, mutation: str | None) -> None:
    code = vif_lifetime_source()
    if mutation:
        old = "      smStaVifRetired(vifIdx)\n"
        assert code.count(old) == 1
        code = code.replace(old, "      discard\n")
    if mutation:
        with pytest.raises(AssertionError):
            run_program(tmp_path, "checked", code + RETIREMENT_CHECKS)
    else:
        run_program(tmp_path, "checked", code + RETIREMENT_CHECKS)


REGISTER_CALLBACK_PLATFORM = PLATFORM.replace(
    "proc mm_hw_info_set(p: pointer) = inc hwSets",
    "proc mm_hw_info_set(p: pointer) =\n"
    "  inc hwSets\n"
    "  if hwResetHook != nil: hwResetHook()",
).replace(
    "proc mm_hw_ap_info_set(i: uint8) = discard",
    "proc mm_hw_ap_info_set(i: uint8) =\n"
    "  if prepareHook != nil: prepareHook()",
).replace(
    "proc td_start(i: uint8) = discard",
    "proc td_start(i: uint8) =\n"
    "  if tdHook != nil: tdHook()",
)


REGISTER_CALLBACK_CHECKS = r'''
for scenario in [
    (VIF_TYPE_STA, "mac"), (VIF_TYPE_STA, "wpa"), (VIF_TYPE_STA, "td"),
    (VIF_TYPE_AP, "mac"), (VIF_TYPE_AP, "ap_hw"),
    (VIF_TYPE_AP, "beacon"), (VIF_TYPE_AP, "td")]:
  let kind = scenario[0]
  let site = scenario[1]
  reset()
  haltAllowed = true
  doAssert vif_mgmt_init()
  var fired = false
  var replacementVifs: typeof(vifs)
  var replacementEnv: Env
  var replacementEpochs: typeof(rxVifEpochs)
  proc replace() =
    doAssert not fired
    fired = true
    hwResetHook = nil
    prepareHook = nil
    initHook = nil
    startHook = nil
    tdHook = nil
    doAssert vif_mgmt_init()
    replacementVifs = vifs
    replacementEnv = env
    replacementEpochs = rxVifEpochs
  case $site
  of "mac": hwResetHook = replace
  of "wpa": initHook = replace
  of "ap_hw": prepareHook = replace
  of "beacon": startHook = replace
  of "td": tdHook = replace
  else: doAssert false
  var assigned = 255'u8
  doAssert vif_mgmt_register(addr mac[0], kind.uint8, false, addr assigned) == 1
  doAssert fired and assigned == 255, $site
  doAssert vifs == replacementVifs and env == replacementEnv, $site
  doAssert rxVifEpochs == replacementEpochs, $site
  doAssert env.activeList.first == nil and
    env.freeList.first == cast[ptr CoListHdr](addr vifs[0])
'''


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_vif_registration_does_not_publish_after_callback_reset(
    tmp_path: Path, mode: str
) -> None:
    run_program(tmp_path, mode,
                vif_lifetime_source(platform=REGISTER_CALLBACK_PLATFORM) +
                REGISTER_CALLBACK_CHECKS)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "epoch", "type", "active", "free", "prepare",
    "counters", "callback_irq", "retire", "stop", "hw", "deinit", "timer1", "timer2", "td",
    "ap_reservation", "deferred", "watchdog"])
def test_vif_teardown_preserves_callback_replacement(
    tmp_path: Path, mode: str, mutation: str | None
) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "vif_lifetime.nim"
    path.write_text(vif_lifetime_source(mutation) + REPLACEMENT_CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address",
                        "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'test'}", *options[mode], str(path)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(reason in result.stdout for reason in
            ["AssertionDefect", "RangeDefect", "AddressSanitizer", "SIGSEGV", "SIGBUS"]), result.stdout
