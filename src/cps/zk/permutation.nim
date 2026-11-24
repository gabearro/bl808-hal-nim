## Exact, witness-independent Beneš permutation network for packed records.
## A switch costs one Boolean constraint and one product constraint. This is
## a component, not a proof of sortedness or RAM read/write consistency.
import r1cs

type
  PermutationRoute* = object
    capacity*: int
    switches*: seq[bool]
  Switch = tuple[left, right: int]

proc routeSwitchCount*(capacity: int): int =
  if capacity <= 0 or (capacity and (capacity-1)) != 0:
    raise newException(ValueError, "permutation capacity must be a positive power of two")
  if capacity == 1: return 0
  var levels = 0
  var n = capacity
  while n > 1:
    inc levels
    n = n shr 1
  if capacity > int.high div levels:
    raise newException(ValueError, "permutation network size overflows")
  capacity*levels - capacity div 2

proc appendTopology(pairs: var seq[Switch], offset, stride, size: int) =
  if size == 1: return
  if size == 2:
    pairs.add (offset, offset+stride)
    return
  for i in 0..<size div 2:
    pairs.add (offset+2*i*stride, offset+(2*i+1)*stride)
  appendTopology(pairs, offset, 2*stride, size div 2)
  appendTopology(pairs, offset+stride, 2*stride, size div 2)
  for i in 0..<size div 2:
    pairs.add (offset+2*i*stride, offset+(2*i+1)*stride)

proc topology(capacity: int): seq[Switch] =
  result = newSeqOfCap[Switch](routeSwitchCount(capacity))
  appendTopology(result, 0, 1, capacity)

proc appendRoute(flags: var seq[bool], target: openArray[int]) =
  let n = target.len
  if n == 1: return
  if n == 2:
    flags.add target[0] == 1
    return
  var inverse = newSeq[int](n)
  for output, input in target: inverse[input] = output
  # Each edge is an input label. Its two neighbours share an input switch
  # or an output switch. Alternating colours route one edge through each
  # of the two half-size subnetworks, including parallel-edge cycles.
  var color = newSeq[int8](n)
  for i in 0..<n: color[i] = -1
  var pending = newSeqOfCap[int](n)
  for start in 0..<n:
    if color[start] >= 0: continue
    color[start] = 0
    pending.add start
    while pending.len > 0:
      let edge = pending.pop()
      for neighbour in [edge xor 1, target[inverse[edge] xor 1]]:
        let expected = 1'i8-color[edge]
        if color[neighbour] < 0:
          color[neighbour] = expected
          pending.add neighbour
        elif color[neighbour] != expected:
          raise newException(ValueError, "inconsistent permutation routing")
  var upper = newSeq[int](n div 2)
  var lower = newSeq[int](n div 2)
  for i in 0..<n div 2:
    flags.add color[2*i] == 1
    let a = target[2*i]
    let b = target[2*i+1]
    upper[i] = (if color[a] == 0: a else: b) div 2
    lower[i] = (if color[a] == 1: a else: b) div 2
  appendRoute(flags, upper)
  appendRoute(flags, lower)
  for i in 0..<n div 2:
    flags.add color[target[2*i]] == 1

proc permutationRoute*(target: openArray[int]): PermutationRoute =
  ## target[output] is the input index wanted at that output. Route generation
  ## is O(N log N) and private; only the capacity determines the circuit.
  let count = routeSwitchCount(target.len)
  var seen = newSeq[bool](target.len)
  for index in target:
    if index < 0 or index >= target.len or seen[index]:
      raise newException(ValueError, "target is not a permutation")
    seen[index] = true
  result.capacity = target.len
  result.switches = newSeqOfCap[bool](count)
  appendRoute(result.switches, target)

proc checkedTopology(length: int, route: PermutationRoute): seq[Switch] =
  let count = routeSwitchCount(route.capacity)
  if length != route.capacity or route.switches.len != count:
    raise newException(ValueError, "permutation route dimensions do not match")
  topology(route.capacity)

proc applyPermutation*[T](input: openArray[T], route: PermutationRoute): seq[T] =
  let pairs = checkedTopology(input.len, route)
  result = @input
  for i, pair in pairs:
    if route.switches[i]: swap(result[pair.left], result[pair.right])

proc constrainPermutation*(c: var Circuit, input: openArray[Linear],
    route: PermutationRoute): seq[Linear] =
  ## Outputs remain linear expressions. No probabilistic multiset hash and no
  ## challenge are used. All packed record fields must fit injectively in the
  ## scalar field; callers constrain ranges, order, and read/write semantics.
  let pairs = checkedTopology(input.len, route)
  when defined(zkbuildPermutationAudit):
    let firstWire = c.values.len
    let firstGate = c.constraints.len
  result = @input
  for i, pair in pairs:
    let selector = c.bit(route.switches[i])
    let delta = c.multiply(selector, result[pair.right]-result[pair.left])
    result[pair.left] = result[pair.left]+delta
    result[pair.right] = result[pair.right]-delta
  when defined(zkbuildPermutationAudit):
    c.recordPermutation(firstWire,firstGate,input,result)
