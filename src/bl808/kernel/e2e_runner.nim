## Single-boot N-attempt runner for e2e tests.
##
## Usage:
##
##   e2eMarkerInit(addr console)
##   e2eRun(totalAttempts = 3, runOne = runOneAttempt, deinitForRetry = teardown)
##
## `runOne` is called once per attempt and is expected to emit phase markers
## as it walks the milestone. `deinitForRetry` runs between attempts to leave
## the stack in a state equivalent to a fresh boot.

import ./e2e_marker

proc e2eRun*(
  totalAttempts: int,
  runOne: proc (): bool {.nimcall.},
  deinitForRetry: proc () {.nimcall.} = nil,
  stopAfterSuccess = false,
) =
  ## Run the test body `totalAttempts` times. `runOne` returns true on success.
  ## Emits attempt:start before each attempt and attempt:ok|fail after.
  for i in 1 .. totalAttempts:
    phaseMark(Phase.attempt, Kind.start):
      kvWrite("n", i.uint32)
      kvWrite("total", totalAttempts.uint32)
    let ok = runOne()
    if ok:
      phaseMark(Phase.attempt, Kind.ok):
        kvWrite("n", i.uint32)
        kvWrite("total", totalAttempts.uint32)
      if stopAfterSuccess:
        break
    else:
      phaseMark(Phase.attempt, Kind.fail):
        kvWrite("n", i.uint32)
        kvWrite("total", totalAttempts.uint32)
    if deinitForRetry != nil:
      deinitForRetry()

proc waitMacReady*() =
  ## Stub for Iteration 1. BLE central tests in Iteration 2 will replace this
  ## with a UART-input read of `@cmd start` from the harness.
  discard
