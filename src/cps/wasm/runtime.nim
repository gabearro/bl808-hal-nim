## WebAssembly runtime / execution engine
## Implements: Store, module instantiation, stack machine interpreter,
## all MVP instructions, host function binding, bulk memory/table ops.

{.experimental: "codeReordering".}

import ./types
import ./block_types
import ./pgo
import std/[math, bitops]
when defined(wasmChunkedMemory):
  import ./linear_memory
when defined(wasmGuardPages):
  import ./guardmem

const WasmPageSize* = 65536
const MaxPages = 65536  # 4 GiB
const WasmSuspendableHostCalls* = defined(wasmSuspendableHostCalls) or
  defined(wasmComponentStackful)
const WasmAtomicWaitEnabled* = defined(wasmSharedCoreTypes) and defined(wasmAtomicWait)
when WasmAtomicWaitEnabled:
  const WasmMaxAtomicWaiters* {.intdefine.} = when defined(bl808lp): 4 else: 16
  static: doAssert WasmMaxAtomicWaiters > 0
# Arena sizes: start small, grow by doubling.
# Small defaults keep per-VM overhead low; most programs fit in the initial
# allocation and never pay a reallocation cost on the hot path.
when defined(bl808lp):
  # All four arenas grow on demand. LP has only 16 KiB writable RAM, so the
  # desktop warm starts and indirect-call cache must not consume its heap.
  const InitialValueStackSize = 32
  const InitialCallStackSize = 4
  const InitialLabelStackSize = 8
  const InitialLocalsSize = 16
  const InitialCallIcSlots = 4
elif defined(bl808m0):
  # M0 shares its 64 KiB OCRAM budget with other firmware services. Keep a
  # useful warm cache but let unusual guest depths grow their own arenas.
  const InitialValueStackSize = 256
  const InitialCallStackSize = 16
  const InitialLabelStackSize = 32
  const InitialLocalsSize = 64
  const InitialCallIcSlots = 64
else:
  const InitialValueStackSize = 1024
  const InitialCallStackSize = 64
  const InitialLabelStackSize = 128
  const InitialLocalsSize = 256
  const InitialCallIcSlots = 512

when defined(wasmChunkedMemory):
  type MemoryBackendFactory* = proc(ctx: pointer, memType: MemType): ref LinearMemory {.nimcall.}

# ---------------------------------------------------------------------------
# Runtime data structures
# ---------------------------------------------------------------------------

type
  WasmTrap* = object of CatchableError

  HostFunc* = proc(args: openArray[WasmValue]): seq[WasmValue] {.closure.}

  WasmHostWait* = object
    ## ready is a side-effect-free readiness check. finish produces the return
    ## lanes exactly once, on the originating core, after ready becomes true.
    ready*: proc(): bool {.closure.}
    finish*: proc(): seq[WasmValue] {.closure.}

  WasmAtomicClock* = proc(): uint64 {.nimcall.}
    ## Monotonic nanoseconds in the store's executor.

  WasmAtomicWaitState = enum
    wawPending, wawNotified, wawExpired, wawAborted

  WasmAtomicWait = ref object
    owner: ptr WasmVM
    arena: ptr Frame
    stackTop: int
    memory: int
    offset, started, duration: uint64
    state: WasmAtomicWaitState

  FuncInst* = object
    funcType*: FuncType
    case isHost*: bool
    of true:
      hostFunc*: HostFunc
    of false:
      moduleIdx*: int
      funcIdx*: int
      code*: ptr Expr
      codeOwner: ref Expr  ## stable, private lifetime for instantiated code
      localTypes*: seq[ValType]

  TableInst* = object
    tableType*: TableType
    elems*: seq[WasmValue]

  MemInst* = object
    memType*: MemType
    data*: seq[byte]
    when defined(wasmChunkedMemory):
      chunked*: ref LinearMemory  ## optional bounded backing
    when defined(wasmGuardPages):
      guardMem*: GuardedMem    ## guard-page-backed virtual reservation
      useGuard*: bool          ## true when guardMem is active

  GlobalInst* = object
    globalType*: GlobalType
    value*: WasmValue

  ElemInst* = object
    elemType*: ValType
    elems*: seq[WasmValue]
    dropped*: bool
    when defined(wasmSharedCoreTypes):
      shared*: bool

  DataInst* = object
    data*: seq[byte]
    dropped*: bool
    when defined(wasmSharedCoreTypes):
      shared*: bool

  ExportInst* = object
    name*: string
    kind*: ExportKind
    idx*: int

  ModuleInst* = object
    types*: seq[FuncType]
    funcAddrs*: seq[int]
    tableAddrs*: seq[int]
    memAddrs*: seq[int]
    globalAddrs*: seq[int]
    elemAddrs*: seq[int]
    dataAddrs*: seq[int]
    tagAddrs*: seq[int]
    exports*: seq[ExportInst]

  Label* = object
    arity*: int
    pc*: int
    stackHeight*: int
    isLoop*: bool
    catchTableIdx*: int32  ## ≥0 = try_table label, index into Frame.code.catchTables; -1 = no catches

  Frame* = object
    pc*: int
    code*: ptr Expr
    brTables*: ptr seq[BrTableData]
    localsStart*: int
    localsCount*: int
    labelStackStart*: int
    returnArity*: int
    moduleIdx*: int
    funcAddr*: int  # store funcAddr of the executing function (for PGO)

  WasmTagInst* = object
    funcType*: FuncType  ## param types = thrown value types; results always empty

  Store* = object
    funcs*: seq[FuncInst]
    tables*: seq[TableInst]
    mems*: seq[MemInst]
    globals*: seq[GlobalInst]
    elems*: seq[ElemInst]
    datas*: seq[DataInst]
    modules*: seq[ModuleInst]
    tags*: seq[WasmTagInst]  ## exception tags (module + imported)

  ## Per-call-site 2-way associative inline cache for call_indirect.
  ## Keyed by (funcAddr, callSitePc) encoded as a uint64.
  ## Each slot holds two (key, elemIdx, calleeAddr) entries and a 1-bit LRU
  ## counter so bimorphic call sites (alternating between 2 targets) hit on
  ## both entries instead of thrashing a single direct-mapped slot.
  ##
  ## Layout: 512 slots × 2 entries = 1024 total entries (same total memory as
  ## the former 1024-slot direct-mapped table).  Hash: key and 511.
  CallIcEntry* = object
    key*: uint64       ## (funcAddr.uint32 shl 32) or callSitePc.uint32; 0 = empty
    elemIdx*: int32    ## cached element index (-1 = unused)
    calleeAddr*: int32 ## resolved store funcAddr of the callee

  CallIcSlot* = object
    a*: CallIcEntry    ## first entry
    b*: CallIcEntry    ## second entry
    evictB*: bool      ## LRU bit: true → next miss evicts b, false → evicts a

  WasmVM* = object
    store*: Store
    # Hot-path stacks use flat uint64 for zero-overhead push/pop
    valueStack*: seq[uint64]
    valueStackTop*: int
    callStack*: seq[Frame]
    callStackTop*: int
    labelStack*: seq[Label]
    labelStackTop*: int
    locals*: seq[uint64]
    localsTop*: int
    # call_indirect inline cache (power-of-two, 2-way slots)
    callIcBuf*: seq[CallIcSlot]
    when WasmSuspendableHostCalls:
      hostWaitSlot: ptr WasmHostWait
    when WasmAtomicWaitEnabled:
      atomicClock: WasmAtomicClock
      atomicWaits: seq[WasmAtomicWait]
    when defined(wasmChunkedMemory):
      memoryFactory*: MemoryBackendFactory
      memoryFactoryContext*: pointer

  WasmExecutionArena* = object
    valueStack: seq[uint64]
    callStack: seq[Frame]
    labelStack: seq[Label]
    locals: seq[uint64]
    valueStackTop, callStackTop, labelStackTop, localsTop: int

  ExternalVal* = object
    case kind*: ExportKind
    of ekFunc:
      funcType*: FuncType
      hostFunc*: HostFunc
    of ekTable:
      tableInst*: TableInst
    of ekMemory:
      memInst*: MemInst
    of ekGlobal:
      globalInst*: GlobalInst
    of ekTag:
      discard  # Tag identity is bound through ExternalStoreRef.

  ExternalStoreRef* = object
    ## An already instantiated external in this VM's store.
    kind*: ExportKind
    address*: int

  StoreImport* = tuple[moduleName, fieldName: string, item: ExternalStoreRef]

# ---------------------------------------------------------------------------
# Trap helper
# ---------------------------------------------------------------------------

template trap(msg: string) =
  raise newException(WasmTrap, msg)

when defined(wasmFunctionReferences):
  proc checkReferenceValues(vm: WasmVM, signature: FuncType, values: openArray[WasmValue],
                            parameters: static bool) =
    let lanes {.cursor.} = when parameters: signature.params else: signature.results
    if signature.references == nil:
      when defined(wasmSharedCoreTypes):
        if vtFuncRef notin lanes: return
      else: return
    if values.len != lanes.len: trap("typed function arity mismatch")
    for i, value in values:
      if value.kind != lanes[i].toValueKind(): trap("typed function value kind mismatch")
      let reference = when parameters: signature.coreParamReference(i)
        else: signature.coreResultReference(i)
      if reference.member == 0 and not reference.nonNull:
        when defined(wasmSharedCoreTypes):
          if value.kind != wvkFuncRef: continue
        else: continue
      if value.isNull():
        if reference.nonNull: trap("null in non-null reference lane")
      elif value.kind == wvkFuncRef:
        let address = value.funcRef.int
        if address < 0 or address >= vm.store.funcs.len or
            not vm.store.funcs[address].funcType.matchesFunctionReference(reference):
          trap("typed function reference value mismatch")

  proc resolveFunctionReference(vm: var WasmVM, moduleIndex, typeIndex: int,
                                reference: int32): int =
    if reference == -1: trap("null function reference")
    if reference < 0 or reference.int >= vm.store.funcs.len:
      trap("invalid function reference")
    result = reference.int
    if not vm.store.funcs[result].funcType.matchesCoreFunctionType(
        vm.store.modules[moduleIndex].types[typeIndex]):
      trap("function reference type mismatch")

when WasmSuspendableHostCalls:
  proc canSuspendHostCall*(vm: var WasmVM): bool {.inline.} =
    vm.hostWaitSlot != nil

  proc suspendHostCall*(vm: var WasmVM, wait: sink WasmHostWait): seq[WasmValue] =
    ## Register a continuation from a host import, then return it immediately.
    if vm.hostWaitSlot == nil:
      trap("host suspension requires sliced interpreter execution")
    if wait.ready == nil or wait.finish == nil or vm.hostWaitSlot[].finish != nil:
      trap("invalid interpreter host wait")
    vm.hostWaitSlot[] = move wait

  proc callSuspendableHost(vm: var WasmVM, host: HostFunc,
                           args: openArray[WasmValue], wait: var WasmHostWait):
                           seq[WasmValue] {.noinline.} =
    let previous = vm.hostWaitSlot
    vm.hostWaitSlot = addr wait
    defer: vm.hostWaitSlot = previous
    result = host(args)
    if wait.finish != nil and result.len != 0:
      trap("suspended host call returned values")

# ---------------------------------------------------------------------------
# VM initialization
# ---------------------------------------------------------------------------

proc initWasmVM*(): WasmVM =
  result.valueStack = newSeq[uint64](InitialValueStackSize)
  result.valueStackTop = 0
  result.callStack = newSeq[Frame](InitialCallStackSize)
  result.callStackTop = 0
  result.labelStack = newSeq[Label](InitialLabelStackSize)
  result.labelStackTop = 0
  result.locals = newSeq[uint64](InitialLocalsSize)
  result.localsTop = 0
  # A smaller power-of-two cache preserves semantics while bounding LP RAM.
  result.callIcBuf = newSeq[CallIcSlot](InitialCallIcSlots)

when WasmSuspendableHostCalls or WasmAtomicWaitEnabled:
  proc initWasmExecutionArena*(): WasmExecutionArena =
    # Several waiters can have live arenas. Each stack grows on demand.
    when defined(bl808lp):
      result.valueStack = newSeq[uint64](16)
      result.callStack = newSeq[Frame](2)
      result.labelStack = newSeq[Label](4)
      result.locals = newSeq[uint64](8)
    else:
      result.valueStack = newSeq[uint64](32)
      result.callStack = newSeq[Frame](4)
      result.labelStack = newSeq[Label](8)
      result.locals = newSeq[uint64](16)

  proc swapWasmExecutionArena*(vm: var WasmVM, arena: var WasmExecutionArena) =
    ## Install a guest thread's stacks while retaining the instance store and
    ## indirect-call cache. Pair calls around each interpreter entry.
    swap(vm.valueStack, arena.valueStack)
    swap(vm.callStack, arena.callStack)
    swap(vm.labelStack, arena.labelStack)
    swap(vm.locals, arena.locals)
    swap(vm.valueStackTop, arena.valueStackTop)
    swap(vm.callStackTop, arena.callStackTop)
    swap(vm.labelStackTop, arena.labelStackTop)
    swap(vm.localsTop, arena.localsTop)

when WasmAtomicWaitEnabled:
  proc setWasmAtomicClock*(vm: var WasmVM, clock: WasmAtomicClock) =
    if vm.atomicWaits.len != 0: trap("cannot replace clock while atomic waits are queued")
    vm.atomicClock = clock

  proc clearWasmAtomicWaits*(vm: var WasmVM) =
    ## Invalidate unfinished notifications when the owning store is closed.
    for wait in vm.atomicWaits:
      wait.state = wawAborted
    vm.atomicWaits.setLen(0)

  proc atomicRemaining(wait: WasmAtomicWait, now: uint64): uint64 =
    if wait.state != wawPending: return 0
    if wait.duration == 0: return uint64.high
    let elapsed = now - wait.started
    if elapsed < wait.duration: wait.duration - elapsed else: 0'u64

  proc beginAtomicWait(vm: var WasmVM, memory: int, offset: uint64,
      timeout: int64): WasmAtomicWait {.noinline.} =
    if vm.atomicWaits.len >= WasmMaxAtomicWaiters: trap("atomic wait capacity exhausted")
    result = WasmAtomicWait(owner: addr vm, arena: addr vm.callStack[0],
      stackTop: vm.callStackTop, memory: memory, offset: offset)
    if timeout > 0:
      if vm.atomicClock == nil: trap("finite atomic wait requires an executor clock")
      result.started = vm.atomicClock()
      result.duration = timeout.uint64
    vm.atomicWaits.add(result)

  proc removeAtomicWait(vm: var WasmVM, wait: WasmAtomicWait) =
    for i, candidate in vm.atomicWaits:
      if candidate == wait:
        vm.atomicWaits.delete(i)
        return

  proc notifyAtomicWaits(vm: var WasmVM, memory: int, offset: uint64,
      count: uint32): uint32 {.noinline.} =
    if count == 0 or vm.atomicWaits.len == 0: return 0
    let now = if vm.atomicClock == nil: 0'u64 else: vm.atomicClock()
    var i = 0
    while i < vm.atomicWaits.len and result < count:
      let wait = vm.atomicWaits[i]
      if wait.atomicRemaining(now) == 0:
        wait.state = wawExpired
        vm.atomicWaits.delete(i)
      elif wait.memory == memory and wait.offset == offset:
        wait.state = wawNotified
        vm.atomicWaits.delete(i)
        inc result
      else:
        inc i

when defined(wasmChunkedMemory):
  proc setMemoryBackendFactory*(vm: var WasmVM, factory: MemoryBackendFactory,
                                context: pointer = nil) =
    ## Opt in before instantiation. The factory must return an independent
    ## memory for each defined memory, with the declared minimum pages present.
    ## Imported memories retain the backing supplied by their host provider.
    vm.memoryFactory = factory
    vm.memoryFactoryContext = context

# ---------------------------------------------------------------------------
# Value stack operations
# ---------------------------------------------------------------------------

# Flat uint64 push/pop — no variant overhead on hot path
# Bounds checks removed: WASM is pre-validated, stack overflow can't happen
proc pushRaw*(vm: var WasmVM, val: uint64) {.inline.} =
  if unlikely(vm.valueStackTop >= vm.valueStack.len):
    vm.valueStack.setLen(vm.valueStack.len * 2)
  vm.valueStack[vm.valueStackTop] = val
  inc vm.valueStackTop

proc popRaw*(vm: var WasmVM): uint64 {.inline.} =
  dec vm.valueStackTop
  vm.valueStack[vm.valueStackTop]

proc push*(vm: var WasmVM, val: WasmValue) {.inline.} =
  case val.kind
  of wvkI32: vm.pushRaw(cast[uint64](val.i32.int64))
  of wvkI64: vm.pushRaw(cast[uint64](val.i64))
  of wvkF32: vm.pushRaw(cast[uint64](cast[uint32](val.f32)))
  of wvkF64: vm.pushRaw(cast[uint64](val.f64))
  of wvkFuncRef: vm.pushRaw(cast[uint64](val.funcRef.int64))
  of wvkExternRef: vm.pushRaw(cast[uint64](val.externRef.int64))
  of wvkV128:
    # v128 occupies 2 value stack slots (low 64 bits first, high 64 bits second)
    var lo, hi: uint64
    copyMem(lo.addr, val.v128[0].unsafeAddr, 8)
    copyMem(hi.addr, val.v128[8].unsafeAddr, 8)
    vm.pushRaw(lo)
    vm.pushRaw(hi)

proc pop*(vm: var WasmVM): WasmValue {.inline.} =
  ## Only used at API boundary — prefer typed popI32/popI64/etc on hot path
  wasmI64(cast[int64](vm.popRaw()))  # return as raw i64; caller converts

proc popI32*(vm: var WasmVM): int32 {.inline.} =
  cast[int32](vm.popRaw() and 0xFFFFFFFF'u64)

proc popI64*(vm: var WasmVM): int64 {.inline.} =
  cast[int64](vm.popRaw())

proc popF32*(vm: var WasmVM): float32 {.inline.} =
  var bits = uint32(vm.popRaw() and 0xFFFFFFFF'u64)
  cast[float32](bits)

proc popF64*(vm: var WasmVM): float64 {.inline.} =
  cast[float64](vm.popRaw())

proc pushI32*(vm: var WasmVM, v: int32) {.inline.} =
  # Zero-extend to 64 bits to keep upper bits clean
  vm.pushRaw(cast[uint64](v.int64) and 0xFFFFFFFF'u64)

proc pushI64*(vm: var WasmVM, v: int64) {.inline.} =
  vm.pushRaw(cast[uint64](v))

proc pushF32*(vm: var WasmVM, v: float32) {.inline.} =
  vm.pushRaw(cast[uint64](cast[uint32](v)))

proc pushF64*(vm: var WasmVM, v: float64) {.inline.} =
  vm.pushRaw(cast[uint64](v))

proc peekRaw*(vm: var WasmVM): uint64 {.inline.} =
  if vm.valueStackTop <= 0:
    trap("value stack underflow on peek")
  vm.valueStack[vm.valueStackTop - 1]

# ---------------------------------------------------------------------------
# WasmValue <-> uint64 conversion helpers
# ---------------------------------------------------------------------------

proc wasmValueToRaw*(v: WasmValue): uint64 {.inline.} =
  ## Convert WasmValue to its raw uint64 representation.
  ## For v128, returns only the low 64 bits (use push() for full 2-slot storage).
  case v.kind
  of wvkI32: cast[uint64](v.i32.int64) and 0xFFFFFFFF'u64
  of wvkI64: cast[uint64](v.i64)
  of wvkF32: cast[uint64](cast[uint32](v.f32))
  of wvkF64: cast[uint64](v.f64)
  of wvkFuncRef: cast[uint64](v.funcRef.int64) and 0xFFFFFFFF'u64
  of wvkExternRef: cast[uint64](v.externRef.int64) and 0xFFFFFFFF'u64
  of wvkV128:
    var lo: uint64
    copyMem(lo.addr, v.v128[0].unsafeAddr, 8)
    lo

proc rawToWasmValue*(raw: uint64, vt: ValType): WasmValue {.inline.} =
  case vt
  of vtI32: wasmI32(cast[int32](raw and 0xFFFFFFFF'u64))
  of vtI64: wasmI64(cast[int64](raw))
  of vtF32:
    var bits = uint32(raw and 0xFFFFFFFF'u64)
    wasmF32(cast[float32](bits))
  of vtF64: wasmF64(cast[float64](raw))
  of vtFuncRef: wasmFuncRef(cast[int32](raw and 0xFFFFFFFF'u64))
  of vtExternRef: wasmExternRef(cast[int32](raw and 0xFFFFFFFF'u64))
  of vtV128: WasmValue(kind: wvkV128)

func initialLocalBits(kind: ValType): uint64 {.inline.} =
  if kind.isRefType(): uint32.high.uint64 else: 0'u64

# ---------------------------------------------------------------------------
# Label stack operations
# ---------------------------------------------------------------------------

proc pushLabel*(vm: var WasmVM, lbl: Label) {.inline.} =
  if vm.labelStackTop >= vm.labelStack.len:
    vm.labelStack.setLen(vm.labelStack.len * 2)
  vm.labelStack[vm.labelStackTop] = lbl
  inc vm.labelStackTop

proc popLabel*(vm: var WasmVM): Label {.inline.} =
  if vm.labelStackTop <= 0:
    trap("label stack underflow")
  dec vm.labelStackTop
  result = vm.labelStack[vm.labelStackTop]

# ---------------------------------------------------------------------------
# Call stack operations
# ---------------------------------------------------------------------------

proc pushFrame*(vm: var WasmVM, frame: Frame) {.inline.} =
  if vm.callStackTop >= vm.callStack.len:
    vm.callStack.setLen(vm.callStack.len * 2)
  vm.callStack[vm.callStackTop] = frame
  inc vm.callStackTop

proc popFrame*(vm: var WasmVM): Frame {.inline.} =
  if vm.callStackTop <= 0:
    trap("call stack underflow")
  dec vm.callStackTop
  result = vm.callStack[vm.callStackTop]

proc currentFrame*(vm: var WasmVM): var Frame {.inline.} =
  if vm.callStackTop <= 0:
    trap("no current frame")
  vm.valueStack.setLen(vm.valueStack.len) # ensure accessible
  vm.callStack[vm.callStackTop - 1]

# ---------------------------------------------------------------------------
# Locals access
# ---------------------------------------------------------------------------

proc getLocalRaw*(vm: var WasmVM, localsStart: int, idx: int): uint64 {.inline.} =
  vm.locals[localsStart + idx]

proc setLocalRaw*(vm: var WasmVM, localsStart: int, idx: int, val: uint64) {.inline.} =
  vm.locals[localsStart + idx] = val

# ---------------------------------------------------------------------------
# Block type helpers
# ---------------------------------------------------------------------------

proc blockResultArity(vm: var WasmVM, pad: uint16, cachedModIdx, instructionPc: int): int {.inline.} =
  ## Decode block result arity from compact pad field.
  ##   pad=0: empty (0 results), pad=1..0xFF: valtype (1 result),
  ##   pad>=0x100: type index (results.len)
  if pad == 0: return 0
  if pad < 0x100 and pad != WideBlockPad: return 1
  let typeIdx = if pad == WideBlockPad: int(vm.callStack[vm.callStackTop-1].code[].wideBlockIndex(instructionPc))
    else: int(pad-0x100)
  vm.store.modules[cachedModIdx].types[typeIdx].results.len

proc blockParamArity(vm: var WasmVM, pad: uint16, cachedModIdx, instructionPc: int): int {.inline.} =
  ## Decode block param arity from compact pad field.
  ##   pad < 0x100: 0 params, pad >= 0x100: type index (params.len)
  if pad < 0x100 and pad != WideBlockPad: return 0
  let typeIdx = if pad == WideBlockPad: int(vm.callStack[vm.callStackTop-1].code[].wideBlockIndex(instructionPc))
    else: int(pad-0x100)
  vm.store.modules[cachedModIdx].types[typeIdx].params.len

# ---------------------------------------------------------------------------
# Memory helpers
# ---------------------------------------------------------------------------

proc getMem(vm: var WasmVM, modIdx: int, memIdx: int = 0): var MemInst {.inline.} =
  let addr0 = vm.store.modules[modIdx].memAddrs[memIdx]
  vm.store.mems[addr0]

proc boundsCheck(mem: var MemInst, ea: uint64, size: int) {.inline.} =
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      let limit = mem.chunked[].byteLen()
      if ea > limit or size.uint64 > limit - ea:
        trap("out of bounds memory access")
      return
  when defined(wasmGuardPages):
    if mem.useGuard:
      return  # hardware guard pages handle the check
  if ea + size.uint64 > mem.data.len.uint64:
    trap("out of bounds memory access")

proc memBasePtr*(mem: var MemInst): ptr byte {.inline.} =
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      return nil  # chunked memory has no stable contiguous native pointer
  when defined(wasmGuardPages):
    if mem.useGuard:
      return cast[ptr byte](mem.guardMem.base)
  if mem.data.len > 0:
    return mem.data[0].addr
  nil

proc memBulkPtr(mem: var MemInst, offset: uint64): ptr byte {.inline.} =
  ## Pointer to byte at `offset` — works for both seq and guard-backed memory.
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      trap("chunked memory has no contiguous bulk pointer")
  when defined(wasmGuardPages):
    if mem.useGuard:
      return cast[ptr byte](cast[uint64](mem.guardMem.base) + offset)
  mem.data[offset.int].addr

proc memByteLen(mem: var MemInst): uint64 {.inline.} =
  ## Current accessible byte count.
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      return mem.chunked[].byteLen()
  when defined(wasmGuardPages):
    if mem.useGuard:
      return mem.guardMem.accessibleBytes
  mem.data.len.uint64

when defined(wasmSharedCoreTypes):
  proc transferMemoryAtomicWord(mem: var MemInst, offset: uint64, width: uint32,
      value: var uint64, writing: static bool, allowIo: bool): bool =
    # A naturally aligned word fits entirely in one chunk of at least 512
    # bytes. A blocked transfer has not read or changed any guest bytes.
    var bytes: array[8, byte]
    when writing:
      for i in 0 ..< width.int: bytes[i] = byte((value shr (8 * i)) and 0xff)
    template transferFlat() =
      when writing: copyMem(mem.memBulkPtr(offset), addr bytes[0], width.int)
      else: copyMem(addr bytes[0], mem.memBulkPtr(offset), width.int)
    when defined(wasmChunkedMemory):
      if mem.chunked != nil:
        let buffer = cast[ptr UncheckedArray[byte]](addr bytes[0])
        let status = when writing: mem.chunked[].writeAt(offset, buffer, width, allowIo)
          else: mem.chunked[].readAt(offset, buffer, width, allowIo)
        if status == lmWouldBlock: return false
        if status != lmOk: trap("linear memory atomic transfer failed: " & $status)
      else: transferFlat()
    else: transferFlat()
    when not writing:
      value = 0
      for i in 0 ..< width.int: value = value or (bytes[i].uint64 shl (8 * i))
    true

  proc checkAtomicAddress(mem: var MemInst, offset: uint64, width: uint32) {.inline.} =
    let length = mem.memByteLen()
    if offset > length or width.uint64 > length - offset:
      trap("out of bounds memory access")
    if (offset and (width - 1).uint64) != 0: trap("unaligned atomic memory access")

  proc executeMemoryAtomic(mem: var MemInst, access: MemoryAtomicSpec,
      offset, expected, input: uint64, allowIo: bool, previous: var uint64): bool =
    if access.kind == maInvalid: trap("unknown memory atomic operation")
    let width = 1'u32 shl access.alignment
    mem.checkAtomicAddress(offset, width)
    if access.kind != maStore and
        not mem.transferMemoryAtomicWord(offset, width, previous, false, allowIo):
      return false
    if access.kind == maLoad: return true
    if access.kind == maCompareExchange:
      let mask = uint64.high shr ((8 - width) * 8)
      if previous != (expected and mask): return true
    var replacement = case access.kind
      of maStore, maExchange, maCompareExchange: input
      of maAdd: previous + input
      of maSub: previous - input
      of maAnd: previous and input
      of maOr: previous or input
      of maXor: previous xor input
      else: trap("unknown memory atomic operation")
    mem.transferMemoryAtomicWord(offset, width, replacement, true, allowIo)

proc loadValSync[T](mem: var MemInst, ea: uint64): T {.inline.} =
  boundsCheck(mem, ea, sizeof(T))
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      let status = mem.chunked[].readAt(ea,
        cast[ptr UncheckedArray[byte]](result.addr), sizeof(T).uint32,
        allowIo = true)
      if status != lmOk: trap("linear memory read failed: " & $status)
      return
  when defined(wasmGuardPages):
    if mem.useGuard:
      copyMem(result.addr, cast[ptr byte](cast[uint64](mem.guardMem.base) + ea), sizeof(T))
      return
  copyMem(result.addr, mem.data[ea.int].unsafeAddr, sizeof(T))

proc storeValSync[T](mem: var MemInst, ea: uint64, val: T) {.inline.} =
  boundsCheck(mem, ea, sizeof(T))
  var v = val
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      let status = mem.chunked[].writeAt(ea,
        cast[ptr UncheckedArray[byte]](v.addr), sizeof(T).uint32,
        allowIo = true)
      if status != lmOk: trap("linear memory write failed: " & $status)
      return
  when defined(wasmGuardPages):
    if mem.useGuard:
      copyMem(cast[ptr byte](cast[uint64](mem.guardMem.base) + ea), v.addr, sizeof(T))
      return
  copyMem(mem.data[ea.int].addr, v.addr, sizeof(T))

proc writeBulk(mem: var MemInst, offset: uint64,
               src: ptr UncheckedArray[byte], count: uint32) =
  if count == 0: return
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      let status = mem.chunked[].writeAt(offset, src, count, allowIo = true)
      if status != lmOk: trap("linear memory bulk write failed: " & $status)
      return
  copyMem(mem.memBulkPtr(offset), src, count.int)

proc checkMemoryRange*(mem: var MemInst, offset: uint64, count: uint32) =
  let length = mem.memByteLen()
  if offset > length or count.uint64 > length - offset or
      count.uint64 > high(int).uint64:
    trap("linear memory range out of bounds")

proc readMemoryBytes*(mem: var MemInst, offset: uint64,
                      dst: ptr UncheckedArray[byte], count: uint32) =
  ## Synchronous bounded view for adapters that run outside a deadline slot.
  mem.checkMemoryRange(offset, count)
  if count == 0: return
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      let status = mem.chunked[].readAt(offset, dst, count, allowIo = true)
      if status != lmOk: trap("linear memory read failed: " & $status)
      return
  copyMem(dst, mem.memBulkPtr(offset), count.int)

proc writeMemoryBytes*(mem: var MemInst, offset: uint64,
                       src: ptr UncheckedArray[byte], count: uint32) =
  mem.checkMemoryRange(offset, count)
  mem.writeBulk(offset, src, count)

proc copyBulk(dst, src: var MemInst, d, s: uint64, count: uint32,
              sameMemory: bool) =
  if count == 0: return
  when defined(wasmChunkedMemory):
    if sameMemory and dst.chunked != nil:
      let status = dst.chunked[].copyWithin(d, s, count, allowIo = true)
      if status != lmOk: trap("linear memory copy failed: " & $status)
      return
  when defined(wasmChunkedMemory):
    let bothFlat = dst.chunked == nil and src.chunked == nil
  else:
    let bothFlat = true
  if bothFlat:
    if sameMemory:
      moveMem(dst.memBulkPtr(d), src.memBulkPtr(s), count.int)
    else:
      copyMem(dst.memBulkPtr(d), src.memBulkPtr(s), count.int)
    return
  when defined(wasmChunkedMemory):
    var scratch: array[64, byte]
    var done = 0'u32
    while done < count:
      let size = min(count - done, scratch.len.uint32)
      if src.chunked != nil:
        let status = src.chunked[].readAt(s + done.uint64,
          cast[ptr UncheckedArray[byte]](addr scratch[0]), size, allowIo = true)
        if status != lmOk: trap("linear memory copy read failed: " & $status)
      else:
        copyMem(addr scratch[0], src.memBulkPtr(s + done.uint64), size.int)
      dst.writeBulk(d + done.uint64,
        cast[ptr UncheckedArray[byte]](addr scratch[0]), size)
      done += size

proc fillBulk(mem: var MemInst, offset: uint64, value: byte, count: uint32) =
  if count == 0: return
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      let status = mem.chunked[].fillAt(offset, value, count, allowIo = true)
      if status != lmOk: trap("linear memory fill failed: " & $status)
      return
  let dst = mem.memBulkPtr(offset)
  for i in 0'u32 ..< count:
    (cast[ptr byte](cast[uint64](dst) + i.uint64))[] = value

proc pageCount(mem: var MemInst): int32 {.inline.} =
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      return cast[int32](mem.chunked[].currentPages())
  when defined(wasmGuardPages):
    if mem.useGuard:
      return int32(mem.guardMem.accessibleBytes div WasmPageSize.uint64)
  int32(mem.data.len div WasmPageSize)

proc growMemory(mem: var MemInst, delta: int32): int32 =
  ## Return the previous page count, or -1 as required by memory.grow.
  if delta < 0: return -1
  let oldPages = mem.pageCount().uint32
  let next = oldPages.uint64 + delta.uint32.uint64
  let declaredMax = if mem.memType.limits.hasMax:
                      mem.memType.limits.max.uint64
                    else:
                      MaxPages.uint64
  if next > declaredMax or next > MaxPages.uint64: return -1
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      var previous: uint32
      if mem.chunked[].grow(delta.uint32, previous) != lmOk: return -1
      return cast[int32](previous)
  when defined(wasmGuardPages):
    if mem.useGuard:
      if not growGuardedMem(mem.guardMem, next.int): return -1
      return cast[int32](oldPages)
  if next > uint64(high(int) div WasmPageSize): return -1
  mem.data.setLen(next.int * WasmPageSize)
  cast[int32](oldPages)

# ---------------------------------------------------------------------------
# Init expression evaluator (for globals, data/elem offsets)
# ---------------------------------------------------------------------------

proc evalModuleInitializer(vm: var WasmVM, expr: Expr, instance: ModuleInst): WasmValue =
  for instr in expr.code:
    case instr.op
    of opI32Const:
      return wasmI32(cast[int32](instr.imm1))
    of opI64Const:
      let u = uint64(instr.imm1) or (uint64(instr.imm2) shl 32)
      return wasmI64(cast[int64](u))
    of opF32Const:
      return wasmF32(cast[float32](instr.imm1))
    of opF64Const:
      let u = uint64(instr.imm1) or (uint64(instr.imm2) shl 32)
      return wasmF64(cast[float64](u))
    of opV128Const:
      if uint64(instr.imm1) >= uint64(expr.v128Consts.len): trap("invalid vector constant in initializer")
      return WasmValue(kind: wvkV128, v128: expr.v128Consts[int(instr.imm1)])
    of opGlobalGet:
      let globalIdx = instr.imm1.int
      let globalAddr = instance.globalAddrs[globalIdx]
      return vm.store.globals[globalAddr].value
    of opRefNull:
      let rtOrd = instr.imm1
      if rtOrd == uint32(ord(vtFuncRef)): return wasmNullFuncRef()
      elif rtOrd == uint32(ord(vtExternRef)): return wasmNullExternRef()
      else: trap("invalid ref.null type in init expr")
    of opRefFunc:
      let funcIdx = instr.imm1.int
      let funcAddr = instance.funcAddrs[funcIdx]
      return wasmFuncRef(funcAddr.int32)
    of opEnd:
      break
    else:
      trap("invalid instruction in init expression: " & $instr.op)
  trap("init expression did not produce a value")

proc evalInitExpr*(vm: var WasmVM, expr: Expr, modIdx: int): WasmValue =
  evalModuleInitializer(vm, expr, vm.store.modules[modIdx])

# ---------------------------------------------------------------------------
# Module instantiation
# ---------------------------------------------------------------------------

proc importLimitsMatch*(actual, required: Limits): bool =
  when defined(wasmSharedCoreTypes):
    if actual.shared != required.shared: return false
  actual.min >= required.min and
    (not required.hasMax or (actual.hasMax and actual.max <= required.max))

proc importTableTypeMatch*(actual, required: TableType): bool =
  when defined(wasmFunctionReferences):
    if not sameCoreReference(actual.elementReference, required.elementReference):
      return false
  actual.elemType == required.elemType and importLimitsMatch(actual.limits, required.limits)

when defined(wasmFunctionReferences):
  proc typedValueMatches(vm: WasmVM, lane: ValType, reference: CoreReferenceType,
                         value: WasmValue): bool =
    if value.kind != lane.toValueKind(): return false
    if not lane.isRefType(): return true
    if value.isNull(): return not reference.nonNull
    if value.kind != wvkFuncRef: return true
    let address = value.funcRef.int
    address >= 0 and address < vm.store.funcs.len and
      vm.store.funcs[address].funcType.matchesFunctionReference(reference)

  proc checkHostTable(vm: WasmVM, table: TableInst, expected: TableType) =
    let limits = table.tableType.limits
    if not importTableTypeMatch(table.tableType, expected) or
        table.elems.len.uint64 < limits.min.uint64 or
        (limits.hasMax and table.elems.len.uint64 > limits.max.uint64):
      trap("incompatible host table import")
    for value in table.elems:
      if not vm.typedValueMatches(expected.elemType, expected.elementReference, value):
        trap("host table element reference type mismatch")

proc allocateDefinedTables(vm: var WasmVM, module: WasmModule, instance: var ModuleInst) =
  when defined(wasmFunctionReferences):
    var nextInitializer = 0
  for i, tableType in module.tables:
    var initial = if tableType.elemType == vtFuncRef: wasmNullFuncRef()
                  else: wasmNullExternRef()
    when defined(wasmFunctionReferences):
      if nextInitializer < module.tableInitializers.len and
          module.tableInitializers[nextInitializer].index == i.uint32:
        let init {.cursor.} = module.tableInitializers[nextInitializer].init
        initial = vm.evalModuleInitializer(init, instance)
        inc nextInitializer
      if not vm.typedValueMatches(tableType.elemType, tableType.elementReference, initial):
        trap("table initializer reference type mismatch")
    if tableType.limits.min.uint64 > uint64(high(int) div sizeof(WasmValue)):
      trap("initial table size exceeds host address range")
    var elems = newSeq[WasmValue](tableType.limits.min.int)
    for entry in elems.mitems: entry = initial
    instance.tableAddrs.add(vm.store.tables.len)
    vm.store.tables.add(TableInst(tableType: tableType, elems: move elems))

proc bindStoreImport(vm: var WasmVM, modInst: var ModuleInst, module: WasmModule,
                     imp: Import, source: ExternalStoreRef) =
  ## Retain the address instead of copying mutable state out of its owner.
  let address = source.address
  if address < 0 or ord(imp.kind) != ord(source.kind):
    trap("incompatible store import")
  case imp.kind
  of ikFunc:
    if address >= vm.store.funcs.len or
        not vm.store.funcs[address].funcType.matchesCoreFunctionType(module.types[imp.funcTypeIdx.int]):
      trap("incompatible store function import")
    modInst.funcAddrs.add(address)
  of ikTable:
    if address >= vm.store.tables.len:
      trap("unknown store table")
    let actual = vm.store.tables[address].tableType
    if not importTableTypeMatch(actual, imp.tableType):
      trap("incompatible store table import")
    modInst.tableAddrs.add(address)
  of ikMemory:
    if address >= vm.store.mems.len: trap("unknown store memory")
    var actual = vm.store.mems[address].memType.limits
    actual.min = vm.store.mems[address].pageCount().uint32
    if not importLimitsMatch(actual, imp.memType.limits):
      trap("incompatible store memory import")
    modInst.memAddrs.add(address)
  of ikGlobal:
    if address >= vm.store.globals.len or
        not importGlobalTypeMatch(vm.store.globals[address].globalType, imp.globalType):
      trap("incompatible store global import")
    modInst.globalAddrs.add(address)
  of ikTag:
    if address >= vm.store.tags.len or
        vm.store.tags[address].funcType != module.types[imp.tagTypeIdx.int]:
      trap("incompatible store tag import")
    modInst.tagAddrs.add(address)

proc instantiateImpl(vm: var WasmVM, module: WasmModule,
    imports: openArray[(string, string, ExternalVal)],
    storeImports: openArray[StoreImport], ownedModule: ptr WasmModule,
    runStart = true): int =
  ## Instantiate a module into the VM store. Returns the module instance index.
  let modIdx = vm.store.modules.len
  var modInst = ModuleInst()
  modInst.types = module.types

  # --- Count imported functions/tables/mems/globals ---
  var importFuncCount = 0
  var importTableCount = 0
  var importMemCount = 0
  var importGlobalCount = 0

  for imp in module.imports:
    case imp.kind
    of ikFunc: inc importFuncCount
    of ikTable: inc importTableCount
    of ikMemory: inc importMemCount
    of ikGlobal: inc importGlobalCount
    of ikTag: discard

  # --- Resolve imports ---
  for imp in module.imports:
    var found = false
    for source in storeImports:
      if source.moduleName == imp.module and source.fieldName == imp.name:
        vm.bindStoreImport(modInst, module, imp, source.item)
        found = true
        break
    if found: continue
    for (impMod, impName, extVal) in imports:
      if impMod == imp.module and impName == imp.name:
        case imp.kind
        of ikFunc:
          if extVal.kind != ekFunc:
            trap("import type mismatch for " & imp.module & "." & imp.name & ": expected function")
          let expected {.cursor.} = module.types[imp.funcTypeIdx.int]
          if (expected.definition != nil or extVal.funcType.definition != nil) and
              not extVal.funcType.matchesCoreFunctionType(expected):
            trap("incompatible host function import")
          let funcAddr = vm.store.funcs.len
          vm.store.funcs.add(FuncInst(
            funcType: extVal.funcType,
            isHost: true,
            hostFunc: extVal.hostFunc
          ))
          modInst.funcAddrs.add(funcAddr)
        of ikTable:
          if extVal.kind != ekTable:
            trap("import type mismatch for " & imp.module & "." & imp.name & ": expected table")
          when defined(wasmFunctionReferences):
            vm.checkHostTable(extVal.tableInst, imp.tableType)
          let tableAddr = vm.store.tables.len
          vm.store.tables.add(extVal.tableInst)
          modInst.tableAddrs.add(tableAddr)
        of ikMemory:
          if extVal.kind != ekMemory:
            trap("import type mismatch for " & imp.module & "." & imp.name & ": expected memory")
          when defined(wasmSharedCoreTypes):
            if imp.memType.limits.shared or extVal.memInst.memType.limits.shared:
              trap("shared memory requires a store import")
          let memAddr = vm.store.mems.len
          vm.store.mems.add(extVal.memInst)
          modInst.memAddrs.add(memAddr)
        of ikGlobal:
          if extVal.kind != ekGlobal:
            trap("import type mismatch for " & imp.module & "." & imp.name & ": expected global")
          when defined(wasmFunctionReferences):
            let expected {.cursor.} = imp.globalType
            if not importGlobalTypeMatch(extVal.globalInst.globalType, expected) or
                not vm.typedValueMatches(expected.valType, expected.reference, extVal.globalInst.value):
              trap("incompatible host global import")
          let globalAddr = vm.store.globals.len
          vm.store.globals.add(extVal.globalInst)
          modInst.globalAddrs.add(globalAddr)
        of ikTag:
          trap("exception tags require a store import")
        found = true
        break
    if not found:
      trap("unresolved import: " & imp.module & "." & imp.name)

  # --- Allocate defined functions ---
  for i in 0 ..< module.funcTypeIdxs.len:
    let funcAddr = vm.store.funcs.len
    let typeIdx = module.funcTypeIdxs[i].int
    let ft = module.types[typeIdx]
    var localTys: seq[ValType] = @[]
    # Expand params
    for p in ft.params:
      localTys.add(p)
    # Expand body locals
    if i < module.codes.len:
      for ld in module.codes[i].locals:
        for j in 0'u32 ..< ld.count:
          localTys.add(ld.valType)
    # Caller-owned decoded modules may be moved, released, or edited after
    # instantiation. Retain a private expression at a stable heap address.
    var codeOwner: ref Expr
    if i < module.codes.len:
      new(codeOwner)
      if ownedModule == nil:
        codeOwner[] = module.codes[i].code
      else:
        codeOwner[] = move ownedModule[].codes[i].code
    vm.store.funcs.add(FuncInst(
      funcType: ft,
      isHost: false,
      moduleIdx: modIdx,
      funcIdx: i,
      code: if codeOwner != nil: addr codeOwner[] else: nil,
      codeOwner: codeOwner,
      localTypes: localTys
    ))
    modInst.funcAddrs.add(funcAddr)

  # --- Allocate defined tables ---
  vm.allocateDefinedTables(module, modInst)

  # --- Allocate defined memories ---
  for mt in module.memories:
    let memAddr = vm.store.mems.len
    let initialPages = mt.limits.min.int
    let maxPages = if mt.limits.hasMax: mt.limits.max.int else: 0
    when defined(wasmChunkedMemory):
      if vm.memoryFactory != nil:
        let backend = vm.memoryFactory(vm.memoryFactoryContext, mt)
        if backend == nil or backend[].currentPages() != mt.limits.min or
            backend[].byteLen() != mt.limits.min.uint64 * WasmPageSize.uint64:
          trap("memory backend rejected module minimum")
        vm.store.mems.add(MemInst(memType: mt, chunked: backend))
      else:
        when defined(wasmGuardPages):
          var mi = MemInst(memType: mt)
          mi.guardMem = allocGuardedMem(initialPages, maxPages)
          mi.useGuard = true
          vm.store.mems.add(mi)
        else:
          let numBytes = initialPages * WasmPageSize
          vm.store.mems.add(MemInst(memType: mt, data: newSeq[byte](numBytes)))
    else:
      when defined(wasmGuardPages):
        var mi = MemInst(memType: mt)
        mi.guardMem = allocGuardedMem(initialPages, maxPages)
        mi.useGuard = true
        vm.store.mems.add(mi)
      else:
        let numBytes = initialPages * WasmPageSize
        vm.store.mems.add(MemInst(
          memType: mt,
          data: newSeq[byte](numBytes)
        ))
    modInst.memAddrs.add(memAddr)

  # We need the module in store before evaluating init exprs (for global.get)
  vm.store.modules.add(modInst)

  # --- Allocate defined globals ---
  for gd in module.globals:
    let globalAddr = vm.store.globals.len
    let initVal = vm.evalInitExpr(gd.init, modIdx)
    when defined(wasmFunctionReferences):
      if not vm.typedValueMatches(gd.globalType.valType, gd.globalType.reference, initVal):
        trap("global initializer value type mismatch")
    vm.store.globals.add(GlobalInst(
      globalType: gd.globalType,
      value: initVal
    ))
    vm.store.modules[modIdx].globalAddrs.add(globalAddr)

  # --- Allocate element segments ---
  for es in module.elements:
    let elemAddr = vm.store.elems.len
    var elemInst = ElemInst(elemType: es.elemType, dropped: es.mode == elemDeclarative)
    when defined(wasmSharedCoreTypes):
      elemInst.shared = es.shared
    if not elemInst.dropped:
      for initExpr in es.init:
        elemInst.elems.add(vm.evalInitExpr(initExpr, modIdx))
    vm.store.elems.add(elemInst)
    vm.store.modules[modIdx].elemAddrs.add(elemAddr)

  # --- Allocate data segments ---
  for ds in module.datas:
    let dataAddr = vm.store.datas.len
    vm.store.datas.add(DataInst(data: ds.data, dropped: false))
    when defined(wasmSharedCoreTypes):
      vm.store.datas[dataAddr].shared = ds.shared
    vm.store.modules[modIdx].dataAddrs.add(dataAddr)

  # --- Initialize active element segments ---
  for i, es in module.elements:
    if es.mode == elemActive:
      let tableAddr = vm.store.modules[modIdx].tableAddrs[es.tableIdx.int]
      let offsetVal = vm.evalInitExpr(es.offset, modIdx)
      let rawOffset = offsetVal.i32.uint32.uint64
      let elemAddr = vm.store.modules[modIdx].elemAddrs[i]
      let elemInst = vm.store.elems[elemAddr]
      let tableSize = vm.store.tables[tableAddr].elems.len.uint64
      if rawOffset > tableSize or elemInst.elems.len.uint64 > tableSize - rawOffset:
        trap("out of bounds table access during element initialization")
      let offset = rawOffset.int
      for j in 0 ..< elemInst.elems.len:
        vm.store.tables[tableAddr].elems[offset + j] = elemInst.elems[j]
      vm.store.elems[elemAddr].dropped = true

  # --- Initialize active data segments ---
  for i, ds in module.datas:
    if ds.mode == dataActive:
      let memAddr = vm.store.modules[modIdx].memAddrs[ds.memIdx.int]
      let offsetVal = vm.evalInitExpr(ds.offset, modIdx)
      let offset = offsetVal.i32.uint32.uint64
      let dataAddr = vm.store.modules[modIdx].dataAddrs[i]
      let dataInst = vm.store.datas[dataAddr]
      when defined(wasmChunkedMemory):
        if vm.store.mems[memAddr].chunked != nil:
          let memorySize = vm.store.mems[memAddr].memByteLen()
          if offset > memorySize or dataInst.data.len.uint64 > memorySize - offset:
            trap("out of bounds memory access during data initialization")
          if runStart and dataInst.data.len > 0:
            vm.store.mems[memAddr].writeBulk(offset,
              cast[ptr UncheckedArray[byte]](dataInst.data[0].unsafeAddr),
              dataInst.data.len.uint32)
          vm.store.datas[dataAddr].dropped = true
          continue
      when defined(wasmGuardPages):
        if vm.store.mems[memAddr].useGuard:
          let guardBytes = vm.store.mems[memAddr].guardMem.accessibleBytes
          if offset > guardBytes or dataInst.data.len.uint64 > guardBytes - offset:
            trap("out of bounds memory access during data initialization")
          if runStart and dataInst.data.len > 0:
            let dst = cast[ptr byte](cast[uint64](vm.store.mems[memAddr].guardMem.base) + offset)
            copyMem(dst, dataInst.data[0].unsafeAddr, dataInst.data.len)
          vm.store.datas[dataAddr].dropped = true
          continue
      let memorySize = vm.store.mems[memAddr].data.len.uint64
      if offset > memorySize or dataInst.data.len.uint64 > memorySize - offset:
        trap("out of bounds memory access during data initialization")
      if runStart and dataInst.data.len > 0:
        copyMem(vm.store.mems[memAddr].data[offset.int].addr,
                dataInst.data[0].unsafeAddr,
                dataInst.data.len)
      vm.store.datas[dataAddr].dropped = true

  # --- Allocate exception tags ---
  for td in module.tagDefs:
    let tagAddr = vm.store.tags.len
    let ft = module.types[td.typeIdx.int]
    vm.store.tags.add(WasmTagInst(funcType: ft))
    vm.store.modules[modIdx].tagAddrs.add(tagAddr)

  # --- Exports ---
  for exp in module.exports:
    var ei = ExportInst(name: exp.name, kind: exp.kind)
    case exp.kind
    of ekFunc:
      ei.idx = vm.store.modules[modIdx].funcAddrs[exp.idx.int]
    of ekTable:
      ei.idx = vm.store.modules[modIdx].tableAddrs[exp.idx.int]
    of ekMemory:
      ei.idx = vm.store.modules[modIdx].memAddrs[exp.idx.int]
    of ekGlobal:
      ei.idx = vm.store.modules[modIdx].globalAddrs[exp.idx.int]
    of ekTag:
      ei.idx = vm.store.modules[modIdx].tagAddrs[exp.idx.int]
    vm.store.modules[modIdx].exports.add(ei)

  # --- Start function ---
  # --- Patch opCall instructions to use direct store indices ---
  # Replace module-relative funcIdx with pre-resolved store funcAddr.
  # This eliminates a double indirection at call time.
  let patchModInst = vm.store.modules[modIdx]
  for i in 0 ..< module.codes.len:
    let codeIdx = i
    let importFuncCount = patchModInst.funcAddrs.len - module.codes.len
    let funcStoreIdx = patchModInst.funcAddrs[importFuncCount + i]
    if funcStoreIdx < vm.store.funcs.len:
      let funcInst = vm.store.funcs[funcStoreIdx]
      if not funcInst.isHost and funcInst.code != nil:
        let code = funcInst.code
        for j in 0 ..< code[].code.len:
          if code[].code[j].op == opCall:
            let origIdx = code[].code[j].imm1.int
            if origIdx < patchModInst.funcAddrs.len:
              code[].code[j].imm1 = uint32(patchModInst.funcAddrs[origIdx])
              code[].code[j].pad = 1  # mark as pre-resolved

  if runStart and module.startFunc >= 0:
    let startFuncAddr = vm.store.modules[modIdx].funcAddrs[module.startFunc.int]
    discard vm.execute(startFuncAddr, [])

  result = modIdx

proc instantiate*(vm: var WasmVM, module: WasmModule,
                  imports: openArray[(string, string, ExternalVal)],
                  storeImports: openArray[StoreImport] = []): int =
  vm.instantiateImpl(module, imports, storeImports, nil)

proc instantiateOwned*(vm: var WasmVM, module: sink WasmModule,
                       imports: openArray[(string, string, ExternalVal)],
                       storeImports: openArray[StoreImport] = []): int =
  ## Consume a private decoded module so its code can move into the store.
  vm.instantiateImpl(module, imports, storeImports, addr module)

proc instantiateForRestore*(vm: var WasmVM, module: sink WasmModule): int =
  ## Prepare a private store. The validated snapshot supplies effects of the
  ## start function and active data segments, so the destination can restore
  ## directly into its own memory policy without paging in the initial image.
  vm.instantiateImpl(module, [], [], addr module, runStart = false)

# ---------------------------------------------------------------------------
# Branch helper
# ---------------------------------------------------------------------------

proc doBranch(vm: var WasmVM, labelDepth: int): int {.inline.} =
  ## Branch to the label at the given depth. Returns the new pc.
  let targetLabelIdx = vm.labelStackTop - 1 - labelDepth
  let targetLabel = vm.labelStack[targetLabelIdx]

  let arity = targetLabel.arity
  let sourceStart = vm.valueStackTop - arity
  if arity < 0 or sourceStart < 0 or targetLabel.stackHeight < 0 or
      targetLabel.stackHeight > sourceStart:
    trap("invalid branch stack height")
  if arity > 0:
    moveMem(addr vm.valueStack[targetLabel.stackHeight],
            addr vm.valueStack[sourceStart], arity * sizeof(uint64))
  vm.valueStackTop = targetLabel.stackHeight + arity

  if targetLabel.isLoop:
    vm.labelStackTop = targetLabelIdx + 1
  else:
    vm.labelStackTop = targetLabelIdx

  targetLabel.pc

# ---------------------------------------------------------------------------
# Float helpers
# ---------------------------------------------------------------------------

proc f32Nearest(v: float32): float32 =
  ## Round to nearest even (IEEE 754 roundTiesToEven)
  if v.isNaN: return v
  if v.classify in {fcInf, fcNegInf, fcZero, fcNegZero}: return v
  let rounded = round(v)
  let diff = v - rounded
  if abs(diff) == 0.5f:
    # Tie: round to even
    let r = rounded.int64
    if (r and 1) != 0:
      if v > 0: return rounded - 1.0f
      else: return rounded + 1.0f
  return rounded

proc f64Nearest(v: float64): float64 =
  ## Round to nearest even (IEEE 754 roundTiesToEven)
  if v.isNaN: return v
  if v.classify in {fcInf, fcNegInf, fcZero, fcNegZero}: return v
  let rounded = round(v)
  let diff = v - rounded
  if abs(diff) == 0.5:
    let r = rounded.int64
    if (r and 1) != 0:
      if v > 0: return rounded - 1.0
      else: return rounded + 1.0
  return rounded

proc f32Min(a, b: float32): float32 =
  if a.isNaN or b.isNaN: return float32(NaN)
  if a == 0 and b == 0:
    # Distinguish -0 and +0
    var ai: uint32
    var bi: uint32
    copyMem(ai.addr, a.unsafeAddr, 4)
    copyMem(bi.addr, b.unsafeAddr, 4)
    if (ai or bi) >= 0x80000000'u32: # at least one is negative zero
      var nz = -0.0f
      return nz
    return a
  if a < b: a else: b

proc f32Max(a, b: float32): float32 =
  if a.isNaN or b.isNaN: return float32(NaN)
  if a == 0 and b == 0:
    var ai: uint32
    var bi: uint32
    copyMem(ai.addr, a.unsafeAddr, 4)
    copyMem(bi.addr, b.unsafeAddr, 4)
    if (ai and bi) >= 0x80000000'u32: # both negative zero
      var nz = -0.0f
      return nz
    return 0.0f
  if a > b: a else: b

proc f64Min(a, b: float64): float64 =
  if a.isNaN or b.isNaN: return NaN
  if a == 0 and b == 0:
    var ai: uint64
    var bi: uint64
    copyMem(ai.addr, a.unsafeAddr, 8)
    copyMem(bi.addr, b.unsafeAddr, 8)
    if (ai or bi) >= 0x8000000000000000'u64:
      var nz = -0.0
      return nz
    return a
  if a < b: a else: b

proc f64Max(a, b: float64): float64 =
  if a.isNaN or b.isNaN: return NaN
  if a == 0 and b == 0:
    var ai: uint64
    var bi: uint64
    copyMem(ai.addr, a.unsafeAddr, 8)
    copyMem(bi.addr, b.unsafeAddr, 8)
    if (ai and bi) >= 0x8000000000000000'u64:
      var nz = -0.0
      return nz
    return 0.0
  if a > b: a else: b

proc f32Copysign(mag, sgn: float32): float32 =
  result = copySign(mag, sgn)

proc f64Copysign(mag, sgn: float64): float64 =
  result = copySign(mag, sgn)

# ---------------------------------------------------------------------------
# Integer rotation helpers
# ---------------------------------------------------------------------------

proc rotl32(val: uint32, count: uint32): uint32 {.inline.} =
  let k = count and 31
  if k == 0: return val
  (val shl k) or (val shr (32 - k))

proc rotr32(val: uint32, count: uint32): uint32 {.inline.} =
  let k = count and 31
  if k == 0: return val
  (val shr k) or (val shl (32 - k))

proc rotl64(val: uint64, count: uint64): uint64 {.inline.} =
  let k = count and 63
  if k == 0: return val
  (val shl k) or (val shr (64 - k))

proc rotr64(val: uint64, count: uint64): uint64 {.inline.} =
  let k = count and 63
  if k == 0: return val
  (val shr k) or (val shl (64 - k))

# ---------------------------------------------------------------------------
# Reinterpret cast helpers
# ---------------------------------------------------------------------------

proc reinterpretI32AsF32(v: int32): float32 {.inline.} =
  copyMem(result.addr, v.unsafeAddr, 4)

proc reinterpretI64AsF64(v: int64): float64 {.inline.} =
  copyMem(result.addr, v.unsafeAddr, 8)

proc reinterpretF32AsI32(v: float32): int32 {.inline.} =
  copyMem(result.addr, v.unsafeAddr, 4)

proc reinterpretF64AsI64(v: float64): int64 {.inline.} =
  copyMem(result.addr, v.unsafeAddr, 8)

# ---------------------------------------------------------------------------
# Truncation helpers (trapping and saturating)
# ---------------------------------------------------------------------------

proc truncI32F32S(v: float32): int32 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 2147483648.0f or tv < -2147483648.0f:
    trap("integer overflow")
  int32(tv)

proc truncI32F32U(v: float32): int32 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 4294967296.0f or tv < 0.0f:
    trap("integer overflow")
  cast[int32](uint32(tv))

proc truncI32F64S(v: float64): int32 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 2147483648.0 or tv < -2147483648.0:
    trap("integer overflow")
  int32(tv)

proc truncI32F64U(v: float64): int32 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 4294967296.0 or tv < 0.0:
    trap("integer overflow")
  cast[int32](uint32(tv))

proc truncI64F32S(v: float32): int64 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v.float64)
  if tv >= 9223372036854775808.0 or tv < -9223372036854775808.0:
    trap("integer overflow")
  int64(tv)

proc truncI64F32U(v: float32): int64 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v.float64)
  if tv >= 18446744073709551616.0 or tv < 0.0:
    trap("integer overflow")
  cast[int64](uint64(tv))

proc truncI64F64S(v: float64): int64 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 9223372036854775808.0 or tv < -9223372036854775808.0:
    trap("integer overflow")
  int64(tv)

proc truncI64F64U(v: float64): int64 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 18446744073709551616.0 or tv < 0.0:
    trap("integer overflow")
  cast[int64](uint64(tv))

# Saturating truncations
proc truncSatI32F32S(v: float32): int32 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 2147483647.0f: return int32.high
  if tv < -2147483648.0f: return int32.low
  int32(tv)

proc truncSatI32F32U(v: float32): int32 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 4294967295.0f: return cast[int32](uint32.high)
  if tv < 0.0f: return 0
  cast[int32](uint32(tv))

proc truncSatI32F64S(v: float64): int32 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 2147483647.0: return int32.high
  if tv < -2147483648.0: return int32.low
  int32(tv)

proc truncSatI32F64U(v: float64): int32 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 4294967295.0: return cast[int32](uint32.high)
  if tv < 0.0: return 0
  cast[int32](uint32(tv))

proc truncSatI64F32S(v: float32): int64 =
  if v.isNaN: return 0
  let tv = trunc(v.float64)
  if tv >= 9223372036854775807.0: return int64.high
  if tv < -9223372036854775808.0: return int64.low
  int64(tv)

proc truncSatI64F32U(v: float32): int64 =
  if v.isNaN: return 0
  let tv = trunc(v.float64)
  if tv >= 18446744073709551615.0: return cast[int64](uint64.high)
  if tv < 0.0: return 0
  cast[int64](uint64(tv))

proc truncSatI64F64S(v: float64): int64 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 9223372036854775807.0: return int64.high
  if tv < -9223372036854775808.0: return int64.low
  int64(tv)

proc truncSatI64F64U(v: float64): int64 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 18446744073709551615.0: return cast[int64](uint64.high)
  if tv < 0.0: return 0
  cast[int64](uint64(tv))

# ---------------------------------------------------------------------------
# Main execution loop
# ---------------------------------------------------------------------------

## On-stack-replacement trigger: filled by execute() when a top-level function's
## inner loops are hot enough to warrant immediate JIT compilation.
## The function runs to completion in the interpreter; the caller should compile
## the flagged function so subsequent invocations run at JIT speed.
type OsrTrigger* = object
  triggered*: bool   ## true when a function crossed the back-edge heat threshold
  funcAddr*: int     ## store funcAddr of the hot function

type
  WasmDeadlineClock* = proc(): uint64 {.nimcall.}

  WasmExecutionStatus* = enum
    wesReady
    wesRunning
    wesYielded
    wesMemoryBlocked
    wesComplete
    wesHostBlocked
    wesAtomicBlocked

  WasmContinuation* = object
    ## Native interpreter frames are never moved between cores. Only the
    ## guest PC, stacks, and arena tops are retained for local resumption.
    status*: WasmExecutionStatus
    instructions*: uint64
    funcAddr: int
    entryValueStackTop: int
    entryCallStackTop: int
    entryLabelStackTop: int
    entryLocalsTop: int
    when WasmAtomicWaitEnabled:
      atomicWait: WasmAtomicWait
    when WasmSuspendableHostCalls:
      hostWait: WasmHostWait
      hostVm: ptr WasmVM
      hostFuncAddr, hostCallStackTop: int
      hostTailCall: bool
    when defined(wasmChunkedMemory):
      faultMemAddr: int
      retryMemoryInstruction: bool
      transferProgress: uint32
      transferBytes: array[16, byte]
      copyCursor: LinearMemoryCopyCursor
      bulkDone: uint32
      bulkPartProgress: uint32
      bulkWriting: bool
      bulkScratch: array[64, byte]

proc continuationEntryFuncAddr*(continuation: WasmContinuation): int {.inline.} =
  continuation.funcAddr

const SuspendedExecution = {wesYielded, wesMemoryBlocked, wesHostBlocked, wesAtomicBlocked}

when WasmAtomicWaitEnabled:
  proc executionAtomicRemainingNs*(vm: var WasmVM, continuation: WasmContinuation): uint64 =
    ## Zero means ready. uint64.high means there is no scheduled wake.
    let wait {.cursor.} = continuation.atomicWait
    if continuation.status != wesAtomicBlocked or wait == nil or
        wait.owner != addr(vm): return uint64.high
    if wait.state != wawPending: return 0
    wait.atomicRemaining(if wait.duration == 0: 0'u64 else: vm.atomicClock())

  proc validateAtomicContinuation(vm: var WasmVM, wait: WasmAtomicWait) =
    if wait == nil or wait.state == wawAborted or wait.owner != addr(vm) or
        wait.stackTop != vm.callStackTop or
        wait.arena != addr(vm.callStack[0]):
      trap("stale interpreter atomic continuation")

when WasmSuspendableHostCalls:
  proc executionHostReady*(continuation: WasmContinuation): bool =
    continuation.status == wesHostBlocked and continuation.hostWait.ready != nil and
      continuation.hostWait.ready()

  proc finishHostWait(vm: var WasmVM, continuation: var WasmContinuation):
      seq[WasmValue] {.noinline.} =
    # Release captures if the result validation or completion callback traps.
    let finish = move continuation.hostWait.finish
    continuation.hostWait.ready = nil
    result = finish()
    let types {.cursor.} = vm.store.funcs[continuation.hostFuncAddr].funcType.results
    if result.len != types.len: trap("suspended host call result arity mismatch")
    for i, lane in result:
      if lane.kind != types[i].toValueKind(): trap("suspended host call result type mismatch")
    when defined(wasmFunctionReferences):
      vm.checkReferenceValues(vm.store.funcs[continuation.hostFuncAddr].funcType, result, false)

proc executionRunnable*(vm: var WasmVM, continuation: WasmContinuation): bool =
  case continuation.status
  of wesYielded: true
  of wesHostBlocked:
    when WasmSuspendableHostCalls: continuation.executionHostReady()
    else: false
  of wesAtomicBlocked:
    when WasmAtomicWaitEnabled: vm.executionAtomicRemainingNs(continuation) == 0
    else: false
  else: false

const OsrBackEdgeThreshold* = 50_000  ## back-edges before signalling OSR

proc executeImpl[resumable: static bool](vm: var WasmVM, funcAddr: int,
              args: openArray[WasmValue],
              profiler: ptr PgoProfiler,
              osrOut: ptr OsrTrigger,
              continuation: ptr WasmContinuation,
              instructionBudget: uint32,
              deadlineClock: WasmDeadlineClock,
              deadlineTick: uint64): seq[WasmValue] =
  ## Execute a function by its address in the store.
  ## Returns the function's result values.
  ## If osrOut is non-nil and the top-level function executes OsrBackEdgeThreshold
  ## loop back-edges, osrOut[].triggered is set to true so the caller can JIT-compile
  ## the function for subsequent calls.
  when WasmSuspendableHostCalls:
    # Nested guest execution must never complete a request in its caller's slot.
    let previousHostWaitSlot = vm.hostWaitSlot
    vm.hostWaitSlot = nil
    defer: vm.hostWaitSlot = previousHostWaitSlot
  let sliced = when resumable and WasmSuspendableHostCalls: continuation != nil
    else: resumable
  when resumable and WasmAtomicWaitEnabled:
    if sliced and continuation[].status == wesAtomicBlocked:
      let wait {.cursor.} = continuation[].atomicWait
      vm.validateAtomicContinuation(wait)
      if continuation[].funcAddr != funcAddr:
        trap("stale interpreter atomic continuation")
      if (deadlineClock != nil and deadlineClock() >= deadlineTick) or
          vm.executionAtomicRemainingNs(continuation[]) != 0:
        return @[]
      let resultBits = if wait.state == wawNotified: 0'u64 else: 2'u64
      if wait.state == wawPending: vm.removeAtomicWait(wait)
      wait.state = wawAborted
      continuation[].atomicWait = nil
      vm.pushRaw(resultBits)
      continuation[].status = wesYielded
  when resumable and WasmSuspendableHostCalls:
    if continuation != nil and continuation[].status == wesHostBlocked:
      if continuation[].funcAddr != funcAddr or continuation[].hostVm != (addr vm) or
          continuation[].hostCallStackTop != vm.callStackTop:
        trap("stale interpreter host continuation")
      if (deadlineClock != nil and deadlineClock() >= deadlineTick) or
          not continuation[].executionHostReady():
        return @[]
      let lanes = vm.finishHostWait(continuation[])
      continuation[].hostVm = nil
      if continuation[].hostTailCall:
        let frame = vm.callStack[vm.callStackTop - 1]
        vm.localsTop = frame.localsStart
        vm.labelStackTop = frame.labelStackStart
        dec vm.callStackTop
      if vm.callStackTop == continuation[].entryCallStackTop:
        vm.valueStackTop = continuation[].entryValueStackTop
        continuation[].status = wesComplete
        return lanes
      for lane in lanes: vm.pushRaw(wasmValueToRaw(lane))
      continuation[].status = wesYielded

    var hostWait: WasmHostWait
    template recordHostWait(address: int, tail: static bool) =
      continuation[].hostWait = move hostWait
      continuation[].hostVm = addr vm
      continuation[].hostFuncAddr = address
      continuation[].hostCallStackTop = vm.callStackTop
      continuation[].hostTailCall = tail
      continuation[].status = wesHostBlocked

  let funcInst {.cursor.} = vm.store.funcs[funcAddr]
  # Handle host functions directly
  if funcInst.isHost:
    when resumable:
      if sliced and continuation[].status in SuspendedExecution:
        trap("invalid host-function continuation")
    when defined(wasmFunctionReferences): vm.checkReferenceValues(funcInst.funcType, args, true)
    when resumable and WasmSuspendableHostCalls:
      if sliced:
        continuation[] = WasmContinuation(
          status: wesRunning, funcAddr: funcAddr,
          entryValueStackTop: vm.valueStackTop, entryCallStackTop: vm.callStackTop,
          entryLabelStackTop: vm.labelStackTop, entryLocalsTop: vm.localsTop)
        result = vm.callSuspendableHost(funcInst.hostFunc, args, hostWait)
        if hostWait.finish != nil: recordHostWait(funcAddr, false)
        else:
          when defined(wasmFunctionReferences): vm.checkReferenceValues(funcInst.funcType, result, false)
          continuation[].status = wesComplete
        return result
    elif resumable:
      continuation[].status = wesComplete
    result = funcInst.hostFunc(args)
    when defined(wasmFunctionReferences): vm.checkReferenceValues(funcInst.funcType, result, false)
    return

  let ft = funcInst.funcType
  var entryValueStackTop = vm.valueStackTop
  var entryCallStackTop = vm.callStackTop
  var entryLabelStackTop = vm.labelStackTop
  var entryLocalsTop = vm.localsTop
  var resuming = false
  when resumable:
    if sliced:
      resuming = continuation[].status in SuspendedExecution
      if resuming:
        if continuation[].funcAddr != funcAddr or
            vm.callStackTop <= continuation[].entryCallStackTop:
          trap("stale interpreter continuation")
        entryValueStackTop = continuation[].entryValueStackTop
        entryCallStackTop = continuation[].entryCallStackTop
        entryLabelStackTop = continuation[].entryLabelStackTop
        entryLocalsTop = continuation[].entryLocalsTop
      else:
        continuation[] = WasmContinuation(
          funcAddr: funcAddr, entryValueStackTop: entryValueStackTop,
          entryCallStackTop: entryCallStackTop, entryLabelStackTop: entryLabelStackTop,
          entryLocalsTop: entryLocalsTop)
      continuation[].status = wesRunning

  if not resuming:
    if args.len != ft.params.len:
      trap("argument count mismatch: expected " & $ft.params.len &
           ", got " & $args.len)

    when defined(wasmFunctionReferences): vm.checkReferenceValues(ft, args, true)

    # Allocate locals: params + body locals
    let localsStart = vm.localsTop
    let totalLocals = funcInst.localTypes.len
    while vm.localsTop + totalLocals > vm.locals.len:
      vm.locals.setLen(vm.locals.len * 2)

    # Copy args into params (convert WasmValue -> uint64)
    for i in 0 ..< ft.params.len:
      vm.locals[localsStart + i] = wasmValueToRaw(args[i])
    # Numeric locals start at zero and nullable reference locals at null.
    for i in ft.params.len ..< totalLocals:
      vm.locals[localsStart + i] = initialLocalBits(funcInst.localTypes[i])
    vm.localsTop = localsStart + totalLocals

    # Push frame
    let frame = Frame(
      pc: 0,
      code: funcInst.code,
      brTables: funcInst.code[].brTables.addr,
      localsStart: localsStart,
      localsCount: totalLocals,
      labelStackStart: vm.labelStackTop,
      returnArity: ft.results.len,
      moduleIdx: funcInst.moduleIdx,
      funcAddr: funcAddr
    )
    vm.pushFrame(frame)

    # Push implicit function-body label
    vm.pushLabel(Label(
      arity: ft.results.len,
      pc: funcInst.code[].code.len,  # end of function
      stackHeight: vm.valueStackTop,
      isLoop: false,
      catchTableIdx: -1
    ))

    # Pre-reserve value stack based on the function's known max stack depth.
    # This converts the per-push bounds check into an occasional resize.
    let needed = vm.valueStackTop + funcInst.code[].maxStackDepth.int + 8
    if needed > vm.valueStack.len:
      vm.valueStack.setLen(max(vm.valueStack.len * 2, needed))

  # Main dispatch loop — cached frame state for minimal overhead
  {.push checks: off.}  # Disable bounds checks on hot path
  var cachedCode: ptr UncheckedArray[Instr]
  var cachedCodeLen: int
  var cachedPc: int
  var cachedModIdx: int
  var cachedLocalsStart: int
  var cachedBrTables: ptr seq[BrTableData]
  var cachedFuncAddr: int
  # Self-call cache: avoids store.funcs lookup and redundant Frame field writes
  # for self-recursive calls (same function calling itself). Set on first
  # self-call, invalidated when a different function is entered.
  var scParamCount: int = -1    # -1 = cache invalid
  var scFuncAddr: int = -1
  var scTotalLocals: int
  var scReturnArity: int
  var scCode: ptr Expr
  var scCodeLen: int
  # Cache value stack as raw pointer + top index to avoid seq field indirection
  var sp: int = vm.valueStackTop  # stack pointer (value stack top)
  var vsBase: ptr UncheckedArray[uint64] = cast[ptr UncheckedArray[uint64]](vm.valueStack[0].addr)
  var locBase: ptr UncheckedArray[uint64] = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
  # OSR heat tracking: count loop back-edges executed in the top-level frame.
  # Only counts when osrOut is provided (i.e., executing inside TieredVM).
  var osrBackEdges: int = 0
  when resumable:
    var sliceInstructions = 0'u32
    var instructionSp = 0
  template trackOsrBackEdge() =
    ## Call at every loop back-edge in the top-level frame.
    ## Signals the caller to JIT-compile the function when the threshold is hit.
    if osrOut != nil and vm.callStackTop == entryCallStackTop + 1:
      inc osrBackEdges
      if osrBackEdges == OsrBackEdgeThreshold and not osrOut[].triggered:
        osrOut[].triggered = true
        osrOut[].funcAddr = cachedFuncAddr
  template loadFrameCache() =
    let f = vm.callStack[vm.callStackTop - 1]
    cachedCode = cast[ptr UncheckedArray[Instr]](f.code[].code[0].addr)
    cachedCodeLen = f.code[].code.len
    cachedPc = f.pc
    cachedModIdx = f.moduleIdx
    cachedLocalsStart = f.localsStart
    cachedBrTables = f.brTables
    cachedFuncAddr = f.funcAddr

  template loadFrameCacheFast() =
    ## Fast path for self-recursive call returns. When the parent frame's
    ## function is the same as the callee (cachedFuncAddr unchanged), only
    ## the varying fields (pc, localsStart) need restoring. Skips 5 loads
    ## (code, codeLen, brTables, moduleIdx, funcAddr) that are invariant.
    let f = vm.callStack[vm.callStackTop - 1]
    cachedPc = f.pc
    cachedLocalsStart = f.localsStart

  template saveFramePc() =
    vm.callStack[vm.callStackTop - 1].pc = cachedPc

  template syncSp() =
    ## Sync cached sp back to vm
    vm.valueStackTop = sp

  template refreshAfterHost() =
    # A synchronous host callback may execute a guest allocator or destructor.
    # That nested execution can move either arena even when the tops match.
    sp = vm.valueStackTop
    vsBase = cast[ptr UncheckedArray[uint64]](addr vm.valueStack[0])
    locBase = cast[ptr UncheckedArray[uint64]](addr vm.locals[0])

  template spush(val: uint64) =
    if unlikely(sp >= vm.valueStack.len):
      vm.valueStack.setLen(vm.valueStack.len * 2)
      vsBase = cast[ptr UncheckedArray[uint64]](vm.valueStack[0].addr)
    vsBase[sp] = val
    inc sp

  template spop(): uint64 =
    dec sp
    vsBase[sp]

  template invokeHost(callee: untyped, address: int, hostArgs: untyped, tail: static bool) =
    syncSp()
    when resumable and WasmSuspendableHostCalls:
      let hostResults = if sliced: vm.callSuspendableHost(callee.hostFunc, hostArgs, hostWait)
        else: callee.hostFunc(hostArgs)
      if hostWait.finish != nil:
        saveFramePc()
        continuation[].instructions += sliceInstructions.uint64
        recordHostWait(address, tail)
        return @[]
    else:
      let hostResults = callee.hostFunc(hostArgs)
    when defined(wasmFunctionReferences): vm.checkReferenceValues(callee.funcType, hostResults, false)
    refreshAfterHost()
    for lane in hostResults:
      spush(wasmValueToRaw(lane))

  template speek(): uint64 =
    vsBase[sp - 1]

  template spushI32(v: int32) = spush(cast[uint64](v.int64) and 0xFFFFFFFF'u64)
  template spopI32(): int32 = cast[int32](spop() and 0xFFFFFFFF'u64)
  template spushI64(v: int64) = spush(cast[uint64](v))
  template spopI64(): int64 = cast[int64](spop())
  template spushF32(v: float32) = spush(cast[uint64](cast[uint32](v)))
  template spopF32(): float32 = (var spopF32Bits = uint32(spop() and 0xFFFFFFFF'u64); cast[float32](spopF32Bits))
  template spushF64(v: float64) = spush(cast[uint64](v))
  template spopF64(): float64 = cast[float64](spop())

  template reloadLocBase() =
    locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)

  template suspendMemoryFault(faultAddr: int) =
    when resumable and defined(wasmChunkedMemory):
      sp = instructionSp
      dec cachedPc
      syncSp()
      saveFramePc()
      dec sliceInstructions  # The faulted instruction has not completed.
      continuation[].instructions += sliceInstructions.uint64
      continuation[].faultMemAddr = faultAddr
      continuation[].retryMemoryInstruction = true
      continuation[].status = wesMemoryBlocked
      return @[]

  template loadVal[T](memoryIndex: int, ea: uint64): T =
    block:
      let memAddr = vm.store.modules[cachedModIdx].memAddrs[memoryIndex]
      template mem: untyped = vm.store.mems[memAddr]
      when resumable and defined(wasmChunkedMemory):
        if sliced and mem.chunked != nil:
          var value: T
          let status = mem.chunked[].readAtProgress(ea,
            cast[ptr UncheckedArray[byte]](addr continuation[].transferBytes[0]),
            sizeof(T).uint32, continuation[].transferProgress)
          if status == lmWouldBlock:
            suspendMemoryFault(memAddr)
          if status != lmOk: trap("linear memory read failed: " & $status)
          copyMem(addr value, addr continuation[].transferBytes[0], sizeof(T))
          continuation[].transferProgress = 0
          value
        else:
          loadValSync[T](mem, ea)
      else:
        loadValSync[T](mem, ea)

  template storeVal[T](memoryIndex: int, ea: uint64, val: T) =
    block:
      let memAddr = vm.store.modules[cachedModIdx].memAddrs[memoryIndex]
      template mem: untyped = vm.store.mems[memAddr]
      when resumable and defined(wasmChunkedMemory):
        if sliced and mem.chunked != nil:
          if continuation[].transferProgress == 0:
            var value = val
            copyMem(addr continuation[].transferBytes[0], addr value, sizeof(T))
          let status = mem.chunked[].writeAtProgress(ea,
            cast[ptr UncheckedArray[byte]](addr continuation[].transferBytes[0]),
            sizeof(T).uint32, continuation[].transferProgress)
          if status == lmWouldBlock:
            suspendMemoryFault(memAddr)
          if status != lmOk: trap("linear memory write failed: " & $status)
          continuation[].transferProgress = 0
        else:
          storeValSync[T](mem, ea, val)
      else:
        storeValSync[T](mem, ea, val)

  template inlineBranch(depth: int) =
    ## Inline fast-path branch for arity 0/1 (same logic as opBr).
    ## Avoids the syncSp → doBranch → sp reload round-trip for common cases.
    let ibTargetIdx = vm.labelStackTop - 1 - depth
    let ibTarget = vm.labelStack[ibTargetIdx]
    if ibTarget.arity == 0:
      sp = ibTarget.stackHeight
      if ibTarget.isLoop:
        vm.labelStackTop = ibTargetIdx + 1
        trackOsrBackEdge()
      else:
        vm.labelStackTop = ibTargetIdx
      cachedPc = ibTarget.pc
    elif ibTarget.arity == 1:
      let ibRetVal = vsBase[sp - 1]
      sp = ibTarget.stackHeight + 1
      vsBase[ibTarget.stackHeight] = ibRetVal
      if ibTarget.isLoop:
        vm.labelStackTop = ibTargetIdx + 1
        trackOsrBackEdge()
      else:
        vm.labelStackTop = ibTargetIdx
      cachedPc = ibTarget.pc
    else:
      syncSp()
      cachedPc = vm.doBranch(depth)
      sp = vm.valueStackTop
    continue

  loadFrameCache()

  # Main dispatch loop
  while vm.callStackTop > entryCallStackTop:
    when resumable:
      # A hard-slot caller supplies a core-local deadline clock. Checking at
      # each guest instruction boundary bounds guest compute preemption to
      # one decoded instruction; host imports and backing I/O need separate
      # admission and may not run inside a hard slot.
      if sliced and (sliceInstructions >= instructionBudget or
          (deadlineClock != nil and deadlineClock() >= deadlineTick)):
        syncSp()
        saveFramePc()
        continuation[].instructions += sliceInstructions.uint64
        continuation[].status = wesYielded
        return @[]
    when resumable and defined(wasmChunkedMemory):
      if sliced: continuation[].retryMemoryInstruction = false
    if unlikely(cachedPc >= cachedCodeLen):
      # Implicit return — function body end reached
      let curFrame = vm.callStack[vm.callStackTop - 1]
      vm.localsTop = curFrame.localsStart
      vm.labelStackTop = curFrame.labelStackStart
      dec vm.callStackTop
      discard curFrame.returnArity  # stack already clean for validated WASM
      if vm.callStackTop > entryCallStackTop:
        loadFrameCache()
        locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
      continue

    when resumable:
      instructionSp = sp
    let instr = cachedCode[cachedPc]
    inc cachedPc
    when resumable:
      inc sliceInstructions

    when defined(wasmTrace):
      block traceBlock:
        # Only trace when the function has 12+ locals (sort function) to reduce noise
        let traceLocCount = vm.callStack[vm.callStackTop - 1].localsCount
        if traceLocCount >= 12:
          var line = "  [" & $(cachedPc - 1) & "] " & $instr.op
          # Add immediates
          case instr.op
          of opLocalGet, opLocalSet, opLocalTee:
            line &= " idx=" & $instr.imm1
          of opI32Const:
            line &= " " & $cast[int32](instr.imm1)
          of opI32Load, opI32Store:
            line &= " off=" & $instr.imm1
          of opBr, opBrIf:
            line &= " depth=" & $instr.imm1
          of opBlock, opLoop, opIf:
            line &= " end=" & $instr.imm1 & " else=" & $instr.imm2
          of opLocalGetLocalGet, opLocalSetLocalGet, opLocalTeeLocalGet, opLocalGetLocalTee:
            line &= " " & $instr.imm1 & "," & $instr.imm2
          of opLocalGetI32Add, opLocalGetI32Sub:
            line &= " loc=" & $instr.imm1
          of opI32ConstI32Add, opI32ConstI32Sub:
            line &= " C=" & $cast[int32](instr.imm1)
          of opI32ConstI32GeS, opI32ConstI32LtS:
            line &= " C=" & $cast[int32](instr.imm1)
          of opI32ConstI32GtU:
            line &= " C=" & $instr.imm1
          of opLocalGetLocalGetI32Add, opLocalGetLocalGetI32Sub:
            line &= " " & $instr.imm1 & "," & $instr.imm2
          of opLocalGetI32ConstI32Sub, opLocalGetI32ConstI32Add:
            line &= " loc=" & $instr.imm1 & " C=" & $cast[int32](instr.imm2)
          of opI32AddLocalSet, opI32SubLocalSet:
            line &= " loc=" & $instr.imm1
          of opLocalGetI32Const:
            line &= " loc=" & $instr.imm1 & " C=" & $cast[int32](instr.imm2)
          of opI32EqzBrIf,
             opI32EqBrIf, opI32NeBrIf, opI32LtSBrIf, opI32GeSBrIf,
             opI32GtSBrIf, opI32LeSBrIf, opI32LtUBrIf, opI32GeUBrIf,
             opI32GtUBrIf, opI32LeUBrIf:
            line &= " depth=" & $instr.imm1
          of opI32ConstI32EqBrIf, opI32ConstI32NeBrIf, opI32ConstI32LtSBrIf,
             opI32ConstI32GeSBrIf, opI32ConstI32GtUBrIf, opI32ConstI32LeUBrIf:
            line &= " C=" & $cast[int32](instr.imm1) & " depth=" & $instr.imm2
          of opLocalTeeBrIf:
            line &= " loc=" & $instr.imm1 & " depth=" & $instr.imm2
          of opLocalGetI64Add, opLocalGetI64Sub:
            line &= " loc=" & $instr.imm1
          of opLocalI32AddInPlace, opLocalI32SubInPlace:
            line &= " loc=" & $instr.imm1 & " C=" & $cast[int32](instr.imm2)
          of opLocalGetLocalGetI32AddLocalSet, opLocalGetLocalGetI32SubLocalSet:
            line &= " X=" & $(instr.imm1 and 0xFFFF'u32) & " Y=" & $(instr.imm1 shr 16) &
                    " Z=" & $instr.imm2
          else:
            if instr.imm1 != 0: line &= " imm1=" & $instr.imm1
          # Stack top 3
          line &= "  | stack["
          let nShow = min(sp, 3)
          for si in countdown(nShow - 1, 0):
            if si < nShow - 1: line &= ", "
            line &= $cast[int32](vsBase[sp - 1 - si] and 0xFFFFFFFF'u64)
          line &= "] sp=" & $sp
          # Show key locals
          line &= " L[0..5]=["
          let ls = cachedLocalsStart
          for li in 0..min(12, traceLocCount - 1):
            if li > 0: line &= ","
            line &= $cast[int32](locBase[ls + li] and 0xFFFFFFFF'u64)
          line &= "]"
          # Dump label stack for branch instructions
          if instr.op in {opBr, opBrIf, opBrTable}:
            line &= " labels["
            let lstart = vm.callStack[vm.callStackTop - 1].labelStackStart
            for li in lstart ..< vm.labelStackTop:
              if li > lstart: line &= ","
              let l = vm.labelStack[li]
              line &= (if l.isLoop: "L" else: "B") & "(" & $l.pc & ")"
            line &= "]"
          echo line

    {.computedGoto.}
    case instr.op
    # ===== Control =====
    of opUnreachable:
      trap("unreachable executed")

    of opNop:
      discard

    of opBlock:
      let resultArity = vm.blockResultArity(instr.pad, cachedModIdx, cachedPc-1)
      let paramArity = vm.blockParamArity(instr.pad, cachedModIdx, cachedPc-1)
      # imm1 = index of matching end instruction
      let endIdx = instr.imm1.int
      let sh = sp - paramArity
      vm.pushLabel(Label(
        arity: resultArity,
        pc: endIdx + 1,  # continuation is after end
        stackHeight: sh,
        isLoop: false,
        catchTableIdx: -1
      ))

    of opLoop:
      let paramArity = vm.blockParamArity(instr.pad, cachedModIdx, cachedPc-1)
      let loopStart = cachedPc  # already advanced past the loop instruction
      let sh = sp - paramArity
      vm.pushLabel(Label(
        arity: paramArity,  # loop branches to start, arity = params
        pc: loopStart,
        stackHeight: sh,
        isLoop: true,
        catchTableIdx: -1
      ))

    of opIf:
      let cond = spopI32()
      let resultArity = vm.blockResultArity(instr.pad, cachedModIdx, cachedPc-1)
      let paramArity = vm.blockParamArity(instr.pad, cachedModIdx, cachedPc-1)
      let endIdx = instr.imm1.int
      let elseIdx = instr.imm2.int
      let sh = sp - paramArity
      if cond == 0 and elseIdx == endIdx:
        # No else clause and condition is false: skip entire if block
        # Don't push a label — we jump past the end, so opEnd won't pop it
        cachedPc = endIdx + 1
      else:
        vm.pushLabel(Label(
          arity: resultArity,
          pc: endIdx + 1,
          stackHeight: sh,
          isLoop: false,
          catchTableIdx: -1
        ))
        if cond == 0:
          # Jump to else clause
          cachedPc = elseIdx + 1

    of opElse:
      # We're in the then-branch; pop the if label and jump past end.
      # The else-path never reaches opElse (opIf jumps directly to elseIdx+1),
      # so opEnd won't see this label again.
      let lbl = vm.popLabel()
      cachedPc = lbl.pc  # jump to end+1

    of opEnd:
      if vm.labelStackTop > vm.callStack[vm.callStackTop - 1].labelStackStart:
        discard vm.popLabel()
      else:
        # End of function body — return
        let curFrame = vm.callStack[vm.callStackTop - 1]
        let arity = curFrame.returnArity
        vm.localsTop = curFrame.localsStart
        vm.labelStackTop = curFrame.labelStackStart
        dec vm.callStackTop  # inline popFrame

        # Restore stack: keep only the arity return values
        if arity == 0:
          discard  # nothing to do
        elif arity == 1:
          # Single return: move it to the label's stack height
          let retVal = vsBase[sp - 1]
          sp = vm.labelStack[curFrame.labelStackStart].stackHeight
          vsBase[sp] = retVal
          inc sp
        else:
          let target = vm.labelStack[curFrame.labelStackStart].stackHeight
          let source = sp - arity
          if source < 0 or target < 0 or target > source:
            trap("invalid return stack height")
          moveMem(addr vsBase[target], addr vsBase[source], arity * sizeof(uint64))
          sp = target + arity

        if vm.callStackTop > entryCallStackTop:
          loadFrameCache()
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
        continue

    of opBr:
      let depth = instr.imm1.int
      let targetLabelIdx = vm.labelStackTop - 1 - depth
      let targetLabel = vm.labelStack[targetLabelIdx]
      if targetLabel.arity == 0:
        sp = targetLabel.stackHeight
        if targetLabel.isLoop:
          vm.labelStackTop = targetLabelIdx + 1
          trackOsrBackEdge()
        else:
          vm.labelStackTop = targetLabelIdx
        cachedPc = targetLabel.pc
      elif targetLabel.arity == 1:
        let retVal = vsBase[sp - 1]
        sp = targetLabel.stackHeight + 1
        vsBase[targetLabel.stackHeight] = retVal
        if targetLabel.isLoop:
          vm.labelStackTop = targetLabelIdx + 1
          trackOsrBackEdge()
        else:
          vm.labelStackTop = targetLabelIdx
        cachedPc = targetLabel.pc
      else:
        syncSp()
        cachedPc = vm.doBranch(depth)
        sp = vm.valueStackTop
      continue

    of opBrIf:
      let cond = spopI32()
      if profiler != nil:
        profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, cond != 0)
      if cond != 0:
        let depth = instr.imm1.int
        let targetLabelIdx = vm.labelStackTop - 1 - depth
        let targetLabel = vm.labelStack[targetLabelIdx]
        if targetLabel.arity == 0:
          sp = targetLabel.stackHeight
          if targetLabel.isLoop:
            vm.labelStackTop = targetLabelIdx + 1
            trackOsrBackEdge()
          else:
            vm.labelStackTop = targetLabelIdx
          cachedPc = targetLabel.pc
        elif targetLabel.arity == 1:
          let retVal = vsBase[sp - 1]
          sp = targetLabel.stackHeight + 1
          vsBase[targetLabel.stackHeight] = retVal
          if targetLabel.isLoop:
            vm.labelStackTop = targetLabelIdx + 1
            trackOsrBackEdge()
          else:
            vm.labelStackTop = targetLabelIdx
          cachedPc = targetLabel.pc
        else:
          syncSp()
          cachedPc = vm.doBranch(depth)
          sp = vm.valueStackTop
        continue

    of opBrTable:
      let idx = spopI32()
      let btData = cachedBrTables[][instr.imm1.int]
      let target = if idx >= 0 and idx.int < btData.labels.len: btData.labels[idx.int]
                   else: btData.defaultLabel
      syncSp()
      cachedPc = vm.doBranch(target.int)
      sp = vm.valueStackTop
      continue

    of opReturn:
      let curFrame = vm.callStack[vm.callStackTop - 1]
      let arity = curFrame.returnArity
      let labelSh = vm.labelStack[curFrame.labelStackStart].stackHeight
      if arity == 1:
        let retVal = vsBase[sp - 1]
        sp = labelSh
        vsBase[sp] = retVal
        inc sp
      elif arity == 0:
        sp = labelSh
      else:
        let source = sp - arity
        if source < 0 or labelSh < 0 or labelSh > source:
          trap("invalid return stack height")
        moveMem(addr vsBase[labelSh], addr vsBase[source], arity * sizeof(uint64))
        sp = labelSh + arity
      vm.localsTop = curFrame.localsStart
      vm.labelStackTop = curFrame.labelStackStart
      dec vm.callStackTop
      if vm.callStackTop <= entryCallStackTop:
        break
      # Fast path: if parent frame is the same function (self-recursive return),
      # only restore the 2 varying fields (pc, localsStart). Skip 5 invariant
      # loads (code, codeLen, brTables, moduleIdx, funcAddr).
      if vm.callStack[vm.callStackTop - 1].funcAddr == cachedFuncAddr:
        loadFrameCacheFast()
      else:
        loadFrameCache()
      locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
      continue

    of opCall:
      # pad=1 means imm1 is already the direct store index (pre-resolved)
      let calleeAddr = if instr.pad == 1: instr.imm1.int
                        else: vm.store.modules[cachedModIdx].funcAddrs[instr.imm1.int]

      # Self-recursive call fast path: skip store.funcs lookup, skip invariant
      # Frame/Label field writes, skip redundant loadFrameCache fields.
      # The self-call cache (sc*) is populated on the first self-call and
      # reused on subsequent calls to the same function.
      if calleeAddr == cachedFuncAddr and calleeAddr == scFuncAddr and scParamCount >= 0:
        let newLocalsStart = vm.localsTop
        let needed = newLocalsStart + scTotalLocals

        if unlikely(needed > vm.locals.len):
          vm.locals.setLen(needed * 2)
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)

        sp -= scParamCount
        for i in 0 ..< scParamCount:
          locBase[newLocalsStart + i] = vsBase[sp + i]
        for i in scParamCount ..< scTotalLocals:
          locBase[newLocalsStart + i] = initialLocalBits(vm.store.funcs[cachedFuncAddr].localTypes[i])
        vm.localsTop = needed

        # Save caller pc; write only varying Frame fields
        vm.callStack[vm.callStackTop - 1].pc = cachedPc
        vm.pushFrame(Frame(
          pc: 0,
          code: scCode,
          brTables: scCode[].brTables.addr,
          localsStart: newLocalsStart,
          localsCount: scTotalLocals,
          labelStackStart: vm.labelStackTop,
          returnArity: scReturnArity,
          moduleIdx: cachedModIdx,
          funcAddr: calleeAddr
        ))

        vm.pushLabel(Label(
          arity: scReturnArity,
          pc: scCodeLen,
          stackHeight: sp,
          isLoop: false,
          catchTableIdx: -1
        ))

        # Only update varying cached fields (code/brTables/moduleIdx/funcAddr unchanged)
        cachedPc = 0
        cachedLocalsStart = newLocalsStart
        continue

      # Cursor avoids copying FuncInst (which has seq fields that trigger
      # atomic refcount ops under --mm:atomicArc on every call)
      let callee {.cursor.} = vm.store.funcs[calleeAddr]

      if unlikely(callee.isHost):
        let nParams = callee.funcType.params.len
        var hostArgs = newSeq[WasmValue](nParams)
        for i in countdown(nParams - 1, 0):
          hostArgs[i] = rawToWasmValue(spop(), callee.funcType.params[i])
        invokeHost(callee, calleeAddr, hostArgs, false)
      else:
        let paramCount = callee.funcType.params.len
        let newLocalsStart = vm.localsTop
        let newTotalLocals = callee.localTypes.len
        let calleeCode = callee.code
        let returnArity = callee.funcType.results.len
        let calleeModIdx = callee.moduleIdx
        let needed = newLocalsStart + newTotalLocals

        # Ensure locals capacity (single check)
        if unlikely(needed > vm.locals.len):
          vm.locals.setLen(needed * 2)
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)

        # Pop args directly into locals (no temp array)
        sp -= paramCount
        for i in 0 ..< paramCount:
          locBase[newLocalsStart + i] = vsBase[sp + i]
        for i in paramCount ..< newTotalLocals:
          locBase[newLocalsStart + i] = initialLocalBits(callee.localTypes[i])
        vm.localsTop = needed

        # Populate self-call cache if this is a self-recursive call
        if calleeAddr == cachedFuncAddr:
          scFuncAddr = calleeAddr
          scParamCount = paramCount
          scTotalLocals = newTotalLocals
          scReturnArity = returnArity
          scCode = calleeCode
          scCodeLen = calleeCode[].code.len
        else:
          scParamCount = -1  # invalidate: entering a different function

        # Save the caller PC before growing the execution arena.
        vm.callStack[vm.callStackTop - 1].pc = cachedPc
        vm.pushFrame(Frame(
          pc: 0,
          code: calleeCode,
          brTables: calleeCode[].brTables.addr,
          localsStart: newLocalsStart,
          localsCount: newTotalLocals,
          labelStackStart: vm.labelStackTop,
          returnArity: returnArity,
          moduleIdx: calleeModIdx,
          funcAddr: calleeAddr
        ))

        vm.pushLabel(Label(
          arity: returnArity,
          pc: calleeCode[].code.len,
          stackHeight: sp,
          isLoop: false,
          catchTableIdx: -1
        ))

        # Inline loadFrameCache for callee
        cachedCode = cast[ptr UncheckedArray[Instr]](calleeCode[].code[0].addr)
        cachedCodeLen = calleeCode[].code.len
        cachedPc = 0
        cachedModIdx = calleeModIdx
        cachedLocalsStart = newLocalsStart
        cachedBrTables = calleeCode[].brTables.addr
        cachedFuncAddr = calleeAddr
        continue

    of opCallIndirect, opCallRef:
      let typeIdx = instr.imm1.int
      let modIdx = cachedModIdx
      var calleeAddr: int
      if instr.op == opCallRef:
        when defined(wasmFunctionReferences):
          calleeAddr = vm.resolveFunctionReference(modIdx, typeIdx, spopI32())
        else: trap("typed function references are disabled")
      else:
        let tableIdx = instr.imm2.int
        let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
        let elemIdx = spopI32()
        if elemIdx < 0 or elemIdx.int >= vm.store.tables[tableAddr].elems.len:
          trap("undefined element")

        # --- 2-way associative inline cache ---
        # Key encodes the call site uniquely: upper 32 bits = funcAddr,
        # lower 32 bits = PC of this call_indirect instruction.
        # Power-of-two 2-way cache; both entries are checked in order.
        let icKey  = (cachedFuncAddr.uint64 shl 32) or (cachedPc - 1).uint32.uint64
        let icSlot = (icKey and (vm.callIcBuf.len.uint64 - 1'u64)).int
        var skipTypeCheck = false
        block icCheck:
          # Check entry A first, then entry B.
          template tryEntry(entry: CallIcEntry) =
            if entry.key == icKey and entry.elemIdx == elemIdx:
              let cachedCallee = entry.calleeAddr.int
              let elem2 = vm.store.tables[tableAddr].elems[elemIdx.int]
              if elem2.kind == wvkFuncRef and elem2.funcRef == cachedCallee:
                calleeAddr = cachedCallee
                skipTypeCheck = true
                break icCheck
          tryEntry(vm.callIcBuf[icSlot].a)
          tryEntry(vm.callIcBuf[icSlot].b)
        if not skipTypeCheck:
          let elem = vm.store.tables[tableAddr].elems[elemIdx.int]
          if elem.kind != wvkFuncRef:
            trap("indirect call on non-funcref")
          if elem.funcRef < 0:
            trap("uninitialized element")
          calleeAddr = elem.funcRef.int
          if calleeAddr >= vm.store.funcs.len:
            trap("undefined function")
          let callee2 {.cursor.} = vm.store.funcs[calleeAddr]
          let expectedType {.cursor.} = vm.store.modules[modIdx].types[typeIdx]
          if not callee2.funcType.matchesCoreFunctionType(expectedType):
            trap("indirect call type mismatch")
          # Update the LRU entry: evictB toggles on each miss so both entries age fairly.
          let newEntry = CallIcEntry(key: icKey, elemIdx: elemIdx,
                                     calleeAddr: calleeAddr.int32)
          if vm.callIcBuf[icSlot].evictB:
            vm.callIcBuf[icSlot].b = newEntry
          else:
            vm.callIcBuf[icSlot].a = newEntry
          vm.callIcBuf[icSlot].evictB = not vm.callIcBuf[icSlot].evictB

      let callee {.cursor.} = vm.store.funcs[calleeAddr]

      # Record call_indirect target for PGO before dispatching.
      if profiler != nil:
        profiler[].recordCallIndirect(cachedFuncAddr, cachedPc - 1, calleeAddr.int32)

      if callee.isHost:
        let nParams = callee.funcType.params.len
        var hostArgs = newSeq[WasmValue](nParams)
        for i in countdown(nParams - 1, 0):
          hostArgs[i] = rawToWasmValue(spop(), callee.funcType.params[i])
        invokeHost(callee, calleeAddr, hostArgs, false)
      else:
        let paramCount = callee.funcType.params.len
        let newLocalsStart = vm.localsTop
        let newTotalLocals = callee.localTypes.len
        let calleeCode = callee.code
        let returnArity = callee.funcType.results.len
        let calleeModIdx = callee.moduleIdx
        let needed = newLocalsStart + newTotalLocals

        # Ensure locals capacity (single check)
        if unlikely(needed > vm.locals.len):
          vm.locals.setLen(needed * 2)
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)

        # Pop args directly into locals (no temp array — same as opCall)
        sp -= paramCount
        for i in 0 ..< paramCount:
          locBase[newLocalsStart + i] = vsBase[sp + i]
        for i in paramCount ..< newTotalLocals:
          locBase[newLocalsStart + i] = initialLocalBits(callee.localTypes[i])
        vm.localsTop = needed

        # Save the caller PC before growing the execution arena.
        vm.callStack[vm.callStackTop - 1].pc = cachedPc
        vm.pushFrame(Frame(
          pc: 0,
          code: calleeCode,
          brTables: calleeCode[].brTables.addr,
          localsStart: newLocalsStart,
          localsCount: newTotalLocals,
          labelStackStart: vm.labelStackTop,
          returnArity: returnArity,
          moduleIdx: calleeModIdx,
          funcAddr: calleeAddr
        ))

        vm.pushLabel(Label(
          arity: returnArity,
          pc: calleeCode[].code.len,
          stackHeight: sp,
          isLoop: false,
          catchTableIdx: -1
        ))

        # Inline loadFrameCache for callee
        cachedCode = cast[ptr UncheckedArray[Instr]](calleeCode[].code[0].addr)
        cachedCodeLen = calleeCode[].code.len
        cachedPc = 0
        cachedModIdx = calleeModIdx
        cachedLocalsStart = newLocalsStart
        cachedBrTables = calleeCode[].brTables.addr
        cachedFuncAddr = calleeAddr
        continue

    # ===== Parametric =====
    of opDrop:
      discard spop()

    of opSelect:
      let cond = spopI32()
      let val2 = spop()
      let val1 = spop()
      if cond != 0:
        spush(val1)
      else:
        spush(val2)

    of opSelectTyped:
      # Same as select but with explicit type
      let cond = spopI32()
      let val2 = spop()
      let val1 = spop()
      if cond != 0:
        spush(val1)
      else:
        spush(val2)

    # ===== Variable =====
    of opLocalGet:
      spush(locBase[cachedLocalsStart + instr.imm1.int])

    of opLocalSet:
      locBase[cachedLocalsStart + instr.imm1.int] = spop()

    of opLocalTee:
      locBase[cachedLocalsStart + instr.imm1.int] = speek()

    of opGlobalGet:
      let modIdx = cachedModIdx
      let globalIdx = instr.imm1.int
      let globalAddr = vm.store.modules[modIdx].globalAddrs[globalIdx]
      let cell {.cursor.} = vm.store.globals[globalAddr]
      when defined(wasmSharedCoreTypes):
        if cell.globalType.shared and cell.globalType.valType == vtV128:
          trap("shared v128 global requires SIMD execution support")
      spush(wasmValueToRaw(cell.value))

    of opGlobalSet:
      let modIdx = cachedModIdx
      let globalIdx = instr.imm1.int
      let globalAddr = vm.store.modules[modIdx].globalAddrs[globalIdx]
      let cell = addr vm.store.globals[globalAddr]
      if cell[].globalType.mut != mutVar:
        trap("cannot set immutable global")
      when defined(wasmSharedCoreTypes):
        if cell[].globalType.shared and cell[].globalType.valType == vtV128:
          trap("shared v128 global requires SIMD execution support")
      cell[].value = rawToWasmValue(spop(), cell[].globalType.valType)

    of opGlobalAtomicGet .. opGlobalAtomicCmpXchg:
      when defined(wasmSharedCoreTypes):
        # One executor owns this store. The entire operation runs in one
        # dispatch with no yield, callout, or reference to peer storage.
        let globalAddr = vm.store.modules[cachedModIdx].globalAddrs[instr.imm1.int]
        let cell = addr vm.store.globals[globalAddr]
        let lane = cell[].globalType.valType
        if lane notin {vtI32, vtI64}: trap("global.atomic requires an i32 or i64 global")
        let previous = wasmValueToRaw(cell[].value)
        if instr.op != opGlobalAtomicGet:
          if cell[].globalType.mut != mutVar: trap("global.atomic: immutable global")
          let mask = if lane == vtI32: uint32.high.uint64 else: uint64.high
          let operand = spop() and mask
          if instr.op == opGlobalAtomicCmpXchg:
            let expected = spop() and mask
            if previous == expected: cell[].value = rawToWasmValue(operand, lane)
          else:
            let next = case instr.op
              of opGlobalAtomicSet, opGlobalAtomicXchg: operand
              of opGlobalAtomicAdd: previous + operand
              of opGlobalAtomicSub: previous - operand
              of opGlobalAtomicAnd: previous and operand
              of opGlobalAtomicOr: previous or operand
              of opGlobalAtomicXor: previous xor operand
              else: trap("invalid global atomic operation")
            cell[].value = rawToWasmValue(next, lane)
        if instr.op != opGlobalAtomicSet: spush(previous)
      else:
        trap("global atomic instructions are disabled")

    # ===== Table =====
    of opTableGet:
      let modIdx = cachedModIdx
      let tableIdx = instr.imm1.int
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let idx = spopI32()
      if idx < 0 or idx.int >= vm.store.tables[tableAddr].elems.len:
        trap("out of bounds table access")
      spush(wasmValueToRaw(vm.store.tables[tableAddr].elems[idx.int]))

    of opTableSet:
      let modIdx = cachedModIdx
      let tableIdx = instr.imm1.int
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let rawVal = spop()
      let idx = spopI32()
      if idx < 0 or idx.int >= vm.store.tables[tableAddr].elems.len:
        trap("out of bounds table access")
      vm.store.tables[tableAddr].elems[idx.int] = rawToWasmValue(rawVal, vm.store.tables[tableAddr].tableType.elemType)

    # ===== Memory load/store =====
    of opMemoryAtomic:
      when defined(wasmSharedCoreTypes):
        let access = memoryAtomicSpec(instr.imm2 and 0xff)
        let input = if access.kind != maLoad: spop() else: 0'u64
        let expected = if access.kind == maCompareExchange: spop() else: 0'u64
        let offset = cast[uint32](spopI32()).uint64 + instr.imm1.uint64
        let memAddr = vm.store.modules[cachedModIdx].memAddrs[instr.pad.int]
        var previous: uint64
        let allowIo = when resumable and defined(wasmChunkedMemory): not sliced else: true
        if not executeMemoryAtomic(vm.store.mems[memAddr], access, offset, expected, input,
            allowIo, previous):
          # No write has occurred. Restore operands and recompute from the
          # current word after the backing store makes the chunk resident.
          when resumable and defined(wasmChunkedMemory):
            suspendMemoryFault(memAddr)
          else:
            trap("linear memory atomic transfer blocked")
        if access.kind != maStore: spush(previous)
      else: trap("atomic instructions are disabled")

    of opAtomicFence:
      # All guest instructions within a store already execute in one order.
      when not defined(wasmSharedCoreTypes): trap("atomic instructions are disabled")

    of opMemoryAtomicNotify, opMemoryAtomicWait32, opMemoryAtomicWait64:
      when WasmAtomicWaitEnabled:
        let waiting = instr.op != opMemoryAtomicNotify
        let wide = instr.op == opMemoryAtomicWait64
        let timeoutOrCount = spop()
        let expected = if wide: spop()
          elif waiting: cast[uint32](spopI32()).uint64
          else: 0'u64
        let offset = cast[uint32](spopI32()).uint64 + instr.imm1.uint64
        let memAddr = vm.store.modules[cachedModIdx].memAddrs[instr.pad.int]
        template memory: untyped = vm.store.mems[memAddr]
        let width = if wide: 8'u32 else: 4'u32
        memory.checkAtomicAddress(offset, width)
        if not waiting:
          spush(vm.notifyAtomicWaits(memAddr, offset, cast[uint32](timeoutOrCount)).uint64)
        else:
          if not memory.memType.limits.shared: trap("atomic wait on unshared memory")
          let allowIo = when resumable and defined(wasmChunkedMemory): not sliced else: true
          var current: uint64
          if not memory.transferMemoryAtomicWord(offset, width, current, false, allowIo):
            when resumable and defined(wasmChunkedMemory): suspendMemoryFault(memAddr)
            else: trap("linear memory atomic transfer blocked")
          if expected != current: spush(1)
          elif timeoutOrCount == 0: spush(2)
          else:
            when resumable:
              if sliced:
                continuation[].atomicWait = vm.beginAtomicWait(memAddr, offset,
                  cast[int64](timeoutOrCount))
                syncSp()
                saveFramePc()
                continuation[].instructions += sliceInstructions.uint64
                continuation[].status = wesAtomicBlocked
                return @[]
            trap("blocking atomic wait requires sliced interpreter execution")
      else: trap("atomic wait and notify are disabled")

    of opI32Load:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI32(loadVal[int32](instr.pad.int, ea))

    of opI64Load:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(loadVal[int64](instr.pad.int, ea))

    of opF32Load:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushF32(loadVal[float32](instr.pad.int, ea))

    of opF64Load:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushF64(loadVal[float64](instr.pad.int, ea))

    of opI32Load8S:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI32(int32(loadVal[int8](instr.pad.int, ea)))

    of opI32Load8U:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI32(int32(loadVal[uint8](instr.pad.int, ea)))

    of opI32Load16S:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI32(int32(loadVal[int16](instr.pad.int, ea)))

    of opI32Load16U:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI32(int32(loadVal[uint16](instr.pad.int, ea)))

    of opI64Load8S:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[int8](instr.pad.int, ea)))

    of opI64Load8U:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[uint8](instr.pad.int, ea)))

    of opI64Load16S:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[int16](instr.pad.int, ea)))

    of opI64Load16U:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[uint16](instr.pad.int, ea)))

    of opI64Load32S:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[int32](instr.pad.int, ea)))

    of opI64Load32U:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[uint32](instr.pad.int, ea)))

    of opI32Store:
      let val = spopI32()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[int32](instr.pad.int, ea, val)

    of opI64Store:
      let val = spopI64()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[int64](instr.pad.int, ea, val)

    of opF32Store:
      let val = spopF32()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[float32](instr.pad.int, ea, val)

    of opF64Store:
      let val = spopF64()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[float64](instr.pad.int, ea, val)

    of opI32Store8:
      let val = spopI32()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[uint8](instr.pad.int, ea, uint8(val and 0xFF))

    of opI32Store16:
      let val = spopI32()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[uint16](instr.pad.int, ea, uint16(val and 0xFFFF))

    of opI64Store8:
      let val = spopI64()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[uint8](instr.pad.int, ea, uint8(val and 0xFF))

    of opI64Store16:
      let val = spopI64()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[uint16](instr.pad.int, ea, uint16(val and 0xFFFF))

    of opI64Store32:
      let val = spopI64()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[uint32](instr.pad.int, ea, uint32(val and 0xFFFFFFFF))

    of opMemorySize:
      spushI32(vm.getMem(cachedModIdx, instr.imm1.int).pageCount())

    of opMemoryGrow:
      let delta = spopI32()
      spushI32(vm.getMem(cachedModIdx, instr.imm1.int).growMemory(delta))

    # ===== Constants =====
    of opI32Const:
      spushI32(cast[int32](instr.imm1))

    of opI64Const:
      let u = uint64(instr.imm1) or (uint64(instr.imm2) shl 32)
      spushI64(cast[int64](u))

    of opF32Const:
      spushF32(cast[float32](instr.imm1))

    of opF64Const:
      let u = uint64(instr.imm1) or (uint64(instr.imm2) shl 32)
      spushF64(cast[float64](u))

    # ===== i32 comparison =====
    of opI32Eqz:
      let a = spopI32()
      spushI32(if a == 0: 1'i32 else: 0'i32)

    of opI32Eq:
      let b = spopI32(); let a = spopI32()
      spushI32(if a == b: 1'i32 else: 0'i32)

    of opI32Ne:
      let b = spopI32(); let a = spopI32()
      spushI32(if a != b: 1'i32 else: 0'i32)

    of opI32LtS:
      let b = spopI32(); let a = spopI32()
      spushI32(if a < b: 1'i32 else: 0'i32)

    of opI32LtU:
      let b = spopI32(); let a = spopI32()
      spushI32(if cast[uint32](a) < cast[uint32](b): 1'i32 else: 0'i32)

    of opI32GtS:
      let b = spopI32(); let a = spopI32()
      spushI32(if a > b: 1'i32 else: 0'i32)

    of opI32GtU:
      let b = spopI32(); let a = spopI32()
      spushI32(if cast[uint32](a) > cast[uint32](b): 1'i32 else: 0'i32)

    of opI32LeS:
      let b = spopI32(); let a = spopI32()
      spushI32(if a <= b: 1'i32 else: 0'i32)

    of opI32LeU:
      let b = spopI32(); let a = spopI32()
      spushI32(if cast[uint32](a) <= cast[uint32](b): 1'i32 else: 0'i32)

    of opI32GeS:
      let b = spopI32(); let a = spopI32()
      spushI32(if a >= b: 1'i32 else: 0'i32)

    of opI32GeU:
      let b = spopI32(); let a = spopI32()
      spushI32(if cast[uint32](a) >= cast[uint32](b): 1'i32 else: 0'i32)

    # ===== i64 comparison =====
    of opI64Eqz:
      let a = spopI64()
      spushI32(if a == 0: 1'i32 else: 0'i32)

    of opI64Eq:
      let b = spopI64(); let a = spopI64()
      spushI32(if a == b: 1'i32 else: 0'i32)

    of opI64Ne:
      let b = spopI64(); let a = spopI64()
      spushI32(if a != b: 1'i32 else: 0'i32)

    of opI64LtS:
      let b = spopI64(); let a = spopI64()
      spushI32(if a < b: 1'i32 else: 0'i32)

    of opI64LtU:
      let b = spopI64(); let a = spopI64()
      spushI32(if cast[uint64](a) < cast[uint64](b): 1'i32 else: 0'i32)

    of opI64GtS:
      let b = spopI64(); let a = spopI64()
      spushI32(if a > b: 1'i32 else: 0'i32)

    of opI64GtU:
      let b = spopI64(); let a = spopI64()
      spushI32(if cast[uint64](a) > cast[uint64](b): 1'i32 else: 0'i32)

    of opI64LeS:
      let b = spopI64(); let a = spopI64()
      spushI32(if a <= b: 1'i32 else: 0'i32)

    of opI64LeU:
      let b = spopI64(); let a = spopI64()
      spushI32(if cast[uint64](a) <= cast[uint64](b): 1'i32 else: 0'i32)

    of opI64GeS:
      let b = spopI64(); let a = spopI64()
      spushI32(if a >= b: 1'i32 else: 0'i32)

    of opI64GeU:
      let b = spopI64(); let a = spopI64()
      spushI32(if cast[uint64](a) >= cast[uint64](b): 1'i32 else: 0'i32)

    # ===== f32 comparison =====
    of opF32Eq:
      let b = spopF32(); let a = spopF32()
      spushI32(if a == b: 1'i32 else: 0'i32)

    of opF32Ne:
      let b = spopF32(); let a = spopF32()
      spushI32(if a != b: 1'i32 else: 0'i32)

    of opF32Lt:
      let b = spopF32(); let a = spopF32()
      spushI32(if a < b: 1'i32 else: 0'i32)

    of opF32Gt:
      let b = spopF32(); let a = spopF32()
      spushI32(if a > b: 1'i32 else: 0'i32)

    of opF32Le:
      let b = spopF32(); let a = spopF32()
      spushI32(if a <= b: 1'i32 else: 0'i32)

    of opF32Ge:
      let b = spopF32(); let a = spopF32()
      spushI32(if a >= b: 1'i32 else: 0'i32)

    # ===== f64 comparison =====
    of opF64Eq:
      let b = spopF64(); let a = spopF64()
      spushI32(if a == b: 1'i32 else: 0'i32)

    of opF64Ne:
      let b = spopF64(); let a = spopF64()
      spushI32(if a != b: 1'i32 else: 0'i32)

    of opF64Lt:
      let b = spopF64(); let a = spopF64()
      spushI32(if a < b: 1'i32 else: 0'i32)

    of opF64Gt:
      let b = spopF64(); let a = spopF64()
      spushI32(if a > b: 1'i32 else: 0'i32)

    of opF64Le:
      let b = spopF64(); let a = spopF64()
      spushI32(if a <= b: 1'i32 else: 0'i32)

    of opF64Ge:
      let b = spopF64(); let a = spopF64()
      spushI32(if a >= b: 1'i32 else: 0'i32)

    # ===== i32 arithmetic =====
    of opI32Clz:
      let a = spopI32()
      spushI32(int32(countLeadingZeroBits(cast[uint32](a))))

    of opI32Ctz:
      let a = spopI32()
      spushI32(int32(countTrailingZeroBits(cast[uint32](a))))

    of opI32Popcnt:
      let a = spopI32()
      spushI32(int32(popcount(cast[uint32](a))))

    of opI32Add:
      let b = spopI32(); let a = spopI32()
      spushI32(a +% b)

    of opI32Sub:
      let b = spopI32(); let a = spopI32()
      spushI32(a -% b)

    of opI32Mul:
      let b = spopI32(); let a = spopI32()
      spushI32(a *% b)

    of opI32DivS:
      let b = spopI32(); let a = spopI32()
      if b == 0: trap("integer divide by zero")
      if a == int32.low and b == -1'i32: trap("integer overflow")
      spushI32(a div b)

    of opI32DivU:
      let b = spopI32(); let a = spopI32()
      if b == 0: trap("integer divide by zero")
      spushI32(cast[int32](cast[uint32](a) div cast[uint32](b)))

    of opI32RemS:
      let b = spopI32(); let a = spopI32()
      if b == 0: trap("integer divide by zero")
      if a == int32.low and b == -1'i32:
        spushI32(0'i32)
      else:
        spushI32(a mod b)

    of opI32RemU:
      let b = spopI32(); let a = spopI32()
      if b == 0: trap("integer divide by zero")
      spushI32(cast[int32](cast[uint32](a) mod cast[uint32](b)))

    of opI32And:
      let b = spopI32(); let a = spopI32()
      spushI32(a and b)

    of opI32Or:
      let b = spopI32(); let a = spopI32()
      spushI32(a or b)

    of opI32Xor:
      let b = spopI32(); let a = spopI32()
      spushI32(a xor b)

    of opI32Shl:
      let b = spopI32(); let a = spopI32()
      spushI32(cast[int32](cast[uint32](a) shl (cast[uint32](b) and 31)))

    of opI32ShrS:
      let b = spopI32(); let a = spopI32()
      spushI32(ashr(a, b and 31))

    of opI32ShrU:
      let b = spopI32(); let a = spopI32()
      spushI32(cast[int32](cast[uint32](a) shr (cast[uint32](b) and 31)))

    of opI32Rotl:
      let b = spopI32(); let a = spopI32()
      spushI32(cast[int32](rotl32(cast[uint32](a), cast[uint32](b))))

    of opI32Rotr:
      let b = spopI32(); let a = spopI32()
      spushI32(cast[int32](rotr32(cast[uint32](a), cast[uint32](b))))

    # ===== i64 arithmetic =====
    of opI64Clz:
      let a = spopI64()
      spushI64(int64(countLeadingZeroBits(cast[uint64](a))))

    of opI64Ctz:
      let a = spopI64()
      spushI64(int64(countTrailingZeroBits(cast[uint64](a))))

    of opI64Popcnt:
      let a = spopI64()
      spushI64(int64(popcount(cast[uint64](a))))

    of opI64Add:
      let b = spopI64(); let a = spopI64()
      spushI64(a +% b)

    of opI64Sub:
      let b = spopI64(); let a = spopI64()
      spushI64(a -% b)

    of opI64Mul:
      let b = spopI64(); let a = spopI64()
      spushI64(a *% b)

    of opI64DivS:
      let b = spopI64(); let a = spopI64()
      if b == 0: trap("integer divide by zero")
      if a == int64.low and b == -1'i64: trap("integer overflow")
      spushI64(a div b)

    of opI64DivU:
      let b = spopI64(); let a = spopI64()
      if b == 0: trap("integer divide by zero")
      spushI64(cast[int64](cast[uint64](a) div cast[uint64](b)))

    of opI64RemS:
      let b = spopI64(); let a = spopI64()
      if b == 0: trap("integer divide by zero")
      if a == int64.low and b == -1'i64:
        spushI64(0'i64)
      else:
        spushI64(a mod b)

    of opI64RemU:
      let b = spopI64(); let a = spopI64()
      if b == 0: trap("integer divide by zero")
      spushI64(cast[int64](cast[uint64](a) mod cast[uint64](b)))

    of opI64And:
      let b = spopI64(); let a = spopI64()
      spushI64(a and b)

    of opI64Or:
      let b = spopI64(); let a = spopI64()
      spushI64(a or b)

    of opI64Xor:
      let b = spopI64(); let a = spopI64()
      spushI64(a xor b)

    of opI64Shl:
      let b = spopI64(); let a = spopI64()
      spushI64(cast[int64](cast[uint64](a) shl (cast[uint64](b) and 63)))

    of opI64ShrS:
      let b = spopI64(); let a = spopI64()
      spushI64(ashr(a, int(b and 63)))

    of opI64ShrU:
      let b = spopI64(); let a = spopI64()
      spushI64(cast[int64](cast[uint64](a) shr (cast[uint64](b) and 63)))

    of opI64Rotl:
      let b = spopI64(); let a = spopI64()
      spushI64(cast[int64](rotl64(cast[uint64](a), cast[uint64](b))))

    of opI64Rotr:
      let b = spopI64(); let a = spopI64()
      spushI64(cast[int64](rotr64(cast[uint64](a), cast[uint64](b))))

    # ===== f32 arithmetic =====
    of opF32Abs:
      let a = spopF32()
      spushF32(abs(a))

    of opF32Neg:
      let a = spopF32()
      spushF32(-a)

    of opF32Ceil:
      let a = spopF32()
      spushF32(ceil(a))

    of opF32Floor:
      let a = spopF32()
      spushF32(floor(a))

    of opF32Trunc:
      let a = spopF32()
      spushF32(trunc(a))

    of opF32Nearest:
      let a = spopF32()
      spushF32(f32Nearest(a))

    of opF32Sqrt:
      let a = spopF32()
      spushF32(sqrt(a))

    of opF32Add:
      let b = spopF32(); let a = spopF32()
      spushF32(a + b)

    of opF32Sub:
      let b = spopF32(); let a = spopF32()
      spushF32(a - b)

    of opF32Mul:
      let b = spopF32(); let a = spopF32()
      spushF32(a * b)

    of opF32Div:
      let b = spopF32(); let a = spopF32()
      spushF32(a / b)

    of opF32Min:
      let b = spopF32(); let a = spopF32()
      spushF32(f32Min(a, b))

    of opF32Max:
      let b = spopF32(); let a = spopF32()
      spushF32(f32Max(a, b))

    of opF32Copysign:
      let b = spopF32(); let a = spopF32()
      spushF32(f32Copysign(a, b))

    # ===== f64 arithmetic =====
    of opF64Abs:
      let a = spopF64()
      spushF64(abs(a))

    of opF64Neg:
      let a = spopF64()
      spushF64(-a)

    of opF64Ceil:
      let a = spopF64()
      spushF64(ceil(a))

    of opF64Floor:
      let a = spopF64()
      spushF64(floor(a))

    of opF64Trunc:
      let a = spopF64()
      spushF64(trunc(a))

    of opF64Nearest:
      let a = spopF64()
      spushF64(f64Nearest(a))

    of opF64Sqrt:
      let a = spopF64()
      spushF64(sqrt(a))

    of opF64Add:
      let b = spopF64(); let a = spopF64()
      spushF64(a + b)

    of opF64Sub:
      let b = spopF64(); let a = spopF64()
      spushF64(a - b)

    of opF64Mul:
      let b = spopF64(); let a = spopF64()
      spushF64(a * b)

    of opF64Div:
      let b = spopF64(); let a = spopF64()
      spushF64(a / b)

    of opF64Min:
      let b = spopF64(); let a = spopF64()
      spushF64(f64Min(a, b))

    of opF64Max:
      let b = spopF64(); let a = spopF64()
      spushF64(f64Max(a, b))

    of opF64Copysign:
      let b = spopF64(); let a = spopF64()
      spushF64(f64Copysign(a, b))

    # ===== Conversions =====
    of opI32WrapI64:
      let a = spopI64()
      spushI32(cast[int32](a and 0xFFFFFFFF'i64))

    of opI32TruncF32S:
      let a = spopF32()
      spushI32(truncI32F32S(a))

    of opI32TruncF32U:
      let a = spopF32()
      spushI32(truncI32F32U(a))

    of opI32TruncF64S:
      let a = spopF64()
      spushI32(truncI32F64S(a))

    of opI32TruncF64U:
      let a = spopF64()
      spushI32(truncI32F64U(a))

    of opI64ExtendI32S:
      let a = spopI32()
      spushI64(int64(a))

    of opI64ExtendI32U:
      let a = spopI32()
      spushI64(int64(cast[uint32](a)))

    of opI64TruncF32S:
      let a = spopF32()
      spushI64(truncI64F32S(a))

    of opI64TruncF32U:
      let a = spopF32()
      spushI64(truncI64F32U(a))

    of opI64TruncF64S:
      let a = spopF64()
      spushI64(truncI64F64S(a))

    of opI64TruncF64U:
      let a = spopF64()
      spushI64(truncI64F64U(a))

    of opF32ConvertI32S:
      let a = spopI32()
      spushF32(float32(a))

    of opF32ConvertI32U:
      let a = spopI32()
      spushF32(float32(cast[uint32](a)))

    of opF32ConvertI64S:
      let a = spopI64()
      spushF32(float32(a))

    of opF32ConvertI64U:
      let a = spopI64()
      spushF32(float32(cast[uint64](a)))

    of opF32DemoteF64:
      let a = spopF64()
      spushF32(float32(a))

    of opF64ConvertI32S:
      let a = spopI32()
      spushF64(float64(a))

    of opF64ConvertI32U:
      let a = spopI32()
      spushF64(float64(cast[uint32](a)))

    of opF64ConvertI64S:
      let a = spopI64()
      spushF64(float64(a))

    of opF64ConvertI64U:
      let a = spopI64()
      spushF64(float64(cast[uint64](a)))

    of opF64PromoteF32:
      let a = spopF32()
      spushF64(float64(a))

    of opI32ReinterpretF32:
      let a = spopF32()
      spushI32(reinterpretF32AsI32(a))

    of opI64ReinterpretF64:
      let a = spopF64()
      spushI64(reinterpretF64AsI64(a))

    of opF32ReinterpretI32:
      let a = spopI32()
      spushF32(reinterpretI32AsF32(a))

    of opF64ReinterpretI64:
      let a = spopI64()
      spushF64(reinterpretI64AsF64(a))

    # ===== Sign extension =====
    of opI32Extend8S:
      let a = spopI32()
      spushI32(int32(int8(a and 0xFF)))

    of opI32Extend16S:
      let a = spopI32()
      spushI32(int32(int16(a and 0xFFFF)))

    of opI64Extend8S:
      let a = spopI64()
      spushI64(int64(int8(a and 0xFF)))

    of opI64Extend16S:
      let a = spopI64()
      spushI64(int64(int16(a and 0xFFFF)))

    of opI64Extend32S:
      let a = spopI64()
      spushI64(int64(int32(a and 0xFFFFFFFF'i64)))

    # ===== Reference =====
    of opRefNull:
      # Null refs are -1 as int32 -> 0xFFFFFFFF in low 32 bits
      # imm1 = refType ordinal
      let rtOrd = instr.imm1
      if rtOrd == uint32(ord(vtFuncRef)):
        spush(wasmValueToRaw(wasmNullFuncRef()))
      elif rtOrd == uint32(ord(vtExternRef)):
        spush(wasmValueToRaw(wasmNullExternRef()))
      else:
        trap("invalid ref.null type")

    of opRefIsNull:
      # Check if ref value is null (-1 in low 32 bits = 0xFFFFFFFF)
      let raw = spop()
      let asI32 = cast[int32](raw and 0xFFFFFFFF'u64)
      spushI32(if asI32 == -1: 1'i32 else: 0'i32)

    of opRefFunc:
      let modIdx = cachedModIdx
      let funcIdx = instr.imm1.int
      let funcAddr2 = vm.store.modules[modIdx].funcAddrs[funcIdx]
      spush(wasmValueToRaw(wasmFuncRef(funcAddr2.int32)))

    of opRefAsNonNull:
      if speek().uint32 == uint32.high: trap("null reference")

    # ===== Saturating truncations =====
    of opI32TruncSatF32S:
      let a = spopF32()
      spushI32(truncSatI32F32S(a))

    of opI32TruncSatF32U:
      let a = spopF32()
      spushI32(truncSatI32F32U(a))

    of opI32TruncSatF64S:
      let a = spopF64()
      spushI32(truncSatI32F64S(a))

    of opI32TruncSatF64U:
      let a = spopF64()
      spushI32(truncSatI32F64U(a))

    of opI64TruncSatF32S:
      let a = spopF32()
      spushI64(truncSatI64F32S(a))

    of opI64TruncSatF32U:
      let a = spopF32()
      spushI64(truncSatI64F32U(a))

    of opI64TruncSatF64S:
      let a = spopF64()
      spushI64(truncSatI64F64S(a))

    of opI64TruncSatF64U:
      let a = spopF64()
      spushI64(truncSatI64F64U(a))

    # ===== Bulk memory =====
    of opMemoryInit:
      let modIdx = cachedModIdx
      let dataIdx = instr.imm1.int
      let memIdx = instr.imm2.int
      let n = cast[uint32](spopI32())
      let s = cast[uint32](spopI32())
      let d = cast[uint32](spopI32())
      let dataAddr = vm.store.modules[modIdx].dataAddrs[dataIdx]
      let dataInst = vm.store.datas[dataAddr]
      let sourceLen = if dataInst.dropped: 0'u64 else: dataInst.data.len.uint64
      if s.uint64 + n.uint64 > sourceLen:
        trap("out of bounds memory access")
      let memAddr = vm.store.modules[modIdx].memAddrs[memIdx]
      if d.uint64 + n.uint64 > vm.store.mems[memAddr].memByteLen():
        trap("out of bounds memory access")
      if n > 0:
        let source = cast[ptr UncheckedArray[byte]](
          vm.store.datas[dataAddr].data[s.int].unsafeAddr)
        when resumable and defined(wasmChunkedMemory):
          if sliced and vm.store.mems[memAddr].chunked != nil:
            let status = vm.store.mems[memAddr].chunked[].writeAtProgress(
              d.uint64, source, n, continuation[].transferProgress)
            if status == lmWouldBlock: suspendMemoryFault(memAddr)
            if status != lmOk: trap("linear memory init failed: " & $status)
            continuation[].transferProgress = 0
          else:
            vm.store.mems[memAddr].writeBulk(d.uint64, source, n)
        else:
          vm.store.mems[memAddr].writeBulk(d.uint64, source, n)

    of opDataDrop:
      let modIdx = cachedModIdx
      let dataIdx = instr.imm1.int
      let dataAddr = vm.store.modules[modIdx].dataAddrs[dataIdx]
      vm.store.datas[dataAddr].dropped = true
      vm.store.datas[dataAddr].data = @[]

    of opMemoryCopy:
      let modIdx = cachedModIdx
      let dstMemIdx = instr.imm1.int
      let srcMemIdx = instr.imm2.int
      let n = cast[uint32](spopI32())
      let s = cast[uint32](spopI32())
      let d = cast[uint32](spopI32())
      let dstMemAddr = vm.store.modules[modIdx].memAddrs[dstMemIdx]
      let srcMemAddr = vm.store.modules[modIdx].memAddrs[srcMemIdx]
      if s.uint64 + n.uint64 > vm.store.mems[srcMemAddr].memByteLen():
        trap("out of bounds memory access")
      if d.uint64 + n.uint64 > vm.store.mems[dstMemAddr].memByteLen():
        trap("out of bounds memory access")
      if n > 0:
        when resumable and defined(wasmChunkedMemory):
          if sliced and dstMemAddr == srcMemAddr and vm.store.mems[dstMemAddr].chunked != nil:
            let status = vm.store.mems[dstMemAddr].chunked[].copyWithinProgress(
              d.uint64, s.uint64, n, continuation[].copyCursor)
            if status == lmWouldBlock: suspendMemoryFault(dstMemAddr)
            if status != lmOk: trap("linear memory copy failed: " & $status)
            continuation[].copyCursor = LinearMemoryCopyCursor()
          elif sliced and (vm.store.mems[dstMemAddr].chunked != nil or
              vm.store.mems[srcMemAddr].chunked != nil):
            while continuation[].bulkDone < n:
              let part = min(n - continuation[].bulkDone,
                             continuation[].bulkScratch.len.uint32)
              if not continuation[].bulkWriting:
                if vm.store.mems[srcMemAddr].chunked != nil:
                  let status = vm.store.mems[srcMemAddr].chunked[].readAtProgress(
                    s.uint64 + continuation[].bulkDone.uint64,
                    cast[ptr UncheckedArray[byte]](addr continuation[].bulkScratch[0]),
                    part, continuation[].bulkPartProgress)
                  if status == lmWouldBlock: suspendMemoryFault(srcMemAddr)
                  if status != lmOk: trap("linear memory copy read failed: " & $status)
                else:
                  copyMem(addr continuation[].bulkScratch[0],
                          vm.store.mems[srcMemAddr].memBulkPtr(
                            s.uint64 + continuation[].bulkDone.uint64), part.int)
                continuation[].bulkWriting = true
                continuation[].bulkPartProgress = 0
              if vm.store.mems[dstMemAddr].chunked != nil:
                let status = vm.store.mems[dstMemAddr].chunked[].writeAtProgress(
                  d.uint64 + continuation[].bulkDone.uint64,
                  cast[ptr UncheckedArray[byte]](addr continuation[].bulkScratch[0]),
                  part, continuation[].bulkPartProgress)
                if status == lmWouldBlock: suspendMemoryFault(dstMemAddr)
                if status != lmOk: trap("linear memory copy write failed: " & $status)
              else:
                copyMem(vm.store.mems[dstMemAddr].memBulkPtr(
                          d.uint64 + continuation[].bulkDone.uint64),
                        addr continuation[].bulkScratch[0], part.int)
              continuation[].bulkDone += part
              continuation[].bulkPartProgress = 0
              continuation[].bulkWriting = false
            continuation[].bulkDone = 0
          else:
            copyBulk(vm.store.mems[dstMemAddr], vm.store.mems[srcMemAddr],
                     d.uint64, s.uint64, n, dstMemAddr == srcMemAddr)
        else:
          copyBulk(vm.store.mems[dstMemAddr], vm.store.mems[srcMemAddr],
                   d.uint64, s.uint64, n, dstMemAddr == srcMemAddr)

    of opMemoryFill:
      let modIdx = cachedModIdx
      let memIdx = instr.imm1.int
      let n = cast[uint32](spopI32())
      let val = cast[uint8](spopI32() and 0xFF)
      let d = cast[uint32](spopI32())
      let memAddr = vm.store.modules[modIdx].memAddrs[memIdx]
      if d.uint64 + n.uint64 > vm.store.mems[memAddr].memByteLen():
        trap("out of bounds memory access")
      if n > 0:
        when resumable and defined(wasmChunkedMemory):
          if sliced and vm.store.mems[memAddr].chunked != nil:
            for cell in continuation[].bulkScratch.mitems: cell = val
            while continuation[].bulkDone < n:
              let part = min(n - continuation[].bulkDone,
                             continuation[].bulkScratch.len.uint32)
              let status = vm.store.mems[memAddr].chunked[].writeAtProgress(
                d.uint64 + continuation[].bulkDone.uint64,
                cast[ptr UncheckedArray[byte]](addr continuation[].bulkScratch[0]),
                part, continuation[].bulkPartProgress)
              if status == lmWouldBlock: suspendMemoryFault(memAddr)
              if status != lmOk: trap("linear memory fill failed: " & $status)
              continuation[].bulkDone += part
              continuation[].bulkPartProgress = 0
            continuation[].bulkDone = 0
          else:
            vm.store.mems[memAddr].fillBulk(d.uint64, val, n)
        else:
          vm.store.mems[memAddr].fillBulk(d.uint64, val, n)

    # ===== Table operations =====
    of opTableInit:
      let modIdx = cachedModIdx
      let elemIdx = instr.imm1.int
      let tableIdx = instr.imm2.int
      let n = cast[uint32](spopI32())
      let s = cast[uint32](spopI32())
      let d = cast[uint32](spopI32())
      let elemAddr = vm.store.modules[modIdx].elemAddrs[elemIdx]
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let elemInst {.cursor.} = vm.store.elems[elemAddr]
      let elemCount = if elemInst.dropped: 0'u64 else: elemInst.elems.len.uint64
      if s.uint64 + n.uint64 > elemCount:
        trap("out of bounds table access")
      if d.uint64 + n.uint64 > vm.store.tables[tableAddr].elems.len.uint64:
        trap("out of bounds table access")
      for i in 0'u32 ..< n:
        vm.store.tables[tableAddr].elems[d.int + i.int] =
          vm.store.elems[elemAddr].elems[s.int + i.int]

    of opElemDrop:
      let modIdx = cachedModIdx
      let elemIdx = instr.imm1.int
      let elemAddr = vm.store.modules[modIdx].elemAddrs[elemIdx]
      vm.store.elems[elemAddr].dropped = true
      vm.store.elems[elemAddr].elems = @[]

    of opTableCopy:
      let modIdx = cachedModIdx
      let dstTableIdx = instr.imm1.int
      let srcTableIdx = instr.imm2.int
      let n = cast[uint32](spopI32())
      let s = cast[uint32](spopI32())
      let d = cast[uint32](spopI32())
      let dstTableAddr = vm.store.modules[modIdx].tableAddrs[dstTableIdx]
      let srcTableAddr = vm.store.modules[modIdx].tableAddrs[srcTableIdx]
      if s.uint64 + n.uint64 > vm.store.tables[srcTableAddr].elems.len.uint64:
        trap("out of bounds table access")
      if d.uint64 + n.uint64 > vm.store.tables[dstTableAddr].elems.len.uint64:
        trap("out of bounds table access")
      if n > 0:
        if d <= s:
          for i in 0'u32 ..< n:
            vm.store.tables[dstTableAddr].elems[d.int + i.int] =
              vm.store.tables[srcTableAddr].elems[s.int + i.int]
        else:
          for i in countdown(n.int - 1, 0):
            vm.store.tables[dstTableAddr].elems[d.int + i] =
              vm.store.tables[srcTableAddr].elems[s.int + i]

    of opTableGrow:
      let modIdx = cachedModIdx
      let tableIdx = instr.imm1.int
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let n = cast[uint32](spopI32())
      let initVal = rawToWasmValue(spop(), vm.store.tables[tableAddr].tableType.elemType)
      let oldSize = vm.store.tables[tableAddr].elems.len
      let newSize = oldSize.uint64 + n.uint64
      let limits = vm.store.tables[tableAddr].tableType.limits
      let maxSize = if limits.hasMax: limits.max.uint64 else: uint32.high.uint64
      if newSize > maxSize or newSize > uint64(high(int) div sizeof(WasmValue)):
        spushI32(-1'i32)
      else:
        vm.store.tables[tableAddr].elems.setLen(newSize.int)
        for i in oldSize ..< newSize.int:
          vm.store.tables[tableAddr].elems[i] = initVal
        vm.store.tables[tableAddr].tableType.limits.min = uint32(newSize)
        spushI32(int32(oldSize))

    of opTableSize:
      let modIdx = cachedModIdx
      let tableIdx = instr.imm1.int
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      spushI32(int32(vm.store.tables[tableAddr].elems.len))

    of opTableFill:
      let modIdx = cachedModIdx
      let tableIdx = instr.imm1.int
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let n = cast[uint32](spopI32())
      let val = rawToWasmValue(spop(), vm.store.tables[tableAddr].tableType.elemType)
      let d = cast[uint32](spopI32())
      if d.uint64 + n.uint64 > vm.store.tables[tableAddr].elems.len.uint64:
        trap("out of bounds table access")
      for i in 0'u32 ..< n:
        vm.store.tables[tableAddr].elems[d.int + i.int] = val

    # ===== Fused superinstructions =====
    of opLocalGetLocalGet:
      # Push two locals in one dispatch
      let v1 = locBase[cachedLocalsStart + instr.imm1.int]
      let v2 = locBase[cachedLocalsStart + instr.imm2.int]
      spush(v1)
      spush(v2)

    of opLocalGetI32Add:
      # TOS = TOS + local[X]  (net sp change = 0 → peek/poke, skip resize check)
      let localVal = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let tos = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      vsBase[sp - 1] = uint64(cast[uint32](tos + localVal))

    of opLocalGetI32Sub:
      # TOS = TOS - local[X]  (net sp change = 0)
      let localVal = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let tos = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      vsBase[sp - 1] = uint64(cast[uint32](tos - localVal))

    of opI32ConstI32Add:
      # TOS = TOS + C  (net sp change = 0)
      let c = cast[int32](instr.imm1)
      let tos = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      vsBase[sp - 1] = uint64(cast[uint32](tos + c))

    of opI32ConstI32Sub:
      # TOS = TOS - C  (net sp change = 0)
      let c = cast[int32](instr.imm1)
      let tos = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      vsBase[sp - 1] = uint64(cast[uint32](tos - c))

    of opLocalSetLocalGet:
      # local[X] = pop; push local[Y]
      locBase[cachedLocalsStart + instr.imm1.int] = spop()
      spush(locBase[cachedLocalsStart + instr.imm2.int])

    of opLocalTeeLocalGet:
      # local[X] = peek; push local[Y]
      locBase[cachedLocalsStart + instr.imm1.int] = speek()
      spush(locBase[cachedLocalsStart + instr.imm2.int])

    of opLocalGetI32Const:
      # Push local[X] then push i32 const C
      spush(locBase[cachedLocalsStart + instr.imm1.int])
      spushI32(cast[int32](instr.imm2))

    of opI32AddLocalSet:
      # local[X] = pop + pop (i32.add then local.set)
      let b = spopI32()
      let a = spopI32()
      let r = a + b
      locBase[cachedLocalsStart + instr.imm1.int] = cast[uint64](r.int64) and 0xFFFFFFFF'u64

    of opI32SubLocalSet:
      # local[X] = pop - pop (i32.sub then local.set)
      let b = spopI32()
      let a = spopI32()
      let r = a - b
      locBase[cachedLocalsStart + instr.imm1.int] = cast[uint64](r.int64) and 0xFFFFFFFF'u64

    of opLocalGetI32Store:
      let localVal = locBase[cachedLocalsStart + instr.imm1.int]
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm2.uint64
      storeVal[int32](0, ea, cast[int32](localVal and 0xFFFFFFFF'u64))

    of opLocalGetI32Load:
      # load mem[local[X] + offset]
      let base = cast[uint32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let ea = base.uint64 + instr.imm2.uint64
      spushI32(loadVal[int32](0, ea))

    of opI32ConstI32Eq:
      # TOS == C
      let a = spopI32()
      let c = cast[int32](instr.imm1)
      spushI32(if a == c: 1'i32 else: 0'i32)

    of opI32ConstI32Ne:
      # TOS != C
      let a = spopI32()
      let c = cast[int32](instr.imm1)
      spushI32(if a != c: 1'i32 else: 0'i32)

    of opLocalGetI32GtS:
      # TOS > local[X] (signed)
      let localVal = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let tos = spopI32()
      spushI32(if tos > localVal: 1'i32 else: 0'i32)

    of opI32ConstI32And:
      # TOS & C
      let a = spopI32()
      let c = cast[int32](instr.imm1)
      spushI32(a and c)

    of opI32ConstI32Mul:
      # TOS * C
      let a = spopI32()
      let c = cast[int32](instr.imm1)
      spushI32(a * c)

    of opLocalGetI32Mul:
      # TOS * local[X]
      let localVal = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let tos = spopI32()
      spushI32(tos * localVal)

    # ===== Triple fused superinstructions =====
    of opLocalGetLocalGetI32Add:
      # push(local[X] + local[Y])
      let a = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let b = cast[int32](locBase[cachedLocalsStart + instr.imm2.int] and 0xFFFFFFFF'u64)
      spushI32(a + b)

    of opLocalGetLocalGetI32Sub:
      let a = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let b = cast[int32](locBase[cachedLocalsStart + instr.imm2.int] and 0xFFFFFFFF'u64)
      spushI32(a - b)

    of opLocalGetI32ConstI32Sub:
      # push(local[X] - C)
      let a = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let c = cast[int32](instr.imm2)
      spushI32(a - c)

    of opLocalGetI32ConstI32Add:
      # push(local[X] + C)
      let a = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let c = cast[int32](instr.imm2)
      spushI32(a + c)

    of opLocalGetLocalTee:
      # Push local[X], then tee TOS to local[Y]
      spush(locBase[cachedLocalsStart + instr.imm1.int])
      locBase[cachedLocalsStart + instr.imm2.int] = speek()

    of opI32ConstI32GtU:
      # TOS > C (unsigned)  (net sp change = 0)
      let a = cast[uint32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      let c = instr.imm1
      vsBase[sp - 1] = uint64(if a > c: 1'u32 else: 0'u32)

    of opI32ConstI32LtS:
      # TOS < C (signed)  (net sp change = 0)
      let a = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      let c = cast[int32](instr.imm1)
      vsBase[sp - 1] = uint64(if a < c: 1'u32 else: 0'u32)

    of opI32ConstI32GeS:
      # TOS >= C (signed)  (net sp change = 0)
      let a = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      let c = cast[int32](instr.imm1)
      vsBase[sp - 1] = uint64(if a >= c: 1'u32 else: 0'u32)

    of opLocalGetI32LoadI32Add:
      # push(TOS + mem[local[X] + offset])
      let base = cast[uint32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let ea = base.uint64 + instr.imm2.uint64
      let loaded = loadVal[int32](0, ea)
      let tos = spopI32()
      spushI32(tos + loaded)

    of opI32EqzBrIf:
      # Branch if TOS == 0
      let v = spopI32()
      let taken = v == 0
      if profiler != nil:
        profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken:
        inlineBranch(instr.imm1.int)

    # ---- Binary comparison + br_if pairs (pop b, pop a, branch if condition) ----
    of opI32EqBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a == b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32NeBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a != b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32LtSBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a < b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32GeSBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a >= b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32GtSBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a > b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32LeSBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a <= b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32LtUBrIf:
      let b = cast[uint32](spopI32()); let a = cast[uint32](spopI32())
      let taken = a < b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32GeUBrIf:
      let b = cast[uint32](spopI32()); let a = cast[uint32](spopI32())
      let taken = a >= b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32GtUBrIf:
      let b = cast[uint32](spopI32()); let a = cast[uint32](spopI32())
      let taken = a > b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32LeUBrIf:
      let b = cast[uint32](spopI32()); let a = cast[uint32](spopI32())
      let taken = a <= b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)

    # ---- Triple: i32.const C; comparison; br_if L (imm1=C, imm2=L) ----
    of opI32ConstI32EqBrIf:
      let a = spopI32(); let c = cast[int32](instr.imm1)
      let taken = a == c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)
    of opI32ConstI32NeBrIf:
      let a = spopI32(); let c = cast[int32](instr.imm1)
      let taken = a != c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)
    of opI32ConstI32LtSBrIf:
      let a = spopI32(); let c = cast[int32](instr.imm1)
      let taken = a < c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)
    of opI32ConstI32GeSBrIf:
      let a = spopI32(); let c = cast[int32](instr.imm1)
      let taken = a >= c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)
    of opI32ConstI32GtUBrIf:
      let a = cast[uint32](spopI32()); let c = instr.imm1
      let taken = a > c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)
    of opI32ConstI32LeUBrIf:
      let a = cast[uint32](spopI32()); let c = instr.imm1
      let taken = a <= c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)

    # ---- local.tee + br_if pair ----
    of opLocalTeeBrIf:
      # Semantics: local[X] = TOS; pop; branch if nonzero
      let val = spop()
      locBase[cachedLocalsStart + instr.imm1.int] = val
      let taken = cast[int32](val and 0xFFFFFFFF'u64) != 0
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken:
        inlineBranch(instr.imm2.int)

    # ---- i64 local.get + arithmetic ----
    of opLocalGetI64Add:
      let v = cast[int64](locBase[cachedLocalsStart + instr.imm1.int])
      let tos = spopI64()
      spushI64(tos + v)
    of opLocalGetI64Sub:
      let v = cast[int64](locBase[cachedLocalsStart + instr.imm1.int])
      let tos = spopI64()
      spushI64(tos - v)

    # ---- Quad fusions ----
    of opLocalI32AddInPlace:
      # local[X] += C
      let idx = cachedLocalsStart + instr.imm1.int
      let c = cast[int32](instr.imm2)
      let cur = cast[int32](locBase[idx] and 0xFFFFFFFF'u64)
      locBase[idx] = uint64(cast[uint32](cur + c))
    of opLocalI32SubInPlace:
      # local[X] -= C
      let idx = cachedLocalsStart + instr.imm1.int
      let c = cast[int32](instr.imm2)
      let cur = cast[int32](locBase[idx] and 0xFFFFFFFF'u64)
      locBase[idx] = uint64(cast[uint32](cur - c))
    of opLocalGetLocalGetI32AddLocalSet:
      # Z = local[X] + local[Y]
      let x = int(instr.imm1 and 0xFFFF'u32)
      let y = int(instr.imm1 shr 16)
      let z = instr.imm2.int
      let a = cast[int32](locBase[cachedLocalsStart + x] and 0xFFFFFFFF'u64)
      let b = cast[int32](locBase[cachedLocalsStart + y] and 0xFFFFFFFF'u64)
      locBase[cachedLocalsStart + z] = uint64(cast[uint32](a + b))
    of opLocalGetLocalGetI32SubLocalSet:
      # Z = local[X] - local[Y]
      let x = int(instr.imm1 and 0xFFFF'u32)
      let y = int(instr.imm1 shr 16)
      let z = instr.imm2.int
      let a = cast[int32](locBase[cachedLocalsStart + x] and 0xFFFFFFFF'u64)
      let b = cast[int32](locBase[cachedLocalsStart + y] and 0xFFFFFFFF'u64)
      locBase[cachedLocalsStart + z] = uint64(cast[uint32](a - b))

    # ===== Tail calls (return_call, return_call_indirect) =====
    of opReturnCall:
      let calleeAddr = if instr.pad == 1: instr.imm1.int
                        else: vm.store.modules[cachedModIdx].funcAddrs[instr.imm1.int]
      let callee {.cursor.} = vm.store.funcs[calleeAddr]
      let curFrame = vm.callStack[vm.callStackTop - 1]
      # The function label marks the boundary between this frame's operands
      # and those its caller must keep. Copy arguments before resetting sp.
      let frameStackBase = vm.labelStack[curFrame.labelStackStart].stackHeight
      if callee.isHost:
        let nParams = callee.funcType.params.len
        var hostArgs = newSeq[WasmValue](nParams)
        for i in countdown(nParams - 1, 0):
          hostArgs[i] = rawToWasmValue(spop(), callee.funcType.params[i])
        sp = frameStackBase
        invokeHost(callee, calleeAddr, hostArgs, true)
        # Treat as return
        vm.localsTop = curFrame.localsStart
        vm.labelStackTop = curFrame.labelStackStart
        dec vm.callStackTop
        if vm.callStackTop <= entryCallStackTop:
          break
        loadFrameCache()
        locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
        continue
      else:
        # Tail call: reuse current frame's stack space
        let calleeCode = callee.code
        let paramCount = callee.funcType.params.len
        let returnArity = callee.funcType.results.len
        let calleeModIdx = callee.moduleIdx
        let localsStart = curFrame.localsStart
        let newTotalLocals = callee.localTypes.len
        let needed = localsStart + newTotalLocals
        if unlikely(needed > vm.locals.len):
          vm.locals.setLen(needed * 2)
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
        # Pop args directly into reused locals
        sp -= paramCount
        for i in 0 ..< paramCount:
          locBase[localsStart + i] = vsBase[sp + i]
        sp = frameStackBase
        for i in paramCount ..< newTotalLocals:
          locBase[localsStart + i] = initialLocalBits(callee.localTypes[i])
        vm.localsTop = needed
        # Reuse frame: update in place (no push/pop)
        vm.labelStackTop = curFrame.labelStackStart
        vm.callStack[vm.callStackTop - 1] = Frame(
          pc: 0,
          code: calleeCode,
          brTables: calleeCode[].brTables.addr,
          localsStart: localsStart,
          localsCount: newTotalLocals,
          labelStackStart: curFrame.labelStackStart,
          returnArity: returnArity,
          moduleIdx: calleeModIdx,
          funcAddr: calleeAddr
        )
        vm.labelStack[vm.labelStackTop] = Label(
          arity: returnArity,
          pc: calleeCode[].code.len,
          stackHeight: sp,
          isLoop: false,
          catchTableIdx: -1
        )
        inc vm.labelStackTop
        cachedCode = cast[ptr UncheckedArray[Instr]](calleeCode[].code[0].addr)
        cachedCodeLen = calleeCode[].code.len
        cachedPc = 0
        cachedModIdx = calleeModIdx
        cachedLocalsStart = localsStart
        cachedBrTables = calleeCode[].brTables.addr
        cachedFuncAddr = calleeAddr
        continue

    of opReturnCallIndirect, opReturnCallRef:
      let typeIdx = instr.imm1.int
      let modIdx = cachedModIdx
      var calleeAddr: int
      if instr.op == opReturnCallRef:
        when defined(wasmFunctionReferences):
          calleeAddr = vm.resolveFunctionReference(modIdx, typeIdx, spopI32())
        else: trap("typed function references are disabled")
      else:
        let tableIdx = instr.imm2.int
        let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
        let elemIdx = spopI32()
        if elemIdx < 0 or elemIdx.int >= vm.store.tables[tableAddr].elems.len:
          trap("undefined element")
        let elem = vm.store.tables[tableAddr].elems[elemIdx.int]
        if elem.kind != wvkFuncRef or elem.funcRef < 0:
          trap("uninitialized element")
        calleeAddr = elem.funcRef.int
        if calleeAddr >= vm.store.funcs.len:
          trap("undefined function")
        let expectedType {.cursor.} = vm.store.modules[modIdx].types[typeIdx]
        if not vm.store.funcs[calleeAddr].funcType.matchesCoreFunctionType(expectedType):
          trap("indirect call type mismatch")
      let callee {.cursor.} = vm.store.funcs[calleeAddr]
      # Tail call reusing current frame
      let curFrame = vm.callStack[vm.callStackTop - 1]
      let frameStackBase = vm.labelStack[curFrame.labelStackStart].stackHeight
      if callee.isHost:
        let nParams = callee.funcType.params.len
        var hostArgs = newSeq[WasmValue](nParams)
        for i in countdown(nParams - 1, 0):
          hostArgs[i] = rawToWasmValue(spop(), callee.funcType.params[i])
        sp = frameStackBase
        invokeHost(callee, calleeAddr, hostArgs, true)
        vm.localsTop = curFrame.localsStart
        vm.labelStackTop = curFrame.labelStackStart
        dec vm.callStackTop
        if vm.callStackTop <= entryCallStackTop:
          break
        loadFrameCache()
        locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
        continue
      else:
        let calleeCode = callee.code
        let paramCount = callee.funcType.params.len
        let returnArity = callee.funcType.results.len
        let calleeModIdx = callee.moduleIdx
        let localsStart = curFrame.localsStart
        let newTotalLocals = callee.localTypes.len
        let needed = localsStart + newTotalLocals
        if unlikely(needed > vm.locals.len):
          vm.locals.setLen(needed * 2)
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
        sp -= paramCount
        for i in 0 ..< paramCount:
          locBase[localsStart + i] = vsBase[sp + i]
        sp = frameStackBase
        for i in paramCount ..< newTotalLocals:
          locBase[localsStart + i] = initialLocalBits(callee.localTypes[i])
        vm.localsTop = needed
        vm.labelStackTop = curFrame.labelStackStart
        vm.callStack[vm.callStackTop - 1] = Frame(
          pc: 0,
          code: calleeCode,
          brTables: calleeCode[].brTables.addr,
          localsStart: localsStart,
          localsCount: newTotalLocals,
          labelStackStart: curFrame.labelStackStart,
          returnArity: returnArity,
          moduleIdx: calleeModIdx,
          funcAddr: calleeAddr
        )
        vm.labelStack[vm.labelStackTop] = Label(
          arity: returnArity,
          pc: calleeCode[].code.len,
          stackHeight: sp,
          isLoop: false,
          catchTableIdx: -1
        )
        inc vm.labelStackTop
        cachedCode = cast[ptr UncheckedArray[Instr]](calleeCode[].code[0].addr)
        cachedCodeLen = calleeCode[].code.len
        cachedPc = 0
        cachedModIdx = calleeModIdx
        cachedLocalsStart = localsStart
        cachedBrTables = calleeCode[].brTables.addr
        cachedFuncAddr = calleeAddr
        continue

    # ===== Exception handling =====
    of opThrow:
      # Resolve tag
      let tagIdx = instr.imm1.int
      let tagAddr = vm.store.modules[cachedModIdx].tagAddrs[tagIdx]
      let tagFt = vm.store.tags[tagAddr].funcType
      let payloadLen = tagFt.params.len
      # Keep payload values in the value-stack arena during unwinding. This
      # avoids a fixed native-stack buffer and supports arbitrary validated
      # tag arity.
      let payloadStart = sp - payloadLen
      if payloadStart < 0: trap("invalid exception payload stack height")
      # Scan label stack top-to-bottom for a matching try_table catch clause.
      # Keep track of which call frame each label segment belongs to,
      # so we can unwind the call stack when we cross a frame boundary.
      var frameIdx = vm.callStackTop - 1
      var scanLabelIdx = vm.labelStackTop - 1
      var caught = false
      block scanLoop:
        while scanLabelIdx >= entryLabelStackTop:
          # When we pass below a frame's label start, step down one frame
          while frameIdx > 0 and
                scanLabelIdx < vm.callStack[frameIdx].labelStackStart:
            dec frameIdx
          let lbl = vm.labelStack[scanLabelIdx]
          if lbl.catchTableIdx >= 0:
            let clauses = vm.callStack[frameIdx].code[].catchTables[lbl.catchTableIdx]
            let frameModIdx = vm.callStack[frameIdx].moduleIdx
            for clause in clauses:
              var matches = false
              case clause.kind
              of ckCatch, ckCatchRef:
                let resolvedAddr = vm.store.modules[frameModIdx].tagAddrs[clause.tagIdx.int]
                matches = (resolvedAddr == tagAddr)
              of ckCatchAll, ckCatchAllRef:
                matches = true
              if matches:
                # Unwind call stack down to frame frameIdx
                while vm.callStackTop - 1 > frameIdx:
                  let f = vm.callStack[vm.callStackTop - 1]
                  vm.localsTop = f.localsStart
                  dec vm.callStackTop
                # Restore label stack to the matching try_table label slot
                vm.labelStackTop = scanLabelIdx + 1
                # Restore cached frame state
                loadFrameCache()
                locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
                # Catch depths exclude the try_table's own label.
                let outerCount = scanLabelIdx - vm.callStack[frameIdx].labelStackStart
                if outerCount <= 0 or uint64(clause.labelDepth) >= uint64(outerCount):
                  trap("catch target outside current function")
                let targetLabelIdx = scanLabelIdx - 1 - clause.labelDepth.int
                let targetLbl = vm.labelStack[targetLabelIdx]
                let target = targetLbl.stackHeight
                if target < 0 or target > payloadStart:
                  trap("invalid catch stack height")
                let needsRef = clause.kind in {ckCatchRef, ckCatchAllRef}
                let keptPayload = clause.kind in {ckCatch, ckCatchRef}
                let newTop = target + (if keptPayload: payloadLen else: 0) +
                  int(needsRef)
                if newTop > vm.valueStack.len:
                  vm.valueStack.setLen(max(newTop, vm.valueStack.len * 2))
                vsBase = cast[ptr UncheckedArray[uint64]](vm.valueStack[0].addr)
                if keptPayload and payloadLen > 0:
                  moveMem(addr vsBase[target], addr vsBase[payloadStart],
                          payloadLen * sizeof(uint64))
                sp = target + (if keptPayload: payloadLen else: 0)
                if needsRef:
                  vsBase[sp] = cast[uint64](-1'i64); inc sp
                # Branching to a loop retains its label for the next iteration.
                vm.labelStackTop = targetLabelIdx + int(targetLbl.isLoop)
                # Jump to the target label's continuation pc
                cachedPc = targetLbl.pc
                caught = true
                break scanLoop
          dec scanLabelIdx
      if not caught:
        trap("uncaught WASM exception: tag " & $tagAddr)

    of opThrowRef:
      # Simplified: treat the exnref as opaque. Pop it and trap.
      # Full exnref tracking would require heap-allocated exception objects.
      discard spop()  # exnref
      trap("throw_ref: exnref propagation not supported in interpreter")

    of opTryTable:
      let resultArity = vm.blockResultArity(instr.pad, cachedModIdx, cachedPc-1)
      let paramArity = vm.blockParamArity(instr.pad, cachedModIdx, cachedPc-1)
      let endIdx = instr.imm1.int
      let sh = sp - paramArity
      if vm.labelStackTop >= vm.labelStack.len:
        vm.labelStack.setLen(vm.labelStack.len * 2)
      vm.labelStack[vm.labelStackTop] = Label(
        arity: resultArity,
        pc: endIdx + 1,
        stackHeight: sh,
        isLoop: false,
        catchTableIdx: instr.imm2.int32
      )
      inc vm.labelStackTop

    # ===== SIMD v128 =====
    # The interpreter does not implement SIMD; these instructions trap.
    # SIMD execution is handled exclusively by the Tier 2 JIT backend.
    of opV128Load, opV128Store, opV128Const,
       opI8x16Splat, opI16x8Splat, opI32x4Splat, opI64x2Splat,
       opF32x4Splat, opF64x2Splat,
       opI8x16ExtractLaneS, opI8x16ExtractLaneU, opI8x16ReplaceLane,
       opI16x8ExtractLaneS, opI16x8ExtractLaneU, opI16x8ReplaceLane,
       opI32x4ExtractLane, opI32x4ReplaceLane,
       opI64x2ExtractLane, opI64x2ReplaceLane,
       opF32x4ExtractLane, opF32x4ReplaceLane,
       opF64x2ExtractLane, opF64x2ReplaceLane,
       opV128Not, opV128And, opV128Or, opV128Xor, opV128AndNot,
       opI8x16Abs, opI8x16Neg, opI8x16Add, opI8x16Sub,
       opI8x16MinS, opI8x16MinU, opI8x16MaxS, opI8x16MaxU,
       opI16x8Abs, opI16x8Neg, opI16x8Add, opI16x8Sub, opI16x8Mul,
       opI32x4Abs, opI32x4Neg, opI32x4Add, opI32x4Sub, opI32x4Mul,
       opI32x4Shl, opI32x4ShrS, opI32x4ShrU,
       opI32x4MinS, opI32x4MinU, opI32x4MaxS, opI32x4MaxU,
       opI64x2Add, opI64x2Sub,
       opF32x4Abs, opF32x4Neg, opF32x4Add, opF32x4Sub, opF32x4Mul, opF32x4Div,
       opF64x2Abs, opF64x2Neg, opF64x2Add, opF64x2Sub, opF64x2Mul, opF64x2Div:
      trap("SIMD v128 not supported in interpreter; use Tier 2 JIT")

  # Sync cached sp back before collecting results
  syncSp()
  when resumable:
    if sliced:
      continuation[].instructions += sliceInstructions.uint64
      continuation[].status = wesComplete

  # Collect results (convert uint64 -> WasmValue based on result types)
  let returnArity = ft.results.len
  result = newSeq[WasmValue](returnArity)
  for i in countdown(returnArity - 1, 0):
    result[i] = rawToWasmValue(vm.popRaw(), ft.results[i])

  # Restore entry state (in case of nested calls through host)
  vm.valueStackTop = entryValueStackTop
  vm.callStackTop = entryCallStackTop
  vm.labelStackTop = entryLabelStackTop
  vm.localsTop = entryLocalsTop

proc execute*(vm: var WasmVM, funcAddr: int,
              args: openArray[WasmValue],
              profiler: ptr PgoProfiler = nil,
              osrOut: ptr OsrTrigger = nil): seq[WasmValue] =
  ## Run a function to completion, allowing existing synchronous host and
  ## memory operations. The sliced entry point below uses the same dispatch.
  let valueTop = vm.valueStackTop
  let callTop = vm.callStackTop
  let labelTop = vm.labelStackTop
  let localsTop = vm.localsTop
  try:
    # A direct host call can reenter the interpreter (for example via canonical
    # realloc). Avoid reserving a dispatch frame before invoking the host.
    let function {.cursor.} = vm.store.funcs[funcAddr]
    if function.isHost:
      when WasmSuspendableHostCalls:
        let previous = vm.hostWaitSlot
        vm.hostWaitSlot = nil
        defer: vm.hostWaitSlot = previous
      when defined(wasmFunctionReferences): vm.checkReferenceValues(function.funcType, args, true)
      result = function.hostFunc(args)
      when defined(wasmFunctionReferences): vm.checkReferenceValues(function.funcType, result, false)
      return
    when WasmSuspendableHostCalls:
      # Keep one generated dispatch body in stackful firmware. A nil
      # continuation selects the same synchronous host and memory semantics.
      result = executeImpl[true](vm, funcAddr, args, profiler, osrOut, nil, 0, nil, 0)
    else:
      result = executeImpl[false](vm, funcAddr, args, profiler, osrOut, nil, 0, nil, 0)
  except CatchableError:
    vm.valueStackTop = valueTop
    vm.callStackTop = callTop
    vm.labelStackTop = labelTop
    vm.localsTop = localsTop
    raise

proc executeSlice*(vm: var WasmVM, funcAddr: int,
                   args: openArray[WasmValue],
                   continuation: var WasmContinuation,
                   instructionBudget: uint32,
                   profiler: ptr PgoProfiler = nil,
                   osrOut: ptr OsrTrigger = nil,
                   deadlineClock: WasmDeadlineClock = nil,
                   deadlineTick = 0'u64): seq[WasmValue] =
  ## Resume on the same core and VM after wesYielded or wesHostBlocked. The returned result seq
  ## is meaningful only when status becomes wesComplete. This preempts at a
  ## guest instruction boundary; it does not bound a host import or page I/O.
  if instructionBudget == 0: trap("zero interpreter instruction budget")
  executeImpl[true](vm, funcAddr, args, profiler, osrOut,
                    addr continuation, instructionBudget,
                    deadlineClock, deadlineTick)

when defined(wasmChunkedMemory):
  proc serviceExecutionMemoryFault*(vm: var WasmVM,
                                    continuation: var WasmContinuation): LinearMemoryStatus =
    ## Run only from a backing-service context outside the guest's slice.
    ## This may perform synchronous SD or IPC I/O; callers must unblock the
    ## task only when the missing chunk is resident.
    if continuation.status != wesMemoryBlocked or
        continuation.faultMemAddr < 0 or
        continuation.faultMemAddr >= vm.store.mems.len:
      return lmInvalidConfig
    let mem = addr vm.store.mems[continuation.faultMemAddr]
    if mem[].chunked == nil: return lmInvalidConfig
    result = mem[].chunked[].servicePendingFault()
    if result == lmOk:
      continuation.status = wesYielded

proc abortExecution*(vm: var WasmVM,
                     continuation: var WasmContinuation) =
  ## Abandon a yielded or trapped call before reusing the VM. This does not
  ## undo guest memory side effects from completed instructions.
  if continuation.status != wesRunning and continuation.status notin SuspendedExecution: return
  when WasmSuspendableHostCalls:
    if continuation.status == wesHostBlocked and continuation.hostVm != (addr vm):
      trap("stale interpreter host continuation")
    continuation.hostWait = WasmHostWait()
    continuation.hostVm = nil
  when WasmAtomicWaitEnabled:
    if continuation.status == wesAtomicBlocked:
      vm.validateAtomicContinuation(continuation.atomicWait)
      vm.removeAtomicWait(continuation.atomicWait)
      continuation.atomicWait.state = wawAborted
      continuation.atomicWait = nil
  vm.valueStackTop = continuation.entryValueStackTop
  vm.callStackTop = continuation.entryCallStackTop
  vm.labelStackTop = continuation.entryLabelStackTop
  vm.localsTop = continuation.entryLocalsTop
  when defined(wasmChunkedMemory):
    continuation.retryMemoryInstruction = false
    continuation.transferProgress = 0
    continuation.copyCursor = LinearMemoryCopyCursor()
    continuation.bulkDone = 0
    continuation.bulkPartProgress = 0
    continuation.bulkWriting = false
  continuation.status = wesReady

# ---------------------------------------------------------------------------
# Portable guest-only suspension state
# ---------------------------------------------------------------------------

const
  WasmPortableMagic = 0x5356_4D57'u32
  WasmPortableStackVersion = 1'u32
  WasmPortableStoreVersion = 2'u32
  WasmPortableWideStoreVersion = 3'u32
  WasmPortableHeaderBytes* = 64
  WasmPortableMaxBytes* = 4096
  WasmPortableLegacyStoreMaxBytes = high(uint16).int
  WasmPortableStagedMaxBytes* = 64 * 1024 * 1024
  WasmPortableFrameBytes = 28
  WasmPortableLabelBytes = 20

when defined(wasmStreamMigration):
  const
    WasmPortableStreamVersion = 4'u32
    WasmPortableStreamFooterBytes* = 8

when defined(wasmStorageMigration):
  type
    WasmPortableIo* = proc(ctx: pointer, offset: int, buf: pointer,
                           count: int): bool {.nimcall.}
    WasmPortableStorage* = object
      ## Exclusive medium, accessed only from normal scheduler context.
      ctx*: pointer
      read*, write*: WasmPortableIo
      seal*: proc(ctx: pointer): bool {.nimcall.}

type
  WasmPortableStatus* = enum
    wpsOk
    wpsNotSuspended
    wpsUnsupportedState
    wpsTooLarge
    wpsInvalidSnapshot
    wpsWrongModule
    wpsPending
    wpsBackingFailed

  WasmPortableSnapshot* = object
    status*: WasmPortableStatus
    bytes*: seq[byte]
    staged*: WasmPortableStaging

  WasmPortableStaging* = object
    ## Caller-owned storage. A completed snapshot reports the populated
    ## length instead of the original capacity.
    data*: ptr UncheckedArray[byte]
    len*: int
    when defined(wasmStorageMigration):
      storage*: ptr WasmPortableStorage

  WasmPortableIoError = object of CatchableError

proc usesPortableBacking*(view: WasmPortableStaging): bool {.inline.} =
  when defined(wasmStorageMigration): view.storage != nil
  else: false

proc hasPortableStaging*(view: WasmPortableStaging): bool {.inline.} =
  view.data != nil or view.usesPortableBacking()

proc validPortableStaging*(view: WasmPortableStaging): bool =
  if view.len notin WasmPortableHeaderBytes..WasmPortableStagedMaxBytes:
    return false
  when defined(wasmStorageMigration):
    if view.usesPortableBacking():
      return view.data == nil and view.storage.read != nil and
        view.storage.write != nil and view.storage.seal != nil
  view.data != nil and view.len.uint - 1 <= high(uint) - cast[uint](view.data)

proc portableInputView*(data: openArray[byte]): WasmPortableStaging {.inline.} =
  result.len = data.len
  if data.len != 0: result.data = cast[ptr UncheckedArray[byte]](unsafeAddr data[0])

proc portableLen(snapshot: WasmPortableSnapshot): int {.inline.} =
  if snapshot.staged.hasPortableStaging(): snapshot.staged.len else: snapshot.bytes.len

proc portableView(snapshot: WasmPortableSnapshot): WasmPortableStaging {.inline.} =
  if snapshot.staged.hasPortableStaging(): snapshot.staged
  else: portableInputView(snapshot.bytes)

proc portableIo(view: WasmPortableStaging, at: int, buf: pointer, count: int,
                writing: static bool): bool =
  if at < 0 or at > view.len or count < 0 or count > view.len - at: return false
  if count == 0: return true
  if buf == nil: return false
  when defined(wasmStorageMigration):
    if view.usesPortableBacking():
      let operation = if writing: view.storage.write else: view.storage.read
      return operation != nil and operation(view.storage.ctx, at, buf, count)
  if view.data == nil: return false
  when writing: copyMem(addr view.data[at], buf, count)
  else: copyMem(buf, addr view.data[at], count)
  true

proc readPortableRange*(view: WasmPortableStaging, at: int, buf: pointer,
                        count: int): bool {.inline.} =
  view.portableIo(at, buf, count, false)

proc writePortableRange*(view: WasmPortableStaging, at: int, buf: pointer,
                         count: int): bool {.inline.} =
  view.portableIo(at, buf, count, true)

proc sealPortableStaging*(view: WasmPortableStaging): bool =
  when defined(wasmStorageMigration):
    if view.usesPortableBacking():
      return view.storage.seal != nil and view.storage.seal(view.storage.ctx)
  true

proc requirePortableIo(ok: bool) {.inline.} =
  if not ok: raise newException(WasmPortableIoError, "snapshot storage I/O failed")

proc portableRead[T: uint8 | uint16 | uint32 | uint64](
    view: WasmPortableStaging, at: int): T {.inline.} =
  when defined(wasmStorageMigration):
    if view.usesPortableBacking():
      var buf: array[sizeof(T), byte]
      requirePortableIo(view.readPortableRange(at, addr buf[0], buf.len))
      for i in 0 ..< buf.len: result = result or (buf[i].T shl (8 * i))
      return
  for i in 0 ..< sizeof(T): result = result or (view.data[at + i].T shl (8 * i))

proc portableWrite[T: uint8 | uint16 | uint32 | uint64](
    view: WasmPortableStaging, at: int, value: T) {.inline.} =
  when defined(wasmStorageMigration):
    if view.usesPortableBacking():
      var buf: array[sizeof(T), byte]
      for i in 0 ..< buf.len: buf[i] = byte(value shr (8 * i))
      requirePortableIo(view.writePortableRange(at, addr buf[0], buf.len))
      return
  for i in 0 ..< sizeof(T): view.data[at + i] = byte(value shr (8 * i))

template portableRead16(data: WasmPortableStaging, at: int): uint16 =
  portableRead[uint16](data, at)
template portableRead32(data: WasmPortableStaging, at: int): uint32 =
  portableRead[uint32](data, at)
template portableRead64(data: WasmPortableStaging, at: int): uint64 =
  portableRead[uint64](data, at)

proc updatePortableChecksum(crc: var uint32, data: openArray[byte], position: int) =
  for i, b in data:
    if position + i in 60 .. 63: continue
    crc = crc xor b.uint32
    for _ in 0 ..< 8:
      crc = (crc shr 1) xor
        (if (crc and 1) != 0: 0xEDB8_8320'u32 else: 0'u32)

when defined(wasmStorageMigration):
  const PortableTransferBytes = 512

  proc portableBackingChecksum(view: WasmPortableStaging): uint32 =
    var crc = not 0'u32
    var buf: array[PortableTransferBytes, byte]
    var pos = 0
    while pos < view.len:
      let count = min(buf.len, view.len - pos)
      requirePortableIo(view.readPortableRange(pos, addr buf[0], count))
      crc.updatePortableChecksum(buf.toOpenArray(0, count - 1), pos)
      pos += count
    not crc

proc portableChecksum(data: WasmPortableStaging): uint32 =
  when defined(wasmStorageMigration):
    if data.usesPortableBacking(): return data.portableBackingChecksum()
  var crc = not 0'u32
  crc.updatePortableChecksum(data.data.toOpenArray(0, data.len - 1), 0)
  not crc

proc portableStoreEligible(vm: WasmVM): bool =
  ## Each function address belongs to the same standalone core module.
  ## Host references and exception state require separate transfer contracts.
  if vm.store.modules.len != 1 or vm.store.funcs.len == 0 or
      vm.store.mems.len > 1 or vm.store.tags.len != 0:
    return false
  for function in vm.store.funcs:
    if function.isHost or function.moduleIdx != 0 or function.code == nil or
        vtExternRef in function.funcType.params or vtExternRef in function.funcType.results:
      return false
  when defined(wasmSharedCoreTypes):
    for memory in vm.store.mems:
      if memory.memType.limits.shared: return false
    for table in vm.store.tables:
      if table.tableType.limits.shared: return false
    for segment in vm.store.elems:
      if segment.shared: return false
    for segment in vm.store.datas:
      if segment.shared: return false
    for global in vm.store.globals:
      if global.globalType.shared: return false
  true

include ./runtime_portable_store

proc portableFrameValid(vm: WasmVM, frame: Frame, localsCount,
                        labelCount: int): bool =
  if frame.funcAddr < 0 or frame.funcAddr >= vm.store.funcs.len or
      frame.moduleIdx != 0 or frame.pc < 0 or frame.localsStart < 0 or
      frame.localsCount < 0 or frame.labelStackStart < 0 or
      frame.labelStackStart > labelCount or frame.returnArity < 0 or
      frame.returnArity > 16:
    return false
  let function = vm.store.funcs[frame.funcAddr]
  if function.isHost or frame.code != function.code or
      frame.brTables != function.code[].brTables.addr or
      frame.pc > function.code[].code.len or
      frame.localsCount != function.localTypes.len or
      frame.localsStart > localsCount or
      frame.localsCount > localsCount - frame.localsStart:
    return false
  true

proc checkPortablePrefix(vm: WasmVM, continuation: WasmContinuation,
                         maxBytes: int, size: var int): WasmPortableStatus =
  if continuation.status != wesYielded:
    return wpsNotSuspended
  when defined(wasmChunkedMemory):
    if continuation.retryMemoryInstruction:
      return wpsNotSuspended
  if not vm.portableStoreEligible() or
      continuation.entryValueStackTop != 0 or
      continuation.entryCallStackTop != 0 or
      continuation.entryLabelStackTop != 0 or
      continuation.entryLocalsTop != 0 or
      vm.callStackTop <= 0 or vm.callStackTop > vm.callStack.len or
      vm.valueStackTop < 0 or vm.valueStackTop > vm.valueStack.len or
      vm.labelStackTop <= 0 or vm.labelStackTop > vm.labelStack.len or
      vm.localsTop < 0 or vm.localsTop > vm.locals.len or
      continuation.funcAddr < 0 or
      continuation.funcAddr >= vm.store.funcs.len:
    return wpsUnsupportedState
  let valueCount = vm.valueStackTop
  let frameCount = vm.callStackTop
  let labelCount = vm.labelStackTop
  let localsCount = vm.localsTop
  if maxBytes < WasmPortableHeaderBytes or
      valueCount > uint16.high.int or frameCount > uint16.high.int or
      labelCount > uint16.high.int or localsCount > uint16.high.int:
    return wpsTooLarge
  size = WasmPortableHeaderBytes + valueCount * 8 + frameCount * WasmPortableFrameBytes +
    labelCount * WasmPortableLabelBytes + localsCount * 8
  if size > maxBytes: return wpsTooLarge
  var previousLabelStart = -1
  for i in 0 ..< frameCount:
    let frame = vm.callStack[i]
    if not vm.portableFrameValid(frame, localsCount, labelCount) or
        frame.labelStackStart < previousLabelStart:
      return wpsUnsupportedState
    previousLabelStart = frame.labelStackStart
  if vm.callStack[0].labelStackStart != 0:
    return wpsUnsupportedState
  # A tail call can replace the first frame while the continuation still
  # names the job's original export. It must preserve that export's results.
  if vm.store.funcs[vm.callStack[0].funcAddr].funcType.results !=
      vm.store.funcs[continuation.funcAddr].funcType.results:
    return wpsUnsupportedState
  for label in vm.labelStack.toOpenArray(0, labelCount - 1):
    if label.arity < 0 or label.arity > 16 or label.pc < 0 or
        label.stackHeight < 0 or label.stackHeight > valueCount or
        label.catchTableIdx != -1:
      return wpsUnsupportedState
  wpsOk

proc writePortableHeader(data: WasmPortableStaging, at: int, vm: WasmVM,
    continuation: WasmContinuation, digest: array[32, byte], version: uint32) =
  portableWrite(data, at, WasmPortableMagic)
  portableWrite(data, at + 4, version)
  requirePortableIo(data.writePortableRange(at + 8, unsafeAddr digest[0], digest.len))
  portableWrite(data, at + 40, continuation.funcAddr.uint32)
  portableWrite(data, at + 44, continuation.instructions)
  portableWrite(data, at + 52, vm.valueStackTop.uint16)
  portableWrite(data, at + 54, vm.callStackTop.uint16)
  portableWrite(data, at + 56, vm.labelStackTop.uint16)
  portableWrite(data, at + 58, vm.localsTop.uint16)
  portableWrite(data, at + 60, 0'u32)

proc writePortableFrame(data: WasmPortableStaging, at: int, frame: Frame) =
  var pos = at
  for field in [frame.pc, frame.localsStart, frame.localsCount,
                frame.labelStackStart, frame.returnArity,
                frame.moduleIdx, frame.funcAddr]:
    portableWrite(data, pos, field.uint32)
    pos += 4

proc writePortableLabel(data: WasmPortableStaging, at: int, label: Label) =
  var pos = at
  for field in [label.arity, label.pc, label.stackHeight,
                int(label.isLoop), label.catchTableIdx.int]:
    portableWrite(data, pos, cast[uint32](field))
    pos += 4

proc capturePortablePrefix(vm: WasmVM, continuation: WasmContinuation,
    moduleDigest: array[32, byte], maxBytes: int,
    staging: WasmPortableStaging): WasmPortableSnapshot =
  let staged = staging.hasPortableStaging()
  let capacity = if staged: staging.len else: WasmPortableMaxBytes
  if (staged and not staging.validPortableStaging()) or
      (not staged and staging.len != 0) or maxBytes > capacity:
    return WasmPortableSnapshot(status: wpsTooLarge)
  var size: int
  result.status = vm.checkPortablePrefix(continuation, maxBytes, size)
  if result.status != wpsOk: return
  result.staged = staging
  result.staged.len = 0
  discard result.appendPortable(size, maxBytes)
  let data = result.portableView()
  let hasStore = vm.portableStoreHasState()
  let version = if not hasStore: WasmPortableStackVersion
                elif maxBytes > WasmPortableLegacyStoreMaxBytes: WasmPortableWideStoreVersion
                else: WasmPortableStoreVersion
  data.writePortableHeader(0, vm, continuation, moduleDigest, version)
  var at = WasmPortableHeaderBytes
  for i in 0 ..< vm.valueStackTop:
    portableWrite(data, at, vm.valueStack[i])
    at += 8
  for i in 0 ..< vm.callStackTop:
    data.writePortableFrame(at, vm.callStack[i])
    at += WasmPortableFrameBytes
  for i in 0 ..< vm.labelStackTop:
    data.writePortableLabel(at, vm.labelStack[i])
    at += WasmPortableLabelBytes
  for i in 0 ..< vm.localsTop:
    portableWrite(data, at, vm.locals[i])
    at += 8
  result.status = wpsOk

proc finishPortableCapture(vm: WasmVM, snapshot: var WasmPortableSnapshot,
    maxBytes: int, cursor: var PortableMemoryCapture, allowAsync: static bool) =
  if vm.portableStoreHasState():
    snapshot.status = vm.capturePortableStore(snapshot, maxBytes, cursor, allowAsync)
    if snapshot.status == wpsPending: return
    if snapshot.status != wpsOk:
      snapshot.bytes = @[]
      snapshot.staged = WasmPortableStaging()
      return
  let view = snapshot.portableView()
  portableWrite(view, 60, portableChecksum(view))
  requirePortableIo(view.sealPortableStaging())
  snapshot.status = wpsOk

proc capturePortableSnapshot*(vm: WasmVM, continuation: WasmContinuation,
    moduleDigest: array[32, byte], maxBytes = WasmPortableMaxBytes,
    staging = WasmPortableStaging()): WasmPortableSnapshot =
  ## Capture only after executeSlice yielded at a guest instruction boundary.
  ## This synchronous entry point leaves asynchronous backing untouched.
  try:
    result = vm.capturePortablePrefix(continuation, moduleDigest, maxBytes, staging)
    if result.status != wpsOk: return
    var cursor: PortableMemoryCapture
    vm.finishPortableCapture(result, maxBytes, cursor, false)
  except WasmPortableIoError:
    result = WasmPortableSnapshot(status: wpsBackingFailed)

when defined(wasmChunkedMemory):
  type WasmPortableCapture* = object
    snapshot: WasmPortableSnapshot
    memory: PortableMemoryCapture
    maxBytes: int

  proc `=copy`(dest: var WasmPortableCapture, source: WasmPortableCapture)
    {.error: "a portable capture with an outstanding page read cannot be copied".}

  proc cancelPortableCapture*(capture: var WasmPortableCapture) =
    if capture.memory.memory != nil:
      capture.memory.memory[].cancelLinearSnapshotRead(capture.memory.reader)
    capture = WasmPortableCapture()

  proc beginPortableCapture*(vm: WasmVM, continuation: WasmContinuation,
      digest: array[32, byte], capture: var WasmPortableCapture,
      maxBytes: int, staging = WasmPortableStaging()): WasmPortableStatus =
    ## Keep the source VM frozen until capture completes or is canceled.
    ## Finish with takePortableSnapshot or cancelPortableCapture.
    if capture.maxBytes != 0: return wpsUnsupportedState
    try:
      capture.snapshot = vm.capturePortablePrefix(continuation, digest, maxBytes, staging)
      if capture.snapshot.status != wpsOk: return capture.snapshot.status
      capture.maxBytes = maxBytes
      vm.finishPortableCapture(capture.snapshot, maxBytes, capture.memory, true)
      capture.snapshot.status
    except WasmPortableIoError:
      capture.cancelPortableCapture()
      wpsBackingFailed

  proc pollPortableCapture*(vm: WasmVM, capture: var WasmPortableCapture): WasmPortableStatus =
    if capture.snapshot.status != wpsPending: return wpsUnsupportedState
    try:
      vm.finishPortableCapture(capture.snapshot, capture.maxBytes, capture.memory, true)
      capture.snapshot.status
    except WasmPortableIoError:
      capture.cancelPortableCapture()
      wpsBackingFailed

  proc takePortableSnapshot*(capture: var WasmPortableCapture): WasmPortableSnapshot =
    if capture.maxBytes == 0 or capture.snapshot.status != wpsOk:
      return WasmPortableSnapshot(status: wpsUnsupportedState)
    result = move capture.snapshot
    capture.cancelPortableCapture()

proc validatePortableSnapshot(vm: var WasmVM, continuation: WasmContinuation,
    data: WasmPortableStaging, expectedDigest: array[32, byte],
    layout: var PortableRestoreLayout, allowPaging: bool): WasmPortableStatus =
  ## Validate the entire little-endian image before changing the destination.
  ## Caller verifies the destination module bytes before supplying its digest.
  if continuation.status != wesReady or vm.callStackTop != 0 or
      vm.valueStackTop != 0 or vm.labelStackTop != 0 or vm.localsTop != 0 or
      not vm.portableStoreEligible():
    return wpsUnsupportedState
  if not data.validPortableStaging() or
      portableRead32(data, 0) != WasmPortableMagic:
    return wpsInvalidSnapshot
  let hasStore = vm.portableStoreHasState()
  let version = portableRead32(data, 4)
  let streamed = when defined(wasmStreamMigration): version == WasmPortableStreamVersion
                 else: false
  var body = data
  var checksumView = data
  var expectedChecksum = portableRead32(data, 60)
  var streamedRuns = -1'i64
  when defined(wasmStreamMigration):
    if streamed:
      if data.len < WasmPortableHeaderBytes + WasmPortableStreamFooterBytes or expectedChecksum != 0:
        return wpsInvalidSnapshot
      body.len -= WasmPortableStreamFooterBytes
      checksumView.len -= 4
      streamedRuns = portableRead32(data, body.len).int64
      expectedChecksum = portableRead32(data, checksumView.len)
      if vm.store.mems.len == 0 and streamedRuns != 0: return wpsInvalidSnapshot
  if not streamed:
    if hasStore:
      if version != WasmPortableWideStoreVersion and
          (version != WasmPortableStoreVersion or data.len > WasmPortableLegacyStoreMaxBytes):
        return wpsInvalidSnapshot
    elif version != WasmPortableStackVersion:
      return wpsInvalidSnapshot
  layout.bodyBytes = body.len
  var digest: array[32, byte]
  requirePortableIo(data.readPortableRange(8, addr digest[0], digest.len))
  if digest != expectedDigest: return wpsWrongModule
  let valueCount = portableRead16(data, 52).int
  let frameCount = portableRead16(data, 54).int
  let labelCount = portableRead16(data, 56).int
  let localsCount = portableRead16(data, 58).int
  let payload = valueCount * 8 + frameCount * WasmPortableFrameBytes +
    labelCount * WasmPortableLabelBytes + localsCount * 8
  let storeOffset = WasmPortableHeaderBytes + payload
  if frameCount == 0 or labelCount == 0 or
      storeOffset > body.len or (not hasStore and storeOffset != body.len) or
      expectedChecksum != portableChecksum(checksumView):
    return wpsInvalidSnapshot
  let root = portableRead32(data, 40)
  if root >= vm.store.funcs.len.uint32: return wpsInvalidSnapshot
  var at = WasmPortableHeaderBytes + valueCount * 8
  var previousLabelStart = -1
  for i in 0 ..< frameCount:
    let pc = portableRead32(data, at)
    let localsStart = portableRead32(data, at + 4)
    let count = portableRead32(data, at + 8)
    let labelStart = portableRead32(data, at + 12)
    let returnArity = portableRead32(data, at + 16)
    let moduleIdx = portableRead32(data, at + 20)
    let funcAddr = portableRead32(data, at + 24)
    if moduleIdx != 0 or funcAddr >= vm.store.funcs.len.uint32:
      return wpsInvalidSnapshot
    let function = vm.store.funcs[funcAddr.int]
    if function.isHost or pc > function.code[].code.len.uint32 or
        count != function.localTypes.len.uint32 or
        localsStart > localsCount.uint32 or
        count > localsCount.uint32 - localsStart or
        labelStart > labelCount.uint32 or
        labelStart.int < previousLabelStart or returnArity > 16:
      return wpsInvalidSnapshot
    if i == 0 and (labelStart != 0 or function.funcType.results !=
        vm.store.funcs[root.int].funcType.results):
      return wpsInvalidSnapshot
    previousLabelStart = labelStart.int
    at += WasmPortableFrameBytes
  var owner = 0
  let frameBase = WasmPortableHeaderBytes + valueCount * 8
  for i in 0 ..< labelCount:
    while owner + 1 < frameCount and
        portableRead32(data, frameBase + (owner + 1) *
          WasmPortableFrameBytes + 12).int <= i:
      inc owner
    let arity = portableRead32(data, at)
    let pc = portableRead32(data, at + 4)
    let stackHeight = portableRead32(data, at + 8)
    let loopFlag = portableRead32(data, at + 12)
    let catchIdx = portableRead32(data, at + 16)
    let funcAddr = portableRead32(data, frameBase + owner *
      WasmPortableFrameBytes + 24).int
    if arity > 16 or pc > vm.store.funcs[funcAddr].code[].code.len.uint32 + 1 or
        stackHeight > valueCount.uint32 or loopFlag > 1 or
        catchIdx != high(uint32):
      return wpsInvalidSnapshot
    at += WasmPortableLabelBytes
  if hasStore:
    if not vm.validatePortableStore(body, storeOffset, layout, allowPaging,
        streamed or version == WasmPortableWideStoreVersion, streamedRuns):
      return wpsInvalidSnapshot
  wpsOk

proc restorePortableFrames(vm: var WasmVM, continuation: var WasmContinuation,
                            data: WasmPortableStaging) =
  let valueCount = portableRead16(data, 52).int
  let frameCount = portableRead16(data, 54).int
  let labelCount = portableRead16(data, 56).int
  let localsCount = portableRead16(data, 58).int
  if vm.valueStack.len < valueCount: vm.valueStack.setLen(valueCount)
  if vm.callStack.len < frameCount: vm.callStack.setLen(frameCount)
  if vm.labelStack.len < labelCount: vm.labelStack.setLen(labelCount)
  if vm.locals.len < localsCount: vm.locals.setLen(localsCount)
  var at = WasmPortableHeaderBytes
  for i in 0 ..< valueCount:
    vm.valueStack[i] = portableRead64(data, at)
    at += 8
  for i in 0 ..< frameCount:
    let funcAddr = portableRead32(data, at + 24).int
    let function = vm.store.funcs[funcAddr]
    vm.callStack[i] = Frame(
      pc: portableRead32(data, at).int,
      code: function.code,
      brTables: function.code[].brTables.addr,
      localsStart: portableRead32(data, at + 4).int,
      localsCount: portableRead32(data, at + 8).int,
      labelStackStart: portableRead32(data, at + 12).int,
      returnArity: portableRead32(data, at + 16).int,
      moduleIdx: 0, funcAddr: funcAddr)
    at += WasmPortableFrameBytes
  for i in 0 ..< labelCount:
    vm.labelStack[i] = Label(
      arity: portableRead32(data, at).int,
      pc: portableRead32(data, at + 4).int,
      stackHeight: portableRead32(data, at + 8).int,
      isLoop: portableRead32(data, at + 12) != 0,
      catchTableIdx: -1)
    at += WasmPortableLabelBytes
  for i in 0 ..< localsCount:
    vm.locals[i] = portableRead64(data, at)
    at += 8
  vm.valueStackTop = valueCount
  vm.callStackTop = frameCount
  vm.labelStackTop = labelCount
  vm.localsTop = localsCount
  continuation = WasmContinuation(status: wesYielded,
    instructions: portableRead64(data, 44), funcAddr: portableRead32(data, 40).int,
    entryValueStackTop: 0, entryCallStackTop: 0,
    entryLabelStackTop: 0, entryLocalsTop: 0)

proc restorePortableSnapshot*(vm: var WasmVM, continuation: var WasmContinuation,
    data: WasmPortableStaging, expectedDigest: array[32, byte]): WasmPortableStatus =
  ## Synchronous restore requires all incoming bytes to fit the resident frames.
  ## A read failure during replay invalidates the dormant VM.
  try:
    var layout: PortableRestoreLayout
    result = vm.validatePortableSnapshot(continuation, data, expectedDigest, layout, false)
    if result != wpsOk: return
    if layout.tailOffset != 0 and not vm.applyPortableStore(data, layout):
      return wpsInvalidSnapshot
    vm.restorePortableFrames(continuation, data)
  except WasmPortableIoError:
    result = wpsBackingFailed

proc restorePortableSnapshot*(vm: var WasmVM, continuation: var WasmContinuation,
    data: openArray[byte], expectedDigest: array[32, byte]): WasmPortableStatus =
  vm.restorePortableSnapshot(continuation, portableInputView(data), expectedDigest)

when defined(wasmChunkedMemory):
  type WasmPortableRestore* = object
    layout: PortableRestoreLayout
    pos, remaining: int
    progress: uint32

  proc beginPortableRestore*(vm: var WasmVM, continuation: var WasmContinuation,
      data: WasmPortableStaging, expectedDigest: array[32, byte],
      pending: var WasmPortableRestore): WasmPortableStatus =
    ## A cold restore validates before any writes. Keep the destination
    ## dormant and the input immutable until polling finishes or it is canceled.
    if pending.layout.cold: return wpsUnsupportedState
    try:
      var layout: PortableRestoreLayout
      result = vm.validatePortableSnapshot(continuation, data, expectedDigest, layout, true)
      if result != wpsOk: return
      if layout.cold:
        continuation.instructions = portableRead64(data, 44)
        continuation.funcAddr = portableRead32(data, 40).int
        pending.layout = layout
        return wpsPending
      if layout.tailOffset != 0 and not vm.applyPortableStore(data, layout):
        return wpsInvalidSnapshot
      vm.restorePortableFrames(continuation, data)
    except WasmPortableIoError:
      result = wpsBackingFailed

  proc beginPortableRestore*(vm: var WasmVM, continuation: var WasmContinuation,
      data: openArray[byte], expectedDigest: array[32, byte],
      pending: var WasmPortableRestore): WasmPortableStatus =
    vm.beginPortableRestore(continuation, portableInputView(data), expectedDigest, pending)

  when defined(wasmStorageMigration):
    proc restorePortableBackingRun(mem: var LinearMemory, data: WasmPortableStaging,
        pos: int, offset: uint64, count: uint32, progress: var uint32): LinearMemoryStatus =
      var buf: array[PortableTransferBytes, byte]
      while progress < count:
        let at = offset + progress.uint64
        # A backed segment never spans two destination frames. If it blocks,
        # writeAt has consumed none of the borrowed scratch bytes.
        let frameBytes = WasmMemoryChunkBytes - (at mod WasmMemoryChunkBytes).uint32
        let size = min(min(buf.len.uint32, frameBytes), count - progress)
        requirePortableIo(data.readPortableRange(pos + progress.int, addr buf[0], size.int))
        let status = mem.writeAt(at, cast[ptr UncheckedArray[byte]](addr buf[0]), size)
        if status != lmOk: return status
        progress += size
      lmOk

  proc pollPortableRestoreImpl(vm: var WasmVM, continuation: var WasmContinuation,
      data: WasmPortableStaging, pending: var WasmPortableRestore): WasmPortableStatus =
    if not pending.layout.cold: return wpsUnsupportedState
    let mem = addr vm.store.mems[0]
    if pending.pos == 0:
      if not mem[].resetPortableMemory(pending.layout): return wpsInvalidSnapshot
      pending.pos = pending.layout.memoryOffset
      pending.remaining = pending.layout.runs
    if mem.chunked[].pendingFault().pending:
      let status = mem.chunked[].servicePendingFault()
      if status == lmWouldBlock: return wpsPending
      if status != lmOk: return wpsBackingFailed
    while pending.remaining > 0:
      let pos = pending.pos
      let offset = portableRead32(data, pos).uint64
      let count = portableRead16(data, pos + 4).uint32
      let status = if data.usesPortableBacking():
        when defined(wasmStorageMigration):
          mem.chunked[].restorePortableBackingRun(data, pos + 6, offset, count, pending.progress)
        else: lmInvalidConfig
      else:
        let src = cast[ptr UncheckedArray[byte]](addr data.data[pos + 6])
        mem.chunked[].writeAtProgress(offset, src, count, pending.progress)
      if status == lmWouldBlock: return wpsPending
      if status != lmOk: return wpsBackingFailed
      pending.pos += 6 + count.int
      dec pending.remaining
      pending.progress = 0
    if not vm.restorePortableStoreTail(data.portableBody(pending.layout), pending.layout.tailOffset, true):
      return wpsInvalidSnapshot
    vm.restorePortableFrames(continuation, data)
    pending = WasmPortableRestore()
    wpsOk

  proc pollPortableRestore*(vm: var WasmVM, continuation: var WasmContinuation,
      data: WasmPortableStaging, pending: var WasmPortableRestore): WasmPortableStatus =
    try:
      vm.pollPortableRestoreImpl(continuation, data, pending)
    except WasmPortableIoError:
      wpsBackingFailed

  proc pollPortableRestore*(vm: var WasmVM, continuation: var WasmContinuation,
      data: openArray[byte], pending: var WasmPortableRestore): WasmPortableStatus =
    vm.pollPortableRestore(continuation, portableInputView(data), pending)

  proc cancelPortableRestore*(vm: var WasmVM, pending: var WasmPortableRestore) =
    ## A canceled destination is discarded by the caller.
    if pending.pos != 0:
      vm.store.mems[0].chunked[].cancelLinearRestore()
    pending = WasmPortableRestore()

when defined(wasmStreamMigration):
  include ./runtime_portable_stream

# ---------------------------------------------------------------------------
# Helper procs for external use
# ---------------------------------------------------------------------------

proc getExport*(vm: var WasmVM, moduleIdx: int, name: string): ExportInst =
  for exp in vm.store.modules[moduleIdx].exports:
    if exp.name == name:
      return exp
  trap("export not found: " & name)

proc invoke*(vm: var WasmVM, moduleIdx: int, name: string,
             args: openArray[WasmValue]): seq[WasmValue] =
  let exp = vm.getExport(moduleIdx, name)
  if exp.kind != ekFunc:
    trap("export is not a function: " & name)
  vm.execute(exp.idx, args)

proc getMemory*(vm: var WasmVM, moduleIdx: int, memIdx: int = 0): var MemInst =
  let memAddr = vm.store.modules[moduleIdx].memAddrs[memIdx]
  vm.store.mems[memAddr]

proc getGlobal*(vm: var WasmVM, moduleIdx: int, globalIdx: int): var GlobalInst =
  let globalAddr = vm.store.modules[moduleIdx].globalAddrs[globalIdx]
  vm.store.globals[globalAddr]

proc getTable*(vm: var WasmVM, moduleIdx: int, tableIdx: int): var TableInst =
  let tableAddr = vm.store.modules[moduleIdx].tableAddrs[tableIdx]
  vm.store.tables[tableAddr]

proc destroyWasmVM*(vm: var WasmVM) =
  ## Release all resources held by the VM, including guard-page memory.
  when defined(wasmGuardPages):
    for i in 0 ..< vm.store.mems.len:
      if vm.store.mems[i].useGuard:
        freeGuardedMem(vm.store.mems[i].guardMem)

proc memCurrentPages*(mem: var MemInst): int {.inline.} =
  ## Current number of allocated WASM pages.
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      return mem.chunked[].currentPages().int
  when defined(wasmGuardPages):
    if mem.useGuard:
      return int(mem.guardMem.accessibleBytes div WasmPageSize.uint64)
  mem.data.len div WasmPageSize
