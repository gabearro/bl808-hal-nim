# One operation of a firmware state machine.
#
# A machine owns one Op. Its serial is advanced only by opGo, when an
# operation (or a new phase of it) starts; opFinish ends it. Whatever the
# operation hands out and does not keep a pointer to carries the serial it
# was issued under, its stamp: a kernel timer (KeTimerEntry.stamp, set by
# ke_timer_try_set), a frame (its confirmation argument, opStampEnv) or a
# port-defined indication (its payload). The receiver drops a delivery
# whose stamp is not current: it belongs to an operation that has ended.
#
# Requests and the replies reserved for them need no stamp: the machine
# holds their pointers while the Op is live, and every replier answers with
# the reserved reply, so a live operation always receives its completion.
# Loss is never signalled.

type Op = object
  serial: uint32  ## 0 is never issued, so a zero stamp means "not stamped"
  live: bool

proc opGo(op: var Op): uint32 =
  ## Start an operation, or a new phase of one. Every earlier stamp is stale.
  inc op.serial
  if op.serial == 0: inc op.serial
  op.live = true
  op.serial

proc opFinish(op: var Op) =
  ## End the operation. Every stamp it issued is stale.
  op.live = false

proc opCurrent(op: Op; stamp: uint32): bool =
  ## A delivery stamped `stamp` belongs to the live operation.
  op.live and stamp == op.serial

template opStampEnv(stamp: uint32): pointer =
  ## A stamp as a frame's confirmation argument.
  cast[pointer](stamp.uint)

template opEnvStamp(env: pointer): uint32 =
  ## The stamp carried by a frame's confirmation argument.
  cast[uint](env).uint32
