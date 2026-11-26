## Station presets, slots 1..99, kept in flash so they survive power-off
## (upstream `src/presets.rs`). Pure Nim over `flashdev.FlashDev`.
##
## Each slot is one 256-byte record: a magic number, checksum, name (<= 32)
## and URL (<= 212), byte for byte as upstream. Here every record sits at
## the start of its own 4 KB sector (the erase unit), so saving one slot
## never touches the others; a marker record in a sector of its own means
## "use the saved slots" (layout in `board.nim`).
##
## Without the marker (a new board, or after "reset to defaults") the
## built-in list fills slots 1..10 and the rest are empty. The first save
## writes slots 1..10, then the marker, so a power cut mid-save leaves the
## defaults rather than a half-written set. A slot with a bad checksum (or
## never written: erased flash) reads as empty.
##
## Upstream reads slots straight from memory-mapped flash; here they are
## read once at boot into a RAM mirror on the heap, which every write
## updates. Upstream's `save` / `reset` are async (they pause 50 ms between
## flash pages so the audio buffer stays fed). Here they are jobs: start
## one, keep its `ticket()`, then watch `finished(ticket, error)`; `poll()`
## (called from the controls task) does one page at a time. A job started
## while another runs waits its turn (upstream accepts overlapping saves
## too: each web task runs its own), so two requests in quick succession
## both take effect, in the order they came.

import ./text, ./timebase, ./board, ./flashdev

const
  Slots* = 99
  NameMax* = 32
  UrlMax* = 212

  BaseSlots = 10
    ## Slots with built-in defaults.
  PauseMs = 50
    ## Between sector writes: each blocks for tens of milliseconds, and the
    ## audio task has to top its buffer back up in between.
  QueueLen = 4
    ## Jobs accepted at a time, the running one included: more than there
    ## are web connections to ask for them.
  ResultSlots = 8
    ## Finished jobs whose result is kept for `finished`.

  SlotMagic = ['N'.byte, 'R'.byte, 'S'.byte, '1'.byte]
  MarkerMagic = ['N'.byte, 'R'.byte, 'P'.byte, 'M'.byte]

  # Slot record layout.
  OffChecksum = 4
  OffNameLen = 8
  OffUrlLen = 9
  OffName = 12
  OffUrl = OffName + NameMax

  Defaults: array[BaseSlots, tuple[name, url: string]] = [
    ## Built-in stations (all checked to serve 128 kbit/s MP3 over plain http).
    ("Groove Salad", "http://ice1.somafm.com/groovesalad-128-mp3"),
    ("Drone Zone", "http://ice1.somafm.com/dronezone-128-mp3"),
    ("DEF CON Radio", "http://ice1.somafm.com/defcon-128-mp3"),
    ("Secret Agent", "http://ice1.somafm.com/secretagent-128-mp3"),
    ("Lush", "http://ice1.somafm.com/lush-128-mp3"),
    ("Indie Pop Rocks", "http://ice1.somafm.com/indiepop-128-mp3"),
    ("Space Station", "http://ice1.somafm.com/spacestation-128-mp3"),
    ("Deep Space One", "http://ice1.somafm.com/deepspaceone-128-mp3"),
    ("Beat Blender", "http://ice1.somafm.com/beatblender-128-mp3"),
    ("Underground 80s", "http://ice1.somafm.com/u80s-128-mp3"),
  ]

static: doAssert OffUrl + UrlMax == FlashPage

type
  Preset* = object
    name*: Text[NameMax]
    url*: Text[UrlMax]

  Page = array[FlashPage, byte]

  JobKind = enum
    jkNone, jkSave, jkFirstSave, jkReset

  Ticket* = uint32
    ## Names one accepted job, counting from 1 (0 is "no job").

  Request = object
    ## A save (or, with `reset`, a reset) waiting for its turn.
    reset: bool
    index: int                        # the slot to save
    nameLen, urlLen: int
    name: array[NameMax, char]
    url: array[UrlMax, char]

  Store = object
    dev: FlashDev
    markerSet: bool                   # the marker record is present
    written: array[Slots, bool]       # the slot's page starts with the slot magic
    saved: array[Slots, Preset]       # what each slot's page decodes to
    generation: uint32
    lastError: string
    job: JobKind                      # what `queue[head]` is doing; jkNone = not begun
    step: int                         # where the running job has got to
    nextAtMs: uint64                  # not before this
    queue: array[QueueLen, Request]   # ring: `count` jobs from `head`, oldest first
    head, count: int
    accepted: Ticket                  # the newest job's ticket
    results: array[ResultSlots, tuple[ticket: Ticket, error: string]]
    page: Page                        # scratch for the record being written

var store: ptr Store

func isEmpty*(p: Preset): bool {.inline.} = p.url.isEmpty

func checksum*(bytes: openArray[byte]): uint32 =
  ## FNV-1a.
  result = 0x811C_9DC5'u32
  for b in bytes:
    result = (result xor b.uint32) * 0x0100_0193'u32

func getLe32(p: openArray[byte]; at: int): uint32 =
  p[at].uint32 or (p[at + 1].uint32 shl 8) or (p[at + 2].uint32 shl 16) or
    (p[at + 3].uint32 shl 24)

func putLe32(p: var openArray[byte]; at: int; v: uint32) =
  for i in 0 .. 3:
    p[at + i] = byte((v shr (8 * i)) and 0xFF)

func slotOffset(index: int): uint32 = sectorOffset(PresetFirstSector + index)
const MarkerOffset = uint32(PresetMarkerSector * FlashSector)

func decode(pg: Page; written: var bool): Preset =
  ## The preset in a slot page; empty if it is corrupt or was never written.
  written = pg.toOpenArray(0, 3) == SlotMagic
  if not written or getLe32(pg, OffChecksum) != checksum(pg.toOpenArray(OffNameLen, FlashPage - 1)):
    return
  let nameLen = min(pg[OffNameLen].int, NameMax)
  let urlLen = min(pg[OffUrlLen].int, UrlMax)
  if nameLen > 0: result.name.addSanitized pg.toOpenArray(OffName, OffName + nameLen - 1)
  if urlLen > 0: result.url.addSanitized pg.toOpenArray(OffUrl, OffUrl + urlLen - 1)

func encode(pg: var Page; name, url: openArray[char]) =
  zeroMem(addr pg, sizeof(pg))
  let nameLen = min(name.len, NameMax)
  let urlLen = min(url.len, UrlMax)
  for i in 0 .. 3: pg[i] = SlotMagic[i]
  pg[OffNameLen] = nameLen.byte
  pg[OffUrlLen] = urlLen.byte
  for i in 0 ..< nameLen: pg[OffName + i] = name[i].byte
  for i in 0 ..< urlLen: pg[OffUrl + i] = url[i].byte
  putLe32(pg, OffChecksum, checksum(pg.toOpenArray(OffNameLen, FlashPage - 1)))

proc presetsInit*(dev: FlashDev) =
  ## Load the saved slots from flash. Call once at boot, before anything
  ## reads a preset. (Until then, and with no flash, the built-in list
  ## shows.)
  if store == nil:
    store = createShared(Store)
  zeroMem(store, sizeof(Store))      # in place: a Store is too big for the stack
  store.dev = dev
  if not dev.ready: return
  dev.read(dev.ctx, MarkerOffset, store.page)
  store.markerSet = store.page.toOpenArray(0, 3) == MarkerMagic
  for i in 0 ..< Slots:
    dev.read(dev.ctx, slotOffset(i), store.page)
    store.saved[i] = decode(store.page, store.written[i])

proc savedInUse(): bool {.inline.} = store != nil and store.markerSet

proc get*(index: int): Preset =
  ## Preset `index` (0-based); empty if out of range, cleared or corrupt.
  if index < 0 or index >= Slots: return
  if savedInUse():
    result = store.saved[index]
  elif index < BaseSlots:
    result.name.add Defaults[index].name
    result.url.add Defaults[index].url

proc find*(url: openArray[char]): int =
  ## The slot whose URL is `url`, or -1.
  if url.len == 0: return -1
  for i in 0 ..< Slots:
    if savedInUse():
      if store.saved[i].url == url: return i
    elif i < BaseSlots and url == Defaults[i].url:
      return i
  -1

proc generation*(): uint32 =
  ## Bumped whenever presets change, so cached lookups refresh.
  if store != nil: store.generation else: 0

proc busy*(): bool =
  ## A save or reset is running or waiting.
  store != nil and store.count > 0

proc lastError*(): string =
  ## How the most recently finished job ended: "" for success, else
  ## upstream's message ("Flash busy", "Flash write failed", "Flash verify
  ## failed").
  if store != nil: store.lastError else: ""

proc ticket*(): Ticket =
  ## The job the last successful `startSave` / `startReset` began.
  if store != nil: store.accepted else: 0

proc finished*(ticket: Ticket; error: var string): bool =
  ## Whether job `ticket` is over, and how it ended (as `lastError`).
  error = ""
  if store == nil or ticket == 0: return true
  # The jobs still in the queue hold the newest `count` tickets.
  if store.accepted - ticket < store.count.Ticket: return false
  let kept = store.results[ticket mod ResultSlots]
  if kept.ticket == ticket: error = kept.error
  true

proc accept(): ptr Request =
  ## The queue entry for one more job, or nil when the queue is full.
  if store == nil or store.count == QueueLen: return nil
  result = addr store.queue[(store.head + store.count) mod QueueLen]
  inc store.count
  inc store.accepted

proc startSave*(index: int; name, url: openArray[char]): string =
  ## Begin saving preset `index` (0-based; an empty URL clears it), after
  ## any job already accepted. Returns "" if it was accepted (see `ticket`),
  ## else why not ("No such preset", "Flash busy").
  if index < 0 or index >= Slots: return "No such preset"
  let r = accept()
  if r == nil: return FlashBusy
  r.reset = false
  r.index = index
  r.nameLen = min(name.len, NameMax)
  r.urlLen = min(url.len, UrlMax)
  for i in 0 ..< r.nameLen: r.name[i] = name[i]
  for i in 0 ..< r.urlLen: r.url[i] = url[i]
  ""

proc startReset*(): string =
  ## Begin going back to the built-in list: erase the marker, then wipe any
  ## saved slots 11..99 so they don't reappear after the next save.
  ## Returns "" (see `ticket`) or "Flash busy".
  let r = accept()
  if r == nil: return FlashBusy
  r.reset = true
  ""

proc writeRecord(offset: uint32): string =
  ## Erase the sector at `offset` and write `store.page` at its start.
  result = writePage(store.dev, offset, store.page, erase = true)
  inc store.generation

proc writeSlot(index: int): string =
  result = writeRecord(slotOffset(index))
  if result.len == 0:
    store.saved[index] = decode(store.page, store.written[index])
  else:
    # What is there now is not known to be a record: it reads as empty,
    # and the next boot looks again.
    store.saved[index] = Preset()
    store.written[index] = false

proc writeMarker(present: bool): string =
  zeroMem(addr store.page, sizeof(store.page))
  if present:
    for i in 0 .. 3: store.page[i] = MarkerMagic[i]
  result = writeRecord(MarkerOffset)
  if result.len == 0: store.markerSet = present
  elif present: store.markerSet = false

proc encodeOwn() =
  ## The record for the slot being saved, into `store.page`.
  let r = addr store.queue[store.head]
  encode(store.page,
         cast[ptr UncheckedArray[char]](addr r.name).toOpenArray(0, r.nameLen - 1),
         cast[ptr UncheckedArray[char]](addr r.url).toOpenArray(0, r.urlLen - 1))

proc finish(error: string) =
  ## The oldest job is over: keep its result and let the next one begin.
  let done = store.accepted - Ticket(store.count - 1)
  store.results[done mod ResultSlots] = (done, error)
  store.lastError = error
  store.job = jkNone
  store.head = (store.head + 1) mod QueueLen
  dec store.count

proc poll*() =
  ## Advance the oldest job by at most one flash page.
  if store == nil or store.count == 0: return
  if store.job == jkNone:
    # Its turn has come. Whether a save is the first one (copy the defaults
    # into slots 1..10, then the marker) depends on what ran before it.
    store.job = if store.queue[store.head].reset: jkReset
                elif store.markerSet: jkSave
                else: jkFirstSave
    store.step = 0
    store.nextAtMs = 0
  if nowMs() < store.nextAtMs: return
  let own = store.queue[store.head].index
  case store.job
  of jkNone: discard
  of jkSave:
    encodeOwn()
    finish writeSlot(own)
  of jkFirstSave:
    # Steps: 0 = the slot itself if it is above the defaults (those were
    # wiped by a reset, or never written), 1..10 = slots 1..10 with a pause
    # after each, 11 = the marker.
    if store.step == 0 and own < BaseSlots:
      store.step = 1
    if store.step > BaseSlots:
      finish writeMarker(present = true)
      return
    var error = ""
    if store.step == 0 or store.step - 1 == own:
      encodeOwn()
      error = writeSlot(own)
    else:
      encode(store.page, Defaults[store.step - 1].name, Defaults[store.step - 1].url)
      error = writeSlot(store.step - 1)
    if error.len > 0:
      finish error
      return
    if store.step > 0:
      store.nextAtMs = nowMs() + PauseMs
    inc store.step
  of jkReset:
    # Step 0 = the marker, then one written slot above the defaults per
    # call, with a pause after each.
    if store.step == 0:
      store.step = BaseSlots
      if store.markerSet:
        let error = writeMarker(present = false)
        if error.len > 0: finish error
        return
    while store.step < Slots and not store.written[store.step]:
      inc store.step
    if store.step >= Slots:
      finish ""
      return
    zeroMem(addr store.page, sizeof(store.page))
    let error = writeSlot(store.step)
    if error.len > 0:
      finish error
      return
    inc store.step
    store.nextAtMs = nowMs() + PauseMs
