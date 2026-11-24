## Nominal Component Model resource ownership for one component instance.
##
## Guest handles are positive i32 table indices. Canonical ABI callers opt
## into the spec's LIFO reuse. Existing opaque handle users can keep indices
## retired for the lifetime of the table.

const
  MaxComponentResourceTypes* = 16
  MaxComponentResourceHandles* = 256

type
  ComponentResourceStatus* = enum
    crOk
    crInvalidType
    crInvalidHandle
    crWrongScope
    crBorrowActive
    crTableFull
    crDestructorFailed
    crLocked

  ComponentResourceRep* = enum
    crrI32
    crrI64

  ComponentResourceDestructor* = proc(ctx: pointer, rep: uint64): bool {.nimcall.}

  ResourceType = object
    identity: uint64
    rep: ComponentResourceRep
    destructor: ComponentResourceDestructor
    context: pointer

  ResourceSlotKind = enum
    rsVacant
    rsOwned
    rsBorrowed

  ResourceSlot = object
    kind: ResourceSlotKind
    typeIndex: uint16
    rep: uint64
    lends: uint16
    rootOwner: uint32
    scope: uint32

  ComponentResourceTable* = object
    types: seq[ResourceType]
    slots: seq[ResourceSlot]
    capacity: uint32
    locked: bool
    closing: bool
    reuseFreed: bool
    freeHead: uint32
    liveOwned: uint32
    liveBorrowed: uint32

  ComponentResourceStats* = object
    liveOwned*: uint32
    liveBorrowed*: uint32
    allocatedHandles*: uint32
    capacity*: uint32
    locked*: bool

proc initResourceTable*(table: var ComponentResourceTable,
                        capacity: uint32,
                        reuseFreed = false): ComponentResourceStatus =
  if capacity == 0 or capacity > MaxComponentResourceHandles.uint32:
    return crTableFull
  table = ComponentResourceTable(capacity: capacity, reuseFreed: reuseFreed)
  table.slots.add(ResourceSlot()) # 0 is always invalid.
  crOk

proc registerResourceType*(table: var ComponentResourceTable,
                           identity: uint64,
                           rep: ComponentResourceRep,
                           destructor: ComponentResourceDestructor = nil,
                           context: pointer = nil,
                           typeIndex: var uint32): ComponentResourceStatus =
  if table.locked: return crLocked
  if identity == 0 or table.types.len >= MaxComponentResourceTypes:
    return crInvalidType
  for existing in table.types:
    if existing.identity == identity: return crInvalidType
  typeIndex = table.types.len.uint32
  table.types.add(ResourceType(identity: identity, rep: rep,
    destructor: destructor, context: context))
  crOk

proc validType(table: ComponentResourceTable, typeIndex: uint32): bool {.inline.} =
  typeIndex < table.types.len.uint32

proc bindResourceType*(table: var ComponentResourceTable, typeIndex, canonicalType: uint32,
                       destructor: ComponentResourceDestructor,
                       context: pointer): ComponentResourceStatus =
  ## Bind a linked type before its first use. Multiple type names can designate
  ## one nominal resource within a component.
  if table.locked or table.closing: return crLocked
  if not table.validType(typeIndex) or not table.validType(canonicalType):
    return crInvalidType
  for slot in table.slots:
    if slot.kind != rsVacant and slot.typeIndex.uint32 == typeIndex:
      return crInvalidType
  table.types[typeIndex.int].identity = table.types[canonicalType.int].identity
  table.types[typeIndex.int].destructor = destructor
  table.types[typeIndex.int].context = context
  crOk

proc liveSlot(table: ComponentResourceTable, handle: uint32): bool {.inline.} =
  handle > 0 and handle < table.slots.len.uint32 and
    table.slots[handle.int].kind != rsVacant

proc reserve(table: var ComponentResourceTable, handle: var uint32): bool =
  if table.closing: return false
  if table.freeHead != 0:
    handle = table.freeHead
    table.freeHead = table.slots[handle.int].rootOwner
    return true
  if table.capacity == 0 or table.slots.len.uint32 > table.capacity:
    return false
  handle = table.slots.len.uint32
  table.slots.add(ResourceSlot())
  true

proc release(table: var ComponentResourceTable, handle: uint32) =
  table.slots[handle.int] = ResourceSlot()
  if table.reuseFreed:
    # A vacant slot has no borrower to use this link.
    table.slots[handle.int].rootOwner = table.freeHead
    table.freeHead = handle

proc newOwned*(table: var ComponentResourceTable, typeIndex: uint32,
               rep: uint64, handle: var uint32): ComponentResourceStatus =
  if table.locked: return crLocked
  if not table.validType(typeIndex): return crInvalidType
  if table.types[typeIndex.int].rep == crrI32 and rep > uint32.high.uint64:
    return crInvalidType
  if not table.reserve(handle): return crTableFull
  table.slots[handle.int] = ResourceSlot(kind: rsOwned,
    typeIndex: typeIndex.uint16, rep: rep)
  inc table.liveOwned
  crOk

proc borrow*(table: var ComponentResourceTable, source, scope: uint32,
             handle: var uint32): ComponentResourceStatus =
  if table.locked: return crLocked
  if scope == 0: return crWrongScope
  if not table.liveSlot(source): return crInvalidHandle
  let original = table.slots[source.int]
  let root = if original.kind == rsOwned: source else: original.rootOwner
  if not table.liveSlot(root) or table.slots[root.int].kind != rsOwned:
    return crInvalidHandle
  if table.slots[root.int].lends == uint16.high:
    return crBorrowActive
  if not table.reserve(handle): return crTableFull
  inc table.slots[root.int].lends
  table.slots[handle.int] = ResourceSlot(kind: rsBorrowed,
    typeIndex: original.typeIndex, rep: original.rep,
    rootOwner: root, scope: scope)
  inc table.liveBorrowed
  crOk

proc representation*(table: ComponentResourceTable, handle,
                     typeIndex: uint32, rep: var uint64): ComponentResourceStatus =
  if table.locked: return crLocked
  if not table.liveSlot(handle): return crInvalidHandle
  if not table.validType(typeIndex) or
      table.types[table.slots[handle.int].typeIndex.int].identity !=
        table.types[typeIndex.int].identity:
    return crInvalidType
  rep = table.slots[handle.int].rep
  crOk

proc lendRepresentation*(table: var ComponentResourceTable, handle, typeIndex: uint32,
                         rep: var uint64): ComponentResourceStatus =
  let status = table.representation(handle, typeIndex, rep)
  if status != crOk: return status
  if table.slots[handle.int].lends == uint16.high: return crBorrowActive
  inc table.slots[handle.int].lends
  crOk

proc releaseLend*(table: var ComponentResourceTable, handle: uint32) =
  if table.liveSlot(handle) and table.slots[handle.int].lends != 0:
    dec table.slots[handle.int].lends

proc newScopedBorrow*(table: var ComponentResourceTable, typeIndex, scope: uint32,
                      rep: uint64, handle: var uint32): ComponentResourceStatus =
  ## Its lender is retained by the calling ABI frame in a different table.
  if table.locked: return crLocked
  if scope == 0: return crWrongScope
  if not table.validType(typeIndex): return crInvalidType
  if table.types[typeIndex.int].rep == crrI32 and rep > uint32.high.uint64:
    return crInvalidType
  if not table.reserve(handle): return crTableFull
  table.slots[handle.int] = ResourceSlot(kind: rsBorrowed,
    typeIndex: typeIndex.uint16, rep: rep, scope: scope)
  inc table.liveBorrowed
  crOk

proc hasScopedBorrows*(table: ComponentResourceTable, scope: uint32): bool =
  for slot in table.slots:
    if slot.kind == rsBorrowed and slot.scope == scope:
      return true

proc takeOwnedRepresentation*(table: var ComponentResourceTable, handle,
                              typeIndex: uint32,
                              rep: var uint64): ComponentResourceStatus =
  ## Lifting an own moves the representation out without calling its destructor.
  let status = table.representation(handle, typeIndex, rep)
  if status != crOk: return status
  let slot = table.slots[handle.int]
  if slot.kind != rsOwned: return crInvalidHandle
  if slot.lends != 0: return crBorrowActive
  table.release(handle)
  dec table.liveOwned
  crOk

proc destroyRepresentation*(table: var ComponentResourceTable, typeIndex: uint32,
                             rep: uint64): ComponentResourceStatus =
  if table.locked: return crLocked
  if not table.validType(typeIndex): return crInvalidType
  let typeInfo = table.types[typeIndex.int]
  if typeInfo.destructor != nil and not typeInfo.destructor(typeInfo.context, rep):
    table.locked = true
    return crDestructorFailed
  crOk

proc dropBorrow*(table: var ComponentResourceTable, handle,
                 scope: uint32): ComponentResourceStatus =
  if table.locked: return crLocked
  if not table.liveSlot(handle) or table.slots[handle.int].kind != rsBorrowed:
    return crInvalidHandle
  let slot = table.slots[handle.int]
  if slot.scope != scope: return crWrongScope
  if slot.lends != 0: return crBorrowActive
  if slot.rootOwner != 0:
    if not table.liveSlot(slot.rootOwner) or
        table.slots[slot.rootOwner.int].lends == 0:
      table.locked = true
      return crLocked
    dec table.slots[slot.rootOwner.int].lends
  table.release(handle)
  dec table.liveBorrowed
  crOk

proc endBorrowScope*(table: var ComponentResourceTable,
                     scope: uint32): ComponentResourceStatus =
  if table.locked: return crLocked
  if scope == 0: return crWrongScope
  for handle in 1 ..< table.slots.len:
    if table.slots[handle].kind == rsBorrowed and
        table.slots[handle].scope == scope:
      let status = table.dropBorrow(handle.uint32, scope)
      if status != crOk: return status
  crOk

proc dropOwned*(table: var ComponentResourceTable,
                handle: uint32): ComponentResourceStatus =
  if table.locked: return crLocked
  if not table.liveSlot(handle) or table.slots[handle.int].kind != rsOwned:
    return crInvalidHandle
  let slot = table.slots[handle.int]
  if slot.lends != 0: return crBorrowActive
  table.release(handle)
  dec table.liveOwned
  table.destroyRepresentation(slot.typeIndex.uint32, slot.rep)

proc dropHandle*(table: var ComponentResourceTable, handle,
                 typeIndex: uint32): ComponentResourceStatus =
  var representation: uint64
  let status = table.representation(handle, typeIndex, representation)
  if status != crOk: return status
  let slot = table.slots[handle.int]
  if slot.kind == rsBorrowed:
    table.dropBorrow(handle, slot.scope)
  else:
    table.dropOwned(handle)

proc transferOwned*(source: var ComponentResourceTable, handle: uint32,
                    target: var ComponentResourceTable, targetType: uint32,
                    newHandle: var uint32): ComponentResourceStatus =
  ## Move an unborrowed owner between instances. The two type registrations
  ## must have the same nominal identity; the source destructor is not called.
  if source.locked or target.locked: return crLocked
  if not source.liveSlot(handle) or source.slots[handle.int].kind != rsOwned:
    return crInvalidHandle
  if not target.validType(targetType): return crInvalidType
  let slot = source.slots[handle.int]
  if slot.lends != 0: return crBorrowActive
  let sourceType = source.types[slot.typeIndex.int]
  let targetInfo = target.types[targetType.int]
  if sourceType.identity != targetInfo.identity or
      sourceType.rep != targetInfo.rep:
    return crInvalidType
  if not target.reserve(newHandle): return crTableFull
  target.slots[newHandle.int] = ResourceSlot(kind: rsOwned,
    typeIndex: targetType.uint16, rep: slot.rep)
  inc target.liveOwned
  source.release(handle)
  dec source.liveOwned
  crOk

proc drainResourceTable*(table: var ComponentResourceTable): ComponentResourceStatus =
  ## Run the destructors of an inactive instance. Keeping the empty table
  ## usable until the graph shuts down lets other instances invoke a
  ## destructor's defining guest after its own handles have been released.
  if table.locked or table.closing: return crLocked
  if table.liveBorrowed != 0: return crBorrowActive
  table.closing = true
  defer: table.closing = false
  for handle in 1 ..< table.slots.len:
    if table.slots[handle].kind == rsOwned:
      let status = table.dropOwned(handle.uint32)
      if status != crOk: return status
  crOk

proc closeResourceTable*(table: var ComponentResourceTable): ComponentResourceStatus =
  result = table.drainResourceTable()
  if result == crOk:
    table.locked = true

proc resourceStats*(table: ComponentResourceTable): ComponentResourceStats =
  ComponentResourceStats(liveOwned: table.liveOwned,
    liveBorrowed: table.liveBorrowed,
    allocatedHandles: max(0, table.slots.len - 1).uint32,
    capacity: table.capacity, locked: table.locked)

proc hasResourceCapacity*(table: ComponentResourceTable, needed: uint32): bool =
  if table.locked or table.closing: return false
  let used = if table.reuseFreed: table.liveOwned + table.liveBorrowed
    else: max(0, table.slots.len - 1).uint32
  used <= table.capacity and needed <= table.capacity - used
