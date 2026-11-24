import bl808/wasm_rt_clock

const limits = WasmClockLimits(maxRoundTripTicks: 200, maxAgeTicks: 150,
  maxProjectionTicks: 10_000, maxUncertaintyTicks: 200)
const asymmetric = WasmClockSample(localSend: 1_000, ownerReceive: 5_020,
  ownerSend: 5_030, localReceive: 1_090, localTicksPerUs: 1, ownerTicksPerUs: 1,
  ownerEpoch: 19, peerSession: 23)
var clock: WasmClockCorrelation
var mapped: WasmClockInterval
doAssert clock.initWasmClockCorrelation(asymmetric, limits)
doAssert clock.mapWasmClockTick(5_100, 1_091, 19, 23, 1, mapped)
doAssert mapped == WasmClockInterval(earliest: 1_078, latest: 1_162)
doAssert clock.mapWasmClockTick(4_990, 1_091, 19, 23, 1, mapped)
doAssert mapped == WasmClockInterval(earliest: 968, latest: 1_052)
doAssert not clock.mapWasmClockTick(5_100, 1_241, 19, 23, 1, mapped)
doAssert not clock.mapWasmClockTick(5_100, 1_080, 19, 23, 1, mapped)
doAssert not clock.mapWasmClockTick(5_100, 1_091, 20, 23, 1, mapped)
doAssert not clock.mapWasmClockTick(5_100, 1_091, 19, 24, 1, mapped)
doAssert not clock.mapWasmClockTick(5_100, 1_091, 19, 23, 2, mapped)
doAssert not clock.mapWasmClockTick(15_100, 1_091, 19, 23, 1, mapped)

var unequal = asymmetric
unequal.localTicksPerUs = 2
var drifting = limits
drifting.relativeSkewPpm = 10_000
doAssert clock.initWasmClockCorrelation(unequal, drifting)
doAssert clock.wasmClockDurationBounds(999, mapped)
doAssert mapped == WasmClockInterval(earliest: 1_978, latest: 2_018)
doAssert clock.mapWasmClockTick(5_120, 1_091, 19, 23, 2, mapped)
# Physical local receive/send at the owner can be inside an asymmetric
# exchange. Both extreme relative rates must map inside the interval.
doAssert mapped.earliest <= 1_218 and mapped.latest >= 1_222
doAssert not clock.mapWasmClockTick(14_000, 1_091, 19, 23, 2, mapped)
doAssert not clock.wasmClockDurationBounds(high(uint64), mapped)

var bad = asymmetric
bad.ownerSend = 5_190
doAssert not clock.initWasmClockCorrelation(bad, limits)
bad = asymmetric
bad.localReceive = 1_400
doAssert not clock.initWasmClockCorrelation(bad, limits)
bad = asymmetric
bad.ownerSend = 5_019
doAssert not clock.initWasmClockCorrelation(bad, limits)
bad = asymmetric
bad.ownerTicksPerUs = 0
doAssert not clock.initWasmClockCorrelation(bad, limits)
var tight = limits
tight.maxUncertaintyTicks = 20
doAssert not clock.initWasmClockCorrelation(asymmetric, tight)

var closeToWrap = asymmetric
closeToWrap.localSend = high(uint64) - 100
closeToWrap.localReceive = high(uint64) - 10
doAssert clock.initWasmClockCorrelation(closeToWrap, limits)
doAssert not clock.mapWasmClockTick(5_100, high(uint64) - 2, 19, 23, 1, mapped)
echo "WASM clock PASS: asymmetric delays, skew, clock rates, stale samples and overflow"
