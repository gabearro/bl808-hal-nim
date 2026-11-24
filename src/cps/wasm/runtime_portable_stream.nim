## Append-only portable snapshots. The footer carries the memory run count
## and checksum so a remote sink never needs to patch an acknowledged byte.

type
  PortableStreamPhase = enum
    pspHeader, pspValues, pspFrames, pspLabels, pspLocals,
    pspMemoryHeader, pspMemoryRun, pspMemoryBytes, pspTableHeader,
    pspTableEntries, pspGlobals, pspElemFlags, pspDataFlags, pspFooter, pspDone

  PortableStreamMemory = object
    data: ptr UncheckedArray[byte]
    base, flatAt: uint64
    pos, size, runEnd: int
    runs: uint32
    when defined(wasmChunkedMemory):
      memory: ref LinearMemory
      order: seq[tuple[number: uint32, index: int]]
      chunk: int
      reader: LinearSnapshotRead

  WasmPortableStream* = object
    phase: PortableStreamPhase
    limit, produced, index, tableIndex: int
    digest: array[32, byte]
    crc: uint32
    memory: PortableStreamMemory

proc `=copy`(dest: var WasmPortableStream, source: WasmPortableStream)
  {.error: "a portable stream with an outstanding page read cannot be copied".}

proc cancelPortableStream*(stream: var WasmPortableStream) =
  when defined(wasmChunkedMemory):
    if stream.memory.memory != nil:
      stream.memory.memory[].cancelLinearSnapshotRead(stream.memory.reader)
  stream = WasmPortableStream()

proc beginPortableStream*(vm: WasmVM, continuation: WasmContinuation,
    digest: array[32, byte], maxBytes: int,
    stream: var WasmPortableStream): WasmPortableStatus =
  if stream.limit != 0: return wpsUnsupportedState
  if maxBytes notin WasmPortableHeaderBytes + WasmPortableStreamFooterBytes..
      WasmPortableStagedMaxBytes:
    return wpsTooLarge
  var prefixBytes: int
  result = vm.checkPortablePrefix(continuation, maxBytes - WasmPortableStreamFooterBytes,
    prefixBytes)
  if result != wpsOk: return
  if vm.store.mems.len != 0:
    let mem = unsafeAddr vm.store.mems[0]
    when defined(wasmChunkedMemory):
      if mem[].chunked != nil:
        if mem[].chunked[].pendingFault().pending: return wpsUnsupportedState
        stream.memory.memory = mem[].chunked
        stream.memory.order = mem[].chunked[].snapshotChunkOrder()
      elif mem[].memByteLen() > PortableFlatScanBytes:
        return wpsTooLarge
    else:
      if mem[].memByteLen() > PortableFlatScanBytes: return wpsTooLarge
  stream.limit = maxBytes
  stream.digest = digest
  stream.crc = not 0'u32

proc streamComplete*(stream: WasmPortableStream): bool {.inline.} =
  stream.phase == pspDone

proc loadPortableSpan(cursor: var PortableStreamMemory, mem: var MemInst): WasmPortableStatus =
  cursor.data = nil
  when defined(wasmChunkedMemory):
    if cursor.memory != nil:
      if cursor.chunk == cursor.order.len: return wpsOk
      let entry = cursor.order[cursor.chunk]
      let status = cursor.memory[].snapshotChunkBytes(entry.index, cursor.reader, cursor.data, true)
      case status
      of lmWouldBlock: return wpsPending
      of lmOk: discard
      else: return wpsBackingFailed
      cursor.base = entry.number.uint64 * WasmMemoryChunkBytes
      cursor.size = WasmMemoryChunkBytes.int
      inc cursor.chunk
      cursor.pos = 0
      return wpsOk
  let length = mem.memByteLen()
  if cursor.flatAt == length: return wpsOk
  cursor.base = cursor.flatAt
  cursor.size = min(length - cursor.flatAt, 4096'u64).int
  cursor.data = cast[ptr UncheckedArray[byte]](mem.memBulkPtr(cursor.flatAt))
  cursor.flatAt += cursor.size.uint64
  cursor.pos = 0
  wpsOk

proc findPortableStreamRun(cursor: var PortableStreamMemory, mem: var MemInst,
                           visits: var int): WasmPortableStatus =
  while true:
    if cursor.data == nil or cursor.pos == cursor.size:
      if visits == 0: return wpsPending
      dec visits
      let status = cursor.loadPortableSpan(mem)
      if status != wpsOk or cursor.data == nil: return status
    while cursor.pos < cursor.size and cursor.data[cursor.pos] == 0:
      inc cursor.pos
    if cursor.pos < cursor.size:
      cursor.runEnd = cursor.pos + 1
      let stop = min(cursor.size, cursor.pos + high(uint16).int)
      while cursor.runEnd < stop and cursor.data[cursor.runEnd] != 0:
        inc cursor.runEnd
      return wpsOk

proc readPortableStream*(vm: WasmVM, continuation: WasmContinuation,
    stream: var WasmPortableStream, dest: var openArray[byte],
    written: var int): WasmPortableStatus =
  ## Freeze the VM and keep its backing alive. A pending result can include a
  ## prefix to ship immediately. Discard the transfer on any terminal error.
  written = 0
  if stream.limit == 0 or dest.len < WasmPortableHeaderBytes:
    return wpsUnsupportedState
  if stream.streamComplete(): return wpsOk
  let output = WasmPortableStaging(data: cast[ptr UncheckedArray[byte]](addr dest[0]), len: dest.len)
  template advanceTo(next: PortableStreamPhase) =
    stream.phase = next
    stream.index = 0
  template need(count: int) =
    if count > stream.limit - stream.produced - written: return wpsTooLarge
    if count > dest.len - written: break
  template emitValue(value: untyped) =
    need(sizeof(value))
    portableWrite(output, written, value)
    written += sizeof(value)
    inc stream.index

  var visits = 8
  while written < dest.len:
    case stream.phase
    of pspHeader:
      need(WasmPortableHeaderBytes)
      output.writePortableHeader(0, vm, continuation, stream.digest, WasmPortableStreamVersion)
      written += WasmPortableHeaderBytes
      advanceTo(pspValues)
    of pspValues:
      if stream.index < vm.valueStackTop: emitValue(vm.valueStack[stream.index])
      else: advanceTo(pspFrames)
    of pspFrames:
      if stream.index < vm.callStackTop:
        need(WasmPortableFrameBytes)
        output.writePortableFrame(written, vm.callStack[stream.index])
        written += WasmPortableFrameBytes
        inc stream.index
      else: advanceTo(pspLabels)
    of pspLabels:
      if stream.index < vm.labelStackTop:
        need(WasmPortableLabelBytes)
        output.writePortableLabel(written, vm.labelStack[stream.index])
        written += WasmPortableLabelBytes
        inc stream.index
      else: advanceTo(pspLocals)
    of pspLocals:
      if stream.index < vm.localsTop: emitValue(vm.locals[stream.index])
      else: advanceTo(pspMemoryHeader)
    of pspMemoryHeader:
      if vm.store.mems.len == 0:
        advanceTo(pspTableHeader)
      else:
        need(12)
        let mem = unsafeAddr vm.store.mems[0]
        portableWrite(output, written, mem[].pageCount().uint32)
        portableWrite(output, written + 4, mem[].portableMemoryLimit())
        portableWrite(output, written + 8, 0'u32)
        written += 12
        advanceTo(pspMemoryRun)
    of pspMemoryRun:
      if dest.len - written < 6: break
      let mem = unsafeAddr vm.store.mems[0]
      # LP may have just one IPC call slot. Ship buffered bytes before
      # initiating a pager read that could reserve that same slot.
      var remaining = if written == 0: visits else: 0
      let status = stream.memory.findPortableStreamRun(mem[], remaining)
      if written == 0: visits = remaining
      if status == wpsPending: break
      if status != wpsOk: return status
      if stream.memory.data == nil:
        advanceTo(pspTableHeader)
      else:
        need(6)
        let offset = stream.memory.base + stream.memory.pos.uint64
        portableWrite(output, written, offset.uint32)
        portableWrite(output, written + 4, (stream.memory.runEnd - stream.memory.pos).uint16)
        written += 6
        inc stream.memory.runs
        advanceTo(pspMemoryBytes)
    of pspMemoryBytes:
      let count = min(stream.memory.runEnd - stream.memory.pos, dest.len - written)
      need(count)
      copyMem(addr dest[written], addr stream.memory.data[stream.memory.pos], count)
      written += count
      stream.memory.pos += count
      if stream.memory.pos == stream.memory.runEnd: advanceTo(pspMemoryRun)
    of pspTableHeader:
      if stream.tableIndex == vm.store.tables.len:
        advanceTo(pspGlobals)
      else:
        need(4)
        portableWrite(output, written, vm.store.tables[stream.tableIndex].elems.len.uint32)
        written += 4
        advanceTo(pspTableEntries)
    of pspTableEntries:
      let table = unsafeAddr vm.store.tables[stream.tableIndex]
      if stream.index == table[].elems.len:
        inc stream.tableIndex
        advanceTo(pspTableHeader)
      else:
        let entry = table[].elems[stream.index]
        let raw = wasmValueToRaw(entry)
        let vt = table[].tableType.elemType
        if entry.kind != vt.toValueKind() or not portableReferenceValid(raw, vt, vm.store.funcs.len):
          return wpsUnsupportedState
        emitValue(raw.uint32)
    of pspGlobals:
      if stream.index == vm.store.globals.len:
        advanceTo(pspElemFlags)
      else:
        let global = unsafeAddr vm.store.globals[stream.index]
        let vt = global[].globalType.valType
        if global[].globalType.mut == mutConst:
          inc stream.index
        elif global[].value.kind != vt.toValueKind():
          return wpsUnsupportedState
        elif vt == vtV128:
          need(16)
          copyMem(addr dest[written], unsafeAddr global[].value.v128[0], 16)
          written += 16
          inc stream.index
        else:
          let raw = wasmValueToRaw(global[].value)
          if vt.isRefType and not portableReferenceValid(raw, vt, vm.store.funcs.len):
            return wpsUnsupportedState
          emitValue(raw)
    of pspElemFlags:
      if stream.index < vm.store.elems.len: emitValue(vm.store.elems[stream.index].dropped.byte)
      else: advanceTo(pspDataFlags)
    of pspDataFlags:
      if stream.index < vm.store.datas.len: emitValue(vm.store.datas[stream.index].dropped.byte)
      else: advanceTo(pspFooter)
    of pspFooter:
      need(WasmPortableStreamFooterBytes)
      portableWrite(output, written, stream.memory.runs)
      stream.crc.updatePortableChecksum(dest.toOpenArray(0, written + 3), stream.produced)
      portableWrite(output, written + 4, not stream.crc)
      written += WasmPortableStreamFooterBytes
      stream.produced += written
      advanceTo(pspDone)
      return wpsOk
    of pspDone:
      break
  if written != 0:
    stream.crc.updatePortableChecksum(dest.toOpenArray(0, written - 1), stream.produced)
    stream.produced += written
  wpsPending
