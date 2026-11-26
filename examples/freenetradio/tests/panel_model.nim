## A behavioural model of the SSD1322 as wired in the usual 256x64 modules,
## written from the controller's command table rather than from the driver:
## it takes bytes with the D/C level they were sent at, as the panel would,
## and keeps the display RAM. Used by `t_panel.nim` and `tools/pincheck.nim`.
##
## What it knows: how many argument bytes each command takes, the command
## lock, the address window and how RAM writes walk through it, the re-map
## bits, and where the 256 visible pixels sit in the 480-column RAM.

const
  RamCols = 120           ## column addresses; each holds 4 pixels (2 bytes)
  RamRows = 128
  VisibleFirstCol* = 0x1C ## 256-pixel panels use the middle of the RAM
  VisibleCols* = 64
  VisibleRows* = 64

type
  Panel* = object
    locked*: bool                 ## command lock (0xFD): only 0xFD is accepted
    on*: bool
    remap*: array[2, byte]
    muxRatio*: int
    startLine*, offset*: int
    colStart*, colEnd*, rowStart*, rowEnd*: int
    col, row, half: int           ## RAM write pointer; half = which byte of the column
    writing: bool
    cmd: byte
    need: int                     ## argument bytes still expected
    args: seq[byte]
    ram: array[RamRows, array[RamCols * 2, byte]]
    errors*: seq[string]
    commands*: int                ## commands completed
    ramBytes*: int                ## bytes written by the last 0x5C

func argCount(cmd: byte): int =
  ## Argument bytes per command (SSD1322 command table); -1 = not a command.
  case cmd
  of 0x15, 0x75, 0xA0, 0xB4, 0xD1: 2
  of 0xA1, 0xA2, 0xAB, 0xB1, 0xB3, 0xB5, 0xB6, 0xBB, 0xBE, 0xC1, 0xC7, 0xCA, 0xFD: 1
  of 0xB8: 15
  of 0x00, 0x5C, 0x5D, 0xA4, 0xA5, 0xA6, 0xA7, 0xA9, 0xAE, 0xAF, 0xB9: 0
  else: -1

proc initPanel*(): Panel =
  ## The state after the RES pulse.
  Panel(locked: false, muxRatio: 127, colEnd: RamCols - 1, rowEnd: RamRows - 1)

proc fail(p: var Panel; msg: string) = p.errors.add msg

proc apply(p: var Panel) =
  let a = p.args
  case p.cmd
  of 0xFD:
    if a[0] == 0x12: p.locked = false
    elif a[0] == 0x16: p.locked = true
    else: p.fail "0xFD with " & $a[0]
  of 0x15:
    if a[0] > a[1] or a[1].int >= RamCols: p.fail "column window " & $a
    p.colStart = a[0].int; p.colEnd = a[1].int
    p.col = p.colStart; p.half = 0
  of 0x75:
    if a[0] > a[1] or a[1].int >= RamRows: p.fail "row window " & $a
    p.rowStart = a[0].int; p.rowEnd = a[1].int
    p.row = p.rowStart
  of 0x5C:
    p.writing = true
    p.col = p.colStart; p.row = p.rowStart; p.half = 0
    p.ramBytes = 0
  of 0xA0: p.remap = [a[0], a[1]]
  of 0xA1: p.startLine = a[0].int
  of 0xA2: p.offset = a[0].int
  of 0xCA:
    if a[0] < 15 or a[0] > 127: p.fail "multiplex ratio " & $a[0]
    p.muxRatio = a[0].int
  of 0xAE: p.on = false
  of 0xAF: p.on = true
  of 0xB8:
    for i in 1 ..< 15:
      if a[i] <= a[i - 1] or a[i] > 180: p.fail "gray table not increasing"
  else: discard
  inc p.commands

proc feed*(p: var Panel; dataLevel: bool; value: byte) =
  ## One byte as the panel sees it: D/C low is a command, high is data.
  if not dataLevel:
    if p.need > 0: p.fail "command 0x" & $p.cmd & " cut short by a new command"
    p.writing = false
    let n = argCount(value)
    if n < 0:
      p.fail "unknown command " & $value
      return
    if p.locked and value != 0xFD:
      p.fail "command " & $value & " while locked"
      return
    p.cmd = value
    p.need = n
    p.args.setLen 0
    if n == 0: p.apply()
  elif p.need > 0:
    p.args.add value
    dec p.need
    if p.need == 0: p.apply()
  elif p.writing:
    if (p.remap[0] and 1) != 0: p.fail "vertical address increment is not modelled"
    p.ram[p.row][p.col * 2 + p.half] = value
    inc p.ramBytes
    inc p.half
    if p.half == 2:
      p.half = 0
      inc p.col
      if p.col > p.colEnd:
        p.col = p.colStart
        inc p.row
        if p.row > p.rowEnd: p.row = p.rowStart
  else:
    p.fail "data byte with no command to take it"

proc pixel*(p: Panel; x, y: int): uint8 =
  ## Gray level shown at (x, y), x to the right and y down as the viewer
  ## sees a 256x64 module whose glass needs re-map 0x14 (the usual one:
  ## nibble re-map and reversed COM scan make the first data byte's high
  ## nibble the top-left pixel).
  let b = p.ram[y][(VisibleFirstCol * 4 + x) div 2]
  let nibbleRemap = (p.remap[0] and 0x04) != 0
  let first = (x and 1) == 0
  if first == nibbleRemap: b shr 4 else: b and 0x0F

proc upright*(p: Panel): bool =
  ## The settings under which `pixel` is what the viewer sees.
  p.remap == [0x14'u8, 0x11] and p.muxRatio == VisibleRows - 1 and
    p.startLine == 0 and p.offset == 0
