"""Deterministic fake-MAC schedules for the real MM timers and scan/ROC gate.

Replay a long run with BL808_WIFI_MODEL_SEED (decimal or 0x...) and
BL808_WIFI_MODEL_STEPS. Failures print the concrete input through the first
divergence (times are unwrapped MAC ticks, including across 32-bit rollover).
"""

from copy import deepcopy
from dataclasses import dataclass, field
import os
from pathlib import Path
import random
import shutil
import subprocess

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_connless_timer_dispatch import source as connless_source
from test_wifi_disconnect_tx import FW, procedure


# The fixture models request ingress, delivery of the queued idle request to
# the radio, and the notice sink. The timer queue, gate, switch start, context
# status arm, operation dispatch and dwell retirement are production Nim. The
# switch's MM_FORCE_IDLE_REQ is static, so starting a switch cannot fail.
GATE_SWITCH = r'''
var attempts, sent: int
proc chan_goto_idle_cb() {.cdecl.} = doAssert false, "departures are outside this fixture"
proc chanSwitchSlot(target: pointer): int =
  for index in 0'u8 ..< 5:
    if target == cast[pointer](addr contexts[index]):
      return (if contexts[index].contextIndexOrMarker == index: index.int else: -1)
  -1
proc chanSwitchBegin() =
  ## chan_switch_start published scheduledCtxt; the request goes to MM.
  doAssert env.switchPending == 0
  env.switchPending = 1
  inc attempts
  inc sent
'''

SETUP = r'''
template scan: untyped = cast[ptr ChanScanPoolOverlay](addr contexts[3].channel)
template roc: untyped = cast[ptr ChanRocOverlay](addr contexts[4].channel)
proc setupScan() =
  setupConnless()
  env.ctxtCount = 0
  attempts = 0
  sent = 0
  scan.slot = 3
  scan.active = 1
  scan.durationTicks = 37
  scan.channel.primFreq = 2462
  roc.slot = 0xFF
  roc.stateLo = 0
'''


def gate_source() -> str:
    code = connless_source()
    code = code.replace(procedure(code, "chan_switch_start"),
                        "proc chan_switch_start*(chanCtxt: pointer) {.exportc, cdecl.}\n", 1)
    code = code.replace("ctxtCount, flags: uint8,", "ctxtCount, flags, switchPending: uint8,", 1)
    # The pool link is a 32-bit field on RV32; it is not dereferenced here.
    pool = layouts("ChanCtxtView", "ChanScanPoolOverlay", "ChanRocOverlay")
    start, end = code.index("  Context = object"), code.index("  Vif = object")
    code = (code[:start] + pool.replace("link*: CoListHdr", "link*: uint32")
            + "  Context = ChanCtxtView\n" + code[end:])
    code += GATE_SWITCH + procedure((FW / "task_handlers.nim").read_text(), "chan_switch_start")
    return code + SETUP


BRIDGE = r'''
import std/strutils

const MM_SCAN_CHANNEL_END_IND = 1'u16
var ps: tuple[statusFlags: uint32]
proc psEnvView(): ptr typeof(ps) = addr ps
proc blmac_pwr_mgt_setf(value: uint32) = discard
proc mm_back_to_host_idle() = discard
proc chan_cde_evt(p: pointer) = doAssert false, "CDE is outside this fixture"
proc chan_get_dominant_chan(): pointer = doAssert false, "home dwell is outside this fixture"
proc chan_get_next_chan(): pointer = doAssert false, "home dwell is outside this fixture"
proc scanDwellPost(id: uint16) =
  doAssert id == MM_SCAN_CHANNEL_END_IND
  doAssert contexts[3].contextIndexOrMarker == 3 and owners[3] != 0
  observed.add("end:" & $owners[3])
proc chanSwitchRetire(p: pointer) =
  # The fake radio already consumed the switch; it cannot cancel a next-home
  # reservation on behalf of the finishing dwell.
  doAssert env.currentCtxt == nil and env.scheduledCtxt != p
'''

DRIVER = r'''
proc indexOf(p: pointer): int =
  if p == nil: return -1
  for i in 0 ..< contexts.len:
    if p == addr contexts[i]: return i
  doAssert false, "unknown context"

proc offer(i, id: int) =
  doAssert i in 3..4 and contexts[i].contextIndexOrMarker == 0xFF
  owners[i] = id
  inc chanCtxtEpochs[i]
  contexts[i].contextIndexOrMarker = i.uint8
  contexts[i].status = 1
  contexts[i].opSlot = 2
  contexts[i].channel.primFreq = (2412 + (id mod 11) * 5).uint16
  env.flags = env.flags or (if i == 3: 2'u8 else: 1'u8)
  chan_conn_less_delay_prog()

proc retireFixtureRequests() =
  for i in 3..4:
    if contexts[i].contextIndexOrMarker == i.uint8:
      observed.add("cancel:" & $owners[i])
      contexts[i].contextIndexOrMarker = 0xFF
      inc chanCtxtEpochs[i]
  env.flags = 0
  env.currentCtxt = nil
  env.scheduledCtxt = nil
  env.switchPending = 0

proc resetRadio() =
  mm_timer_init()
  inc txResetEpoch
  retireFixtureRequests()

proc retune() =
  let target = env.scheduledCtxt
  let i = indexOf(target)
  doAssert i in 3..4 and env.switchPending == 1
  env.flags = env.flags and not 0x20'u8
  env.switchPending = 0
  env.scheduledCtxt = nil
  env.currentCtxt = target
  chan_upd_ctxt_status(target, 4)
  observed.add("retune:" & $owners[i])

proc queueSnapshot(): string =
  var rows: seq[string]
  var node = mm_timer_list.first
  var last: ptr CoListHdr
  while node != nil:
    doAssert rows.len < timers.len, "MM timer queue cycle"
    let slot = timerIndex(node)
    doAssert slot in 1..3
    rows.add($slot & ":" & $mmTimerAt(node).expiry)
    last = node
    node = node.next
  # co_list_pop_front deliberately leaves the old tail on an empty list.
  doAssert last == nil or mm_timer_list.last == last, "MM timer queue tail"
  if rows.len == 0: "-" else: rows.join(",")

proc requestSnapshot(i: int): string =
  result = $chanCtxtEpochs[i]
  if contexts[i].contextIndexOrMarker != 0xFF:
    doAssert contexts[i].contextIndexOrMarker == i.uint8
    result.add(":" & $owners[i] & ":" & $contexts[i].status &
               ":" & $contexts[i].channel.primFreq)

var line: string
while stdin.readLine(line):
  let row = line.splitWhitespace()
  now = uint32(parseBiggestUInt(row[1]) and 0xFFFF_FFFF'u64)
  let arg = parseInt(row[2])
  if row[0] == "begin":
    let start = now
    setupScan()
    now = start
    env.ctxtCount = arg.uint8
    env.flags = 0
    for i in 3..4: contexts[i].contextIndexOrMarker = 0xFF
    chanConnlessTimerOwner.serial = high(uint32)
    chanCtxtTimerOwner.serial = high(uint32)
    continue

  let id = parseInt(row[3])
  let before = attempts
  observed.setLen(0)
  let op = row[0]
  case op
  of "offer": offer(arg, id)
  of "join_prepare":
    onTrace = proc(tag: string) =
      if tag == "[WIFI-NIMFW] cld_prog delay ":
        onTrace = nil
        offer(4, id + 1)
    offer(3, id)
    doAssert onTrace == nil, "missed gate preparation boundary"
  of "clear_arm":
    onHardware = proc() = mm_timer_clear(addr timers[3])
    offer(arg, id)
    doAssert onHardware == nil, "missed gate publication boundary"
  of "rearm": chan_conn_less_delay_prog()
  of "aux": mm_timer_set(addr timers[1], now + cast[uint32](arg.int32))
  of "poll": mm_timer_schedule()
  of "retune": retune()
  of "next_home": env.scheduledCtxt = addr contexts[0]
  of "home_done": env.scheduledCtxt = nil
  of "cancel":
    mm_timer_clear(addr timers[3])
    retireFixtureRequests()
  of "reset": resetRadio()
  of "pop_clear", "pop_reset", "pop_replace":
    onUnlock = proc() =
      if not mmTimerScheduling or mm_timer_list.first != nil: return
      onUnlock = nil
      if op == "pop_reset": resetRadio()
      else:
        mm_timer_clear(addr timers[3])
        retireFixtureRequests()
        if op == "pop_replace": offer(arg, id)
    mm_timer_schedule()
    doAssert onUnlock == nil, "missed dequeue/dispatch boundary"
  else: doAssert false, "unknown schedule operation: " & op

  doAssert enabled and not mmTimerScheduling and mmTimerMutationTop == nil
  echo env.flags, " ", indexOf(env.currentCtxt), " ", indexOf(env.scheduledCtxt),
       " ", env.switchPending, " ", attempts - before, " ", queueSnapshot(),
       " ", requestSnapshot(3), " ", requestSnapshot(4), " ",
       (if observed.len == 0: "-" else: observed.join(","))
  stdout.flushFile()
'''


def nim_source() -> str:
    code = gate_source()
    code = code.replace(procedure(code, "chanCtxtOpEvent"),
                        "proc chanCtxtOpEvent(ctxtPtr: pointer; saved: uint32)\n", 1)
    code = code.replace(" lastMacTime: uint32]",
                        " lastMacTime: uint32, activeList: CoList,"
                        " surveySnapshot, scanDelayCount, connlessDelayCount: uint8]", 1)
    code = code.replace("  inc sent\n", '  inc sent\n  observed.add("switch:" & '
                        '$owners[chanCtxtAt(env.scheduledCtxt).contextIndexOrMarker])\n', 1)
    code = code.replace("  delivered.add(cast[uint](p))", '  observed.add("aux")', 1)
    code = "var observed: seq[string]\nvar owners: array[5, int]\n" + code
    worker = procedure((FW / "kernel_mac_channel.nim").read_text(), "chanCtxtOpEvent")
    return code + BRIDGE + worker + DRIVER


WRAP = 1 << 32
GATE, OP, AUX = 3, 2, 1
SCAN, ROC = 3, 4
BASE_DELAY, DWELL, SWITCH_GUARD = 30_000, 2048, 4000
SHORT_DEPTH, DEFAULT_STEPS = 3, 400
DEFAULT_SEEDS = (0xB1808, 0xC011)


@dataclass
class Model:
    """Unwrapped timer calendar plus per-request lifetimes, not timer owners."""

    now: int
    home_count: int
    timers: dict[int, int] = field(default_factory=dict)
    requests: dict[int, int] = field(default_factory=dict)
    epochs: dict[int, int] = field(default_factory=lambda: {SCAN: 0, ROC: 0})
    terminal: set[int] = field(default_factory=set)
    selected: int | None = None
    operating: bool = False
    next_home: bool = False
    guard_fired: bool = False
    attempts: int = 0
    trace: list[tuple[str, str]] = field(default_factory=list)
    actions: list[str] = field(default_factory=list)
    effects: list[str] = field(default_factory=list)

    def arm(self, slot: int, deadline: int) -> None:
        self.timers.pop(slot, None)
        self.timers[slot] = deadline

    def arm_gate(self) -> None:
        if self.selected is None and GATE not in self.timers:
            delay = 0 if self.home_count == 0 else BASE_DELAY * (1 if ROC in self.requests else 4)
            self.arm(GATE, self.now + delay)

    def offer(self, kind: int, ident: int, *, arm: bool = True) -> None:
        assert kind not in self.requests
        self.requests[kind] = ident
        self.epochs[kind] += 1
        if arm:
            self.arm_gate()

    def retire(self, kind: int, notice: str | None) -> None:
        ident = self.requests.pop(kind)
        assert ident not in self.terminal
        self.terminal.add(ident)
        self.epochs[kind] += 1
        if notice:
            self.effects.append(f"{notice}:{ident}")

    def cancel(self, *, reset: bool) -> None:
        if reset:
            self.timers.clear()
        else:
            self.timers.pop(GATE, None)
        for kind in (SCAN, ROC):
            if kind in self.requests:
                self.retire(kind, "cancel")
        self.selected = None
        self.operating = self.next_home = self.guard_fired = False

    def poll(self, op: str, arg: int, ident: int) -> None:
        while self.timers:
            slot = min(self.timers, key=self.timers.__getitem__)
            if self.timers[slot] - self.now >= 50:
                break
            del self.timers[slot]
            if op.startswith("pop_"):
                self.cancel(reset=op == "pop_reset")
                if op == "pop_replace":
                    self.offer(arg, ident)
                break
            if slot == AUX:
                self.effects.append("aux")
            elif slot == GATE:
                self.attempts += 1
                self.selected = ROC if ROC in self.requests else SCAN
                self.effects.append(f"switch:{self.requests[self.selected]}")
                self.arm(OP, self.now + SWITCH_GUARD)
            elif not self.operating:
                self.guard_fired = True
            else:
                self.retire(self.selected, "end" if self.selected == SCAN else None)
                self.selected = None
                self.operating = False
                if self.requests:
                    self.arm_gate()

    def choices(self) -> list[str]:
        idle = self.selected is None
        actions = ["reset"]
        if not self.next_home:
            actions += ["scan"] * (SCAN not in self.requests)
            actions += ["roc"] * (ROC not in self.requests)
            if idle and not self.requests:
                actions += ["join_prepare"]
                if not self.timers:
                    actions += ["clear_arm"]
        if AUX not in self.timers:
            actions += ["aux"]
        if idle and self.requests:
            actions += ["cancel"]
            if GATE not in self.timers:
                actions += ["rearm"]
            else:
                if AUX not in self.timers:
                    actions += ["pop_clear"]
                    if self.home_count and len(self.requests) == 1:
                        actions += ["pop_replace"]
        if self.timers:
            actions += ["edge", "near", "due", "late"]
            if AUX not in self.timers:
                actions += ["pop_reset"]
        if not idle and not self.operating:
            actions += ["retune"]
        if self.operating and self.selected == SCAN and not self.next_home and len(self.requests) == 1:
            actions += ["next_home"]
        if idle and self.next_home:
            actions += ["home_done"]
        return actions

    def step(self, action: str) -> None:
        ident = 2 * len(self.trace) + 2
        self.attempts = 0
        self.effects = []
        op, arg = action, 0
        if action in {"scan", "roc", "clear_arm"}:
            arg = ROC if action == "roc" else SCAN
            self.offer(arg, ident, arm=action != "clear_arm")
            if action != "clear_arm":
                op = "offer"
        elif action == "join_prepare":
            self.offer(SCAN, ident, arm=False)
            self.offer(ROC, ident + 1)
        elif action == "rearm":
            self.arm_gate()
        elif action == "aux":
            arg = min(self.timers.values(), default=self.now + 100) - self.now
            self.arm(AUX, self.now + (arg if arg >= 0 else 3000))
        elif action in {"edge", "near", "due", "late",
                        "pop_clear", "pop_reset", "pop_replace"}:
            if action in {"pop_clear", "pop_replace"}:
                deadline = self.timers[GATE]
            else:
                deadline = min(self.timers.values())
            self.now = max(self.now, deadline + {"edge": -50, "near": -49, "late": 7000}.get(action, 0))
            if action == "pop_replace":
                arg = next(iter(self.requests))
            if action in {"edge", "near", "due", "late"}:
                op = "poll"
            self.poll(op, arg, ident)
        elif action == "retune":
            self.operating, self.guard_fired = True, False
            self.arm(OP, self.now + DWELL)
            self.effects.append(f"retune:{self.requests[self.selected]}")
        elif action == "next_home":
            self.next_home = True
        elif action == "home_done":
            self.next_home = False
        elif action in {"cancel", "reset"}:
            self.cancel(reset=action == "reset")
        else:
            raise AssertionError(action)
        self.actions.append(action)
        self.trace.append((f"{op} {self.now} {arg} {ident}", self.snapshot()))

    def snapshot(self) -> str:
        flags = 0
        current = scheduled = -1
        for kind in self.requests:
            pending = 2 if kind == SCAN else 1
            flags |= pending << 2 if kind == self.selected else pending
        if self.selected is not None or GATE in self.timers:
            flags |= 0x10
        if self.guard_fired:
            flags |= 0x20
        if self.operating:
            current = self.selected
        elif self.selected is not None:
            scheduled = self.selected
        if self.next_home:
            scheduled = 0
        queue = ",".join(f"{slot}:{time % WRAP}" for slot, time in
                         sorted(self.timers.items(), key=lambda pair: pair[1]))
        requests = []
        for kind in (SCAN, ROC):
            item = str(self.epochs[kind])
            if kind in self.requests:
                ident = self.requests[kind]
                status = 1 if kind != self.selected else (4 if self.operating else 2)
                item += f":{ident}:{status}:{2412 + 5 * (ident % 11)}"
            requests.append(item)
        return " ".join(map(str, (flags, current, scheduled, int(scheduled in {SCAN, ROC}),
                                  self.attempts, queue or "-", *requests,
                                  ",".join(self.effects) or "-")))

    def drain(self) -> None:
        """Fair suffix: no new requests/failures, deliver idle, clock and MM work."""
        for _ in range(10):
            if self.selected is not None and not self.operating:
                self.step("retune")
            elif self.next_home and self.selected is None:
                self.step("home_done")
            elif self.timers:
                self.step("due")
            elif self.requests:
                self.step("rearm")
            else:
                return
        raise AssertionError(f"model did not quiesce: {self.trace}")


@dataclass
class Schedule:
    name: str
    start: int
    home_count: int
    trace: list[tuple[str, str]]
    actions: list[str]

    @classmethod
    def from_model(cls, name: str, start: int, model: Model):
        return cls(name, start, model.home_count, model.trace, model.actions)

    @property
    def header(self) -> str:
        return f"begin {self.start} {self.home_count}"


def short_schedules():
    def walk(model, depth):
        if depth == 0:
            model.drain()
            yield model
        else:
            for action in model.choices():
                branch = deepcopy(model)
                branch.step(action)
                yield from walk(branch, depth - 1)

    # Explore every legal continuation from both cold and active cutpoints.
    # Exact-zero gate/dwell deadlines exercise the wrap sentinel regressions.
    for start, home in ((WRAP - DWELL, 0), (WRAP - 4 * BASE_DELAY, 1)):
        for prefix in ((), ("scan", "due", "retune")):
            model = Model(start, home)
            for action in prefix:
                model.step(action)
            for i, branch in enumerate(walk(model, SHORT_DEPTH)):
                yield Schedule.from_model(f"short {prefix or 'cold'} #{i}", start, branch)


def long_schedules(seed, steps):
    for home in (0, 1):
        start = WRAP - 101
        model = Model(start, home)
        rng = random.Random(seed)
        for step in range(steps):
            model.step(rng.choice(model.choices()))
            if (step + 1) % 40 == 0:
                model.drain()
        model.drain()
        yield Schedule.from_model(f"seed={seed:#x} steps={steps}", start, model)


def compile_target(tmp_path: Path, code: str, mode: str) -> Path:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required to run the Wi-Fi timer model fuzzer")
    source, binary = tmp_path / "timer_model.nim", tmp_path / "timer_model"
    source.write_text(code)
    flags = [] if mode == "checked" else ["--mm:arc", "--exceptions:goto", "-d:release",
                                          "--checks:off", "--assertions:on", "--threads:off"]
    result = subprocess.run(
        [nim, "c", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         f"--nimcache:{tmp_path / 'cache'}", f"-o:{binary}", *flags, str(source)],
        capture_output=True, text=True, timeout=90,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return binary


def script_for(case: Schedule, end: int | None = None) -> str:
    return "\n".join([case.header, *(command for command, _ in case.trace[:end])]) + "\n"


def mismatch_fields(expected: str, actual: str | None) -> tuple[int, ...] | None:
    if actual is None or len(actual.split()) != len(expected.split()):
        return None
    return tuple(i for i, (a, b) in enumerate(zip(expected.split(), actual.split())) if a != b)


def minimize(binary: Path, case: Schedule, at: int, fields: tuple[int, ...]) -> Schedule:
    """Remove action chunks, regenerating times, IDs and legal oracle outputs."""
    original = case.actions[:at + 1]
    actions = original
    best = Schedule(case.name, case.start, case.home_count, case.trace[:at + 1], actions)
    granularity, budget = 2, 96
    while len(actions) > 1 and budget:
        candidate_len = (len(actions) + granularity - 1) // granularity
        for start in range(0, len(actions), candidate_len):
            candidate = actions[:start] + actions[start + candidate_len:]
            accepted = False
            model = Model(case.start, case.home_count)
            for action in candidate:
                if action not in model.choices():
                    break
                model.step(action)
            else:
                reduced = Schedule.from_model(case.name, case.start, model)
                budget -= 1
                try:
                    run = subprocess.run([str(binary)], input=script_for(reduced), capture_output=True,
                                         text=True, timeout=1)
                except subprocess.TimeoutExpired:
                    run = None
                if run is not None:
                    for i, (line, (_, expected)) in enumerate(zip(run.stdout.splitlines(), model.trace)):
                        if line == expected:
                            continue
                        if candidate[i] == original[-1] and mismatch_fields(expected, line) == fields:
                            actions = candidate[:i + 1]
                            best = Schedule(case.name, case.start, case.home_count, model.trace[:i + 1], actions)
                            granularity = max(2, granularity - 1)
                            accepted = True
                        break
            if accepted or not budget:
                break
        else:
            if granularity >= len(actions):
                break
            granularity = min(len(actions), 2 * granularity)
    return best


def compare(binary: Path, schedules: list[Schedule]) -> None:
    script = "".join(script_for(case) for case in schedules)
    result = subprocess.run([str(binary)], input=script, capture_output=True, text=True, timeout=30)
    output = iter(result.stdout.splitlines())
    for case in schedules:
        for i, (_, expected) in enumerate(case.trace):
            actual = next(output, None)
            if actual != expected:
                fields = mismatch_fields(expected, actual)
                if fields:
                    reduced = minimize(binary, case, i, fields)
                    prefix = script_for(reduced).rstrip("\n")
                else:
                    prefix = script_for(case, i + 1).rstrip("\n")
                details = result.stderr if actual is None else ""
                raise AssertionError(f"{case.name}, first divergence at step {i + 1}\n"
                                     f"Reproducer prefix:\n{prefix}\n"
                                     f"expected: {expected}\nactual:   {actual}\n{details}")
    assert result.returncode == 0 and next(output, None) is None, result.stderr


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_timer_channel_gate_model(tmp_path: Path, mode: str) -> None:
    seed = os.environ.get("BL808_WIFI_MODEL_SEED")
    seeds = DEFAULT_SEEDS if seed is None else (int(seed, 0),)
    steps = int(os.environ.get("BL808_WIFI_MODEL_STEPS", str(DEFAULT_STEPS)))
    assert steps > 0, "BL808_WIFI_MODEL_STEPS must be positive"
    schedules = list(short_schedules())
    schedules.extend(case for seed in seeds for case in long_schedules(seed, steps))
    compare(compile_target(tmp_path, nim_source(), mode), schedules)


def test_model_rejects_prior_scheduled_context_bug(tmp_path: Path) -> None:
    # Restore the old rule requiring even an operating scan to match the
    # scheduled context captured when the dwell timer was armed.
    code = nim_source()
    fixed = "(operatingScan or env.scheduledCtxt == owner.scheduled)"
    assert code.count(fixed) == 1
    mutant = code.replace(fixed, "(env.scheduledCtxt == owner.scheduled)")
    model = Model(WRAP - DWELL, 0)
    for action in ("reset", "scan", "due", "retune", "next_home", "due"):
        model.step(action)
    case = Schedule.from_model("scheduled-context mutant", WRAP - DWELL, model)
    with pytest.raises(AssertionError, match=r"(?s)first divergence at step 6.*expected:.*end:4.*actual:   24 3 0") as error:
        compare(compile_target(tmp_path, mutant, "checked"), [case])
    assert "\nreset " not in str(error.value)
