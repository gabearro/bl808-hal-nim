## Remembers the user's settings across power cycles: the last station,
## volume and mute, whether it was playing, the clock, display and equaliser
## choices (upstream `src/settings.rs`). The radio comes back as it was
## left. Pure Nim over `flashdev.FlashDev`.
##
## Two kinds of 256-byte record, each in a ring of its own (`board.nim`):
## the settings (a small fixed record) and the station URL (up to 240
## characters). They're separate so a volume or EQ change doesn't rewrite
## the URL, and changing station doesn't rewrite the settings.
##
## Flash wear: saving on every button press would wear the flash out
## quickly while someone flicks through stations or holds volume-up.
## Instead:
##
##   - nothing is saved until the thing has stayed the same for 10 s, and
##     only if it differs from what's already saved, so a burst of changes
##     costs one write once it's over;
##   - each ring has 32 slots over two 4 KB sectors, every record carrying a
##     sequence number; the newest valid one wins at boot. A save programs
##     the next blank slot; a sector is erased only when the ring comes
##     round to it, while the other sector holds the newest record. So a
##     power cut mid-write loses nothing, and there are sixteen saves per
##     erase.
##
## Settings record (magic "NRC1"):
##
##   0 magic   4 sequence (u32 LE)   8 checksum (FNV-1a of 12..)
##   12 volume  13 muted  14 playing
##   15 UTC offset (i8, quarter hours)  16 DST enabled  17 status bar info
##   18 bit 0: hide the clock on the dimmed screen; bits 1-2: visualiser
##   19 bass  20 mid  21 treble (i8, dB)  22 EQ preset switcher entry
##   23 custom bass  24 custom mid  25 custom treble (i8, dB)
##
## URL record (magic "NRU1"):
##
##   0 magic   4 sequence   8 checksum (FNV-1a of the URL bytes)
##   12 URL length   16.. URL

import ./board, ./flashdev, ./timebase, ./status, ./prefs, ./diag, ./text

const
  SlotsPerSector = FlashSector div FlashPage
  RingSlots = RingSectors * SlotsPerSector
  SettingsMagic = ['N'.byte, 'R'.byte, 'C'.byte, '1'.byte]
  UrlMagic = ['N'.byte, 'R'.byte, 'U'.byte, '1'.byte]
  OffUrl = 16
  UrlMax* = FlashPage - OffUrl
  SettleMs = 10_000
    ## How long something must stay unchanged before it's saved.

static: doAssert RingSlots == 32

type
  Page = array[FlashPage, byte]

  Settings = object
    volume: uint8
    muted: bool
    playing: bool
    utcQh: int8               # time zone offset in quarter hours
    dst: bool
    info: uint8               # status bar contents (prefs.Info*)
    sleepClock: bool          # show the time on the dimmed idle screen
    visualiser: uint8         # meters / spectrum / cycle (prefs.Vis*)
    eq: array[3, int8]        # gains in dB: bass, mid, treble
    eqSelected: uint8         # the preset switcher's entry
    eqCustom: array[3, int8]  # the Custom preset's gains

  Ring = object
    ## One ring of record slots being saved to: where it is, what's saved,
    ## and what's waiting to settle.
    firstSector: int
    slot: int                 # the slot last written
    seq: uint32               # and its sequence number
    hasSaved: bool
    saved: uint32             # fingerprint of what's saved
    pending: uint32           # fingerprint seen last check
    changedAtMs: uint64       # since when it has been unchanged
    blank: uint32             # bit per slot: still erased, so programmable

  State = object
    dev: FlashDev
    cfg, url: Ring
    page: Page                # scratch for reading and building records

var st: State

func checksum[T: byte | char](bytes: openArray[T]): uint32 =
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

func slotOffset(r: Ring; slot: int): uint32 =
  sectorOffset(r.firstSector) + uint32(slot * FlashPage)

# ---- Settings records ---------------------------------------------------

proc currentSettings(): Settings =
  ## What should be remembered right now.
  Settings(
    volume: player.volume,
    muted: player.muted,
    # Stopped means the user stopped it. Anything else (including an
    # error) means they last asked for it to play.
    playing: not player.url.isEmpty and player.phase != phStopped,
    utcQh: offsetQh().int8,
    dst: dstEnabled(),
    info: statusInfo(),
    sleepClock: sleepClock(),
    visualiser: visualiser(),
    eq: eqGains(),
    eqSelected: eqSelected(),
    eqCustom: eqCustom(),
  )

func readSettings(pg: Page; seq: var uint32; s: var Settings): bool =
  ## The settings record in `pg`, if it's valid.
  if pg.toOpenArray(0, 3) != SettingsMagic or
      getLe32(pg, 8) != checksum(pg.toOpenArray(12, FlashPage - 1)):
    return false      # never written (erased flash), or corrupt
  func gain(b: byte): int8 = clamp(cast[int8](b), -EqMaxDb.int8, EqMaxDb.int8)
  s = Settings(
    volume: min(pg[12], 100),
    muted: pg[13] != 0,
    playing: pg[14] != 0,
    utcQh: clamp(cast[int8](pg[15]), MinOffsetQh.int8, MaxOffsetQh.int8),
    dst: pg[16] != 0,
    info: pg[17],
    sleepClock: (pg[18] and 1) == 0,
    visualiser: (pg[18] shr 1) and 3,
    eq: [gain(pg[19]), gain(pg[20]), gain(pg[21])],
    eqSelected: pg[22],
    eqCustom: [gain(pg[23]), gain(pg[24]), gain(pg[25])],
  )
  seq = getLe32(pg, 4)
  true

func encodeSettings(pg: var Page; s: Settings) =
  ## The record for `s`, sequence number left 0. Its checksum covers the
  ## settings but not the sequence, so it doubles as a fingerprint: equal
  ## checksums mean equal settings (near enough, for deciding to save).
  zeroMem(addr pg, sizeof(pg))
  for i in 0 .. 3: pg[i] = SettingsMagic[i]
  pg[12] = s.volume
  pg[13] = s.muted.byte
  pg[14] = s.playing.byte
  pg[15] = cast[byte](s.utcQh)
  pg[16] = s.dst.byte
  pg[17] = s.info
  pg[18] = (not s.sleepClock).byte or (s.visualiser shl 1)
  for i in 0 .. 2:
    pg[19 + i] = cast[byte](s.eq[i])
    pg[23 + i] = cast[byte](s.eqCustom[i])
  pg[22] = s.eqSelected
  putLe32(pg, 8, checksum(pg.toOpenArray(12, FlashPage - 1)))

proc settingsFingerprint(s: Settings): uint32 =
  encodeSettings(st.page, s)
  getLe32(st.page, 8)

# ---- URL records --------------------------------------------------------

func readUrl(pg: Page; seq: var uint32; url: var Text[UrlMax]): bool =
  ## The URL record in `pg`, if it's valid.
  let len = min(pg[12].int, UrlMax)
  if pg.toOpenArray(0, 3) != UrlMagic or
      getLe32(pg, 8) != checksum(cast[ptr UncheckedArray[byte]](unsafeAddr pg[OffUrl]).toOpenArray(0, len - 1)):
    return false
  url.clear()
  url.addSanitized cast[ptr UncheckedArray[byte]](unsafeAddr pg[OffUrl]).toOpenArray(0, len - 1)
  seq = getLe32(pg, 4)
  true

func encodeUrl(pg: var Page; url: openArray[char]) =
  ## The record for `url` (sequence left 0).
  zeroMem(addr pg, sizeof(pg))
  for i in 0 .. 3: pg[i] = UrlMagic[i]
  pg[12] = url.len.byte
  for i in 0 ..< url.len: pg[OffUrl + i] = url[i].byte
  putLe32(pg, 8, checksum(pg.toOpenArray(OffUrl, OffUrl + url.len - 1)))

# ---- Rings --------------------------------------------------------------

func isBlank(pg: Page): bool =
  for b in pg:
    if b != 0xFF: return false
  true

proc scan(r: var Ring; firstSector: int; isUrl: bool) =
  ## Find the newest valid record and which slots are still blank.
  r = Ring(firstSector: firstSector, slot: RingSlots - 1)
  if not st.dev.ready: return
  var cfg: Settings
  var url: Text[UrlMax]
  for slot in 0 ..< RingSlots:
    st.dev.read(st.dev.ctx, r.slotOffset(slot), st.page)
    if isBlank(st.page):
      r.blank = r.blank or (1'u32 shl slot)
      continue
    var seq: uint32
    let valid = if isUrl: readUrl(st.page, seq, url) else: readSettings(st.page, seq, cfg)
    # The highest sequence number wins (the later slot, if two are equal).
    if valid and (not r.hasSaved or seq >= r.seq):
      r.slot = slot
      r.seq = seq
      r.hasSaved = true
      r.saved = getLe32(st.page, 8)

proc track(r: var Ring; now: uint32) =
  ## Start watching: `now` is the current fingerprint.
  r.pending = now
  r.changedAtMs = nowMs()

proc store(r: var Ring): string =
  ## Write `st.page` (sequence already set) to the ring's next slot.
  # The next blank slot after the newest record. Coming round to the start
  # of a sector that isn't blank, erase it: the newest record is in the
  # other one. (A slot left non-blank by a failed write is skipped.)
  var slot = r.slot
  var erase = false
  for _ in 0 ..< RingSlots:
    slot = (slot + 1) mod RingSlots
    if (r.blank and (1'u32 shl slot)) != 0: break
    if slot mod SlotsPerSector == 0:
      erase = true
      break
  result = writePage(st.dev, r.slotOffset(slot), st.page, erase)
  if not st.dev.ready: return
  if erase:
    # The sector is blank again, unless the erase itself may have failed
    # (then it is tried again next time).
    let sectorMask = uint32((1 shl SlotsPerSector) - 1) shl slot
    if result == FlashWriteFailed: r.blank = r.blank and not sectorMask
    else: r.blank = r.blank or sectorMask
  r.blank = r.blank and not (1'u32 shl slot)
  if result.len == 0:
    r.slot = slot

proc tick(r: var Ring; now: uint32; isUrl: bool) =
  ## Call about once a second with the current fingerprint.
  if now != r.pending:
    r.pending = now
    r.changedAtMs = nowMs()
  elif not (r.hasSaved and r.saved == now) and
      elapsedMs(r.changedAtMs, nowMs()) >= SettleMs:
    if isUrl: encodeUrl(st.page, player.url.chars)
    else: encodeSettings(st.page, currentSettings())
    putLe32(st.page, 4, r.seq + 1)
    let error = store(r)
    if error.len == 0:
      r.seq += 1
      r.hasSaved = true
      r.saved = now
      inc stats.settingsSaves
    else:
      # No flash or a failed write: try again later rather than spinning
      # on it.
      inc stats.settingsFailures
      stats.settingsLastError = error
      r.changedAtMs = nowMs()

# ---- Startup and saving ---------------------------------------------------

proc settingsInit*(dev: FlashDev) =
  ## Find the newest records in flash. Call once at boot, before
  ## `settingsRestore`.
  st.dev = dev
  scan(st.cfg, SettingsRingSector, isUrl = false)
  scan(st.url, UrlRingSector, isUrl = true)

proc urlFingerprint(): uint32 =
  ## Of the URL to remember: the playing one, unless it's too long to store
  ## (a cut one wouldn't work).
  if player.url.len > 0 and player.url.len <= UrlMax: checksum(player.url.chars)
  else: checksum(default(array[0, byte]))

proc settingsRestore*() =
  ## Load the newest valid records into `prefs` and the player. Call after
  ## the flash store is up and before the stream task starts (it starts
  ## playing then if it was playing before).
  var cfg: Settings
  var url: Text[UrlMax]
  var seq: uint32
  var haveCfg, haveUrl = false
  if st.dev.ready:
    if st.cfg.hasSaved:
      st.dev.read(st.dev.ctx, st.cfg.slotOffset(st.cfg.slot), st.page)
      haveCfg = readSettings(st.page, seq, cfg)
    if st.url.hasSaved:
      st.dev.read(st.dev.ctx, st.url.slotOffset(st.url.slot), st.page)
      haveUrl = readUrl(st.page, seq, url)
  if haveCfg:
    setOffsetQh(cfg.utcQh.int)
    setDstEnabled(cfg.dst)
    setStatusInfo(cfg.info)
    setSleepClock(cfg.sleepClock)
    setVisualiser(cfg.visualiser)
    restoreEq(cfg.eq, cfg.eqSelected, cfg.eqCustom)
  if haveCfg or haveUrl:
    if haveCfg: status.restore($url, cfg.volume, cfg.muted, cfg.playing)
    else: status.restore($url, player.volume, false, false)
  # From here on, watch for changes (upstream's `save_task` starts here).
  track(st.cfg, settingsFingerprint(currentSettings()))
  track(st.url, urlFingerprint())

proc settingsTick*() =
  ## Call about once a second: saves what has been unchanged for 10 s and
  ## differs from what is stored.
  tick(st.cfg, settingsFingerprint(currentSettings()), isUrl = false)
  # An empty URL isn't worth saving over a real one (a failed play request
  # can clear it); only a non-empty change is remembered.
  if player.url.len > 0 and player.url.len <= UrlMax:
    tick(st.url, urlFingerprint(), isUrl = true)
