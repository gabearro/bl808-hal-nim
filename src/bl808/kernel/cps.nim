## BL808 Kernel CPS Barrel Module
##
## Import this to get the full CPS green-thread API:
##   import bl808/kernel/cps
##
## Provides:
##   - {.cps.} macro for async proc transformation
##   - Continuation, CpsFuture[T], CpsVoidFuture types
##   - run() trampoline, complete/fail/addCallback/read/finished
##   - Heap allocator (heapInit)
##   - Monotonic clock (readTick, msToTicks, usToTicks)
##   - Cooperative scheduler (schedulerInit, runScheduler, post, addTimer)
##   - Sleep primitives (sleepMs, sleepUs, yieldNow)
##   - ISR bridge (registerIsrFuture, completeIsrSlot)
##   - Sync primitives, channels, and task handles
##
## Optional drivers live in their own modules. Import them explicitly, e.g.
## `bl808/kernel/asyncuart`, `bl808/kernel/asynci2c`, `bl808/kernel/asyncspi`,
## `bl808/kernel/ipcbridge`, or `bl808/kernel/log`.

import ./runtime
export runtime

import ./transform
export transform

import ./alloc
export alloc

import ./clock
export clock

import ./sched
export sched

import ./sleep
export sleep

import ./fault
export fault

import ./boothealth
export boothealth

import ./isrbridge
export isrbridge

import ./sync
export sync

import ./channels
export channels

import ./tasks
export tasks
