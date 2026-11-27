import cps/wasm/component_resources

proc countDrop(ctx: pointer, rep: uint64): bool {.nimcall.} =
  let count = cast[ptr uint32](ctx)
  inc count[]
  rep == 42

proc failDrop(ctx: pointer, rep: uint64): bool {.nimcall.} =
  discard ctx
  discard rep
  false

proc main() =
  var source, target: ComponentResourceTable
  doAssert source.initResourceTable(4) == crOk
  doAssert target.initResourceTable(2) == crOk
  var drops = 0'u32
  var sourceType, targetType: uint32
  doAssert source.registerResourceType(0x1234, crrI32,
    countDrop, addr drops, sourceType) == crOk
  doAssert target.registerResourceType(0x1234, crrI32,
    countDrop, addr drops, targetType) == crOk
  var owner, borrowed, nested: uint32
  doAssert source.newOwned(sourceType, 42, owner) == crOk
  doAssert owner == 1
  doAssert source.borrow(owner, 7, borrowed) == crOk
  doAssert source.borrow(borrowed, 8, nested) == crOk
  doAssert source.dropOwned(owner) == crBorrowActive
  var rep: uint64
  doAssert source.representation(nested, sourceType, rep) == crOk
  doAssert rep == 42
  doAssert source.dropBorrow(borrowed, 8) == crWrongScope
  doAssert source.endBorrowScope(8) == crOk
  doAssert source.representation(nested, sourceType, rep) == crInvalidHandle
  doAssert source.dropBorrow(borrowed, 7) == crOk
  var moved: uint32
  doAssert source.transferOwned(owner, target, targetType, moved) == crOk
  doAssert source.dropOwned(owner) == crInvalidHandle
  doAssert target.representation(moved, targetType, rep) == crOk
  doAssert rep == 42 and drops == 0
  doAssert target.dropOwned(moved) == crOk
  doAssert drops == 1
  doAssert target.dropOwned(moved) == crInvalidHandle
  doAssert target.resourceStats().liveOwned == 0
  doAssert target.resourceStats().allocatedHandles == 1
  doAssert target.closeResourceTable() == crOk
  doAssert target.newOwned(targetType, 42, moved) == crLocked
  var scoped: ComponentResourceTable
  doAssert scoped.initResourceTable(3) == crOk
  var scopedType, scopedOwner, scopedBorrow: uint32
  doAssert scoped.registerResourceType(0x7777, crrI32,
    countDrop, addr drops, scopedType) == crOk
  doAssert scoped.newOwned(scopedType, 42, scopedOwner) == crOk
  doAssert scoped.borrow(scopedOwner, 9, scopedBorrow) == crOk
  doAssert scoped.closeResourceTable() == crBorrowActive
  doAssert scoped.endBorrowScope(9) == crOk
  doAssert scoped.closeResourceTable() == crOk
  doAssert drops == 2
  var foreign: ComponentResourceTable
  doAssert foreign.initResourceTable(2, reuseFreed = true) == crOk
  var foreignType, aliasType, scopedHandle: uint32
  doAssert foreign.registerResourceType(1, crrI32, countDrop, addr drops, foreignType) == crOk
  doAssert foreign.registerResourceType(2, crrI32, nil, nil, aliasType) == crOk
  doAssert foreign.bindResourceType(aliasType, foreignType, countDrop, addr drops) == crOk
  doAssert foreign.newScopedBorrow(aliasType, 3, 42, scopedHandle) == crOk
  doAssert foreign.hasScopedBorrows(3)
  doAssert foreign.lendRepresentation(scopedHandle, foreignType, rep) == crOk
  doAssert rep == 42
  doAssert foreign.takeOwnedRepresentation(scopedHandle, foreignType, rep) == crInvalidHandle
  doAssert foreign.dropHandle(scopedHandle, foreignType) == crBorrowActive
  foreign.releaseLend(scopedHandle)
  doAssert foreign.dropHandle(scopedHandle, foreignType) == crOk
  doAssert not foreign.hasScopedBorrows(3) and drops == 2
  doAssert foreign.closeResourceTable() == crOk
  var failure: ComponentResourceTable
  doAssert failure.initResourceTable(1) == crOk
  var failureType, failed: uint32
  doAssert failure.registerResourceType(0x5555, crrI64,
    failDrop, nil, failureType) == crOk
  doAssert failure.newOwned(failureType, 99, failed) == crOk
  doAssert failure.dropOwned(failed) == crDestructorFailed
  doAssert failure.newOwned(failureType, 100, failed) == crLocked
  when defined(wasmComponentAsyncCallbacks):
    var mixed: ComponentResourceTable
    doAssert mixed.initResourceTable(2, reuseFreed = true) == crOk
    var kind, control, owned, borrowCandidate: uint32
    doAssert mixed.registerResourceType(1, crrI32, nil, nil, kind) == crOk
    doAssert mixed.newAsyncHandle(control) and control == 1
    doAssert mixed.newOwned(kind, 42, owned) == crOk and owned == 2
    doAssert not mixed.hasResourceCapacity(1)
    var controlRep: uint64
    doAssert mixed.representation(control, kind, controlRep) == crInvalidHandle
    doAssert mixed.borrow(control, 1, borrowCandidate) == crInvalidHandle
    doAssert not mixed.dropAsyncHandle(owned)
    doAssert mixed.dropAsyncHandle(control) and mixed.hasResourceCapacity(1)
    doAssert mixed.newOwned(kind, 9, owned) == crOk and owned == control
    doAssert mixed.closeResourceTable() == crOk
  echo "component resources:ok"

main()
