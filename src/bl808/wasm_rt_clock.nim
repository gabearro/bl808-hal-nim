## Bound the correspondence between a worker clock and an M0 clock.
## The sample brackets two owner timestamps with a worker send/receive
## pair. Forward and return delays may differ. All bounds require the
## caller-supplied relative rate envelope to hold over the whole horizon.

const
  ClockPpm = 1_000_000'u64
  MaxWasmClockTicksPerUs* = 1_000'u32

type
  WasmClockLimits* = object
    maxRoundTripTicks*, maxAgeTicks*, maxProjectionTicks*, maxUncertaintyTicks*: uint64
    relativeSkewPpm*: uint32

  WasmClockSample* = object
    localSend*, ownerReceive*, ownerSend*, localReceive*: uint64
    localTicksPerUs*, ownerTicksPerUs*: uint32
    ownerEpoch*, peerSession*: uint32

  WasmClockInterval* = object
    earliest*, latest*: uint64

  WasmClockCorrelation* = object
    sample: WasmClockSample
    limits: WasmClockLimits
    lowerRate, upperRate, divisor, quantization: uint64

proc validWasmClockLimits*(limits: WasmClockLimits): bool =
  limits.maxRoundTripTicks > 0 and limits.maxAgeTicks > 0 and
    limits.maxProjectionTicks > 0 and
    limits.maxUncertaintyTicks > 0 and limits.relativeSkewPpm.uint64 < ClockPpm

proc scaled(ticks, numerator, denominator: uint64, roundUp: static bool,
            value: var uint64): bool =
  # Quotient/remainder avoids a product of a 64-bit timestamp and a rate.
  # The bounded rate fields ensure that the remainder product fits.
  let quotient = ticks div denominator
  if quotient > high(uint64) div numerator: return false
  let remainder = (ticks mod denominator) * numerator
  var tail = remainder div denominator
  when roundUp:
    if remainder mod denominator != 0: inc tail
  let scaledWhole = quotient * numerator
  if tail > high(uint64) - scaledWhole: return false
  value = scaledWhole + tail
  true

proc wasmClockDurationBounds*(correlation: WasmClockCorrelation,
    ownerTicks: uint64, duration: var WasmClockInterval): bool =
  if correlation.divisor == 0: return false
  scaled(ownerTicks, correlation.lowerRate, correlation.divisor, false, duration.earliest) and
    scaled(ownerTicks, correlation.upperRate, correlation.divisor, true, duration.latest)

proc isFreshWasmClock*(correlation: WasmClockCorrelation, now: uint64,
    ownerEpoch, peerSession, localTicksPerUs: uint32): bool =
  correlation.divisor != 0 and ownerEpoch == correlation.sample.ownerEpoch and
    peerSession == correlation.sample.peerSession and
    localTicksPerUs == correlation.sample.localTicksPerUs and
    now >= correlation.sample.localReceive and
    now - correlation.sample.localReceive <= correlation.limits.maxAgeTicks

proc project(correlation: WasmClockCorrelation, localAnchor, ownerAnchor, target: uint64,
             upper: static bool, bound: var uint64): bool =
  let forward = target >= ownerAnchor
  let span = if forward: target - ownerAnchor else: ownerAnchor - target
  var elapsed: WasmClockInterval
  if not correlation.wasmClockDurationBounds(span, elapsed) or
      elapsed.latest > correlation.limits.maxProjectionTicks:
    return false
  let width = if forward == upper: elapsed.latest else: elapsed.earliest
  if forward:
    if width > high(uint64) - localAnchor: return false
    bound = localAnchor + width
  else:
    bound = localAnchor - min(localAnchor, width)
  true

proc mapPeerTick(correlation: WasmClockCorrelation, ownerTick: uint64,
                  local: var WasmClockInterval): bool =
  let sample = correlation.sample
  if not correlation.project(sample.localSend, sample.ownerReceive, ownerTick, false,
        local.earliest) or
      not correlation.project(sample.localReceive, sample.ownerSend, ownerTick, true,
        local.latest) or correlation.quantization > high(uint64) - local.latest:
    return false
  local.earliest -= min(local.earliest, correlation.quantization)
  local.latest += correlation.quantization
  local.latest >= local.earliest and
    local.latest - local.earliest <= correlation.limits.maxUncertaintyTicks

proc initWasmClockCorrelation*(correlation: var WasmClockCorrelation,
    sample: WasmClockSample, limits: WasmClockLimits): bool =
  correlation = WasmClockCorrelation()
  if not limits.validWasmClockLimits() or
      sample.ownerEpoch == 0 or sample.peerSession == 0 or
      sample.localTicksPerUs notin 1'u32..MaxWasmClockTicksPerUs or
      sample.ownerTicksPerUs notin 1'u32..MaxWasmClockTicksPerUs or
      sample.localReceive < sample.localSend or sample.ownerSend < sample.ownerReceive:
    return false
  let roundTrip = sample.localReceive - sample.localSend
  if roundTrip > limits.maxRoundTripTicks: return false
  let skew = limits.relativeSkewPpm.uint64
  var candidate = WasmClockCorrelation(sample: sample, limits: limits,
    lowerRate: sample.localTicksPerUs.uint64 * (ClockPpm - skew),
    upperRate: sample.localTicksPerUs.uint64 * (ClockPpm + skew),
    divisor: sample.ownerTicksPerUs.uint64 * ClockPpm)
  var ownerQuantum, processing: WasmClockInterval
  if not candidate.wasmClockDurationBounds(1, ownerQuantum) or
      not candidate.wasmClockDurationBounds(sample.ownerSend - sample.ownerReceive, processing):
    return false
  candidate.quantization = ownerQuantum.latest + 1
  if processing.earliest > roundTrip and processing.earliest - roundTrip > candidate.quantization:
    return false
  var checked: WasmClockInterval
  if not candidate.mapPeerTick(sample.ownerSend, checked): return false
  correlation = candidate
  true

proc mapWasmClockTick*(correlation: WasmClockCorrelation, ownerTick, now: uint64,
    ownerEpoch, peerSession, localTicksPerUs: uint32,
    local: var WasmClockInterval): bool =
  correlation.isFreshWasmClock(now, ownerEpoch, peerSession, localTicksPerUs) and
    correlation.mapPeerTick(ownerTick, local)
