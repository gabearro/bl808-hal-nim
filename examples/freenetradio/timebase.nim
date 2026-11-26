## Monotonic time for the platform-independent modules.
##
## The firmware installs the kernel tick (`setClock`); host tests leave it
## unset and move a fake clock with `setFakeTimeUs` / `advanceFakeTimeMs`.
## Time starts at boot and never goes backwards.

type NowUsProc* = proc(): uint64 {.nimcall.}

var
  clockImpl: NowUsProc
  fakeUs: uint64

proc setClock*(impl: NowUsProc) = clockImpl = impl

proc nowUs*(): uint64 {.inline.} =
  if clockImpl != nil: clockImpl() else: fakeUs

proc nowMs*(): uint64 {.inline.} = nowUs() div 1000

proc setFakeTimeUs*(us: uint64) = fakeUs = us
proc advanceFakeTimeMs*(ms: uint64) = fakeUs += ms * 1000

func elapsedMs*(sinceMs, now: uint64): uint64 {.inline.} =
  ## Saturating `now - since` (upstream's `elapsed_sat`).
  if now > sinceMs: now - sinceMs else: 0
