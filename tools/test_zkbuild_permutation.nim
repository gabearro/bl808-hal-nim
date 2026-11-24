import std/[algorithm, random]
import cps/zk/[r1cs, permutation]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc identity(n: int): seq[int] =
  for i in 0..<n: result.add i

proc build(target: openArray[int]): Circuit =
  result = initCircuit()
  var input, expected: seq[Linear]
  for i in 0..<target.len: input.add result.publicInput(scalar(i+17))
  for i in target: expected.add result.publicInput(scalar(i+17))
  let actual = result.constrainPermutation(input, permutationRoute(target))
  for i in 0..<target.len: result.assertEqual(actual[i], expected[i])

proc rejected(target: seq[int]): bool =
  try: discard permutationRoute(target)
  except ValueError: return true

proc main() =
  var exhaustive = 0
  for n in [1, 2, 4, 8]:
    var target = identity(n)
    while true:
      let route = permutationRoute(target)
      require(route.switches.len == routeSwitchCount(n), "switch count")
      require(applyPermutation(identity(n), route) == target, "incorrect route")
      inc exhaustive
      if not target.nextPermutation(): break
  require(rejected(@[]) and rejected(@[0, 1, 2]) and rejected(@[0, 0]) and
    rejected(@[-1, 0]) and rejected(@[0, 2]), "malformed permutation accepted")
  for capacity in [-1, 0, 3, int.high]:
    var fails = false
    try: discard routeSwitchCount(capacity)
    except ValueError: fails = true
    require(fails, "malformed capacity accepted")
  var malformed = permutationRoute(@[1, 0])
  malformed.switches.setLen(0)
  var fails = false
  try: discard applyPermutation(@[1, 2], malformed)
  except ValueError: fails = true
  require(fails, "malformed route length accepted")

  var rng = initRand(0x42454e45)
  var circuits, mutations = 0
  for n in [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024]:
    let reference = build(identity(n))
    require(reference.satisfied(), "identity circuit")
    require(reference.constraints.len == 2*routeSwitchCount(n)+n,
      "unexpected permutation constraint cost")
    for sample in 0..<(if n <= 16: 16 else: 2):
      var target = identity(n)
      rng.shuffle(target)
      require(applyPermutation(identity(n), permutationRoute(target)) == target,
        "random route")
      var circuit = build(target)
      require(circuit.satisfied(), "permutation constraints")
      require(circuit.sameShape(reference), "witness-dependent permutation shape")
      inc circuits
      for index in [1, n+1, 2*n]:
        let original = circuit.values[index]
        circuit.values[index] = original+scalar(1)
        require(not circuit.satisfied(), "changed public value accepted")
        circuit.values[index] = original
        inc mutations
      if n > 1:
        let selector = 2*n+1
        let original = circuit.values[selector]
        circuit.values[selector] = scalar(2)
        require(not circuit.satisfied(), "non-Boolean switch accepted")
        circuit.values[selector] = original
        circuit.values[selector+1] += scalar(1)
        require(not circuit.satisfied(), "changed switch product accepted")
        inc mutations, 2
  # Duplicate payloads are legitimate: routing permutes records, not labels
  # inferred from payloads. The route must work for arbitrary input values.
  let duplicates = @[9, 9, 4, 4]
  require(applyPermutation(duplicates, permutationRoute(@[3, 1, 0, 2])) == @[4, 9, 9, 4],
    "duplicate payload route")
  echo "zkbuild permutation: PASS (", exhaustive, " exhaustive routes; ",
    circuits, " R1CS cases through N=1024; ", mutations, " mutations rejected; 2 constraints/switch)"

main()
