## State for the opt-in setup AP channel qualification image.

const
  ApSweepFirstChannel = 1
  ApSweepLastChannel = 11
  ApSweepAdvanceDelayMs = 1_000'u32

type
  ApSweepReply = enum
    apSweepReject, apSweepProbe, apSweepAdvance
  ApChannelSweep = object
    channel: int
    ready, probed, advancing: bool
    advanceQueuedAt: uint32

proc apSweepOpen(sweep: var ApChannelSweep; channel: int) =
  sweep = ApChannelSweep(channel: channel, ready: true)

proc apSweepRequest(sweep: ApChannelSweep; clientChannel: uint;
                    request: openArray[byte]): ApSweepReply =
  if not sweep.ready or sweep.advancing or clientChannel != sweep.channel.uint:
    return apSweepReject
  let path = "/bench/channel/" & $sweep.channel & " HTTP/1.1\r\n"
  if request.requestStartsWith("GET " & path):
    return apSweepProbe
  if sweep.probed and request.requestStartsWith("POST " & path):
    return apSweepAdvance
  apSweepReject

proc apSweepResponseQueued(sweep: var ApChannelSweep; reply: ApSweepReply; now: uint32) =
  case reply
  of apSweepReject: discard
  of apSweepProbe: sweep.probed = true
  of apSweepAdvance:
    sweep.advanceQueuedAt = now
    sweep.advancing = true

proc apSweepAdvanceDue(sweep: ApChannelSweep; now: uint32): bool =
  sweep.ready and sweep.advancing and now - sweep.advanceQueuedAt >= ApSweepAdvanceDelayMs

proc apSweepSsid(prefix: string; channel: int): string =
  prefix & "-ch" & (if channel < 10: "0" else: "") & $channel
