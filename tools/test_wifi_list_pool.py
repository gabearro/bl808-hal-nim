"""Exercise the firmware's shared lists/pools with returning assertions."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_timer_progress import source as rx_timer_source


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n" + "".join(
        re.search(rf"(?m)^  {name}\* = object\n(?:    .*\n)+", layout).group()
        for name in ("CoListHdr", "CoList", "CoDlistHdr", "CoDlist", "CoPoolNode", "CoPool")
    )
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    return types + PLATFORM + "".join(
        procedure(kernel, name) for name in (
            "co_list_init", "co_list_push_back", "co_list_push_front",
            "co_list_pop_front", "co_list_extract", "co_list_remove",
            "co_dlist_init", "co_dlist_push_back", "co_dlist_push_front",
            "co_dlist_pop_front", "co_dlist_extract",
            "co_pool_init", "co_pool_alloc", "co_pool_free",
        )
    )


PLATFORM = r'''
var
  assertions: seq[cint]
  assertionHook: proc()
  list: CoList
  nodes: array[4, CoListHdr]
  dlist: CoDlist
  dnodes: array[4, CoDlistHdr]
  pool: CoPool
  pnodes: array[4, CoPoolNode]
  payload: array[8, uint32]
proc assert_err(condition, file: cstring; line: cint) =
  assertions.add(line)
  if assertionHook != nil: assertionHook()
proc setup() =
  assertions.setLen(0)
  assertionHook = nil
  for i in 0 ..< nodes.len:
    nodes[i].next = if i + 1 < nodes.len: addr nodes[i + 1] else: nil
    dnodes[i].next = if i + 1 < dnodes.len: addr dnodes[i + 1] else: nil
    dnodes[i].prev = if i > 0: addr dnodes[i - 1] else: nil
    pnodes[i].next = if i + 1 < pnodes.len: addr pnodes[i + 1] else: nil
    pnodes[i].element = addr payload[2 * i]
  list = CoList(first: addr nodes[0], last: addr nodes[^1])
  dlist = CoDlist(first: addr dnodes[0], last: addr dnodes[^1], elementCount: 4)
  pool = CoPool(first: addr pnodes[0], freeNodeCount: 4)
  for i in 0 ..< payload.len: payload[i] = 0xAABBCCDD'u32
'''


CASES = {
    "push_back": r'''
for empty in [false, true]:
  setup()
  if empty: list.first = nil
  let before = list
  let links = nodes
  co_list_push_back(addr list, nil)
  doAssert assertions == @[71.cint]
  doAssert list == before and nodes == links
''',
    "push_front": r'''
for empty in [false, true]:
  setup()
  if empty: list.first = nil
  let before = list
  let links = nodes
  co_list_push_front(addr list, nil)
  doAssert assertions == @[94.cint]
  doAssert list == before and nodes == links
''',
    "extract": r'''
setup()
let links = nodes
co_list_extract(nil, addr nodes[1])
doAssert assertions == @[129.cint] and nodes == links
''',
    "remove": r'''
for invalid in 0 .. 4:
  setup()
  let before = list
  let links = nodes
  case invalid
  of 0: co_list_remove(nil, cast[ptr CoListHdr](1), nil)
  of 1: co_list_remove(addr list, nil, nil)
  of 2: co_list_remove(addr list, addr nodes[0], addr nodes[2])
  of 3: co_list_remove(addr list, addr nodes[0], nil)
  else: co_list_remove(addr list, addr nodes[^1], nil)
  let line = case invalid
             of 0: 360.cint
             of 1, 4: 362.cint
             else: 361.cint
  doAssert assertions == @[line]
  doAssert list == before and nodes == links
''',
    "dlist_extract": r'''
for absent in [false, true]:
  setup()
  dlist.first = nil
  let before = dlist
  let links = dnodes
  co_dlist_extract(addr dlist, if absent: nil else: addr dnodes[1])
  doAssert assertions == @[142.cint]
  doAssert dlist == before and dnodes == links
''',
    "pool_init": r'''
for badAddress in [false, true]:
  for badSize in [false, true]:
    if not badAddress and not badSize: continue
    setup()
    let before = pool
    let links = pnodes
    let data = payload
    let memory = cast[pointer](cast[uint](addr payload[0]) + badAddress.uint)
    co_pool_init(addr pool, addr pnodes[0], memory,
                 if badSize: 7'u32 else: 8'u32, 1)
    doAssert assertions == @[if badAddress: 42.cint else: 43.cint]
    doAssert pool == before and pnodes == links and payload == data
''',
    "pool_alloc": r'''
for empty in [false, true]:
  setup()
  if empty: pool = default(CoPool)
  let before = pool
  let links = pnodes
  doAssert co_pool_alloc(addr pool, 0) == nil
  doAssert assertions == @[73.cint]
  doAssert pool == before and pnodes == links
''',
    "pool_free": r'''
for absent in [false, true]:
  for count in [0'u32, 1]:
    if not absent and count != 0: continue
    setup()
    let before = pool
    let links = pnodes
    co_pool_free(addr pool, (if absent: nil else: addr pnodes[2]), count)
    doAssert assertions == @[if count == 0: 113.cint else: 114.cint]
    doAssert pool == before and pnodes == links
''',
    "list_valid": r'''
setup()
co_list_init(addr list)
co_list_push_back(addr list, addr nodes[1])
co_list_push_front(addr list, addr nodes[0])
co_list_push_back(addr list, addr nodes[2])
doAssert list.first == (addr nodes[0]) and list.last == (addr nodes[2])
co_list_extract(addr list, addr nodes[1])
doAssert nodes[0].next == (addr nodes[2])
co_list_remove(addr list, addr nodes[0], addr nodes[2])
doAssert nodes[0].next == nil and nodes[2].next == nil
doAssert list.last == (addr nodes[0])
doAssert co_list_pop_front(addr list) == (addr nodes[0])
doAssert list.first == nil and list.last == (addr nodes[0])
co_list_push_back(addr list, addr nodes[3])
co_list_extract(addr list, addr nodes[3])
doAssert list.first == nil and list.last == (addr nodes[3])
co_list_push_front(addr list, addr nodes[1])
co_list_remove(addr list, nil, addr nodes[1])
doAssert list.first == nil and nodes[1].next == nil
doAssert assertions.len == 0
''',
    "dlist_valid": r'''
setup()
co_dlist_init(addr dlist)
co_dlist_push_back(addr dlist, addr dnodes[1])
co_dlist_push_front(addr dlist, addr dnodes[0])
co_dlist_push_back(addr dlist, addr dnodes[2])
co_dlist_extract(addr dlist, addr dnodes[1])
doAssert dnodes[0].next == (addr dnodes[2]) and dnodes[2].prev == (addr dnodes[0])
doAssert dlist.elementCount == 2
co_dlist_extract(addr dlist, addr dnodes[2])
doAssert dlist.last == (addr dnodes[0]) and dnodes[0].next == nil
doAssert co_dlist_pop_front(addr dlist) == (addr dnodes[0])
doAssert dlist == default(CoDlist)
co_dlist_push_front(addr dlist, addr dnodes[3])
co_dlist_extract(addr dlist, addr dnodes[3])
doAssert dlist == default(CoDlist) and assertions.len == 0
''',
    "pool_valid": r'''
for count in 1'u32 .. 4'u32:
  setup()
  let data = payload
  co_pool_init(addr pool, addr pnodes[0], addr payload[0], 8, count)
  doAssert pool.first == (addr pnodes[0]) and pool.freeNodeCount == count
  for i in 0 ..< count.int:
    doAssert pnodes[i].element == (addr payload[2 * i])
    doAssert pnodes[i].next == (if i + 1 < count.int: addr pnodes[i + 1] else: nil)
  doAssert payload == data
  let links = pnodes
  doAssert co_pool_alloc(addr pool, count + 1) == nil
  doAssert pnodes == links and pool.freeNodeCount == count
  let first = co_pool_alloc(addr pool, 1)
  doAssert first == (addr pnodes[0]) and pnodes[0].next == nil
  let rest = if count > 1: co_pool_alloc(addr pool, count - 1) else: nil
  doAssert pool.first == nil and pool.freeNodeCount == 0
  doAssert co_pool_alloc(addr pool, 1) == nil
  co_pool_free(addr pool, first, 1)
  if rest != nil: co_pool_free(addr pool, rest, count - 1)
  doAssert pool.freeNodeCount == count
  let combined = cast[ptr CoPoolNode](co_pool_alloc(addr pool, count))
  var node = combined
  var seen: seq[pointer]
  while node != nil:
    doAssert cast[pointer](node) notin seen and seen.len < count.int
    seen.add(cast[pointer](node))
    node = node.next
  doAssert seen.len == count.int and pool.first == nil and payload == data
  doAssert assertions.len == 0
''',
    "assertion_reentry": r'''
for operation in 0 .. 7:
  setup()
  dlist.first = nil
  assertionHook = proc() =
    list = CoList(first: addr nodes[3], last: addr nodes[3])
    nodes[3].next = nil
    dlist = CoDlist(first: addr dnodes[3], last: addr dnodes[3], elementCount: 1)
    dnodes[3] = default(CoDlistHdr)
    pool = CoPool(first: addr pnodes[3], freeNodeCount: 1)
    pnodes[3].next = nil
  case operation
  of 0: co_list_push_back(addr list, nil)
  of 1: co_list_push_front(addr list, nil)
  of 2: co_list_extract(nil, addr nodes[0])
  of 3: co_list_remove(addr list, addr nodes[0], addr nodes[2])
  of 4: co_dlist_extract(addr dlist, addr dnodes[1])
  of 5: co_pool_init(addr pool, addr pnodes[0], addr payload[0], 7, 1)
  of 6: doAssert co_pool_alloc(addr pool, 0) == nil
  else: co_pool_free(addr pool, addr pnodes[0], 0)
  doAssert assertions.len == 1
  doAssert list.first == (addr nodes[3]) and list.last == (addr nodes[3])
  doAssert nodes[3].next == nil
  doAssert dlist.first == (addr dnodes[3]) and dlist.last == (addr dnodes[3])
  doAssert dlist.elementCount == 1 and dnodes[3] == default(CoDlistHdr)
  doAssert pool.first == (addr pnodes[3]) and pool.freeNodeCount == 1
  doAssert pnodes[3].next == nil
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_list_pool_contract(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rx_ready_queue_uses_list_contract(tmp_path: Path, mode: str) -> None:
    code = rx_timer_source()
    actual = procedure((FW / "kernel_mac_channel.nim").read_text(), "co_list_push_back")
    code = code.replace(procedure(code, "co_list_push_back"), actual, 1)
    code = ("proc assert_err(condition, file: cstring; line: cint) =\n"
            "  doAssert false, \"unexpected list assertion\"\n" + code)
    run_program(tmp_path, mode, code + r'''
for incoming in [false, true]:
  for staleTail in [false, true]:
    for cycle in [false, true]:
      setupTimer()
      interrupts = incoming
      let stale = addr rxSwTableDescAt(3).link
      if staleTail:
        env.queue.last = stale
        stale.next = cast[ptr CoListHdr](1)
      prepareReady(1)
      rxHeaderHwDescAt(0).next = rxHeaderHwDescAt(1)
      rxHeaderHwDescAt(1).next =
        if cycle: cast[pointer](rxHeaderHwDescAt(1)) else: cast[pointer](1)
      env.submittedHead = rxHeaderHwDescAt(0)
      rxl_timer_int_handler()
      doAssert assertions == @[193] and assertIrqs == @[false]
      doAssert queued() == @[cast[pointer](addr rxSwTableDescAt(0).link)]
      doAssert env.queue.last == (addr rxSwTableDescAt(0).link)
      doAssert env.submittedHead == rxHeaderHwDescAt(1)
      doAssert events == 0x00100000'u32 and channelReads == 1
      doAssert interrupts == incoming
      if staleTail: doAssert stale.next == cast[ptr CoListHdr](1)
''')
