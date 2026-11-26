## The settings menu, opened with the remote's # button (upstream
## `src/menu.rs`). Main page: visualiser, Equaliser submenu, time zone,
## daylight saving, status bar contents, clock on the dimmed screen, the
## address (read-only) and About. The display draws it; `remote.nim` routes
## buttons here while it is open: up/down pick a row, left/right change it,
## OK opens a submenu or closes the menu (from a submenu OK goes back), #
## closes it from anywhere. Pure Nim; task context only.

import ./timebase, ./prefs, ./ui, ./about

const
  IdleCloseMs = 15_000
    ## The menu closes itself after this long without a button.

  Rows* = 8
  RowVisual* = 0
  RowEq* = 1
  RowZone* = 2
  RowDst* = 3
  RowInfo* = 4
  RowSleepClock* = 5
  RowAddress* = 6
  RowAbout* = 7

  EqRows* = 4               ## the preset switcher, then bass / mid / treble
  EqPreset* = 0
  EqBass* = 1

type
  Page* = enum
    pgMain, pgEqualiser, pgAbout

  Key* = enum
    keyUp, keyDown, keyLeft, keyRight, keyOk

  MenuState = object
    open: bool
    page: Page
    row: int
    lastInputMs: uint64

var state: MenuState

proc aboutItems*(): int =
  ## About page items: the repo / licence header, then one per library.
  ## `row` is the first item showing; two fit on screen.
  min(about.count() + 1, 255)

proc isOpen*(): bool =
  ## Whether the menu is showing. Closes it if it has sat idle too long.
  if state.open and elapsedMs(state.lastInputMs, nowMs()) >= IdleCloseMs:
    state.open = false
  state.open

proc view*(page: var Page; row: var int): bool =
  ## The page showing and its selected row; false if the menu is closed.
  if not isOpen(): return false
  page = state.page
  row = state.row
  true

proc toggle*() =
  ## Open the menu, or close it if it is open (the # button).
  let wasOpen = isOpen()
  state = MenuState(open: not wasOpen, page: pgMain, row: 0, lastInputMs: nowMs())
  ui.wake()

proc key*(k: Key) =
  state.lastInputMs = nowMs()
  let row = state.row
  if state.page == pgAbout:
    # Scroll: up / down by one library, left / right by a screenful.
    let last = max(aboutItems() - 2, 0)
    case k
    of keyUp: state.row = clamp(row - 1, 0, last)
    of keyDown: state.row = clamp(row + 1, 0, last)
    of keyLeft: state.row = clamp(row - 2, 0, last)
    of keyRight: state.row = clamp(row + 2, 0, last)
    of keyOk:
      state.page = pgMain
      state.row = RowAbout
    return
  let rows = if state.page == pgMain: Rows else: EqRows
  let step = if k == keyRight: 1 else: -1
  case k
  of keyUp: state.row = (row + rows - 1) mod rows
  of keyDown: state.row = (row + 1) mod rows
  of keyOk:
    if state.page == pgEqualiser:
      state.page = pgMain
      state.row = RowEq
    elif row == RowEq:
      state.page = pgEqualiser
      state.row = 0
    elif row == RowAbout:
      state.page = pgAbout
      state.row = 0
    else:
      state.open = false
  of keyLeft, keyRight:
    if state.page == pgEqualiser:
      if row == EqPreset: stepEqPreset(step)
      else: adjustEqGain(row - EqBass, step)
    elif k == keyRight and row == RowEq:
      state.page = pgEqualiser
      state.row = 0
    elif k == keyRight and row == RowAbout:
      state.page = pgAbout
      state.row = 0
    else:
      case row
      of RowVisual: stepVisualiser(step)
      of RowZone: setOffsetQh(offsetQh() + step)
      of RowDst: setDstEnabled(not dstEnabled())
      of RowInfo: stepStatusInfo(step)
      of RowSleepClock: setSleepClock(not sleepClock())
      else: discard

proc menuInit*() =
  state = MenuState()
