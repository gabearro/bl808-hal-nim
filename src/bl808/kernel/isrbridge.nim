## Zero-allocation ISR-to-scheduler bridge for the BL808 kernel.
##
## Hardware ISRs cannot safely allocate memory or run CPS continuations.
## This module provides a fixed-size slot table and a lock-free completion
## ring that ISRs write slot indices into. The scheduler drains the ring
## each iteration and completes the corresponding futures in task context.
##
## Usage from a peripheral driver:
##   1. `let slot = registerIsrFuture(myFuture)` — allocate a slot
##   2. Enable the hardware interrupt
##   3. In the ISR handler: `completeIsrSlot(slot)` — zero allocation
##   4. Scheduler calls `drainIsrCompletions()` → `complete(future)`

import ../core
import ./runtime

# =============================================================================
# Configuration
# =============================================================================

const
  MaxIsrSlots* = 32
    ## Maximum number of concurrently pending ISR-driven futures.

  CompletionRingSize = 64
    ## Power-of-2 ring buffer for ISR completion notifications.

  CompletionRingMask = CompletionRingSize - 1

# =============================================================================
# Slot table
# =============================================================================

type
  IsrSlot = object
    future: CpsVoidFuture
    active: bool

var slots: array[MaxIsrSlots, IsrSlot]

# =============================================================================
# Completion ring (lock-free single-producer single-consumer)
#
# ISR writes to ring[head] and increments head (single producer).
# Scheduler reads from ring[tail] and increments tail (single consumer).
# No atomics needed: ISR has interrupts disabled, scheduler checks
# under withInterruptsDisabled.
# =============================================================================

var
  ring: array[CompletionRingSize, int32]
  ringHead: int  ## Written by ISRs only
  ringTail: int  ## Read by scheduler only
  ringCount: int
  ringOverflows: uint64

# =============================================================================
# Initialization
# =============================================================================

proc isrBridgeInit*() =
  ## Initialize the ISR bridge. Call once at boot.
  for i in 0 ..< MaxIsrSlots:
    slots[i].future = nil
    slots[i].active = false
  for i in 0 ..< CompletionRingSize:
    ring[i] = -1
  ringHead = 0
  ringTail = 0
  ringCount = 0
  ringOverflows = 0

# =============================================================================
# Slot registration (task context)
# =============================================================================

proc releaseIsrSlot*(slot: int)

proc releaseIsrSlotIfFuture(slot: int, fut: CpsVoidFuture) =
  if slot >= 0 and slot < MaxIsrSlots:
    withInterruptsDisabled:
      if slots[slot].future == fut:
        slots[slot].active = false
        slots[slot].future = nil

proc registerIsrFuture*(fut: CpsVoidFuture): int =
  ## Allocate an ISR slot for a pending future.
  ## Returns the slot index (0..MaxIsrSlots-1), or -1 if no slots available.
  ## Call from task context only.
  for i in 0 ..< MaxIsrSlots:
    if not slots[i].active:
      slots[i] = IsrSlot(future: fut, active: true)
      let slot = i
      fut.addCallback(proc() =
        releaseIsrSlotIfFuture(slot, fut)
      )
      return slot
  -1

proc releaseIsrSlot*(slot: int) =
  ## Manually release a slot without completing its future.
  ## Use for cancellation or cleanup.
  if slot >= 0 and slot < MaxIsrSlots:
    withInterruptsDisabled:
      slots[slot].active = false
      slots[slot].future = nil

# =============================================================================
# ISR completion (interrupt context — zero allocation)
# =============================================================================

proc completeIsrSlot*(slot: int) =
  ## Signal that the ISR event for `slot` has occurred.
  ## Called from ISR context with interrupts disabled.
  ## Writes the slot index into the completion ring.
  ## The scheduler will call complete() on the future later.
  if slot < 0 or slot >= MaxIsrSlots:
    return
  if not slots[slot].active:
    return
  if ringCount >= CompletionRingSize:
    ringOverflows.inc
    return
  ring[ringHead and CompletionRingMask] = slot.int32
  ringHead = (ringHead + 1) and CompletionRingMask
  ringCount.inc

# =============================================================================
# Scheduler drain (task context)
# =============================================================================

proc drainIsrCompletions*() =
  ## Drain the completion ring and complete pending futures.
  ## Called by the scheduler each iteration. Ring bookkeeping is done with
  ## interrupts disabled, but futures are completed in task context.
  while true:
    var slot = -1
    var fut: CpsVoidFuture = nil
    withInterruptsDisabled:
      if ringCount > 0:
        slot = ring[ringTail and CompletionRingMask].int
        ring[ringTail and CompletionRingMask] = -1
        ringTail = (ringTail + 1) and CompletionRingMask
        ringCount.dec
        if slot >= 0 and slot < MaxIsrSlots and slots[slot].active:
          fut = slots[slot].future
          slots[slot].active = false
          slots[slot].future = nil
    if slot < 0:
      break
    if fut != nil and not fut.finished:
      complete(fut)

# =============================================================================
# Stats
# =============================================================================

proc isrBridgeActiveSlotsCount*(): int =
  for i in 0 ..< MaxIsrSlots:
    if slots[i].active:
      inc result

proc isrBridgePendingCompletions*(): int =
  ringCount

proc isrBridgeOverflowCount*(): uint64 =
  ringOverflows
