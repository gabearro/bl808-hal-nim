## The portable execution snapshot stores guest state following the stacks.
## Counts and types of stores come from the verified module. Linear memory
## records are ordered nonzero byte runs in a zero-filled logical address
## space, independent of the destination's frame size and physical layout.

const PortableFlatScanBytes = 64'u64 * 1024 * 1024

proc portableStoreHasState(vm: WasmVM): bool =
  vm.store.mems.len != 0 or vm.store.tables.len != 0 or
    vm.store.globals.len != 0 or vm.store.elems.len != 0 or vm.store.datas.len != 0

proc appendPortable(snapshot: var WasmPortableSnapshot, count, maxBytes: int): int =
  let at = snapshot.portableLen()
  if count > maxBytes - at: return -1
  if snapshot.staged.hasPortableStaging():
    snapshot.staged.len = at + count
  else:
    snapshot.bytes.setLen(at + count)
  at

proc appendMemoryRuns(data: var WasmPortableSnapshot, src: ptr UncheckedArray[byte],
    base: uint64, size, maxBytes: int, runCount: var uint32, runLimit: uint32): bool =
  var i = 0
  while i < size:
    if src[i] == 0:
      inc i
      continue
    let start = i
    let available = maxBytes - data.portableLen() - 6
    if available <= 0 or runCount == runLimit: return false
    let stop = start + min(size - start, min(available, high(uint16).int))
    while i < stop and src[i] != 0:
      inc i
    let count = i - start
    let at = data.appendPortable(6 + count, maxBytes)
    let view = data.portableView()
    portableWrite(view, at, (base + start.uint64).uint32)
    portableWrite(view, at + 4, count.uint16)
    requirePortableIo(view.writePortableRange(at + 6, addr src[start], count))
    inc runCount
  true

proc portableMemoryLimit(mem: var MemInst): uint32 =
  result = if mem.memType.limits.hasMax: mem.memType.limits.max else: MaxPages.uint32
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      result = min(result, mem.chunked[].snapshotPageLimit())

proc portableReferenceValid(raw: uint64, vt: ValType, funcs: int): bool =
  raw == high(uint32).uint64 or (vt == vtFuncRef and raw < funcs.uint64)

proc portableTableReferenceValid(vm: WasmVM, table: TableType, raw: uint64): bool =
  if not portableReferenceValid(raw, table.elemType, vm.store.funcs.len): return false
  when defined(wasmFunctionReferences):
    vm.typedValueMatches(table.elemType, table.elementReference, rawToWasmValue(raw, table.elemType))
  else: true

proc portableGlobalReferenceValid(vm: WasmVM, global: GlobalType, raw: uint64): bool =
  if not portableReferenceValid(raw, global.valType, vm.store.funcs.len): return false
  when defined(wasmFunctionReferences):
    vm.typedValueMatches(global.valType, global.reference, rawToWasmValue(raw, global.valType))
  else: true

type PortableMemoryCapture = object
  when defined(wasmChunkedMemory):
    memory: ref LinearMemory
    order: seq[tuple[number: uint32, index: int]]
    index, header: int
    runs: uint32
    reader: LinearSnapshotRead

proc capturePortableStore(vm: WasmVM, data: var WasmPortableSnapshot,
    maxBytes: int, cursor: var PortableMemoryCapture,
    allowAsync: static bool): WasmPortableStatus =
  let wide = maxBytes > WasmPortableLegacyStoreMaxBytes
  let memoryHeaderBytes = if wide: 12 else: 10
  let runLimit = if wide: high(uint32) else: high(uint16).uint32
  for i in 0 ..< vm.store.mems.len:
    # The backing supplies borrowed bytes for capture. This leaves the source
    # memory, frame assignments, and fault state untouched.
    let memory = unsafeAddr vm.store.mems[i]
    template mem: untyped = memory[]
    when defined(wasmChunkedMemory):
      if mem.chunked != nil:
        if cursor.memory == nil:
          if mem.chunked[].pendingFault().pending: return wpsUnsupportedState
          cursor.header = data.appendPortable(memoryHeaderBytes, maxBytes)
          if cursor.header < 0: return wpsTooLarge
          portableWrite(data.portableView(), cursor.header, mem.pageCount().uint32)
          portableWrite(data.portableView(), cursor.header + 4, mem.portableMemoryLimit())
          cursor.memory = mem.chunked
          cursor.order = mem.chunked[].snapshotChunkOrder()
        while cursor.index < cursor.order.len:
          let entry = cursor.order[cursor.index]
          var src: ptr UncheckedArray[byte]
          let status = mem.chunked[].snapshotChunkBytes(entry.index, cursor.reader, src, allowAsync)
          if status == lmWouldBlock: return wpsPending
          if status != lmOk: return wpsUnsupportedState
          if not data.appendMemoryRuns(src, entry.number.uint64 * WasmMemoryChunkBytes,
              WasmMemoryChunkBytes.int, maxBytes, cursor.runs, runLimit): return wpsTooLarge
          inc cursor.index
        if wide:
          portableWrite(data.portableView(), cursor.header + 8, cursor.runs)
        else:
          portableWrite(data.portableView(), cursor.header + 8, cursor.runs.uint16)
        continue
    let header = data.appendPortable(memoryHeaderBytes, maxBytes)
    if header < 0: return wpsTooLarge
    portableWrite(data.portableView(), header, mem.pageCount().uint32)
    portableWrite(data.portableView(), header + 4, mem.portableMemoryLimit())
    var runs = 0'u32
    let size = mem.memByteLen()
    if size > PortableFlatScanBytes: return wpsTooLarge
    if not data.appendMemoryRuns(cast[ptr UncheckedArray[byte]](mem.memBasePtr()),
        0, size.int, maxBytes, runs, runLimit): return wpsTooLarge
    if wide:
      portableWrite(data.portableView(), header + 8, runs)
    else:
      portableWrite(data.portableView(), header + 8, runs.uint16)
  for table in vm.store.tables:
    let elemType = table.tableType.elemType
    if table.elems.len > (maxBytes - data.portableLen() - 4) div 4:
      return wpsTooLarge
    let at = data.appendPortable(4 + 4 * table.elems.len, maxBytes)
    if at < 0: return wpsTooLarge
    let view = data.portableView()
    portableWrite(view, at, table.elems.len.uint32)
    for i, entry in table.elems:
      let raw = wasmValueToRaw(entry)
      if entry.kind != elemType.toValueKind() or
          not vm.portableTableReferenceValid(table.tableType, raw):
        return wpsUnsupportedState
      portableWrite(view, at + 4 + 4 * i, raw.uint32)
  for global in vm.store.globals:
    if global.globalType.mut == mutConst: continue
    let vt = global.globalType.valType
    let at = data.appendPortable(if vt == vtV128: 16 else: 8, maxBytes)
    if at < 0: return wpsTooLarge
    if global.value.kind != vt.toValueKind(): return wpsUnsupportedState
    if vt == vtV128:
      requirePortableIo(data.portableView().writePortableRange(at, unsafeAddr global.value.v128[0], 16))
    else:
      let raw = wasmValueToRaw(global.value)
      if vt.isRefType and not vm.portableGlobalReferenceValid(global.globalType, raw):
        return wpsUnsupportedState
      portableWrite(data.portableView(), at, raw)
  let at = data.appendPortable(vm.store.elems.len + vm.store.datas.len, maxBytes)
  if at < 0: return wpsTooLarge
  let view = data.portableView()
  for i, elem in vm.store.elems: portableWrite(view, at + i, elem.dropped.byte)
  for i, segment in vm.store.datas:
    portableWrite(view, at + vm.store.elems.len + i, segment.dropped.byte)
  wpsOk

type PortableRestoreLayout = object
  memoryOffset, runs, tailOffset, bodyBytes: int
  pages, pageLimit: uint32
  when defined(wasmChunkedMemory): cold: bool

proc validatePortableMemory(mem: var MemInst, data: WasmPortableStaging, at: var int,
                            layout: var PortableRestoreLayout, allowPaging, wide: bool,
                            streamedRuns: int64): bool =
  let memoryHeaderBytes = if wide: 12 else: 10
  if data.len - at < memoryHeaderBytes: return false
  let pages = portableRead32(data, at)
  let sourceLimit = portableRead32(data, at + 4)
  var runCount = if wide: portableRead32(data, at + 8)
                 else: portableRead16(data, at + 8).uint32
  if streamedRuns >= 0:
    if runCount != 0: return false
    runCount = streamedRuns.uint32
  at += memoryHeaderBytes
  if runCount > ((data.len - at) div 7).uint32: return false
  let runs = runCount.int
  let currentPages = mem.pageCount().uint32
  if pages < currentPages or pages > sourceLimit or sourceLimit > mem.portableMemoryLimit():
    return false
  let size = pages.uint64 * WasmPageSize.uint64
  layout.memoryOffset = at
  layout.runs = runs
  layout.pages = pages
  layout.pageLimit = sourceLimit
  when defined(wasmChunkedMemory):
    var chunks = 0'u32
    var lastChunk = -1'i64
  var previousEnd = 0'u64
  for _ in 0 ..< runs:
    if data.len - at < 6: return false
    let offset = portableRead32(data, at).uint64
    let count = portableRead16(data, at + 4).int
    at += 6
    if count == 0 or count > data.len - at or offset < previousEnd or
        offset > size or count.uint64 > size - offset:
      return false
    previousEnd = offset + count.uint64
    when defined(wasmChunkedMemory):
      if mem.chunked != nil:
        let first = (offset div WasmMemoryChunkBytes).int64
        let last = ((previousEnd - 1) div WasmMemoryChunkBytes).int64
        chunks += (last - max(first, lastChunk + 1) + 1).uint32
        lastChunk = last
    at += count
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      layout.cold = mem.chunked[].snapshotRequiresBacking(chunks)
      return mem.chunked[].canRestoreLinearSnapshot(pages, chunks, allowPaging)
  size <= PortableFlatScanBytes and size <= high(int).uint64

proc resetPortableMemory(mem: var MemInst, layout: PortableRestoreLayout): bool =
  when defined(wasmChunkedMemory):
    if mem.chunked != nil:
      mem.chunked[].resetLinearForSnapshot(layout.pages)
    else:
      if mem.growMemory(int32(layout.pages - mem.pageCount().uint32)) < 0: return false
      let size = layout.pages.int * WasmPageSize
      if size != 0: zeroMem(mem.memBasePtr(), size)
  else:
    if mem.growMemory(int32(layout.pages - mem.pageCount().uint32)) < 0: return false
    let size = layout.pages.int * WasmPageSize
    if size != 0: zeroMem(mem.memBasePtr(), size)
  mem.memType.limits.hasMax = true
  mem.memType.limits.max = layout.pageLimit
  true

proc restorePortableStoreTail(vm: var WasmVM, data: WasmPortableStaging, at: int,
                              apply: static bool): bool =
  var pos = at
  for table in vm.store.tables.mitems:
    if data.len - pos < 4: return false
    let count = portableRead32(data, pos)
    pos += 4
    let limits = table.tableType.limits
    if count < table.elems.len.uint32 or count > ((data.len - pos) div 4).uint32 or
        (limits.hasMax and count > limits.max): return false
    when apply: table.elems.setLen(count.int)
    for i in 0 ..< count.int:
      let raw = portableRead32(data, pos).uint64
      if not vm.portableTableReferenceValid(table.tableType, raw): return false
      when apply: table.elems[i] = rawToWasmValue(raw, table.tableType.elemType)
      pos += 4
  for global in vm.store.globals.mitems:
    if global.globalType.mut == mutConst: continue
    let vt = global.globalType.valType
    let size = if vt == vtV128: 16 else: 8
    if size > data.len - pos: return false
    if vt == vtV128:
      when apply:
        requirePortableIo(data.readPortableRange(pos, addr global.value.v128[0], 16))
    else:
      let raw = portableRead64(data, pos)
      if (vt in {vtI32, vtF32} and raw > high(uint32).uint64) or
          (vt.isRefType and not vm.portableGlobalReferenceValid(global.globalType, raw)):
        return false
      when apply: global.value = rawToWasmValue(raw, vt)
    pos += size
  if data.len - pos != vm.store.elems.len + vm.store.datas.len: return false
  for elem in vm.store.elems.mitems:
    let dropped = portableRead[uint8](data, pos)
    if dropped > 1 or (elem.dropped and dropped == 0): return false
    when apply: elem.dropped = dropped != 0
    inc pos
  for segment in vm.store.datas.mitems:
    let dropped = portableRead[uint8](data, pos)
    if dropped > 1 or (segment.dropped and dropped == 0): return false
    when apply: segment.dropped = dropped != 0
    inc pos
  true

proc validatePortableStore(vm: var WasmVM, data: WasmPortableStaging, at: int,
                           layout: var PortableRestoreLayout, allowPaging, wide: bool,
                           streamedRuns: int64): bool =
  var pos = at
  for mem in vm.store.mems.mitems:
    if not mem.validatePortableMemory(data, pos, layout, allowPaging, wide, streamedRuns): return false
  layout.tailOffset = pos
  vm.restorePortableStoreTail(data, pos, false)

proc portableBody(data: WasmPortableStaging, layout: PortableRestoreLayout):
    WasmPortableStaging {.inline.} =
  result = data
  result.len = layout.bodyBytes

when defined(wasmStorageMigration):
  proc applyPortableBackingRun(mem: var MemInst, data: WasmPortableStaging,
                               pos: int, offset: uint64, count: uint32) =
    var buf: array[PortableTransferBytes, byte]
    var progress = 0'u32
    while progress < count:
      let size = min(buf.len.uint32, count - progress)
      requirePortableIo(data.readPortableRange(pos + progress.int, addr buf[0], size.int))
      mem.writeBulk(offset + progress.uint64, cast[ptr UncheckedArray[byte]](addr buf[0]), size)
      progress += size

proc applyPortableStore(vm: var WasmVM, data: WasmPortableStaging,
                        layout: PortableRestoreLayout): bool =
  for mem in vm.store.mems.mitems:
    if not mem.resetPortableMemory(layout): return false
    var pos = layout.memoryOffset
    for _ in 0 ..< layout.runs:
      let offset = portableRead32(data, pos)
      let count = portableRead16(data, pos + 4)
      pos += 6
      if data.usesPortableBacking():
        when defined(wasmStorageMigration):
          mem.applyPortableBackingRun(data, pos, offset.uint64, count.uint32)
      else:
        let src = cast[ptr UncheckedArray[byte]](addr data.data[pos])
        mem.writeBulk(offset.uint64, src, count.uint32)
      pos += count.int
  vm.restorePortableStoreTail(data.portableBody(layout), layout.tailOffset, true)
