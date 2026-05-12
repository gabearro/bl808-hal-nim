## Async typed channels for the BL808 kernel.
##
## Channels provide typed message-passing between CPS tasks:
##
##   let ch = newChannel[int](4)       # bounded, capacity 4
##   await ch.send(42)                  # blocks if full
##   let val: int = await ch.recv()     # blocks if empty
##
##   let uch = newUnboundedChannel[string]()
##   await uch.send("hello")            # never blocks
##   let msg: string = await uch.recv() # blocks if empty
##
## All operations are cooperative — no locks, single-core only.

import ./runtime

# =============================================================================
# Bounded channel
# =============================================================================

type
  SendWaiter[T] = object
    value: T
    future: CpsVoidFuture

  AsyncChannel*[T] = ref object
    buf: seq[T]
    head, tail, count, cap: int
    recvWaiters: seq[CpsFuture[T]]
    sendWaiters: seq[SendWaiter[T]]
    closed: bool

proc popRecvWaiter[T](ch: AsyncChannel[T]): CpsFuture[T] =
  while ch.recvWaiters.len > 0:
    let w = ch.recvWaiters[0]
    ch.recvWaiters.delete(0)
    if not w.finished:
      return w
  nil

proc wakeOneSender[T](ch: AsyncChannel[T]) =
  ## Move one blocked sender into either a waiting receiver or the ring buffer.
  while ch.sendWaiters.len > 0:
    let sw = ch.sendWaiters[0]
    ch.sendWaiters.delete(0)
    if sw.future.finished:
      continue

    let rw = ch.popRecvWaiter()
    if rw != nil:
      complete(rw, sw.value)
      complete(sw.future)
      return

    if ch.count < ch.cap:
      ch.buf[ch.tail] = sw.value
      ch.tail = (ch.tail + 1) mod ch.cap
      inc ch.count
      complete(sw.future)
      return

    ch.sendWaiters.insert(sw, 0)
    return

proc newChannel*[T](capacity: int): AsyncChannel[T] =
  ## Create a bounded channel with the given capacity.
  assert capacity > 0, "channel capacity must be positive"
  result = AsyncChannel[T](
    buf: newSeq[T](capacity),
    head: 0, tail: 0, count: 0, cap: capacity,
    recvWaiters: @[],
    sendWaiters: @[],
    closed: false,
  )

proc send*[T](ch: AsyncChannel[T], value: T): CpsVoidFuture =
  ## Send a value into the channel.
  ## If a receiver is waiting, deliver directly.
  ## If the buffer has space, enqueue.
  ## Otherwise, block until space is available.
  if ch.closed:
    return failedLocalVoidFuture(
      newException(IOError, "channel closed"))

  # Fast path: a receiver is already waiting
  let recvWaiter = ch.popRecvWaiter()
  if recvWaiter != nil:
    complete(recvWaiter, value)
    return completedLocalVoidFuture()

  # Buffer has space
  if ch.count < ch.cap:
    ch.buf[ch.tail] = value
    ch.tail = (ch.tail + 1) mod ch.cap
    inc ch.count
    return completedLocalVoidFuture()

  # Full — block the sender and keep its value queued.
  let f = newLocalCpsVoidFuture()
  ch.sendWaiters.add(SendWaiter[T](value: value, future: f))
  f

proc recv*[T](ch: AsyncChannel[T]): CpsFuture[T] =
  ## Receive a value from the channel.
  ## If data is available, returns immediately.
  ## Otherwise, blocks until a sender provides data.
  if ch.count > 0:
    let value = ch.buf[ch.head]
    var def: T
    ch.buf[ch.head] = def
    ch.head = (ch.head + 1) mod ch.cap
    dec ch.count
    ch.wakeOneSender()
    return completedFuture[T](value)

  if ch.closed:
    return failedFuture[T](
      newException(IOError, "channel closed"))

  # Empty — block the receiver
  let f = newLocalCpsFuture[T]()
  ch.recvWaiters.add(f)
  f

proc tryRecv*[T](ch: AsyncChannel[T]): (T, bool) =
  ## Non-blocking receive. Returns (value, true) or (default, false).
  if ch.count > 0:
    let value = ch.buf[ch.head]
    var def: T
    ch.buf[ch.head] = def
    ch.head = (ch.head + 1) mod ch.cap
    dec ch.count
    ch.wakeOneSender()
    return (value, true)
  var def: T
  (def, false)

proc trySend*[T](ch: AsyncChannel[T], value: T): bool =
  ## Non-blocking send. Returns false if the channel is full.
  if ch.closed:
    return false
  let recvWaiter = ch.popRecvWaiter()
  if recvWaiter != nil:
    complete(recvWaiter, value)
    return true
  if ch.count < ch.cap:
    ch.buf[ch.tail] = value
    ch.tail = (ch.tail + 1) mod ch.cap
    inc ch.count
    true
  else:
    false

proc len*[T](ch: AsyncChannel[T]): int {.inline.} = ch.count
proc capacity*[T](ch: AsyncChannel[T]): int {.inline.} = ch.cap
proc isFull*[T](ch: AsyncChannel[T]): bool {.inline.} = ch.count >= ch.cap
proc isEmpty*[T](ch: AsyncChannel[T]): bool {.inline.} = ch.count == 0

proc close*[T](ch: AsyncChannel[T]) =
  ## Close the channel. Pending receivers get an error.
  ch.closed = true
  for w in ch.recvWaiters:
    if not w.finished:
      fail(w, newException(IOError, "channel closed"))
  ch.recvWaiters.setLen(0)
  for w in ch.sendWaiters:
    if not w.future.finished:
      fail(w.future, newException(IOError, "channel closed"))
  ch.sendWaiters.setLen(0)

# =============================================================================
# Unbounded channel (never blocks on send)
# =============================================================================

type
  UnboundedChannel*[T] = ref object
    buf: seq[T]
    recvWaiters: seq[CpsFuture[T]]
    closed: bool

proc newUnboundedChannel*[T](): UnboundedChannel[T] =
  UnboundedChannel[T](buf: @[], recvWaiters: @[], closed: false)

proc send*[T](ch: UnboundedChannel[T], value: T) =
  ## Send a value. Never blocks (unbounded buffer).
  if ch.closed: return

  # Deliver directly to a waiting receiver
  while ch.recvWaiters.len > 0:
    let w = ch.recvWaiters[0]
    ch.recvWaiters.delete(0)
    if not w.finished:
      complete(w, value)
      return

  # Buffer it
  ch.buf.add(value)

proc recv*[T](ch: UnboundedChannel[T]): CpsFuture[T] =
  ## Receive a value. Blocks if empty.
  if ch.buf.len > 0:
    let value = ch.buf[0]
    ch.buf.delete(0)
    return completedFuture[T](value)

  if ch.closed:
    return failedFuture[T](
      newException(IOError, "channel closed"))

  let f = newLocalCpsFuture[T]()
  ch.recvWaiters.add(f)
  f

proc len*[T](ch: UnboundedChannel[T]): int {.inline.} = ch.buf.len
proc isEmpty*[T](ch: UnboundedChannel[T]): bool {.inline.} = ch.buf.len == 0

proc close*[T](ch: UnboundedChannel[T]) =
  ch.closed = true
  for w in ch.recvWaiters:
    if not w.finished:
      fail(w, newException(IOError, "channel closed"))
  ch.recvWaiters.setLen(0)
