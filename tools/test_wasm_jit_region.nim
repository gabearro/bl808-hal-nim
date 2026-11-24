import cps/wasm/jit/memory

type RegionState = object
  writes: int
  seals: int
  rejectWrite: bool
  rejectSeal: bool
  writable: bool

proc protect(ctx: pointer, writable: bool): bool {.nimcall.} =
  let state = cast[ptr RegionState](ctx)
  if (writable and state[].rejectWrite) or
      (not writable and state[].rejectSeal): return false
  if writable: inc state[].writes
  else: inc state[].seals
  state[].writable = writable
  true

proc expectRejected(body: proc() {.closure.}) =
  var rejected = false
  try: body()
  except OSError: rejected = true
  doAssert rejected

proc main() =
  var region: array[32, uint64]
  var state: RegionState
  expectRejected(proc() = discard initJitMemPoolIn(nil, 128, protect))
  expectRejected(proc() = discard initJitMemPoolIn(addr region[0], 128, nil))
  var pool = initJitMemPoolIn(addr region[0], sizeof(region),
                              protect, addr state)
  let code = pool.writeCode([0x00000013'u32, 0x00008067'u32])
  doAssert code.address == addr region[0]
  doAssert code.size == 8 and pool.used == 8
  doAssert region[0] == 0x0000806700000013'u64
  doAssert state.writes == 1 and state.seals == 1
  doAssert not state.writable
  expectRejected(proc() = discard pool.alloc(0))
  expectRejected(proc() = discard pool.alloc(sizeof(region)))
  state.rejectWrite = true
  expectRejected(proc() = discard pool.writeCode([0x00000013'u32]))
  doAssert state.writes == 1 and state.seals == 1
  doAssert pool.used == 8 and not state.writable
  state.rejectWrite = false
  state.rejectSeal = true
  expectRejected(proc() = discard pool.writeCode([0x00000013'u32]))
  doAssert pool.used == 8 and state.writable
  state.rejectSeal = false
  pool.enableExecute()
  doAssert not state.writable
  pool.destroy()
  doAssert pool.base == nil and pool.capacity == 0
  echo "bounded JIT region:ok"

main()
