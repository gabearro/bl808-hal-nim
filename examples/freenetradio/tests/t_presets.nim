## Host tests for the preset store (`presets.nim`) on a RAM flash.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_presets.nim

import std/strutils
import ../presets, ../flashdev, ../board, ../timebase, ../text
import ./ramflash

const
  MarkerAt = PresetMarkerSector * FlashSector
  DefaultNames = ["Groove Salad", "Drone Zone", "DEF CON Radio", "Secret Agent", "Lush",
                  "Indie Pop Rocks", "Space Station", "Deep Space One", "Beat Blender",
                  "Underground 80s"]
  DefaultStreams = ["groovesalad", "dronezone", "defcon", "secretagent", "lush", "indiepop",
                    "spacestation", "deepspaceone", "beatblender", "u80s"]

proc slotAt(index: int): int = (PresetFirstSector + index) * FlashSector

proc fnv(bytes: openArray[byte]): uint32 =
  result = 0x811C_9DC5'u32
  for b in bytes: result = (result xor b.uint32) * 0x0100_0193'u32

proc record(name, url: string): seq[byte] =
  ## A slot page built from upstream's layout, independently of presets.nim.
  result = newSeq[byte](256)
  result[0] = 'N'.byte; result[1] = 'R'.byte; result[2] = 'S'.byte; result[3] = '1'.byte
  result[8] = name.len.byte
  result[9] = url.len.byte
  for i, c in name: result[12 + i] = c.byte
  for i, c in url: result[44 + i] = c.byte
  let sum = fnv(result.toOpenArray(8, 255))
  for i in 0 .. 3: result[4 + i] = byte((sum shr (8 * i)) and 0xFF)

proc put(f: RamFlash; at: int; bytes: openArray[byte]) =
  for i, b in bytes: f.mem[at + i] = b

proc isDefaults(): bool =
  for i in 0 ..< Slots:
    let p = get(i)
    if i < 10:
      if $p.name != DefaultNames[i] or
          $p.url != "http://ice1.somafm.com/" & DefaultStreams[i] & "-128-mp3": return false
    elif not p.isEmpty or p.name.len != 0: return false
  true

proc run(maxPolls = 10_000): int =
  ## Pump the job as the controls task does (every 5 ms); returns the ms it took.
  let t0 = nowMs()
  var polls = 0
  while busy():
    advanceFakeTimeMs(5)
    presets.poll()
    inc polls
    doAssert polls < maxPolls
  int(nowMs() - t0)

proc save(index: int; name, url: string): string =
  result = startSave(index, name, url)
  if result.len == 0:
    discard run()
    result = lastError()

block: # before init and with no flash: the built-in list
  doAssert isDefaults() and not busy() and generation() == 0
  doAssert startSave(0, "a", "b") == "Flash busy"
  doAssert startReset() == "Flash busy"
  presetsInit(FlashDev())
  doAssert isDefaults()
  doAssert find("http://ice1.somafm.com/lush-128-mp3") == 4
  doAssert find("") == -1 and find("http://nope/") == -1
  doAssert get(-1).isEmpty and get(99).isEmpty
  doAssert startSave(99, "a", "b") == "No such preset" and startSave(-1, "a", "b") == "No such preset"
  doAssert startSave(3, "a", "b") == ""       # starts, then finds it cannot write
  doAssert busy()
  discard run()
  doAssert lastError() == "Flash busy" and isDefaults()

block: # blank flash: defaults; the first save writes slots 1..10 then the marker
  setFakeTimeUs(5_000_000)
  let f = newRamFlash()
  presetsInit(f.dev)
  doAssert isDefaults()
  let gen0 = generation()
  doAssert startSave(2, "My Station", "http://my.example/stream") == ""
  doAssert busy()
  # Until the marker is there, the defaults still show.
  var polls = 0
  while busy():
    advanceFakeTimeMs(5)
    presets.poll()
    inc polls
    if busy(): doAssert isDefaults()
    # One page at most per poll.
    doAssert f.programs <= polls
  doAssert lastError() == ""
  doAssert f.programs == 11 and f.erases == 11
  # Ten slot writes 50 ms apart, then the marker: about half a second.
  let ms = polls * 5
  doAssert ms >= 500 and ms <= 560, $ms
  doAssert generation() == gen0 + 11
  for i in 0 ..< 10:
    let p = get(i)
    if i == 2:
      doAssert $p.name == "My Station" and $p.url == "http://my.example/stream"
    else:
      doAssert $p.name == DefaultNames[i]
  for i in 10 ..< Slots: doAssert get(i).isEmpty
  # Byte for byte upstream's pages.
  doAssert f.mem[slotAt(2) ..< slotAt(2) + 256] == record("My Station", "http://my.example/stream")
  doAssert f.mem[slotAt(0) ..< slotAt(0) + 256] ==
    record("Groove Salad", "http://ice1.somafm.com/groovesalad-128-mp3")
  var marker = newSeq[byte](256)
  marker[0] = 'N'.byte; marker[1] = 'R'.byte; marker[2] = 'P'.byte; marker[3] = 'M'.byte
  doAssert f.mem[MarkerAt ..< MarkerAt + 256] == marker
  doAssert find("http://my.example/stream") == 2
  doAssert find("http://ice1.somafm.com/defcon-128-mp3") == -1

  # Later saves touch one sector only.
  doAssert save(57, "Fifty-eight", "https://x.example/a?b=c") == ""
  doAssert f.programs == 12 and f.erases == 12 and f.sectorErases[PresetFirstSector + 57] == 1
  doAssert $get(57).name == "Fifty-eight" and find("https://x.example/a?b=c") == 57
  # Saving again erases that sector again and nothing else.
  doAssert save(57, "58", "http://x.example/2") == ""
  doAssert f.sectorErases[PresetFirstSector + 57] == 2 and f.erases == 13
  doAssert $get(57).url == "http://x.example/2"
  # An empty URL clears the slot (upstream keeps the name in the record).
  doAssert save(57, "kept", "") == ""
  doAssert get(57).isEmpty and f.mem[slotAt(57) ..< slotAt(57) + 256] == record("kept", "")
  # It survives a reboot.
  presetsInit(f.dev)
  doAssert $get(2).name == "My Station" and $get(0).name == "Groove Salad" and get(57).isEmpty

  # Reset: the marker goes, then every written slot above 10 is wiped.
  doAssert save(10, "Eleven", "http://eleven/") == ""
  doAssert save(98, "Last", "http://last/") == ""
  let erasesBefore = f.erases
  doAssert startReset() == ""
  presets.poll()
  doAssert isDefaults()                   # from the first page on
  let took = run()
  doAssert lastError() == "" and isDefaults()
  # Marker + slots 11, 58 (cleared but still a record) and 99.
  doAssert f.erases == erasesBefore + 4
  doAssert took >= 150 and took <= 170, $took
  for i in [10, 57, 98]:
    doAssert f.mem[slotAt(i) ..< slotAt(i) + 256] == newSeq[byte](256)
  doAssert f.mem[MarkerAt ..< MarkerAt + 256] == newSeq[byte](256)
  # Slots 1..10 are left as they were (and ignored).
  doAssert f.mem[slotAt(2) ..< slotAt(2) + 256] == record("My Station", "http://my.example/stream")
  presetsInit(f.dev)
  doAssert isDefaults()
  # A reset with nothing saved does nothing.
  let e2 = f.erases
  doAssert startReset() == ""
  discard run()
  doAssert f.erases == e2 and lastError() == ""
  # The next first save rewrites the defaults over the old slot 3.
  doAssert save(0, "One", "http://one/") == ""
  doAssert $get(0).name == "One" and $get(2).name == "DEF CON Radio" and get(10).isEmpty

block: # first save of a slot above the defaults: that slot first, then 1..10, then the marker
  let f = newRamFlash()
  presetsInit(f.dev)
  doAssert startSave(20, "Twenty-one", "http://21/") == ""
  presets.poll()
  doAssert f.programs == 1 and f.sectorErases[PresetFirstSector + 20] == 1
  presets.poll()                          # no pause after it
  doAssert f.programs == 2 and f.sectorErases[PresetFirstSector] == 1
  discard run()
  doAssert f.programs == 12 and lastError() == ""
  doAssert $get(20).name == "Twenty-one" and $get(9).name == "Underground 80s"

block: # limits and odd bytes
  let f = newRamFlash()
  presetsInit(f.dev)
  let longName = repeat('n', 40)
  let longUrl = "http://" & repeat('u', 300)
  doAssert save(5, longName, longUrl) == ""
  doAssert $get(5).name == repeat('n', NameMax) and $get(5).url == longUrl[0 ..< UrlMax]
  doAssert f.mem[slotAt(5) ..< slotAt(5) + 256] == record(longName[0 ..< 32], longUrl[0 ..< 212])
  # Stored as given, shown as printable ASCII.
  doAssert save(6, "Caf\xC3\xA9\tRadio", "http://h/\xFFx") == ""
  doAssert f.mem[slotAt(6) + 12 ..< slotAt(6) + 12 + 11] == cast[seq[byte]]("Caf\xC3\xA9\tRadio")
  doAssert $get(6).name == "Caf? Radio" and $get(6).url == "http://h/?x"
  # A record written by upstream's code reads back, length bytes clamped.
  var pg = record("Up", "http://up/")
  f.put(slotAt(30), pg)
  pg = record("x", "y")
  pg[8] = 200
  pg[9] = 255
  let sum = fnv(pg.toOpenArray(8, 255))
  for i in 0 .. 3: pg[4 + i] = byte((sum shr (8 * i)) and 0xFF)
  f.put(slotAt(31), pg)
  presetsInit(f.dev)
  doAssert $get(30).name == "Up" and $get(30).url == "http://up/"
  doAssert get(31).name.len == NameMax and get(31).url.len == UrlMax

block: # corrupt records read as empty
  let f = newRamFlash()
  presetsInit(f.dev)
  doAssert save(0, "One", "http://one/") == ""
  f.mem[slotAt(1) + 50] = f.mem[slotAt(1) + 50] xor 1       # payload
  f.mem[slotAt(2) + 4] = f.mem[slotAt(2) + 4] xor 0x80      # checksum
  f.mem[slotAt(3)] = 'X'.byte                               # magic
  presetsInit(f.dev)
  doAssert $get(0).name == "One"
  doAssert get(1).isEmpty and get(2).isEmpty and get(3).isEmpty
  doAssert get(1).name.len == 0
  doAssert $get(4).name == "Lush"
  # A damaged marker means "not saved": back to the defaults.
  f.mem[MarkerAt + 3] = 0
  presetsInit(f.dev)
  doAssert isDefaults()

block: # write failures
  let f = newRamFlash()
  presetsInit(f.dev)
  doAssert save(0, "One", "http://one/") == ""
  f.failProgram = true
  doAssert save(1, "Two", "http://two/") == "Flash write failed"
  doAssert get(1).isEmpty and $get(0).name == "One"       # only that slot is lost
  f.failProgram = false
  f.failVerify = true
  doAssert save(2, "Three", "http://three/") == "Flash verify failed"
  f.failVerify = false
  f.failErase = true
  doAssert save(3, "Four", "http://four/") == "Flash write failed"
  doAssert startReset() == ""
  discard run()
  doAssert lastError() == "Flash write failed"
  f.failErase = false
  doAssert not busy() and save(1, "Two", "http://two/") == "" and $get(1).name == "Two"
  # A failure part-way through the first save stops it: no marker.
  let g = newRamFlash()
  presetsInit(g.dev)
  doAssert startSave(0, "One", "http://one/") == ""
  for _ in 0 ..< 30:
    advanceFakeTimeMs(5)
    presets.poll()
  g.failProgram = true
  discard run()
  doAssert lastError() == "Flash write failed" and isDefaults()
  g.failProgram = false
  doAssert save(0, "One", "http://one/") == "" and $get(0).name == "One"

block: # power cuts at every point of a first save
  var cuts = 0
  for bytes in [0, 1, 7, 100, 255, 2000]:
    var op = 0
    while true:
      let f = newRamFlash()
      presetsInit(f.dev)
      f.cutAt(op, bytes)
      let error = save(12, "Thirteen", "http://13/")
      if not f.dead:
        doAssert error == "" and op == 24     # 12 erases + 12 programs
        break
      doAssert error == "Flash write failed"
      inc cuts
      f.powerOn()
      presetsInit(f.dev)
      # Either the marker made it (everything before it was written and
      # verified) or the built-in list shows: never a half-written set.
      if f.mem[MarkerAt] == 'N'.byte and f.mem[MarkerAt + 3] == 'M'.byte:
        doAssert op == 23 and bytes >= 4
        doAssert $get(12).name == "Thirteen" and $get(9).name == "Underground 80s"
      else:
        doAssert isDefaults()
      # And saving again works.
      doAssert save(12, "Thirteen", "http://13/") == ""
      doAssert $get(12).name == "Thirteen" and $get(0).name == "Groove Salad"
      inc op
  doAssert cuts == 6 * 24

block: # power cuts during a later save and during a reset
  for bytes in [0, 3, 9, 200, 3000]:
    for op in 0 .. 1:
      let f = newRamFlash()
      presetsInit(f.dev)
      doAssert save(4, "Old", "http://old/") == ""
      doAssert save(40, "Other", "http://other/") == ""
      f.cutAt(op, bytes)
      doAssert save(4, "New", "http://new/") == "Flash write failed"
      f.powerOn()
      presetsInit(f.dev)
      # Slot 5 is the old one, empty, or (cut after the last byte went in)
      # the new one; nothing else changed.
      if op == 0 and bytes == 0: doAssert $get(4).name == "Old"
      elif op == 1 and bytes >= 256: doAssert $get(4).name == "New"
      else: doAssert get(4).isEmpty
      doAssert $get(3).name == "Secret Agent" and $get(5).name == "Indie Pop Rocks"
      doAssert $get(40).url == "http://other/"
    for op in 0 .. 5:
      let f = newRamFlash()
      presetsInit(f.dev)
      doAssert save(4, "Mine", "http://mine/") == ""
      doAssert save(40, "A", "http://a/") == ""
      doAssert save(41, "B", "http://b/") == ""
      f.cutAt(op, bytes)
      doAssert startReset() == ""
      discard run()
      doAssert f.dead and lastError() == "Flash write failed"
      f.powerOn()
      presetsInit(f.dev)
      if f.mem[MarkerAt] == 'N'.byte and f.mem[MarkerAt + 1] == 'R'.byte and
          f.mem[MarkerAt + 2] == 'P'.byte and f.mem[MarkerAt + 3] == 'M'.byte:
        doAssert op == 0 and bytes < 4 and $get(4).name == "Mine" and $get(41).name == "B"
      else:
        doAssert isDefaults()
        # Finishing the reset later leaves nothing to come back.
        doAssert startReset() == ""
        discard run()
        doAssert lastError() == ""
        doAssert save(0, "One", "http://one/") == ""
        for i in 10 ..< Slots: doAssert get(i).isEmpty

block: # jobs started while another runs wait their turn, each with its own result
  setFakeTimeUs(9_000_000)
  let f = newRamFlash()
  presetsInit(f.dev)
  var error = "?"
  doAssert finished(0, error) and error == ""           # no job
  # A first save (eleven sectors), a second save and a reset, all at once.
  doAssert startSave(0, "One", "http://one/") == ""
  let first = ticket()
  doAssert startSave(11, "Twelve", "http://twelve/") == ""
  let second = ticket()
  doAssert second == first + 1 and busy()
  doAssert not finished(first, error) and not finished(second, error)
  # The first runs alone: the second has not touched flash when it ends.
  while not finished(first, error):
    advanceFakeTimeMs(5)
    presets.poll()
  doAssert error == "" and f.programs == 11 and busy()
  doAssert $get(0).name == "One" and get(11).isEmpty
  doAssert not finished(second, error)
  # The second is then an ordinary one-sector save (the marker is there now).
  discard run()
  doAssert finished(second, error) and error == "" and f.programs == 12
  doAssert $get(11).name == "Twelve" and $get(0).name == "One" and $get(1).name == "Drone Zone"

  # Each job keeps its own result, whatever ran after it.
  f.failProgram = true
  doAssert startSave(1, "Two", "http://two/") == ""
  let failing = ticket()
  discard run()
  f.failProgram = false
  doAssert startSave(2, "Three", "http://three/") == ""
  let working = ticket()
  discard run()
  doAssert lastError() == ""
  doAssert finished(failing, error) and error == "Flash write failed"
  doAssert finished(working, error) and error == ""

  # A save asked for during a reset lands after it: it is a first save again.
  doAssert startReset() == ""
  let resetJob = ticket()
  doAssert startSave(20, "Twenty-one", "http://21/") == ""
  let afterReset = ticket()
  while not finished(resetJob, error):
    advanceFakeTimeMs(5)
    presets.poll()
  doAssert error == "" and isDefaults() and not finished(afterReset, error)
  discard run()
  doAssert finished(afterReset, error) and error == ""
  doAssert $get(20).name == "Twenty-one" and $get(0).name == "Groove Salad" and get(11).isEmpty

  # The queue is bounded: a job too many is refused with upstream's message.
  for i in 0 ..< 4:
    doAssert startSave(30 + i, "q", "http://q/") == ""
  let newest = ticket()
  doAssert startSave(40, "q", "http://q/") == "Flash busy" and startReset() == "Flash busy"
  doAssert ticket() == newest
  discard run()
  doAssert finished(newest, error) and error == "" and $get(33).url == "http://q/"
  doAssert get(40).isEmpty

echo "t_presets: ok"
