## Bounded Component Model 0.2 canonical lift/lower path.
##
## This decoder accepts a bounded execution profile, including opt-in
## callback tasks. Unsupported definitions are rejected before core module
## instantiation. In particular, accepting a component header alone must never
## be mistaken for component validation.

import types, binary, validate, runtime, utf8_names, component_resources

when defined(wasmComponentStackful) and not defined(wasmComponentAsyncCallbacks):
  {.error: "wasmComponentStackful requires wasmComponentAsyncCallbacks".}
const ComponentEndpointsEnabled = defined(wasmComponentFutures) or defined(wasmComponentStreams)
when ComponentEndpointsEnabled and not defined(wasmComponentAsyncCallbacks):
  {.error: "wasmComponentFutures and wasmComponentStreams require wasmComponentAsyncCallbacks".}
when defined(wasmComponentHostEndpoints) and not ComponentEndpointsEnabled:
  {.error: "wasmComponentHostEndpoints requires wasmComponentFutures or wasmComponentStreams".}
when defined(wasmComponentThreads) and not defined(wasmComponentStackful):
  {.error: "wasmComponentThreads requires wasmComponentStackful".}
when defined(wasmComponentThreadSpawn) and not
    (defined(wasmComponentThreads) and defined(wasmFunctionReferences)):
  {.error: "wasmComponentThreadSpawn requires wasmComponentThreads and wasmFunctionReferences".}
when defined(wasmComponentStackful) and defined(wasmChunkedMemory):
  import linear_memory

const
  ComponentVersion* = "0.2.0"
  ComponentSpecRevision* = "585526aa1f2c7f76f07557d16e265dede38b3acb"
  MaxComponentBytes* = when defined(bl808lp): 768
    elif defined(bl808m0): 4 * 1024
    elif defined(bl808d0): 64 * 1024
    else: 1024 * 1024
  MaxComponentTypes = when defined(bl808lp): 8 else: 128
  MaxComponentGuestThreads = when defined(bl808lp): 3 else: 32
  MaxComponentFunctions = when defined(bl808lp): 8 else: 128
  MaxComponentCoreModules = when defined(bl808lp): 4 else: 32
  MaxFlatParams = 16
  MaxFlatAsyncParams = 4
  MaxComponentAsyncTasks = when defined(bl808lp): 4 else: 32
  MaxComponentParams = 32
  MaxComponentStringBytes = 4096
  MaxComponentByteListBytes = 4096
  MaxGenericListValues = when defined(bl808lp): 32 else: 512
  MaxValueTypeNesting = when defined(bl808lp): 4 else: 8
  MaxComponentRecordFields = 32
  MaxComponentVariantCases = 16
  MaxComponentFlags = 32
  MaxIndirectParamBytes = 4096
  MaxCanonicalValueBytes = 1 shl 28
  MaxComponentNesting = when defined(bl808lp): 1
    elif defined(bl808m0) or defined(bl808d0): 2
    else: 8
  MaxComponentContractNesting = when defined(bl808lp): 2 else: 8
  MaxComponentContractComparisons = when defined(bl808lp): 32 else: 1024
  MaxInstanceNesting = when defined(bl808lp): 2 else: 8
  NestedInterfaceIndex = 0x8000'u16
  MaxComponentInstances = when defined(bl808lp): 8
    elif defined(bl808m0): 32
    else: 128
  MaxComponentCallDepth = when defined(bl808lp): 2
    elif defined(bl808m0) or defined(bl808d0): 4
    else: 32
  # Canonical core sources normally name a one-based module instance. The high
  # bit instead selects a zero-based index in the generated core function table.
  GeneratedCoreSource = 0x100'u16

static:
  doAssert MaxComponentFunctions <= GeneratedCoreSource.int
  doAssert MaxComponentFunctions <= uint8.high.int

type
  ComponentError* = object of CatchableError

  ComponentNameAttributes* = object
    ## Optional host metadata. The declared name is the linker key.
    implements*, versionSuffix*, externalId*: string
    hasExternalId*: bool

  ExternalName = tuple[name: string, sort: byte, attributes: ComponentNameAttributes]

  ComponentPrim* = enum
    cpBool = 0x7f
    cpS8 = 0x7e
    cpU8 = 0x7d
    cpS16 = 0x7c
    cpU16 = 0x7b
    cpS32 = 0x7a
    cpU32 = 0x79
    cpS64 = 0x78
    cpU64 = 0x77
    cpF32 = 0x76
    cpF64 = 0x75
    cpChar = 0x74
    cpString = 0x73
    cpRecord = 0x72
    cpVariant = 0x71
    cpBytes = 0x70
    cpTuple = 0x6f
    cpFlags = 0x6e
    cpEnum = 0x6d
    cpOption = 0x6b
    cpResult = 0x6a
    cpU32List = 0x68
    cpU64List = 0x67
    cpOwnedResource = 0x66
    cpBorrowedResource = 0x65
    cpList = 0x64
    cpMap = 0x63
    cpFixedList = 0x62
    cpFuture = 0x61
    cpStream = 0x60
    cpErrorContext = 0x5f
    cpInterfaceType = 0x42  # an instance type, never a ComponentValue
    cpFunctionType = 0x41
    cpComponentType = 0x40
    cpResourceType = 0x3f  # a nominal type, never a ComponentValue

  ComponentRecordField* = object
    name*: string
    kind*: ComponentPrim
    shape: ref CanonicalSlot
    offset: uint32

  ComponentVariantCase* = object
    name*: string
    hasPayload*: bool
    payloadKind*: ComponentPrim
    shape: ref CanonicalSlot

  ComponentValue* = object
    kind*: ComponentPrim
    ## Integer bits are in the low end, sign extended for signed types.
    ## Floating point bits retain their IEEE representation.
    bits*: uint64
    text*: string
    bytes*: seq[byte]
    fields*: seq[ComponentValue]
    caseIndex*: uint32
    ownsResource: bool
    resource: ComponentOwnedValue
    when ComponentEndpointsEnabled:
      endpoint: ComponentEndpointValue
    when defined(wasmComponentErrorContext):
      errorContext: ComponentErrorContextValue

  ComponentFuncType* = object
    params*: seq[ComponentPrim]
    paramNames: seq[string]
    paramTypeIndices*: seq[int32]
    hasResult*: bool
    when defined(wasmComponentAsyncCallbacks):
      isAsync*: bool
    resultType*: ComponentPrim
    resultTypeIndex*: int32
    paramArea: CanonicalParams
    resultShape: ref CanonicalSlot

  AbiLayout = tuple[size, alignment: int]

  ResourceUse = enum ruOwn, ruBorrow, ruEndpoint, ruErrorContext
  ResourceUses = set[ResourceUse]

  RecordShape = ref object
    fields: seq[ComponentRecordField]
    layout: AbiLayout
    flatWidth: uint16
    typeNodes: uint16
    depth: uint8
    hasPointers: bool
    resources: ResourceUses

  CanonicalSlot {.byref.} = object
    offset: uint16
    resourceType: uint16
    kind: ComponentPrim
    resources: ResourceUses
    recordShape: RecordShape
    cases: seq[ComponentVariantCase]
    listElement: ref CanonicalSlot
    listLength: uint32

  CanonicalParams = ref object
    layout: AbiLayout
    slots: seq[CanonicalSlot]

  TypeVisibility = enum tvPrivate, tvImported, tvExported

  RebasedShapes = ref seq[tuple[local, origin: ref CanonicalSlot]]

  ShapeScope = object
    parent: ptr ShapeScope
    resourceAliases: ptr seq[ResourceTypeAlias]
    handleTypes: ptr seq[ResourceTypeAlias]
    interfaceType: ptr InterfaceType
    rebasedShapes: RebasedShapes
    publishedResources: seq[ResourceName]
    importedResources: seq[ResourceName]
    outerValueNames: ref seq[tuple[index, depth: uint16]]
    coreModuleValues: ptr seq[CoreModuleValue]
    corePlan: ptr ComponentPlan
    componentTypes: ptr seq[ComponentTypeDefinition]
    contractDepth: uint8
    functionTypes: ptr seq[ComponentFuncType]
    interfaceTypes: ptr seq[InterfaceType]
    functionOrigins: ref seq[FunctionTypeOrigin]
    componentDefinitions: ptr ComponentDefinitionScope
    coreTypes: seq[CoreTypeDeclaration]
    componentBoundary: bool
    kinds: seq[ComponentPrim]
    shapes: seq[ref CanonicalSlot]
    visible: array[MaxComponentTypes, TypeVisibility]

  FunctionTypeOrigin = object
    aliasIndex, typeIndex: uint16
    scope: ptr ShapeScope
    names: FunctionTypeNames

  FunctionTypeNames = ref seq[tuple[shape: ref CanonicalSlot, diagnostic: string]]

  # Separate member tables need their declaration order for type visibility.
  ResourceName = ref object
    ## Identity of a resource type name, independent of its runtime ordinal.

  ResourceNameBindings = ref seq[tuple[source, target: ResourceName]]
  ResourceNames = ref seq[ResourceName]
  ResourceNameProjection = ref seq[tuple[source: ResourceName, ordinal: uint16, target: ResourceName]]

  VisibilityMember = enum vmType, vmResource, vmFunction, vmFunctionType, vmInstance
  VisibilityOrder = ref seq[tuple[member: VisibilityMember, index: uint8]]

  OuterTypeReference = tuple[target: ptr ShapeScope, index, depth: uint32,
                             crossedComponent, crossedNamingScope: bool]

  CoreLiftSource = enum
    clsFunction, clsMemory, clsRealloc, clsPostReturn

  CanonicalStringEncoding = enum
    cseUtf8, cseUtf16, cseLatin1Utf16

  ComponentTarget = enum
    ctCore, ctImport, ctChild

  ComponentExport* = object
    name*: string
    coreName*: string
    signature*: ComponentFuncType
    memoryName: string
    reallocName: string
    postReturnName: string
    when defined(wasmComponentAsyncCallbacks):
      callbackSource: uint16
      callbackName: string
    when defined(wasmComponentStackful):
      stackful: bool
    coreSources: array[CoreLiftSource, uint16]
    stringEncoding: CanonicalStringEncoding
    target: ComponentTarget
    targetIndex: uint16
    visibilityNames: FunctionTypeNames
    resourceNames: ResourceNames

  ComponentHostFunc* = proc(args: openArray[ComponentValue]):
    seq[ComponentValue] {.closure.}

  ComponentCallTarget = ref object
    owner: pointer  # raw reference into the component graph that owns the binding
    entry: ptr ComponentExport  # child exports stay in the owning graph
    ownedEntry: ref ComponentExport  # keep a descriptor from the decode plan alive

  ComponentHostBinding* = object
    name*: string
    signature*: ComponentFuncType
    callback*: ComponentHostFunc
    target: ComponentCallTarget

  ComponentHostInterface* = object
    name*: string
    functions*: seq[ComponentHostBinding]
    interfaces*: seq[ComponentHostInterface]
    coreModules*: seq[ComponentHostCoreModule]
    components*: seq[ComponentHostDefinition]

  ComponentImport = object
    name: string
    signature: ComponentFuncType
    interfaceIndex: uint16  # zero for a function at component scope
    visibilityNames: FunctionTypeNames

  ComponentPlan* = object
    validated: bool
    instanceCount: uint8
    coreBytes: seq[byte]
    extraCoreBytes: seq[seq[byte]]
    exports*: seq[ComponentExport]
    imports: seq[ComponentImport]
    instances: seq[CoreInstantiation]
    lowerings: seq[CoreLowering]
    resources: seq[LocalResourcePlan]
    handleTypes: seq[ResourceTypeAlias]
    links: ComponentLinks

  ComponentHostDefinition* = object
    name*: string
    plan*: ComponentPlan

  ComponentHostCoreModule* = object
    name*: string
    bytes*: seq[byte]

  CanonicalExecutionState = ref object
    mayLeave: bool
    when defined(wasmComponentContext) or defined(wasmComponentAsyncCallbacks):
      context: ptr int32
    when defined(wasmComponentAsyncCallbacks):
      callbackTask: ptr CanonicalCallbackTask
      borrowScope: uint32
    when defined(wasmComponentThreads):
      thread: ComponentGuestThread
      contextSecond: ptr int32

  CanonicalCallbackResolution = enum
    ccrRunning, ccrCancelPending, ccrCancelDelivered, ccrReturned, ccrCancelled

  CanonicalCallbackTask = object
    when defined(wasmComponentAsyncCallbacks):
      signature: ptr ComponentFuncType
      memoryAddress: int
      encoding: CanonicalStringEncoding
      resolution: CanonicalCallbackResolution
      subtask: pointer   # Backpointer to the subtask owning this invocation.
      values: seq[ComponentValue]

  ComponentCallbackState* = enum
    ccsReady, ccsYielded, ccsComplete, ccsUnresolved, ccsTrapped, ccsWaiting,
    ccsCoreWaiting, ccsThreadsWaiting

  ComponentCallback* = ref object
    graph: ComponentInstance
    invocation: ComponentInvocation

  ComponentInvocation = ref object
    owner: pointer # The graph owns internal invocations and threads.
    entry: ComponentExport
    args: seq[ComponentValue]
    context: int32
    task: CanonicalCallbackTask
    state: ComponentCallbackState
    resultTaken: bool
    waiting: ComponentWaitRegistration
    when defined(wasmComponentAsyncCallbacks):
      borrows: TaskBorrowScope
    when defined(wasmComponentStackful):
      core: ComponentCoreTurn
    when defined(wasmComponentThreads):
      implicitId: uint32
      explicitThreads: uint8

  ComponentGuestState = enum
    cgtSuspended, cgtReady, cgtRunning, cgtWaiting, cgtFinished

  ComponentGuestThread = ref object
    owner: pointer
    invocation: ComponentInvocation
    id: uint32
    state: ComponentGuestState
    implicit: bool
    core: ComponentCoreTurn
    directResults: ptr seq[WasmValue]
    closure: WasmValue
    context, contextSecond: int32

  ComponentCoreReservation = object
    exclusive: ref bool

  ComponentCoreTurn = ref object
    arena: WasmExecutionArena
    continuation: WasmContinuation
    address: int
    reservation: ComponentCoreReservation

  ComponentWaitSet = ref object
    members, waiters: int

  ComponentWaitRegistration = object
    id: uint32
    waitSet: ComponentWaitSet

  ComponentAsyncSlot = object
    waitSet: ComponentWaitSet
    subtask: ComponentSubtask
    when ComponentEndpointsEnabled:
      endpoint: ComponentEndpoint

  EndpointCopyState = enum
    fcIdle, fcCopying, fcCancelling, fcDone

  EndpointGuestBuffer = object
    memoryAddress, reallocAddress: int
    encoding: CanonicalStringEncoding
    offset, count, progress: uint32
    active: bool
    when defined(wasmComponentHostEndpoints):
      host: ComponentHostBuffer

  ComponentHostBuffer = ref object
    values: seq[ComponentValue]

  ComponentEndpointState = object
    other: ptr ComponentEndpointState   # Non-owning. Dropping either end detaches the pair.
    shape: ref CanonicalSlot
    owner: pointer
    handle, joined: uint32
    writable: bool
    state: EndpointCopyState
    eventPending: bool
    eventProgress: uint32
    buffer: EndpointGuestBuffer
    when defined(wasmComponentStackful):
      syncWaiter: ref bool

  ComponentEndpoint = ref ComponentEndpointState

  # Retain the nominal identity without retaining its component graph.
  EndpointResourceIdentity = tuple[state: LocalResourceState, ordinal: uint32]

  ComponentEndpointValue = ref object
    endpoint: ComponentEndpoint
    payloadResources: seq[EndpointResourceIdentity]
    when defined(wasmComponentHostEndpoints):
      operation: ComponentHostBuffer

  ComponentSubtaskState = enum
    cstStarting, cstStarted, cstReturned, cstCancelledBeforeStart, cstCancelledBeforeReturn

  ComponentSubtask = ref object
    lowering: ComponentScheduledLowering
    arguments: seq[WasmValue]
    call: ComponentInvocation
    returnPointer: uint32
    handle, joined: uint32
    state: ComponentSubtaskState
    eventPending, delivered, cancellationRequested, cancelling: bool
    when defined(wasmComponentAsyncCallbacks):
      lenders: ResourceLendBatch
      unresolvedBorrows: TaskBorrowScope
    when defined(wasmComponentStackful):
      cancelWaiter: ref bool
      flatResults: seq[WasmValue]

  ComponentScheduledLowering = ref object
    caller: pointer
    callback: ComponentHostFunc
    target: ComponentCallTarget
    signature: ComponentFuncType
    memoryAddress, reallocAddress: int
    encoding: CanonicalStringEncoding
    when defined(wasmComponentStackful):
      synchronous: bool

  ComponentInstance* = ref object
    vm: WasmVM
    exports: seq[ComponentExport]
    execution: CanonicalExecutionState
    activeEntries: uint8
    locked: bool
    resources: LocalResourceState
    handleTypes: seq[ResourceTypeAlias]
    outstandingOwners: int
    links: ComponentLinkState
    generatedFunctions: ref seq[int]  # store function addresses plus one
    when defined(wasmComponentAsyncCallbacks):
      asyncSlots: seq[ComponentAsyncSlot]
      backpressure: uint16
    when defined(wasmComponentStackful):
      pausedExclusive: ref bool

  ComponentLinks = ref object
    children: seq[ChildInstantiation]
    aliases: seq[ChildExport]
    interfaceImports: seq[InterfaceImport]
    nameAttributes: ref seq[tuple[name: string, importing: bool, attributes: ComponentNameAttributes]]
    interfaceExports: ref seq[InterfaceExport]
    nestedInterfaceExports: ref seq[InterfaceExport]
    resourceExports: seq[NamedResourceType]
    resourceEqualityImports: seq[NamedResourceType]
    valueExports: seq[NamedValueType]
    valueImports: seq[NamedValueType]
    typeExports, typeImports: ExternalTypeSurface
    visibilityOrder: VisibilityOrder
    componentImports: ref seq[NamedComponentType]
    componentExports: ref seq[NamedComponentDefinition]
    coreModules: CoreModuleExternals
    hasInterfaceDefinitions: bool
    needsResourceFrames: bool
    lexical: LexicalLayout
    contractResources: ContractResources
    linkedResources: LinkedResourceFrame

  NamedComponentType = object
    name: string
    plan: ref ComponentPlan
    interfaceImport: bool

  ComponentTypeDefinition = object
    index: uint32
    plan: ref ComponentPlan

  ComponentArgument = object
    plan: ref ComponentPlan       # visible type, or the unconstrained definition
    implementation: ref ComponentPlan  # for an ascribed local definition
    importIndex: uint16 # one-based in the enclosing component
    childIndex: uint16  # one-based when aliasing a child export
    childExport: uint16
    childInterface: uint16
    localIndex: uint16   # definition bound at its declaration in this component
    captureIndex: uint16 # one-based in the definition's captured context

  BoundDefinition = object
    plan: ref ComponentPlan
    captures: DefinitionCaptures

  DefinitionCaptures = ref object
    components: seq[BoundDefinition]
    modules: seq[CoreModuleImage]
    resources: seq[CapturedResource]

  ResourceFrame = ref object
    owner: pointer # borrowed from this instantiation's component tree

  ResourceLocation = tuple[frame: ResourceFrame, slot: uint16]
  CapturedResource = tuple[slot: uint16, origin: ResourceLocation]

  LinkedResourceFrame = ref object
    local: ResourceFrame
    captures: seq[CapturedResource]

  LexicalDefinition = object
    plan: ref ComponentPlan
    beforeChild: int

  LexicalLayout = ref object
    componentCaptures: seq[ComponentArgument] # indices in the immediate enclosing component
    moduleCaptures: seq[CoreModuleValue]
    definitions: seq[LexicalDefinition]       # in section order, interleaved with child instances

  NamedComponentDefinition = object
    name: string
    value: ComponentArgument
    captures: DefinitionCaptures # set on resolved exports

  ComponentDefinitionScope = object
    plans: seq[ref ComponentPlan]
    sources: seq[tuple[index: uint16, value: ComponentArgument]]

  ComponentInstantiation = ref object
    definition: ComponentArgument
    arguments: seq[ComponentArgument]

  InterfaceImport = object
    name: string
    firstBinding, bindingCount: int
    valueTypes: seq[NamedValueType]
    resourceTypes: seq[NamedResourceType]
    children: ref seq[InterfaceImport]
    coreModules: ref seq[NamedCoreModule]
    components: ref seq[NamedComponentDefinition]
    typeExternals: ExternalTypeSurface

  InterfaceExport = object
    name: string
    methods: seq[ComponentExport]
    resourceTypes: seq[NamedResourceType]
    valueTypes: seq[NamedValueType]
    children: ref seq[uint16]
    coreModules: ref seq[NamedCoreModule]
    components: ref seq[NamedComponentDefinition]
    typeExternals: ExternalTypeSurface
    visibilityOrder: VisibilityOrder

  NamedValueType = object
    name: string
    shape: ref CanonicalSlot
    origin: ref CanonicalSlot

  NamedFunctionType = object
    name: string
    signature: ComponentFuncType
    names: FunctionTypeNames

  ExternalTypeSurface = ref object
    functions: ref seq[NamedFunctionType]
    components: ref seq[NamedComponentType]
    instances: ref seq[NamedInstanceType]

  NamedInstanceType = object
    name: string
    shape: ref InterfaceType

  NamedResourceType = object
    name: string
    resourceIndex: uint16
    typeName: ResourceName

  ChildInstantiation = object
    plan: ref ComponentPlan
    beforeCore: int
    arguments: seq[ComponentExport]
    resourceArgs: seq[uint16]
    resourceNameBindings: ResourceNameBindings
    componentArguments: ComponentInstantiation
    resourceReexports: seq[tuple[childType, parentType: uint16]]
    coreModuleArguments: ref seq[CoreModuleValue]
    valueTypeArguments: RebasedShapes # child import alias to the supplied parent type
    projectedValueTypes: RebasedShapes

  ChildExport = object
    childIndex: uint16
    exportIndex: uint16
    interfaceIndex: uint16  # zero for a function at component scope

  ComponentLinkStore = ref object
    locked: bool
    callDepth: int
    root: pointer
    when defined(wasmComponentAsyncCallbacks):
      pendingSubtasks: seq[ComponentSubtask]
      nextSubtask, startingSubtasks: int
      activeCallbackTurns: uint8
      pumping: bool
    when defined(wasmComponentThreads):
      guestThreads: seq[ComponentGuestThread]
      switchTarget: ComponentGuestThread
      nextGuestThread: int

  ComponentLinkState = ref object
    store: ComponentLinkStore
    children: seq[ComponentInstance]
    aliases: seq[ChildExport]
    bindings: seq[ComponentHostBinding]
    interfaceExports: ref seq[InterfaceExport]
    nestedInterfaceExports: ref seq[InterfaceExport]
    resourceBindings: seq[ResourceBinding]

  ResourceBinding = object
    owner: pointer  # the parent owns the forwarding instance
    resourceIndex: uint32

  ComponentOwnedValue = ref object
    owner: ComponentInstance
    when defined(wasmComponentAsyncCallbacks):
      borrowOwner: pointer
    graph: ComponentInstance
    resourceIndex: uint32
    representation: uint64
    live: bool
    lends: uint32

  ResourceLend = object
    handle: uint32
    token: ComponentOwnedValue
    when defined(wasmComponentAsyncCallbacks):
      sourceScope: TaskBorrowScope

  TaskBorrowScopeState = object
    resources: LocalResourceState
    id: uint32
    pins: seq[ComponentOwnedValue]

  TaskBorrowScope = ref TaskBorrowScopeState

  ResourceLendBatchState = object
    resources: LocalResourceState
    lends: seq[ResourceLend]

  ResourceLendBatch = ref ResourceLendBatchState

  CoreFunctionKind = enum
    cfLower
    cfAlias

  CoreFunction = object
    kind: CoreFunctionKind
    loweringIndex: uint32
    coreInstance: uint32
    name: string

  CoreExportAlias = object
    name: string
    coreInstance: uint32

  ComponentFunctionKind = enum
    fnImport
    fnLift
    fnChild

  ComponentFunction = object
    kind: ComponentFunctionKind
    typeIndex: uint32
    coreFunction: uint32
    importIndex: uint32
    memoryAlias: int32
    reallocFunction: int32
    postReturnFunction: int32
    when defined(wasmComponentAsyncCallbacks):
      callbackFunction: uint32  # one-based core function index
    when defined(wasmComponentStackful):
      stackful: bool
    stringEncoding: CanonicalStringEncoding

  NamedComponentMethod = object
    name: string
    fn: ComponentFunction

  DeclaredInstance = object
    childIndex: int  # -1 for a named import or synthesized instance
    interfaceIndex: uint16
    visibility: TypeVisibility
    methods: seq[NamedComponentMethod]
    resourceTypes: seq[NamedResourceType]
    valueTypes: seq[NamedValueType]
    children: ref seq[NamedInstance]
    coreModules: ref seq[NamedCoreModule]
    components: ref seq[NamedComponentDefinition]
    typeExternals: ExternalTypeSurface
    visibilityOrder: VisibilityOrder

  NamedInstance = object
    name: string
    value: DeclaredInstance

  InterfaceType = object
    typeIndex: uint32
    methods: seq[ComponentImport]
    valueTypes: seq[NamedValueType]
    resources: InterfaceResourceTypes
    children: ref seq[InterfaceTypeMember]
    outerNames: ref seq[OuterValueName]
    visibilityError: string
    coreModules: ref seq[NamedCoreModule]
    components: ref seq[NamedComponentDefinition]
    typeExternals: ExternalTypeSurface
    visibilityOrder: VisibilityOrder

  OuterValueName = tuple[depth: uint16, visibility: TypeVisibility]
  InterfaceTypeMember = object
    name: string
    definition: ref InterfaceType
    resources: seq[uint16] # maps the member's resource ordinals into its parent type

  LexicalResource = tuple[depth, ordinal: uint16] # depth zero introduces an abstract type
  InterfaceResourceOrdinal = range[0 .. MaxComponentResourceTypes - 1]
  ResourceOrdinals = set[InterfaceResourceOrdinal]

  ContractResources = ref object
    captures: seq[tuple[slot: uint16, source: LexicalResource]]
    used: ResourceOrdinals
    live: ResourceOrdinals # slots needed by a concrete component's lexical environment

  InterfaceResourceTypes = ref object
    resourceTypes: seq[NamedResourceType]
    handleTypes: seq[ResourceTypeAlias]
    enclosing: seq[LexicalResource]
    # Stable across aliases and resource rebasing. The ordinal identifies the
    # declaration within this scope, including resources introduced by members.
    nominalScope: ref byte
    names: seq[string]     # abstract resource names, including those introduced by nested exports
    used: set[InterfaceResourceOrdinal]

  CoreInstanceKind = enum
    ciInline
    ciModule

  CoreInstance = object
    kind: CoreInstanceKind
    moduleIndex: uint8
    storeIndex: uint8
    exports: seq[tuple[name: string, kind: ExportKind, itemIndex: uint32]]
    args: seq[tuple[name: string, instanceIndex: uint32]]

  CoreImportSource = object
    instanceIndex: int16  # -1 for a generated canonical core function
    itemIndex: uint16     # embedded export ordinal or canonical lowering index

  CoreLowering = object
    kind: CoreLoweringKind
    targetIndex: uint16
    memoryInstance: uint8
    reallocSource: uint16
    generatedReference: bool
    when defined(wasmComponentAsyncCallbacks):
      asyncLower: bool
      asyncCancel: bool
    when ComponentEndpointsEnabled:
      endpointShape: ref CanonicalSlot
    when defined(wasmComponentThreads):
      threadTable: uint8  # one-based core instance source
      threadTableName: string
      threadClosure: ValType
      contextSlot: uint8
    when defined(wasmComponentThreadSpawn):
      threadSignature: ref FuncType
    afterCores, afterChildren: uint8
    memoryName: string
    reallocName: string
    stringEncoding: CanonicalStringEncoding
    resourceSignature: ref ComponentFuncType
    localTarget: ref ComponentExport

  CoreLoweringKind = enum
    clHost, clResourceNew, clResourceDrop, clResourceRep, clChild, clLocal,
    clContextGet, clContextSet, clTaskReturn,
    clWaitableSetNew, clWaitableSetDrop, clWaitableSetPoll, clWaitableJoin,
    clSubtaskDrop, clBackpressureInc, clBackpressureDec, clTaskCancel, clSubtaskCancel,
    clWaitableSetWait, clThreadYield,
    clErrorContextNew, clErrorContextDebugMessage, clErrorContextDrop,
    clThreadIndex, clThreadNewIndirect, clThreadResumeLater, clThreadSuspend,
    clThreadSuspendResume, clThreadYieldResume, clThreadSuspendPromote, clThreadYieldPromote,
    clThreadSpawnRef, clThreadAvailableParallelism,
    clEndpointNew, clEndpointRead, clEndpointWrite, clEndpointCancelRead, clEndpointCancelWrite,
    clEndpointDropReadable, clEndpointDropWritable, clEndpointForward

  CanonicalInstantiations = object
    plan: ptr ComponentPlan
    bindings: ptr seq[ComponentHostBinding]
    next: int

  LocalResourcePlan = object
    destructorSource: uint16
    destructorName: string
    importName: string
    importInterface: uint16
    sourceChild: uint16  # one-based index of an instantiated child
    ascribedFrom: uint16 # one-based implementation of an abstract resource export
    importedTypeName: ResourceName

  ResourceTypeAlias = object
    typeIndex: uint16
    resourceIndex: uint16
    visible: bool
    imported: bool
    typeName: ResourceName

  ResourceDestructorContext = ref object
    vm: ptr WasmVM
    address: int
    when defined(wasmComponentThreads):
      owner: pointer
    when defined(wasmComponentContext) or defined(wasmComponentAsyncCallbacks):
      execution: CanonicalExecutionState

  LocalResourceState = ref object
    table: ComponentResourceTable
    destructors: seq[ResourceDestructorContext]
    when defined(wasmComponentAsyncCallbacks):
      nextBorrowScope: uint32
      taskBorrowScopes, lendBatches: seq[pointer]  # Weak registrations for graph cleanup.

  CoreInstantiation = object
    moduleIndex: uint8
    imports: seq[CoreImportSource]
    external: ExternalCoreInstantiation

  CoreModuleShape = ref WasmModule # signature only, with no executable code

  CoreTypeDeclaration = object
    function: FuncType
    module: CoreModuleShape      # nil for a function type

  CoreModuleImage = ref object
    bytes: seq[byte]
    shape: CoreModuleShape

  CoreModuleValue = object
    shape: CoreModuleShape       # ascribed type when a module crosses a boundary
    image: CoreModuleImage       # present for local embedded bytes
    embeddedIndex: uint8         # one-based index for the direct embedded path
    importIndex: uint16          # one-based when this value is an import
    childIndex: uint16           # one-based when aliasing a child's export
    childExport: uint16
    childInterface: uint16       # zero for a component-level export
    captureIndex: uint16

  NamedCoreModule = object
    name: string
    value: CoreModuleValue
    interfaceImport: bool        # registered in the plan's shared import index space

  CoreModuleExternals = ref object
    imports, exports: seq[NamedCoreModule]

  ExternalCoreInstantiation = ref object
    source: CoreModuleValue
    image: CoreModuleImage       # assigned during preflight linking

  CoreExportType = object
    name: string
    case kind: ExportKind
    of ekFunc, ekTag:
      funcType: FuncType
    of ekTable:
      tableType: TableType
    of ekMemory:
      memType: MemType
    of ekGlobal:
      globalType: GlobalType

when defined(wasmChunkedMemory):
  type ComponentMemoryFactory* = MemoryBackendFactory
else:
  type ComponentMemoryFactory* = pointer

when defined(wasmComponentStackful):
  proc `=destroy`(reservation: var ComponentCoreReservation) =
    if reservation.exclusive != nil: reservation.exclusive[] = false
    `=destroy`(reservation.exclusive)

when defined(wasmComponentHostEndpoints):
  type
    ComponentHostEndpoint* = ComponentEndpointValue
    ComponentEndpointStatus* = enum
      cesIdle, cesPending, cesCompleted, cesDropped, cesCancelled
    ComponentEndpointResult* = object
      status*: ComponentEndpointStatus
      count*: uint32
      values*: seq[ComponentValue] # Received values or the unsent suffix of a write.

when defined(wasmComponentAsyncCallbacks):
  proc `=destroy`(scope: var TaskBorrowScopeState)
  proc `=destroy`(batch: var ResourceLendBatchState)

when ComponentEndpointsEnabled:
  proc detachEndpoint(endpoint: var ComponentEndpointState) =
    let other = endpoint.other
    endpoint.other = nil
    if other == nil: return
    other.other = nil
    if other.state != fcDone and not other.eventPending:
      other.eventPending = true
      other.eventProgress = 0

  proc `=destroy`(endpoint: var ComponentEndpointState) =
    endpoint.detachEndpoint()
    `=destroy`(endpoint.shape)
    when defined(wasmComponentHostEndpoints): `=destroy`(endpoint.buffer.host)
    when defined(wasmComponentStackful): `=destroy`(endpoint.syncWaiter)

when defined(wasmComponentAsyncCallbacks):
  proc `=destroy`(registration: var ComponentWaitRegistration) =
    if registration.waitSet != nil: dec registration.waitSet.waiters
    `=destroy`(registration.waitSet)

  proc unregister(registrations: var seq[pointer], item: pointer) =
    for i, registration in registrations:
      if registration == item:
        registrations.del(i)
        return

  proc findBorrowScope(resources: LocalResourceState, id: uint32): TaskBorrowScope =
    if id == 0: return nil
    for registration in resources.taskBorrowScopes:
      if cast[ptr TaskBorrowScopeState](registration).id == id:
        return cast[TaskBorrowScope](registration)

  proc releaseTaskBorrows(scope: var TaskBorrowScopeState) =
    if scope.resources == nil: return
    if scope.id != 0: discard scope.resources.table.endBorrowScope(scope.id)
    for pin in scope.pins: dec pin.lends
    scope.resources.taskBorrowScopes.unregister(addr scope)
    scope.pins = @[]
    scope.resources = nil
    scope.id = 0

  proc `=destroy`(scope: var TaskBorrowScopeState) =
    scope.releaseTaskBorrows()

proc releaseLends(resources: LocalResourceState, lends: openArray[ResourceLend]) =
  for lent in lends:
    lent.token.live = false
    lent.token.owner = nil
    when defined(wasmComponentAsyncCallbacks): lent.token.borrowOwner = nil
    resources.table.releaseLend(lent.handle)

when defined(wasmComponentAsyncCallbacks):
  proc releaseLendBatch(batch: var ResourceLendBatchState) =
    if batch.resources == nil: return
    batch.resources.releaseLends(batch.lends)
    batch.resources.lendBatches.unregister(addr batch)
    batch.resources = nil
    batch.lends = @[]

  proc `=destroy`(batch: var ResourceLendBatchState) =
    batch.releaseLendBatch()

proc componentFail(message: string) {.noreturn.} =
  raise newException(ComponentError, message)

func endpointName(kind: ComponentPrim): string =
  if kind == cpStream: "stream" else: "future"

func endpointEnabled(kind: ComponentPrim): bool =
  case kind
  of cpFuture: defined(wasmComponentFutures)
  of cpStream: defined(wasmComponentStreams)
  else: false

proc visibilityIssue(message: string, deferred: ptr string) {.noinline.} =
  if deferred == nil: componentFail(message)
  if deferred[].len == 0: deferred[] = message

template boundedAdd(target, value, maximum: untyped) =
  if target.len >= maximum:
    componentFail("component index-space limit")
  target.add(value)

proc addMember(order: var VisibilityOrder, member: VisibilityMember, index: int) =
  if order == nil: new(order)
  order[].add((member, index.uint8))

proc take(data: openArray[byte], pos: var int, limit: int): byte =
  if pos >= limit or pos < 0: componentFail("truncated component")
  result = data[pos]
  inc pos

proc takeU32(data: openArray[byte], pos: var int, limit: int,
             signedTypeIndex = false): uint32 =
  ## Unsigned LEB128, limited to five bytes with no overflow bits.
  var shift = 0
  for i in 0 .. 4:
    let b = take(data, pos, limit)
    if i == 4 and (b and 0xf0'u8) != 0:
      componentFail("component integer overflow")
    result = result or (uint32(b and 0x7f'u8) shl shift)
    if (b and 0x80'u8) == 0:
      # A nonnegative s33 uses one more sign bit than an unsigned index.
      if signedTypeIndex and i < 4 and (b and 0x40'u8) != 0:
        componentFail("negative component value type index")
      return
    shift += 7
  componentFail("component integer overflow")

proc takeCount(data: openArray[byte], pos: var int, limit, maximum: int): int =
  let value = takeU32(data, pos, limit)
  if value > maximum.uint32: componentFail("component count limit")
  value.int

proc takeName(data: openArray[byte], pos: var int, limit: int,
              allowEmpty = false, maxLength = 255): string =
  let n = takeU32(data, pos, limit)
  if (n == 0 and not allowEmpty) or n > maxLength.uint32 or n.uint64 > uint64(limit - pos):
    componentFail("invalid component name")
  result = newString(n.int)
  for i in 0 ..< n.int:
    result[i] = char(take(data, pos, limit))
  if not validWasmName(result): componentFail("invalid component UTF-8")

func validLabel(name: string, first, stop: int, lowerOnly = false): bool =
  if first >= stop or name[first] notin {'a'..'z', 'A'..'Z'}: return false
  var letterCase = 0
  var word = false
  for i in first ..< stop:
    case name[i]
    of '-':
      if not word: return false
      letterCase = 0
      word = false
    of '0'..'9': word = true
    of 'a'..'z':
      if letterCase == 2: return false
      letterCase = 1
      word = true
    of 'A'..'Z':
      if lowerOnly or letterCase == 1: return false
      letterCase = 2
      word = true
    else: return false
  word

func nextLabelChar(name: string, pos: var int): char =
  while pos < name.len and name[pos] == '-':
    inc pos
  if pos >= name.len: return '\0'
  result = name[pos]
  inc pos
  if result in 'A'..'Z': result = char(ord(result) + ord('a') - ord('A'))

func sameCanonicalNameAt(left, right: string, i, j: int): bool =
  var i = i
  var j = j
  while true:
    let a = nextLabelChar(left, i)
    let b = nextLabelChar(right, j)
    if a != b: return false
    if a == '\0': return true

type ResourceMemberKind = enum
  rmNone, rmConstructor, rmMethod, rmStatic

func resourceMember(name: string): tuple[kind: ResourceMemberKind, first, dot: int] =
  if name.len == 0 or name[0] != '[': return
  const Constructor = "[constructor]"
  const Method = "[method]"
  const Static = "[static]"
  if name.len > Constructor.len and name[0 ..< Constructor.len] == Constructor:
    if validLabel(name, Constructor.len, name.len):
      return (rmConstructor, Constructor.len, name.len)
    return
  if name.len > Method.len and name[0 ..< Method.len] == Method:
    result.kind = rmMethod
    result.first = Method.len
  elif name.len > Static.len and name[0 ..< Static.len] == Static:
    result.kind = rmStatic
    result.first = Static.len
  else:
    return
  for i in result.first ..< name.len:
    if name[i] != '.': continue
    if validLabel(name, result.first, i) and validLabel(name, i + 1, name.len):
      result.dot = i
      return
    break
  result.kind = rmNone

func memberCanonicalStart(name: string): int =
  let member = resourceMember(name)
  if member.kind notin {rmMethod, rmStatic}: return 0
  if sameCanonicalNameAt(name[member.first ..< member.dot], name, 0,
      member.dot + 1):
    return member.dot + 1
  member.first

func sameCanonicalName(left, right: string): bool =
  sameCanonicalNameAt(left, right, memberCanonicalStart(left),
    memberCanonicalStart(right))

proc takeLabel(data: openArray[byte], pos: var int, limit: int): string =
  result = takeName(data, pos, limit, allowEmpty = true)
  if not validLabel(result, 0, result.len):
    componentFail("invalid Component Model label")

func scanVersionIdentifiers(name: string, pos: var int,
                            preRelease: bool): bool =
  while true:
    let start = pos
    var allDigits = true
    while pos < name.len and name[pos] in {'0'..'9', 'a'..'z', 'A'..'Z', '-'}:
      if name[pos] notin '0'..'9': allDigits = false
      inc pos
    if pos == start or
        (preRelease and allDigits and pos - start > 1 and name[start] == '0'):
      return false
    if pos == name.len or name[pos] != '.': return true
    inc pos

func canonicalVersionEnd(name: string, start: int): int =
  ## Validate the full SemVer and return the end of its canonical prefix.
  var pos = start
  var split = -1
  for part in 0 ..< 3:
    let first = pos
    while pos < name.len and name[pos] in '0'..'9':
      inc pos
    if pos == first or (pos - first > 1 and name[first] == '0'): return -1
    if part < 2 and split < 0 and name[first] != '0': split = pos
    if part < 2:
      if pos == name.len or name[pos] != '.': return -1
      inc pos
  if pos < name.len and name[pos] == '-':
    inc pos
    if not scanVersionIdentifiers(name, pos, preRelease = true): return -1
    split = pos
  if split < 0: split = pos
  if pos < name.len and name[pos] == '+':
    inc pos
    if not scanVersionIdentifiers(name, pos, preRelease = false): return -1
  if pos == name.len: split else: -1

func interfaceVersionMarker(name: string): int =
  ## Return -1 for a non-interface name or the end of the path for an interface.
  var colon = -1
  var slash = -1
  var version = name.len
  for i, c in name:
    case c
    of ':':
      if colon >= 0: return -1
      colon = i
    of '/':
      if slash >= 0: return -1
      slash = i
    of '@':
      version = i
      break
    else: discard
  if colon >= 0 and slash > colon and slash < version and
      validLabel(name, 0, colon, lowerOnly = true) and
      validLabel(name, colon + 1, slash, lowerOnly = true) and
      validLabel(name, slash + 1, version):
    return version
  -1

proc requireInterfaceVersion(name, suffix: string, marker: int) {.noinline.} =
  if marker == name.len:
    if suffix.len != 0: componentFail("a version suffix requires the name to have a version")
    return
  if suffix.len == 0:
    if canonicalVersionEnd(name, marker + 1) < 0:
      componentFail("invalid Component Model name: invalid interface version")
  else:
    let versionEnd = canonicalVersionEnd(name & suffix, marker + 1)
    if versionEnd < 0: componentFail("invalid interface version")
    if versionEnd != name.len: componentFail("invalid canonical interface version split")

proc readNameAttributes(data: openArray[byte], pos: var int, limit: int):
    ComponentNameAttributes {.noinline.} =
  let count = takeCount(data, pos, limit, 3)
  var seen: set[0..2]
  for _ in 0 ..< count:
    let tag = take(data, pos, limit)
    if tag > 2: componentFail("unknown component name attribute")
    if tag.int in seen: componentFail("duplicate component name attribute")
    seen.incl(tag.int)
    case tag
    of 0:
      result.implements = takeName(data, pos, limit, allowEmpty = true)
      if result.implements.len == 0: componentFail("implements requires an interface name")
    of 1:
      when defined(wasmComponentCanonicalNames):
        result.versionSuffix = takeName(data, pos, limit, allowEmpty = true)
        if result.versionSuffix.len == 0: componentFail("version suffix cannot be empty")
      else:
        componentFail("component canonical names are disabled")
    else:
      result.hasExternalId = true
      result.externalId = takeName(data, pos, limit, allowEmpty = true,
        maxLength = MaxComponentBytes)

proc takeExternalName(data: openArray[byte], pos: var int, limit: int): ExternalName {.noinline.} =
  let tag = take(data, pos, limit)
  if tag > 2: componentFail("unsupported component name attributes")
  result.name = takeName(data, pos, limit, allowEmpty = true)
  if tag == 2: result.attributes = readNameAttributes(data, pos, limit)
  result.sort = take(data, pos, limit)
  let name = result.name
  let plain = validLabel(name, 0, name.len)
  let marker = interfaceVersionMarker(name)
  let member = resourceMember(name).kind != rmNone
  if not plain and marker < 0 and not member:
    componentFail("invalid Component Model name")
  if member and result.sort != 1:
    componentFail("resource member name requires a function")
  let attrs = unsafeAddr result.attributes
  if attrs.implements.len != 0:
    if result.sort != 5: componentFail("only instances can have an implements attribute")
    if not plain: componentFail("implements requires a plain external name")
    let implemented = interfaceVersionMarker(attrs.implements)
    if implemented < 0: componentFail("implements requires an interface name")
    requireInterfaceVersion(attrs.implements, attrs.versionSuffix, implemented)
  elif marker >= 0:
    if attrs.versionSuffix.len != 0 and result.sort != 5:
      componentFail("only instances can have a version-suffix attribute")
    requireInterfaceVersion(name, attrs.versionSuffix, marker)
  elif attrs.versionSuffix.len != 0:
    componentFail("version-suffix requires an interface name or implements")

proc rememberNameAttributes(plan: var ComponentPlan, external: ExternalName,
                            importing: bool) {.noinline.} =
  let attrs = unsafeAddr external.attributes
  if attrs.implements.len == 0 and attrs.versionSuffix.len == 0 and not attrs.hasExternalId:
    return
  if plan.links == nil: new(plan.links)
  if plan.links.nameAttributes == nil: new(plan.links.nameAttributes)
  plan.links.nameAttributes[].add((external.name, importing, attrs[]))

proc componentNameAttributes*(plan: ComponentPlan, name: string,
                              importing: bool): ComponentNameAttributes =
  ## Look up metadata on an import or export of this component.
  if plan.links != nil and plan.links.nameAttributes != nil:
    for entry in plan.links.nameAttributes[]:
      if entry.name == name and entry.importing == importing: return entry.attributes

proc takePrim(data: openArray[byte], pos: var int, limit: int): ComponentPrim =
  let b = take(data, pos, limit)
  case b
  of 0x7f'u8: cpBool
  of 0x7e'u8: cpS8
  of 0x7d'u8: cpU8
  of 0x7c'u8: cpS16
  of 0x7b'u8: cpU16
  of 0x7a'u8: cpS32
  of 0x79'u8: cpU32
  of 0x78'u8: cpS64
  of 0x77'u8: cpU64
  of 0x76'u8: cpF32
  of 0x75'u8: cpF64
  of 0x74'u8: cpChar
  of 0x73'u8: cpString
  of 0x64'u8:
    when defined(wasmComponentErrorContext): cpErrorContext
    else: componentFail("component error-context is disabled")
  else: componentFail("unsupported component value type")

const PrimitiveValues = {cpBool, cpS8, cpU8, cpS16, cpU16, cpS32, cpU32,
  cpS64, cpU64, cpF32, cpF64, cpChar, cpString, cpErrorContext}
const MapKeyTypes = PrimitiveValues - {cpF32, cpF64, cpErrorContext}

proc takeValType(data: openArray[byte], pos: var int, limit: int,
                 valueKinds: openArray[ComponentPrim]): tuple[kind: ComponentPrim,
                                                              index: int32] =
  if pos >= limit: componentFail("truncated component value type")
  if data[pos] in 0x73'u8 .. 0x7f'u8 or data[pos] == 0x64'u8:
    return (takePrim(data, pos, limit), -1'i32)
  let index = takeU32(data, pos, limit, signedTypeIndex = true)
  when ComponentEndpointsEnabled:
    if index < valueKinds.len.uint32 and endpointEnabled(valueKinds[index.int]):
      return (valueKinds[index.int], index.int32)
  if index >= valueKinds.len.uint32 or
      valueKinds[index.int] notin PrimitiveValues + {cpBytes, cpU32List, cpU64List, cpList, cpMap, cpFixedList,
                                   cpRecord, cpTuple, cpFlags,
                                   cpOption, cpVariant, cpEnum, cpResult,
                                   cpOwnedResource, cpBorrowedResource}:
    componentFail("unsupported component value type index")
  (valueKinds[index.int], index.int32)

proc readComponentResult(data: openArray[byte], pos: var int, limit: int,
    valueKinds: openArray[ComponentPrim], signature: var ComponentFuncType) =
  case take(data, pos, limit)
  of 0x00'u8:
    signature.hasResult = true
    let valueType = takeValType(data, pos, limit, valueKinds)
    if valueType.kind == cpBorrowedResource:
      componentFail("component function result contains a borrowed resource")
    signature.resultType = valueType.kind
    signature.resultTypeIndex = if valueType.kind in
        {cpRecord, cpTuple, cpFlags, cpOption, cpVariant, cpEnum,
         cpResult, cpList, cpMap, cpFixedList, cpOwnedResource, cpFuture, cpStream}:
      valueType.index else: -1'i32
  of 0x01'u8:
    if take(data, pos, limit) != 0x00'u8:
      componentFail("unsupported component result list")
  else: componentFail("unsupported component result list")

func asyncSignature(signature: ComponentFuncType): bool {.inline.} =
  when defined(wasmComponentAsyncCallbacks): signature.isAsync
  else: false

proc readFuncType(data: openArray[byte], pos: var int,
                  limit: int, valueKinds: openArray[ComponentPrim]): ComponentFuncType =
  case take(data, pos, limit)
  of 0x40'u8: discard
  of 0x43'u8:
    when defined(wasmComponentAsyncCallbacks): result.isAsync = true
    else: componentFail("async component function types are disabled")
  else: componentFail("unsupported component type")
  let count = takeCount(data, pos, limit, MaxComponentParams)
  for _ in 0 ..< count:
    let label = takeLabel(data, pos, limit)
    for previous in result.paramNames:
      if sameCanonicalName(previous, label):
        componentFail("duplicate component parameter")
    result.paramNames.add(label)
    let valueType = takeValType(data, pos, limit, valueKinds)
    result.params.add(valueType.kind)
    if valueType.kind in {cpRecord, cpTuple, cpFlags, cpOption, cpVariant,
                          cpEnum, cpResult, cpList, cpMap, cpFixedList,
                          cpOwnedResource, cpBorrowedResource, cpFuture, cpStream}:
      if result.paramTypeIndices.len == 0:
        for _ in 0 ..< result.params.len - 1:
          result.paramTypeIndices.add(-1'i32)
      result.paramTypeIndices.add(valueType.index)
    elif result.paramTypeIndices.len > 0:
      result.paramTypeIndices.add(-1'i32)
  readComponentResult(data, pos, limit, valueKinds, result)

proc coreType(t: ComponentPrim): ValType =
  case t
  of cpBool, cpS8, cpU8, cpS16, cpU16, cpS32, cpU32, cpChar,
     cpOwnedResource, cpBorrowedResource, cpFuture, cpStream, cpErrorContext: vtI32
  of cpS64, cpU64: vtI64
  of cpF32: vtF32
  of cpF64: vtF64
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap, cpFixedList, cpRecord, cpTuple, cpFlags, cpOption,
     cpVariant, cpEnum, cpResult, cpResourceType, cpInterfaceType, cpFunctionType, cpComponentType:
    componentFail("composite value needs canonical lowering")

const
  CanonicalPairs = {cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap}
  CanonicalVariants = {cpOption, cpVariant, cpEnum, cpResult}
  ShapedValues = {cpRecord, cpTuple, cpFlags, cpList, cpMap, cpFixedList, cpFuture, cpStream} + CanonicalVariants
  ResourceValues = {cpOwnedResource, cpBorrowedResource}

proc handleSlot(kind: ComponentPrim, typeIndex: int32): CanonicalSlot =
  let use = if kind == cpOwnedResource: ruOwn else: ruBorrow
  CanonicalSlot(kind: kind, resourceType: typeIndex.uint16, resources: {use})

proc plainValueSlot(kind: ComponentPrim): CanonicalSlot =
  result.kind = kind
  if kind == cpErrorContext: result.resources = {ruErrorContext}

proc parameterSlot(sig: ComponentFuncType, i: int): CanonicalSlot =
  if sig.paramArea != nil: return sig.paramArea.slots[i]
  let kind = sig.params[i]
  if kind in ResourceValues: handleSlot(kind, sig.paramTypeIndices[i])
  else: plainValueSlot(kind)

proc resultSlot(sig: ComponentFuncType): CanonicalSlot =
  if sig.resultShape != nil: return sig.resultShape[]
  if sig.resultType in ResourceValues: handleSlot(sig.resultType, sig.resultTypeIndex)
  else: plainValueSlot(sig.resultType)

proc parameterResources(sig: ComponentFuncType): ResourceUses =
  for i, kind in sig.params:
    case kind
    of cpOwnedResource: result.incl(ruOwn)
    of cpBorrowedResource: result.incl(ruBorrow)
    of cpErrorContext: result.incl(ruErrorContext)
    else:
      if kind in ShapedValues:
        result = result + sig.paramArea.slots[i].resources

proc hasResourceResult(sig: ComponentFuncType): bool =
  sig.hasResult and (sig.resultType in {cpOwnedResource, cpErrorContext} or
    (sig.resultShape != nil and sig.resultShape.resources != {}))

template fieldSlot(field: ComponentRecordField): CanonicalSlot =
  (if field.shape == nil: CanonicalSlot(kind: field.kind) else: field.shape[])

template caseSlot(item: ComponentVariantCase): CanonicalSlot =
  (if item.shape == nil: CanonicalSlot(kind: item.payloadKind) else: item.shape[])

proc singleLaneType(slot: CanonicalSlot): ValType =
  case slot.kind
  of cpRecord, cpTuple:
    singleLaneType(fieldSlot(slot.recordShape.fields[0]))
  of cpFixedList:
    singleLaneType(slot.listElement[])
  of cpFlags, cpOption, cpVariant, cpResult, cpEnum: vtI32
  else: coreType(slot.kind)

proc flatSlotWidth(slot: CanonicalSlot): int

proc coreResultType(sig: ComponentFuncType): ValType =
  case sig.resultType
  of cpRecord, cpTuple, cpFixedList:
    if flatSlotWidth(sig.resultShape[]) == 1:
      singleLaneType(sig.resultShape[])
    else: vtI32
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap, cpOption, cpVariant, cpEnum,
     cpResult, cpFlags: vtI32
  else: coreType(sig.resultType)

proc flatSlotWidth(slot: CanonicalSlot): int =
  if slot.kind in {cpRecord, cpTuple}: return slot.recordShape.flatWidth.int
  if slot.kind == cpFixedList:
    # Larger values are passed indirectly. Do not expand their lane arrays.
    return min((MaxFlatParams + 1).uint64,
      slot.listLength.uint64 * flatSlotWidth(slot.listElement[]).uint64).int
  if slot.kind in CanonicalVariants:
    result = 1
    for item in slot.cases:
      if item.hasPayload:
        result = max(result, 1 + flatSlotWidth(caseSlot(item)))
    return
  if slot.kind in CanonicalPairs: 2 else: 1

proc joinLane(left, right: ValType): ValType =
  if left == right: left
  elif left in {vtI32, vtF32} and right in {vtI32, vtF32}: vtI32
  else: vtI64

proc flatLaneType(slot: CanonicalSlot, index: int): ValType =
  case slot.kind
  of cpFixedList:
    return flatLaneType(slot.listElement[], index mod flatSlotWidth(slot.listElement[]))
  of cpRecord, cpTuple:
    var remaining = index
    for field in slot.recordShape.fields:
      let child = fieldSlot(field)
      let width = flatSlotWidth(child)
      if remaining < width: return flatLaneType(child, remaining)
      remaining -= width
  of cpOption, cpVariant, cpEnum, cpResult:
    if index == 0: return vtI32
    let payloadIndex = index - 1
    var found = false
    for item in slot.cases:
      if not item.hasPayload: continue
      let child = caseSlot(item)
      if payloadIndex >= flatSlotWidth(child): continue
      let lane = flatLaneType(child, payloadIndex)
      result = if found: joinLane(result, lane) else: lane
      found = true
    if found: return
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap, cpFlags:
    return vtI32
  else: return coreType(slot.kind)
  componentFail("invalid canonical flat lane index")

proc paramFlatWidth(sig: ComponentFuncType, i: int): int =
  let kind = sig.params[i]
  if kind in ShapedValues: return flatSlotWidth(sig.paramArea.slots[i])
  if kind in CanonicalPairs: 2 else: 1

proc flatParamCount(sig: ComponentFuncType): int =
  for i in 0 ..< sig.params.len:
    result += paramFlatWidth(sig, i)

func paramsUseMemoryArea(sig: ComponentFuncType): bool =
  sig.paramArea != nil and sig.paramArea.layout.size > 0

proc recordScalarBytes(kind: ComponentPrim): int
proc variantLayout(cases: openArray[ComponentVariantCase], pointerBytes = 4):
    tuple[size, alignment, payloadOffset: int]

func abiAlign(offset, alignment: int): int =
  (offset + alignment - 1) and not (alignment - 1)

proc flagBytes(count: int): int =
  if count <= 8: 1
  elif count <= 16: 2
  else: 4

proc flagMask(count: int): uint32 =
  if count == 32: uint32.high
  else: (1'u32 shl count) - 1

proc canonicalSlotLayout(slot: CanonicalSlot, pointerBytes = 4): AbiLayout =
  case slot.kind
  of cpRecord, cpTuple:
    if pointerBytes == 4: return slot.recordShape.layout
    result.alignment = 1
    for field in slot.recordShape.fields:
      let layout = canonicalSlotLayout(fieldSlot(field), pointerBytes)
      result.size = abiAlign(result.size, layout.alignment) + layout.size
      result.alignment = max(result.alignment, layout.alignment)
      if result.size >= MaxCanonicalValueBytes: return
    result.size = abiAlign(result.size, result.alignment)
  of cpOption, cpVariant, cpEnum, cpResult:
    let variant = variantLayout(slot.cases, pointerBytes)
    return (variant.size, variant.alignment)
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap:
    return (2 * pointerBytes, pointerBytes)
  of cpFixedList:
    let element = canonicalSlotLayout(slot.listElement[], pointerBytes)
    let size = slot.listLength.uint64 * element.size.uint64
    return (min(size, MaxCanonicalValueBytes.uint64).int, element.alignment)
  of cpOwnedResource, cpBorrowedResource, cpFuture, cpStream, cpErrorContext: return (4, 4)
  of cpFlags:
    let width = flagBytes(slot.cases.len)
    return (width, width)
  else:
    let width = recordScalarBytes(slot.kind)
    return (width, width)

proc validateCanonicalTypeSize(slot: CanonicalSlot) =
  # The binary validity limit applies to both pointer widths, even when
  # this execution profile only exposes memory32.
  if canonicalSlotLayout(slot, 8).size >= MaxCanonicalValueBytes:
    componentFail("component type exceeds maximum byte size")

proc newSlot(slot: sink CanonicalSlot): ref CanonicalSlot =
  new(result)
  result[] = slot

proc setShape(scope: var ShapeScope, shape: ref CanonicalSlot) =
  # Most type slots are functions or nominal types with no value layout.
  scope.shapes.setLen(scope.kinds.len)
  scope.shapes[^1] = shape

proc saveShape(scope: var ShapeScope, shape: sink CanonicalSlot) =
  if shape.kind in ShapedValues:
    scope.setShape(newSlot(move shape))

proc canonicalShape(typeIndex: int32, shapes: openArray[ref CanonicalSlot]): ref CanonicalSlot =
  if typeIndex < 0 or typeIndex >= shapes.len.int32 or shapes[typeIndex.int] == nil:
    componentFail("unknown canonical value type")
  shapes[typeIndex.int]

proc canonicalSlot(kind: ComponentPrim, typeIndex: int32,
                   shapes: openArray[ref CanonicalSlot]): CanonicalSlot =
  if kind in ShapedValues: canonicalShape(typeIndex, shapes)[]
  elif kind in ResourceValues: handleSlot(kind, typeIndex)
  else: plainValueSlot(kind)

proc layoutCanonicalParams(area: CanonicalParams) =
  area.layout.alignment = 1
  for slot in area.slots.mitems:
    let layout = canonicalSlotLayout(slot)
    let offset = abiAlign(area.layout.size, layout.alignment)
    if offset + layout.size > MaxIndirectParamBytes:
      componentFail("canonical parameter area exceeds profile limit")
    slot.offset = offset.uint16
    area.layout.size = offset + layout.size
    area.layout.alignment = max(area.layout.alignment, layout.alignment)
  area.layout.size = abiAlign(area.layout.size, area.layout.alignment)
  if area.layout.size > MaxIndirectParamBytes:
    componentFail("canonical parameter area exceeds profile limit")

proc configureCanonicalType(sig: var ComponentFuncType, shapes: openArray[ref CanonicalSlot]) =
  if sig.hasResult and sig.resultType in ShapedValues:
    sig.resultShape = canonicalShape(sig.resultTypeIndex, shapes)
    if ruBorrow in sig.resultShape.resources:
      componentFail("component function result contains a borrowed resource")
  var hasShapes = false
  var leafCount = sig.params.len
  for kind in sig.params:
    if kind in ShapedValues: hasShapes = true
    if kind in CanonicalPairs: inc leafCount
  if not hasShapes and leafCount <= MaxFlatParams: return
  let area = CanonicalParams(slots: newSeqOfCap[CanonicalSlot](sig.params.len))
  for i, kind in sig.params:
    let typeIndex = if i < sig.paramTypeIndices.len: sig.paramTypeIndices[i] else: -1'i32
    area.slots.add(canonicalSlot(kind, typeIndex, shapes))
  sig.paramArea = area
  if flatParamCount(sig) > MaxFlatParams: layoutCanonicalParams(area)

when defined(wasmComponentAsyncCallbacks):
  proc configureAsyncParams(sig: var ComponentFuncType) =
    if sig.flatParamCount() <= MaxFlatAsyncParams: return
    if sig.paramArea != nil and sig.paramArea.layout.alignment != 0: return
    let area = CanonicalParams(slots: newSeqOfCap[CanonicalSlot](sig.params.len))
    for i in 0 ..< sig.params.len: area.slots.add(parameterSlot(sig, i))
    sig.paramArea = area
    layoutCanonicalParams(area)

  proc asyncResultArea(sig: ComponentFuncType): bool =
    sig.hasResult and flatSlotWidth(resultSlot(sig)) > 0

proc resultUsesMemory(sig: ComponentFuncType): bool =
  if not sig.hasResult: return false
  case sig.resultType
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap: true
  of cpRecord, cpTuple, cpFixedList: flatSlotWidth(sig.resultShape[]) > 1
  of cpOption, cpVariant, cpResult: flatSlotWidth(sig.resultShape[]) > 1
  else: false

proc hasPointerPayload(slot: CanonicalSlot): bool =
  case slot.kind
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap: true
  of cpRecord, cpTuple: slot.recordShape.hasPointers
  of cpFixedList: hasPointerPayload(slot.listElement[])
  of cpOption, cpVariant, cpResult:
    for item in slot.cases:
      if item.hasPayload and hasPointerPayload(caseSlot(item)): return true
    false
  else: false

proc resultRequiresRealloc(sig: ComponentFuncType): bool =
  if not sig.hasResult: return false
  if sig.resultShape != nil: return hasPointerPayload(sig.resultShape[])
  sig.resultType in CanonicalPairs

proc matchFlatType(slot: CanonicalSlot, lanes: openArray[ValType], offset: var int): bool =
  case slot.kind
  of cpRecord, cpTuple:
    for field in slot.recordShape.fields:
      if not matchFlatType(fieldSlot(field), lanes, offset): return false
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap:
    if lanes[offset] != vtI32 or lanes[offset + 1] != vtI32: return false
    offset += 2
  of cpOption, cpVariant, cpEnum, cpResult, cpFixedList:
    for i in 0 ..< flatSlotWidth(slot):
      if lanes[offset] != flatLaneType(slot, i): return false
      inc offset
  else:
    let kind = if slot.kind == cpFlags: vtI32 else: coreType(slot.kind)
    if lanes[offset] != kind: return false
    inc offset
  true

proc signatureMatchesCore(sig: ComponentFuncType, ft: FuncType,
                          forLower = false, callback = false, stackful = false): bool =
  if not ft.isPlainCoreFunction(): return false  # Canonical ABI uses a final singleton type.
  let indirect = sig.paramsUseMemoryArea()
  let expectedParams = if indirect: 1 else: flatParamCount(sig)
  let resultPointer = forLower and sig.resultUsesMemory()
  let hasResult = (sig.hasResult or callback) and not stackful
  let resultKind = if callback: vtI32 elif sig.hasResult: coreResultType(sig) else: vtI32
  if ft.params.len != expectedParams + resultPointer.int or
      ft.results.len != (hasResult and not resultPointer).int:
    return false
  if indirect:
    if ft.params[0] != vtI32: return false
    if resultPointer: return ft.params[1] == vtI32
    return not hasResult or ft.results[0] == resultKind
  var offset = 0
  for i, p in sig.params:
    let slot = if p in ShapedValues: sig.paramArea.slots[i] else: CanonicalSlot(kind: p)
    if not matchFlatType(slot, ft.params, offset): return false
  if hasResult:
    if resultPointer: return ft.params[offset] == vtI32
    if ft.results[0] != resultKind:
      return false
  true

proc coreFuncType(module: WasmModule, functionIndex: uint32): FuncType =
  var imported = 0'u32
  for imp in module.imports:
    if imp.kind != ikFunc: continue
    if imported == functionIndex:
      if imp.funcTypeIdx >= module.types.len.uint32:
        componentFail("invalid imported core function type")
      return module.types[imp.funcTypeIdx.int]
    inc imported
  if functionIndex < imported or
      functionIndex - imported >= module.funcTypeIdxs.len.uint32:
    componentFail("invalid core function index")
  let typeIndex = module.funcTypeIdxs[(functionIndex - imported).int]
  if typeIndex >= module.types.len.uint32:
    componentFail("invalid core function type")
  module.types[typeIndex.int]

proc validateCoreExport(module: WasmModule, exp: ComponentExport) =
  var found = false
  for item in module.exports:
    if item.name != exp.coreName: continue
    if found or item.kind != ekFunc:
      componentFail("invalid core function alias")
    let callback = when defined(wasmComponentAsyncCallbacks): exp.callbackSource != 0 else: false
    let stackful = when defined(wasmComponentStackful): exp.stackful else: false
    if not signatureMatchesCore(exp.signature, coreFuncType(module, item.idx),
                                callback = callback, stackful = stackful):
      componentFail("canonical function type mismatch")
    found = true
  if not found: componentFail("missing core function export")

proc hasMemoryParam(sig: ComponentFuncType): bool =
  if sig.paramsUseMemoryArea(): return true
  for i, param in sig.params:
    if param in CanonicalPairs: return true
    if param in ShapedValues and hasPointerPayload(sig.paramArea.slots[i]):
      return true
  false

proc hasMemoryType(sig: ComponentFuncType): bool =
  sig.hasMemoryParam() or sig.resultUsesMemory()

proc supportedHostSignature(sig: ComponentFuncType, linkedResources = false): bool =
  linkedResources or (sig.parameterResources() == {} and
    (not sig.hasResult or sig.resultSlot().resources == {}))

proc coreExportType(module: WasmModule, exp: Export): CoreExportType =
  ## The core validator has checked each export index, including re-exports.
  var index = exp.idx.int
  if exp.kind != ekFunc:
    for imp in module.imports:
      if ord(imp.kind) != ord(exp.kind): continue
      if index == 0:
        case imp.kind
        of ikFunc: break
        of ikTable:
          return CoreExportType(name: exp.name, kind: ekTable,
            tableType: imp.tableType)
        of ikMemory:
          return CoreExportType(name: exp.name, kind: ekMemory,
            memType: imp.memType)
        of ikGlobal:
          return CoreExportType(name: exp.name, kind: ekGlobal,
            globalType: imp.globalType)
        of ikTag:
          return CoreExportType(name: exp.name, kind: ekTag,
            funcType: module.types[imp.tagTypeIdx.int])
      dec index
  case exp.kind
  of ekFunc:
    CoreExportType(name: exp.name, kind: ekFunc,
      funcType: coreFuncType(module, exp.idx))
  of ekTable:
    CoreExportType(name: exp.name, kind: ekTable, tableType: module.tables[index])
  of ekMemory:
    CoreExportType(name: exp.name, kind: ekMemory, memType: module.memories[index])
  of ekGlobal:
    CoreExportType(name: exp.name, kind: ekGlobal,
      globalType: module.globals[index].globalType)
  of ekTag:
    CoreExportType(name: exp.name, kind: ekTag,
      funcType: module.types[module.tagDefs[index].typeIdx.int])

proc coreImportMatches(module: WasmModule, imp: Import,
                       actual: CoreExportType): bool =
  if ord(imp.kind) != ord(actual.kind): return false
  case imp.kind
  of ikFunc: actual.funcType.matchesCoreFunctionType(module.types[imp.funcTypeIdx.int])
  of ikTable:
    importTableTypeMatch(actual.tableType, imp.tableType)
  of ikMemory: importLimitsMatch(actual.memType.limits, imp.memType.limits)
  of ikGlobal: importGlobalTypeMatch(actual.globalType, imp.globalType)
  of ikTag: actual.funcType == module.types[imp.tagTypeIdx.int]

proc decodeCoreModule(image: CoreModuleImage): WasmModule =
  decodeModule(image.bytes, optimize = false, retainCustomSections = false,
    allowFunctionSubtyping = true)

proc embeddedCount(plan: ComponentPlan): int =
  if plan.coreBytes.len == 0: 0 else: 1 + plan.extraCoreBytes.len

proc embeddedCoreBytes(plan: ComponentPlan, index: int): lent seq[byte] =
  if index == 0: return plan.coreBytes
  return plan.extraCoreBytes[index - 1]

proc validatedCoreModule(bytes: openArray[byte]): WasmModule =
  try:
    result = decodeModule(bytes, optimize = false, retainCustomSections = false,
      allowFunctionSubtyping = true)
    validateModule(result, allowMultipleMemories = true, allowFunctionSubtyping = true)
  except CatchableError as e:
    componentFail("invalid embedded core module: " & e.msg)
  if result.imports.len > MaxComponentFunctions or
      result.exports.len > MaxComponentFunctions:
    componentFail("embedded core index-space limit")
  for i, item in result.imports:
    for j in 0 ..< i:
      if item.module == result.imports[j].module and item.name == result.imports[j].name:
        componentFail("duplicate core module import: " & item.module & ":" & item.name)

proc moduleShape(value: CoreModuleValue): CoreModuleShape =
  if value.shape != nil: return value.shape
  if value.image == nil: componentFail("unbound core module type")
  if value.image.shape == nil:
    let module = validatedCoreModule(value.image.bytes)
    new(value.image.shape)
    value.image.shape.types = module.types
    value.image.shape.imports = module.imports
    value.image.shape.exports = module.exports
    value.image.shape.funcTypeIdxs = module.funcTypeIdxs
    value.image.shape.tables = module.tables
    value.image.shape.memories = module.memories
    value.image.shape.tagDefs = module.tagDefs
    for item in module.globals:
      value.image.shape.globals.add(GlobalDef(globalType: item.globalType))
  value.image.shape

proc typeOfImport(module: WasmModule, item: Import): CoreExportType =
  case item.kind
  of ikFunc: CoreExportType(kind: ekFunc, funcType: module.types[item.funcTypeIdx.int])
  of ikTable: CoreExportType(kind: ekTable, tableType: item.tableType)
  of ikMemory: CoreExportType(kind: ekMemory, memType: item.memType)
  of ikGlobal: CoreExportType(kind: ekGlobal, globalType: item.globalType)
  of ikTag: CoreExportType(kind: ekTag, funcType: module.types[item.tagTypeIdx.int])

proc requireModuleSubtype(actual, expected: CoreModuleShape) =
  for item in actual.imports:
    var found = false
    for candidate in expected.imports:
      if item.module == candidate.module and item.name == candidate.name:
        found = true
        if not coreImportMatches(actual[], item, typeOfImport(expected[], candidate)):
          componentFail("core module import type mismatch: " & item.module & ":" & item.name)
        break
    if not found:
      componentFail("core module requires import: " & item.module & ":" & item.name)
  for item in expected.exports:
    var found = false
    for candidate in actual.exports:
      if item.name != candidate.name: continue
      found = true
      let need = coreExportType(expected[], item)
      let have = coreExportType(actual[], candidate)
      var matches = false
      if have.kind == need.kind:
        case need.kind
        of ekFunc: matches = have.funcType.matchesCoreFunctionType(need.funcType)
        of ekTag: matches = have.funcType == need.funcType
        of ekTable:
          matches = importTableTypeMatch(have.tableType, need.tableType)
        of ekMemory: matches = importLimitsMatch(have.memType.limits, need.memType.limits)
        of ekGlobal: matches = importGlobalTypeMatch(have.globalType, need.globalType)
      if not matches:
        componentFail("core module export type mismatch: " & item.name)
      break
    if not found: componentFail("core module lacks export: " & item.name)

proc readCoreModuleSurface(reader: var BinaryReader, parent: ptr ShapeScope): CoreModuleShape =
  new(result)
  let count = reader.readU32()
  if count > MaxComponentFunctions.uint32:
    componentFail("core module type declaration limit")
  for _ in 0 ..< count.int:
    let tag = reader.readByte()
    case tag
    of 1:
      when defined(wasmFunctionReferences):
        let group = reader.readCoreFunctionGroup(result.types, MaxComponentTypes - result.types.len)
        result.types.add(group)
      else:
        if reader.peekByte() == 0x60:
          boundedAdd(result.types, reader.readFuncType(), MaxComponentTypes)
        else:
          let group = reader.readCoreFunctionGroup(result.types, MaxComponentTypes - result.types.len)
          result.types.add(group)
    of 2:
      if reader.readByte() != 0x10 or reader.readByte() != 1:
        componentFail("unsupported core module type alias")
      let depth = reader.readU32()
      let index = reader.readU32()
      var function: FuncType
      if depth == 0:
        if index >= result.types.len.uint32: componentFail("unknown core function type")
        function = result.types[index.int]
      else:
        var outer = parent
        for _ in 1 ..< depth:
          if outer == nil: componentFail("unknown outer core type scope")
          outer = outer.parent
        if outer == nil or index >= outer.coreTypes.len.uint32 or
            outer.coreTypes[index.int].module != nil:
          componentFail("unknown outer core function type")
        function = outer.coreTypes[index.int].function
      boundedAdd(result.types, move function, MaxComponentTypes)
    of 0, 3:
      let importing = tag == 0
      let namespace = if importing: reader.readName() else: ""
      let name = reader.readName()
      if importing:
        for existing in result.imports:
          if existing.module == namespace and existing.name == name:
            componentFail("duplicate core module import: " & namespace & ":" & name)
      else:
        for existing in result.exports:
          if existing.name == name: componentFail("duplicate core module export: " & name)
      var item: Export
      case reader.readByte()
      of 0:
        let index = reader.readU32()
        if index >= result.types.len.uint32: componentFail("unknown core function type")
        if importing:
          result.imports.add(Import(module: namespace, name: name, kind: ikFunc, funcTypeIdx: index))
        else:
          item = Export(name: name, kind: ekFunc, idx: result.funcTypeIdxs.len.uint32)
          result.funcTypeIdxs.add(index)
      of 1:
        let table = reader.readTableType(result.types)
        if table.elemType notin {vtFuncRef, vtExternRef} or
            (table.limits.hasMax and table.limits.min > table.limits.max):
          componentFail("invalid core module table type")
        when defined(wasmSharedCoreTypes):
          if table.limits.shared and not table.elementReference.isSharedCoreReference():
            componentFail("shared core module table requires a shared reference type")
        if importing:
          result.imports.add(Import(module: namespace, name: name, kind: ikTable, tableType: table))
        else:
          item = Export(name: name, kind: ekTable, idx: result.tables.len.uint32)
          result.tables.add(table)
      of 2:
        let memory = reader.readMemType()
        if not memory.limits.validMemoryLimits():
          componentFail("invalid core module memory limits")
        if importing:
          result.imports.add(Import(module: namespace, name: name, kind: ikMemory, memType: memory))
        else:
          item = Export(name: name, kind: ekMemory, idx: result.memories.len.uint32)
          result.memories.add(memory)
      of 3:
        let global = reader.readGlobalType(result.types)
        when defined(wasmSharedCoreTypes):
          if not global.hasValidGlobalSharing():
            componentFail("shared core module global requires a shared reference type")
        if importing:
          result.imports.add(Import(module: namespace, name: name, kind: ikGlobal, globalType: global))
        else:
          item = Export(name: name, kind: ekGlobal, idx: result.globals.len.uint32)
          result.globals.add(GlobalDef(globalType: global))
      of 4:
        let index = reader.readTagType()
        if index >= result.types.len.uint32 or result.types[index.int].results.len != 0:
          componentFail("invalid core module tag type")
        if importing:
          result.imports.add(Import(module: namespace, name: name, kind: ikTag, tagTypeIdx: index))
        else:
          item = Export(name: name, kind: ekTag, idx: result.tagDefs.len.uint32)
          result.tagDefs.add(WasmTagDef(typeIdx: index))
      else: componentFail("unsupported core module external type")
      if not importing: result.exports.add(item)
    else: componentFail("unsupported core module type declaration")
  var importCounts: array[ExportKind, uint32]
  for item in result.imports: inc importCounts[ExportKind(ord(item.kind))]
  for item in result.exports.mitems: item.idx += importCounts[item.kind]

proc readCoreType(data: openArray[byte], pos: var int, stop: int, scope: var ShapeScope) =
  if pos >= stop: componentFail("missing core type")
  var reader = viewBinaryReader(data.toOpenArray(pos, stop - 1))
  try:
    case data[pos]
    of 0x50:
      discard reader.readByte()
      let ty = CoreTypeDeclaration(module: readCoreModuleSurface(reader, addr scope))
      boundedAdd(scope.coreTypes, ty, MaxComponentTypes)
    of 0x00, 0x4e, 0x4f, 0x60, 0x65:
      when not defined(wasmFunctionReferences):
        if data[pos] == 0x60:
          let ty = CoreTypeDeclaration(function: reader.readFuncType())
          boundedAdd(scope.coreTypes, ty, MaxComponentTypes)
          pos = stop - reader.remaining()
          return
      var prior = newSeqOfCap[FuncType](scope.coreTypes.len)
      for entry in scope.coreTypes: prior.add(entry.function)
      let group = reader.readCoreFunctionGroup(prior,
        MaxComponentTypes - scope.coreTypes.len, componentTopLevel = true)
      for signature in group:
        scope.coreTypes.add(CoreTypeDeclaration(function: signature))
    else:
      componentFail("unsupported core type definition")
  except WasmDecodeError as error:
    componentFail("invalid core type: " & error.msg)
  pos = stop - reader.remaining()

proc readModuleTypeRef(data: openArray[byte], pos: var int, stop: int,
                       scope: ShapeScope): CoreModuleShape =
  if take(data, pos, stop) != 0x11: componentFail("expected core module sort")
  let index = takeU32(data, pos, stop)
  if index >= scope.coreTypes.len.uint32 or scope.coreTypes[index.int].module == nil:
    componentFail("unknown core module type")
  scope.coreTypes[index.int].module

proc coreExternals(plan: var ComponentPlan): CoreModuleExternals =
  if plan.links == nil: new(plan.links)
  if plan.links.coreModules == nil: new(plan.links.coreModules)
  plan.links.coreModules

proc addCoreModuleImport(plan: var ComponentPlan, name: string,
                         shape: CoreModuleShape, interfaceImport = false): CoreModuleValue =
  let links = plan.coreExternals()
  result = CoreModuleValue(shape: shape, importIndex: (links.imports.len + 1).uint16)
  boundedAdd(links.imports, NamedCoreModule(name: name, value: result,
    interfaceImport: interfaceImport), MaxComponentCoreModules)

proc addCoreModuleExport(plan: var ComponentPlan, name: string, value: CoreModuleValue) =
  let links = plan.coreExternals()
  boundedAdd(links.exports, NamedCoreModule(name: name, value: value), MaxComponentCoreModules)

proc findModuleName(modules: openArray[NamedCoreModule], name: string): int =
  for i, item in modules:
    if item.name == name: return i
  -1

proc findModuleImport(modules: openArray[NamedCoreModule], name: string): int =
  for i, item in modules:
    if not item.interfaceImport and item.name == name: return i
  -1

proc addInstanceModule(modules: var ref seq[NamedCoreModule], item: sink NamedCoreModule) =
  if modules == nil: new(modules)
  boundedAdd(modules[], move item, MaxComponentCoreModules)

proc addInstanceComponent(components: var ref seq[NamedComponentDefinition],
                          item: sink NamedComponentDefinition) =
  if components == nil: new(components)
  boundedAdd(components[], move item, MaxComponentFunctions)

proc startModuleNamespace(plan: ComponentPlan, modules: var seq[CoreModuleValue]) =
  if modules.len == 0:
    for i in 0 ..< plan.embeddedCount():
      modules.add(CoreModuleValue(embeddedIndex: (i + 1).uint8))

proc typedModuleValue(plan: ComponentPlan, modules: var seq[CoreModuleValue],
                      index: uint32): CoreModuleValue =
  plan.startModuleNamespace(modules)
  if index >= modules.len.uint32: componentFail("unknown core module value")
  let value = addr modules[index.int]
  if value.embeddedIndex != 0 and value.image == nil:
    value.image = CoreModuleImage(bytes: plan.embeddedCoreBytes(value.embeddedIndex.int - 1))
  value[]

proc checkCoreAlias(module: WasmModule, name: string, kind: ExportKind) =
  for exp in module.exports:
    if exp.name == name and exp.kind == kind: return
  componentFail("invalid core export alias")

func lookupResourceType(aliases: openArray[ResourceTypeAlias],
                        typeIndex: uint32): int =
  for i, alias in aliases:
    if alias.typeIndex.uint32 == typeIndex: return i
  -1

func resourceIndex(aliases: openArray[ResourceTypeAlias], typeIndex: uint32): int =
  let index = lookupResourceType(aliases, typeIndex)
  if index < 0: -1 else: aliases[index].resourceIndex.int

proc collectResourceTypes(slot: CanonicalSlot, handles: var seq[uint16]) =
  if slot.resources == {}: return
  case slot.kind
  of cpOwnedResource, cpBorrowedResource:
    handles.add(slot.resourceType)
  of cpList, cpFixedList, cpFuture, cpStream:
    if slot.listElement == nil: return
    collectResourceTypes(slot.listElement[], handles)
  of cpRecord, cpTuple:
    for field in slot.recordShape.fields:
      if field.shape != nil: collectResourceTypes(field.shape[], handles)
  of cpOption, cpVariant, cpResult:
    for item in slot.cases:
      if item.shape != nil: collectResourceTypes(item.shape[], handles)
  else: discard

proc signatureResourceTypes(sig: ComponentFuncType): seq[uint16] =
  for i in 0 ..< sig.params.len:
    collectResourceTypes(parameterSlot(sig, i), result)
  if sig.hasResult: collectResourceTypes(resultSlot(sig), result)

proc requireVisibleResourceSlot(aliases: openArray[ResourceTypeAlias], slot: CanonicalSlot,
    forImport: bool, diagnostic: string, deferred: ptr string = nil,
    scope: ptr ShapeScope = nil) =
  var handles: seq[uint16]
  collectResourceTypes(slot, handles)
  for handle in handles:
    let index = lookupResourceType(aliases, handle.uint32)
    if index < 0:
      visibilityIssue(diagnostic, deferred)
      return
    let alias = unsafeAddr aliases[index]
    let visible = if scope != nil and scope.corePlan != nil and alias.typeName != nil:
        if forImport: alias.typeName in scope.importedResources
        else: alias.typeName in scope.publishedResources
      else: alias.visible and (not forImport or alias.imported)
    if not visible:
      visibilityIssue(diagnostic, deferred)
      return

proc requireVisibleResources(plan: ComponentPlan, signature: ComponentFuncType,
    forImport = false, deferred: ptr string = nil, scope: ptr ShapeScope = nil) =
  for i in 0 ..< signature.params.len:
    requireVisibleResourceSlot(plan.handleTypes, parameterSlot(signature, i), forImport,
      (if forImport: "resource parameter type is not imported"
       else: "resource parameter type is not exported"), deferred, scope)
  if signature.hasResult:
    requireVisibleResourceSlot(plan.handleTypes, resultSlot(signature), forImport,
      (if forImport: "resource result type is not imported"
       else: "resource result type is not exported"), deferred, scope)

proc publishResourceName(scope: ptr ShapeScope, name: ResourceName, importing = false) =
  if name == nil: return
  if name notin scope.publishedResources: scope.publishedResources.add(name)
  if importing and name notin scope.importedResources: scope.importedResources.add(name)
  for alias in scope.resourceAliases[].mitems:
    if alias.typeName == name:
      alias.visible = true
      alias.imported = alias.imported or importing
  if scope.handleTypes != nil:
    for handle in scope.handleTypes[].mitems:
      if handle.typeName == name:
        handle.visible = true
        handle.imported = handle.imported or importing

proc newResourceName(): ResourceName =
  new(result)

proc requireImportedResourceName(scope: ShapeScope, alias: ResourceTypeAlias) =
  if alias.typeName in scope.publishedResources and alias.typeName notin scope.importedResources:
    componentFail("resource type import refers to an exported name")

const NamedValueTypes = {cpRecord, cpVariant, cpEnum, cpFlags}

proc externallyVisible(visibility: TypeVisibility, forImport: bool): bool =
  visibility == tvImported or (not forImport and visibility == tvExported)

proc deferredVisibility(scope: ptr ShapeScope): ptr string =
  if scope.interfaceType != nil: return addr scope.interfaceType.visibilityError

proc requireVisibleChildren(slot: CanonicalSlot, scope: ptr ShapeScope, forImport: bool)

proc outerNameDepth(scope: ptr ShapeScope, index: int): uint16 =
  if scope.outerValueNames != nil:
    for source in scope.outerValueNames[]:
      if source.index.int == index: return source.depth

proc addOuterName(shape: var InterfaceType, name: OuterValueName) =
  if shape.outerNames == nil: new(shape.outerNames)
  if name notin shape.outerNames[]: shape.outerNames[].add(name)

proc noteOuterName(scope, owner: ptr ShapeScope, visibility: TypeVisibility,
                   outerDepth: uint16) {.noinline.} =
  if scope.interfaceType == nil: return
  var depth = outerDepth
  var declaring = scope
  while declaring != owner:
    inc depth
    declaring = declaring.parent
  if depth != 0:
    scope.interfaceType[].addOuterName((depth, visibility))

proc originOfShape(shape: ref CanonicalSlot, scope: ptr ShapeScope): ref CanonicalSlot {.noinline.} =
  result = shape
  var owner = scope
  while owner != nil:
    if owner.rebasedShapes != nil:
      for i in countdown(owner.rebasedShapes[].high, 0):
        let entry = unsafeAddr owner.rebasedShapes[][i]
        if entry.local == result:
          result = entry.origin
    owner = owner.parent

proc rememberShapeOrigin(scope: var ShapeScope, shape, origin: ref CanonicalSlot) =
  if shape == origin: return
  if scope.rebasedShapes == nil: new(scope.rebasedShapes)
  scope.rebasedShapes[].add((shape, origin))

proc namedOrigin(value: NamedValueType): ref CanonicalSlot =
  if value.origin != nil: value.origin else: value.shape

proc hasNamedShape(values: openArray[NamedValueType], shape: ref CanonicalSlot,
                   owner: ptr ShapeScope): bool =
  for value in values:
    if value.shape == shape or value.namedOrigin() == shape or
        originOfShape(value.namedOrigin(), owner) == shape: return true

proc namesFromImport(surface: InterfaceImport, shape: ref CanonicalSlot,
                     owner: ptr ShapeScope): bool =
  if hasNamedShape(surface.valueTypes, shape, owner): return true
  if surface.children != nil:
    for child in surface.children[]:
      if namesFromImport(child, shape, owner): return true

proc exportedInterface[T: ComponentLinks | ComponentLinkState](links: T,
    index: uint16): ptr InterfaceExport

proc namesFromExport(links: ComponentLinks, surface: InterfaceExport,
                     shape: ref CanonicalSlot, owner: ptr ShapeScope): bool =
  if hasNamedShape(surface.valueTypes, shape, owner): return true
  if surface.children != nil:
    for child in surface.children[]:
      if namesFromExport(links, links.exportedInterface(child)[], shape, owner): return true

proc namesFromInstanceType(surface: InterfaceType, shape: ref CanonicalSlot,
                           owner: ptr ShapeScope): bool =
  if hasNamedShape(surface.valueTypes, shape, owner): return true
  if surface.children != nil:
    for child in surface.children[]:
      if namesFromInstanceType(child.definition[], shape, owner): return true

proc interfaceTypeVisibility(owner: ptr ShapeScope, shape: ref CanonicalSlot,
                             forImport: bool): TypeVisibility {.noinline.} =
  if owner.corePlan != nil and owner.corePlan.links != nil:
    let links = owner.corePlan.links
    for item in links.interfaceImports:
      if namesFromImport(item, shape, owner): return tvImported
    if not forImport and links.interfaceExports != nil:
      for item in links.interfaceExports[]:
        if namesFromExport(links, item, shape, owner): return tvExported
  if not forImport and owner.interfaceType != nil and owner.interfaceType.children != nil:
    for member in owner.interfaceType.children[]:
      if namesFromInstanceType(member.definition[], shape, owner): return tvExported

proc requireVisibleReference(shape: ref CanonicalSlot, scope: ptr ShapeScope,
    forImport: bool, diagnostic: string) =
  if shape.kind in NamedValueTypes:
    let origin = originOfShape(shape, scope)
    var owner = scope
    while owner != nil:
      for i, candidate in owner.shapes:
        if candidate != nil and externallyVisible(owner.visible[i], forImport) and
            (candidate == shape or (shape.resources != {} and
              originOfShape(candidate, owner) == origin)):
          noteOuterName(scope, owner, owner.visible[i], owner.outerNameDepth(i))
          return
      let visibility = interfaceTypeVisibility(owner, origin, forImport)
      if visibility != tvPrivate:
        noteOuterName(scope, owner, visibility, 0)
        return
      # Both a concrete component and a component type start a new set of
      # external names. An instance type can still use its enclosing names.
      if owner.corePlan != nil: break
      owner = owner.parent
    visibilityIssue(diagnostic, deferredVisibility(scope))
    return
  requireVisibleChildren(shape[], scope, forImport)

proc requireVisibleChildren(slot: CanonicalSlot, scope: ptr ShapeScope, forImport: bool) =
  case slot.kind
  of cpList, cpFixedList:
    requireVisibleReference(slot.listElement, scope, forImport,
      "named component list element type is not externally visible")
  of cpFuture, cpStream:
    if slot.listElement != nil:
      requireVisibleReference(slot.listElement, scope, forImport,
        "named component " & endpointName(slot.kind) & " payload type is not externally visible")
  of cpMap:
    requireVisibleChildren(slot.listElement[], scope, forImport)
  of cpRecord, cpTuple:
    for field in slot.recordShape.fields:
      if field.shape != nil:
        requireVisibleReference(field.shape, scope, forImport,
          "named component field type is not externally visible")
  of cpOption, cpVariant, cpResult:
    for item in slot.cases:
      if item.shape != nil:
        requireVisibleReference(item.shape, scope, forImport,
          "named component case payload type is not externally visible")
  else: discard

proc requireVisibleValueTypes(sig: ComponentFuncType, scope: var ShapeScope,
                              forImport = false, origin: ptr ShapeScope = nil) =
  let declaration = if origin == nil: addr scope else: origin
  for i, kind in sig.params:
    if kind in NamedValueTypes:
      requireVisibleReference(canonicalShape(sig.paramTypeIndices[i], declaration.shapes),
        addr scope, forImport, "named component parameter type is not externally visible")
    elif kind in ShapedValues:
      requireVisibleChildren(sig.paramArea.slots[i], addr scope, forImport)
  if not sig.hasResult: return
  if sig.resultType in NamedValueTypes:
    requireVisibleReference(canonicalShape(sig.resultTypeIndex, declaration.shapes),
      addr scope, forImport, "named component result type is not externally visible")
  elif sig.resultType in ShapedValues:
    requireVisibleChildren(sig.resultShape[], addr scope, forImport)

proc functionTypeOrigin(scope: ptr ShapeScope, index: uint32): FunctionTypeOrigin =
  if scope.functionOrigins != nil:
    for origin in scope.functionOrigins[]:
      if origin.aliasIndex.uint32 == index: return origin
  FunctionTypeOrigin(typeIndex: index.uint16, scope: scope)

proc requireVisibleFunctionType(scope: var ShapeScope, index: uint32,
                                forImport = false) =
  let original = functionTypeOrigin(addr scope, index)
  if original.scope != nil:
    requireVisibleValueTypes(original.scope.functionTypes[][original.typeIndex.int], scope,
      forImport, original.scope)
  elif original.names != nil:
    for item in original.names[]:
      requireVisibleReference(item.shape, addr scope, forImport, item.diagnostic)

proc collectFunctionTypeNames(slot: CanonicalSlot, scope: ptr ShapeScope,
                              names: var FunctionTypeNames)

proc collectFunctionTypeName(shape: ref CanonicalSlot, scope: ptr ShapeScope,
                             diagnostic: string, names: var FunctionTypeNames) =
  if shape.kind in NamedValueTypes:
    if names == nil: new(names)
    names[].add((originOfShape(shape, scope), diagnostic))
  else:
    collectFunctionTypeNames(shape[], scope, names)

proc collectFunctionTypeNames(slot: CanonicalSlot, scope: ptr ShapeScope,
                              names: var FunctionTypeNames) =
  case slot.kind
  of cpList, cpFixedList:
    collectFunctionTypeName(slot.listElement, scope,
      "named component list element type is not externally visible", names)
  of cpMap:
    collectFunctionTypeNames(slot.listElement[], scope, names)
  of cpRecord, cpTuple:
    for field in slot.recordShape.fields:
      if field.shape != nil:
        collectFunctionTypeName(field.shape, scope,
          "named component field type is not externally visible", names)
  of cpOption, cpVariant, cpResult:
    for item in slot.cases:
      if item.shape != nil:
        collectFunctionTypeName(item.shape, scope,
          "named component case payload type is not externally visible", names)
  else: discard

proc functionTypeNames(scope: ptr ShapeScope, index: uint32): FunctionTypeNames =
  let declaration = functionTypeOrigin(scope, index)
  if declaration.scope == nil: return declaration.names
  let owner = declaration.scope
  let sig = unsafeAddr owner.functionTypes[][declaration.typeIndex.int]
  for i, kind in sig.params:
    if kind in NamedValueTypes:
      collectFunctionTypeName(canonicalShape(sig.paramTypeIndices[i], owner.shapes), owner,
        "named component parameter type is not externally visible", result)
    elif kind in ShapedValues:
      collectFunctionTypeNames(sig.paramArea.slots[i], owner, result)
  if sig.resultShape != nil:
    collectFunctionTypeName(sig.resultShape, owner,
      "named component result type is not externally visible", result)

proc namedFunctionType(scope: ptr ShapeScope, index: uint32, name: string): NamedFunctionType =
  NamedFunctionType(name: name, signature: scope.functionTypes[][index.int],
    names: functionTypeNames(scope, index))

proc addNamedFunctionType(types: var ExternalTypeSurface, item: sink NamedFunctionType) =
  if types == nil: new(types)
  if types.functions == nil: new(types.functions)
  boundedAdd(types.functions[], move item, MaxComponentTypes)

template functionsIn(types: ExternalTypeSurface): ref seq[NamedFunctionType] =
  (if types == nil: nil else: types.functions)

template componentsIn(types: ExternalTypeSurface): ref seq[NamedComponentType] =
  (if types == nil: nil else: types.components)

template instancesIn(types: ExternalTypeSurface): ref seq[NamedInstanceType] =
  (if types == nil: nil else: types.instances)

template functionTypes(surface: InterfaceType | ref InterfaceType | ptr InterfaceType |
                                InterfaceImport | InterfaceExport | ptr InterfaceExport |
                                DeclaredInstance): ref seq[NamedFunctionType] =
  functionsIn(surface.typeExternals)

template functionTypeImports(links: ComponentLinks): ref seq[NamedFunctionType] =
  functionsIn(links.typeImports)

template functionTypeExports(links: ComponentLinks): ref seq[NamedFunctionType] =
  functionsIn(links.typeExports)

proc addExportedFunctionType(types: var ExternalTypeSurface, order: var VisibilityOrder,
                             item: sink NamedFunctionType) =
  if item.names != nil or signatureResourceTypes(item.signature).len != 0:
    let existing = functionsIn(types)
    order.addMember(vmFunctionType, if existing == nil: 0 else: existing[].len)
  types.addNamedFunctionType(move item)

proc addFunctionAlias(scope: var ShapeScope, signature: ComponentFuncType,
                      origin: FunctionTypeOrigin) =
  if scope.kinds.len >= MaxComponentTypes: componentFail("component type index-space limit")
  if origin.scope != addr scope:
    var alias = origin
    alias.aliasIndex = scope.kinds.len.uint16
    if scope.functionOrigins == nil: new(scope.functionOrigins)
    scope.functionOrigins[].add(alias)
  scope.kinds.add(cpFunctionType)
  scope.functionTypes[].add(signature)

proc isFunctionType(scope: ShapeScope, index: uint32): bool =
  index < scope.kinds.len.uint32 and scope.kinds[index.int] == cpFunctionType

proc externFunctionType(scope: var ShapeScope, index: uint32, name: string,
                        importing = false): NamedFunctionType {.noinline.} =
  requireVisibleFunctionType(scope, index, forImport = importing)
  result = namedFunctionType(addr scope, index, name)
  if scope.handleTypes != nil:
    ComponentPlan(handleTypes: scope.handleTypes[]).requireVisibleResources(result.signature,
      forImport = importing, deferred = deferredVisibility(addr scope), scope = addr scope)
  scope.addFunctionAlias(result.signature, functionTypeOrigin(addr scope, index))

proc addPlanFunctionType(plan: var ComponentPlan, scope: var ShapeScope, index: uint32,
                         name: string, importing: bool) {.noinline.} =
  let declaration = externFunctionType(scope, index, name, importing)
  if plan.links == nil: new(plan.links)
  if importing: plan.links.typeImports.addNamedFunctionType(declaration)
  else: plan.links.typeExports.addExportedFunctionType(plan.links.visibilityOrder, declaration)

proc coreFunctionSource(fn: CoreFunction, instances: openArray[CoreInstance]): uint16 =
  case fn.kind
  of cfAlias: instances[fn.coreInstance.int].storeIndex.uint16 + 1
  of cfLower: GeneratedCoreSource or fn.loweringIndex.uint16

proc markCoreFunctionReference(plan: var ComponentPlan, fn: CoreFunction) =
  if fn.kind == cfLower:
    plan.lowerings[fn.loweringIndex.int].generatedReference = true

proc addLowering(plan: var ComponentPlan, lowering: sink CoreLowering) =
  lowering.afterCores = plan.instances.len.uint8
  if plan.links != nil:
    lowering.afterChildren = plan.links.children.len.uint8
  boundedAdd(plan.lowerings, move lowering, MaxComponentFunctions)

proc describeLift(lifted: ComponentFunction,
    types: openArray[ComponentFuncType], instances: openArray[CoreInstance],
    coreFunctions: openArray[CoreFunction],
    memories: openArray[CoreExportAlias]): ComponentExport =
  let target = unsafeAddr coreFunctions[lifted.coreFunction.int]
  result.coreName = target.name
  result.signature = types[lifted.typeIndex.int]
  result.stringEncoding = lifted.stringEncoding
  result.coreSources[clsFunction] = coreFunctionSource(target[], instances)
  when defined(wasmComponentAsyncCallbacks):
    if lifted.callbackFunction != 0:
      let callback = unsafeAddr coreFunctions[lifted.callbackFunction.int - 1]
      result.callbackSource = coreFunctionSource(callback[], instances)
      result.callbackName = callback.name
  when defined(wasmComponentStackful):
    result.stackful = lifted.stackful
  if lifted.memoryAlias >= 0:
    let source = unsafeAddr memories[lifted.memoryAlias.int]
    result.memoryName = source.name
    result.coreSources[clsMemory] = instances[source.coreInstance.int].storeIndex + 1
  if lifted.reallocFunction >= 0:
    let source = unsafeAddr coreFunctions[lifted.reallocFunction.int]
    result.reallocName = source.name
    result.coreSources[clsRealloc] = coreFunctionSource(source[], instances)
  if lifted.postReturnFunction >= 0:
    let source = unsafeAddr coreFunctions[lifted.postReturnFunction.int]
    result.postReturnName = source.name
    result.coreSources[clsPostReturn] = coreFunctionSource(source[], instances)

proc exportedInterface[T: ComponentLinks | ComponentLinkState](links: T,
    index: uint16): ptr InterfaceExport =
  if (index and NestedInterfaceIndex) != 0:
    return unsafeAddr links.nestedInterfaceExports[][int(index and not NestedInterfaceIndex)]
  return unsafeAddr links.interfaceExports[][index.int - 1]

proc interfaceExportCount[T: ComponentLinks | ComponentLinkState](links: T): int =
  if links != nil and links.interfaceExports != nil: links.interfaceExports[].len else: 0

proc appendInterfaceExport(links: ComponentLinks, surface: sink InterfaceExport) =
  if surface.coreModules != nil or surface.components != nil: links.hasInterfaceDefinitions = true
  if links.interfaceExports == nil: new(links.interfaceExports)
  boundedAdd(links.interfaceExports[], move surface, MaxComponentFunctions)

proc appendNestedExport(links: ComponentLinks, surface: sink InterfaceExport): uint16 =
  if surface.coreModules != nil or surface.components != nil: links.hasInterfaceDefinitions = true
  if links.nestedInterfaceExports == nil: new(links.nestedInterfaceExports)
  result = NestedInterfaceIndex or links.nestedInterfaceExports[].len.uint16
  boundedAdd(links.nestedInterfaceExports[], move surface, MaxComponentFunctions)

proc childFunctionExport(links: ComponentLinks, index: int): ptr ComponentExport =
  let alias = links.aliases[index]
  let child = links.children[alias.childIndex.int].plan
  if alias.interfaceIndex == 0:
    addr child.exports[alias.exportIndex.int]
  else:
    addr child.links.exportedInterface(alias.interfaceIndex).methods[alias.exportIndex.int]

proc describeFunction(fn: ComponentFunction, plan: ComponentPlan,
    types: openArray[ComponentFuncType], instances: openArray[CoreInstance],
    coreFunctions: openArray[CoreFunction],
    memories: openArray[CoreExportAlias]): ComponentExport =
  case fn.kind
  of fnLift:
    result = describeLift(fn, types, instances, coreFunctions, memories)
  of fnImport:
    result.target = ctImport
    result.targetIndex = fn.importIndex.uint16
    result.signature = plan.imports[fn.importIndex.int].signature
  of fnChild:
    result.target = ctChild
    result.targetIndex = fn.importIndex.uint16
    result.signature = childFunctionExport(plan.links, fn.importIndex.int).signature

proc loweringSignature(plan: ComponentPlan, lowering: CoreLowering): ComponentFuncType =
  if lowering.resourceSignature != nil: return lowering.resourceSignature[]
  case lowering.kind
  of clHost: plan.imports[lowering.targetIndex.int].signature
  of clChild: childFunctionExport(plan.links, lowering.targetIndex.int).signature
  of clLocal: lowering.localTarget.signature
  else: componentFail("canonical lowering has no component signature")

proc generatedCoreType(plan: ComponentPlan, lowering: CoreLowering): FuncType =
  if lowering.kind == clContextGet: return FuncType(results: @[vtI32])
  if lowering.kind == clContextSet: return FuncType(params: @[vtI32])
  if lowering.kind == clTaskReturn:
    let signature = lowering.resourceSignature
    if signature.hasResult:
      let slot = resultSlot(signature[])
      let width = flatSlotWidth(slot)
      if width > MaxFlatParams:
        result.params.add(vtI32)
      else:
        for i in 0 ..< width: result.params.add(flatLaneType(slot, i))
    return
  case lowering.kind
  of clErrorContextNew: return FuncType(params: @[vtI32, vtI32], results: @[vtI32])
  of clErrorContextDebugMessage: return FuncType(params: @[vtI32, vtI32])
  of clErrorContextDrop: return FuncType(params: @[vtI32])
  of clWaitableSetNew, clThreadYield, clThreadIndex, clThreadSuspend,
     clThreadAvailableParallelism:
    return FuncType(results: @[vtI32])
  of clWaitableSetDrop, clSubtaskDrop, clThreadResumeLater:
    return FuncType(params: @[vtI32])
  of clThreadSuspendResume .. clThreadYieldPromote:
    return FuncType(params: @[vtI32], results: @[vtI32])
  of clThreadNewIndirect:
    when defined(wasmComponentThreads):
      return FuncType(params: @[vtI32, lowering.threadClosure], results: @[vtI32])
    else: componentFail("guest thread operations are disabled")
  of clThreadSpawnRef:
    when defined(wasmComponentThreadSpawn):
      result = FuncType(params: @[vtFuncRef, lowering.threadSignature.params[0]],
        results: @[vtI32])
      new(result.references)
      result.references.params = @[lowering.threadSignature[].coreFunctionReference()]
      return
    else: componentFail("canonical thread spawning is disabled")
  of clWaitableSetPoll, clWaitableSetWait:
    return FuncType(params: @[vtI32, vtI32], results: @[vtI32])
  of clWaitableJoin: return FuncType(params: @[vtI32, vtI32])
  of clBackpressureInc, clBackpressureDec, clTaskCancel: return FuncType()
  of clSubtaskCancel: return FuncType(params: @[vtI32], results: @[vtI32])
  of clEndpointNew: return FuncType(results: @[vtI64])
  of clEndpointRead, clEndpointWrite:
    when ComponentEndpointsEnabled:
      if lowering.endpointShape.kind == cpStream:
        return FuncType(params: @[vtI32, vtI32, vtI32], results: @[vtI32])
    return FuncType(params: @[vtI32, vtI32], results: @[vtI32])
  of clEndpointCancelRead, clEndpointCancelWrite:
    return FuncType(params: @[vtI32], results: @[vtI32])
  of clEndpointDropReadable, clEndpointDropWritable: return FuncType(params: @[vtI32])
  of clEndpointForward: return FuncType(params: @[vtI32, vtI32])
  else: discard
  if lowering.kind notin {clHost, clChild, clLocal}:
    result.params = @[vtI32]
    if lowering.kind != clResourceDrop: result.results = @[vtI32]
    return
  let signature = loweringSignature(plan, lowering)
  let indirect = when defined(wasmComponentAsyncCallbacks):
    if lowering.asyncLower: signature.flatParamCount() > MaxFlatAsyncParams
    else: signature.paramsUseMemoryArea()
  else: signature.paramsUseMemoryArea()
  if indirect:
    result.params.add(vtI32)
  else:
    for i, kind in signature.params:
      let slot = if kind in ShapedValues: signature.paramArea.slots[i]
        else: CanonicalSlot(kind: kind)
      for lane in 0 ..< flatSlotWidth(slot):
        result.params.add(flatLaneType(slot, lane))
  when defined(wasmComponentAsyncCallbacks):
    if lowering.asyncLower:
      if signature.asyncResultArea(): result.params.add(vtI32)
      result.results.add(vtI32)
      return
  if signature.resultUsesMemory():
    result.params.add(vtI32)
  elif signature.hasResult:
    result.results.add(coreResultType(signature))

proc requireGeneratedCoreType(plan: var ComponentPlan, fn: CoreFunction,
    expected: FuncType, diagnostic: string) =
  if plan.generatedCoreType(plan.lowerings[fn.loweringIndex.int]) != expected:
    componentFail(diagnostic)
  plan.markCoreFunctionReference(fn)

proc `==`(left, right: CanonicalSlot): bool =
  if left.offset != right.offset or left.kind != right.kind or
      left.listLength != right.listLength or left.cases.len != right.cases.len:
    return false
  for i, item in left.cases:
    let other = unsafeAddr right.cases[i]
    if item.name != other.name or item.hasPayload != other.hasPayload or
        item.payloadKind != other.payloadKind:
      return false
    if item.shape != other.shape and caseSlot(item) != caseSlot(other[]):
      return false
  if left.listElement != right.listElement:
    if left.listElement == nil or right.listElement == nil or
        left.listElement[] != right.listElement[]:
      return false
  if left.recordShape == nil or right.recordShape == nil:
    return left.recordShape == nil and right.recordShape == nil
  if left.recordShape == right.recordShape: return true
  if left.recordShape.fields.len != right.recordShape.fields.len: return false
  for i, field in left.recordShape.fields:
    let other = unsafeAddr right.recordShape.fields[i]
    if field.name != other.name or field.kind != other.kind: return false
    if field.shape != other.shape and fieldSlot(field) != fieldSlot(other[]):
      return false
  true

proc matchComponentFunction(actual, expected: ComponentFuncType): bool =
  if actual.params != expected.params or actual.paramNames != expected.paramNames or
      actual.asyncSignature() != expected.asyncSignature() or
      actual.hasResult != expected.hasResult or
      (expected.hasResult and actual.resultType != expected.resultType):
    return false
  if actual.resultShape == nil or expected.resultShape == nil:
    if actual.resultShape != nil or expected.resultShape != nil: return false
  elif actual.resultShape[] != expected.resultShape[]:
    return false
  if actual.paramArea == nil or expected.paramArea == nil:
    return actual.paramArea == nil and expected.paramArea == nil
  actual.paramArea.slots == expected.paramArea.slots

proc resourceOfExport(plan: ComponentPlan, exp: ComponentExport, index: int32): int =
  if exp.target != ctChild:
    return resourceIndex(plan.handleTypes, index.uint32)
  let alias = plan.links.aliases[exp.targetIndex.int]
  let node = unsafeAddr plan.links.children[alias.childIndex.int]
  let source = if alias.interfaceIndex == 0:
      unsafeAddr node.plan.exports[alias.exportIndex.int]
    else:
      unsafeAddr node.plan.links.exportedInterface(alias.interfaceIndex)[]
        .methods[alias.exportIndex.int]
  let index = resourceOfExport(node.plan[], source[], index)
  if index < 0 or index >= node.resourceArgs.len: return -1
  node.resourceArgs[index].int - 1

proc bindResourceHandleIndex(plan: var ComponentPlan, resource: uint16,
                             visibility = tvImported, name: ResourceName = nil): int32 =
  # A handle used by a function imported from another scope has no local
  # declaration in the component's own type index space.
  let bank = case visibility
    of tvImported: 0
    of tvExported: 1
    of tvPrivate: 2
  const NamedHandleStart = MaxComponentTypes + 3 * MaxComponentResourceTypes
  if name != nil:
    for alias in plan.handleTypes:
      if alias.typeIndex.int >= NamedHandleStart and alias.typeName == name and
          alias.resourceIndex == resource and alias.imported == (visibility == tvImported):
        return alias.typeIndex.int32
    let ordinal = NamedHandleStart + plan.handleTypes.len
    if ordinal > uint16.high.int: componentFail("component resource alias limit")
    plan.handleTypes.add(ResourceTypeAlias(typeIndex: ordinal.uint16,
      resourceIndex: resource, visible: visibility != tvPrivate, imported: visibility == tvImported,
      typeName: name))
    return ordinal.int32
  let typeIndex = (MaxComponentTypes + bank * MaxComponentResourceTypes + resource.int).uint16
  if lookupResourceType(plan.handleTypes, typeIndex.uint32) < 0:
    plan.handleTypes.add(ResourceTypeAlias(typeIndex: typeIndex,
      resourceIndex: resource, visible: visibility != tvPrivate, imported: visibility == tvImported))
  typeIndex.int32

type ResourceTypeMapping = seq[tuple[source, target: uint16]]

proc mappedHandle(mapping: ResourceTypeMapping, source: uint16): uint16 =
  for entry in mapping:
    if entry.source == source: return entry.target
  componentFail("unbound canonical resource type")

proc rebaseResourceSlot(slot: CanonicalSlot, mapping: ResourceTypeMapping,
                        origins: RebasedShapes = nil): CanonicalSlot

proc rebaseResourceShape(shape: ref CanonicalSlot, mapping: ResourceTypeMapping,
                         origins: RebasedShapes): ref CanonicalSlot =
  if shape == nil or shape.resources * {ruOwn, ruBorrow} == {}: return shape
  result = newSlot(rebaseResourceSlot(shape[], mapping, origins))
  if origins != nil and shape.kind in NamedValueTypes:
    origins[].add((result, shape))

proc rebaseResourceSlot(slot: CanonicalSlot, mapping: ResourceTypeMapping,
                        origins: RebasedShapes): CanonicalSlot =
  result = slot
  if slot.resources == {}: return
  case slot.kind
  of cpOwnedResource, cpBorrowedResource:
    result.resourceType = mappedHandle(mapping, slot.resourceType)
  of cpList, cpFixedList, cpFuture, cpStream:
    result.listElement = rebaseResourceShape(slot.listElement, mapping, origins)
  of cpRecord, cpTuple:
    result.recordShape = new(RecordShape)
    result.recordShape[] = slot.recordShape[]
    for field in result.recordShape.fields.mitems:
      if field.shape != nil and field.shape.resources != {}:
        field.shape = rebaseResourceShape(field.shape, mapping, origins)
  of cpOption, cpVariant, cpResult:
    for item in result.cases.mitems:
      if item.shape != nil and item.shape.resources != {}:
        item.shape = rebaseResourceShape(item.shape, mapping, origins)
  else: discard

proc projectValueShape(shape: ref CanonicalSlot, node: var ChildInstantiation,
                       handles: ResourceTypeMapping): ref CanonicalSlot =
  ## Substitute the actual type names at the child boundary. Structural
  ## equality alone cannot establish which name an exported field refers to.
  for binding in node.valueTypeArguments[]:
    if binding.local == shape: return binding.origin
  if node.projectedValueTypes != nil:
    for binding in node.projectedValueTypes[]:
      if binding.local == shape: return binding.origin
  var view = shape[]
  var changed = false
  case shape.kind
  of cpOwnedResource, cpBorrowedResource:
    view.resourceType = mappedHandle(handles, shape.resourceType)
    changed = view.resourceType != shape.resourceType
  of cpList, cpMap, cpFixedList:
    view.listElement = projectValueShape(shape.listElement, node, handles)
    changed = view.listElement != shape.listElement
  of cpFuture, cpStream:
    if shape.listElement != nil:
      view.listElement = projectValueShape(shape.listElement, node, handles)
      changed = view.listElement != shape.listElement
  of cpRecord, cpTuple:
    for i, field in shape.recordShape.fields:
      if field.shape == nil: continue
      let member = projectValueShape(field.shape, node, handles)
      if member == field.shape: continue
      if not changed:
        new(view.recordShape)
        view.recordShape[] = shape.recordShape[]
        changed = true
      view.recordShape.fields[i].shape = member
  of cpOption, cpVariant, cpResult:
    for i, item in shape.cases:
      if item.shape == nil: continue
      let member = projectValueShape(item.shape, node, handles)
      if member == item.shape: continue
      view.cases[i].shape = member
      changed = true
  else: discard
  if not changed: return shape
  result = newSlot(view)
  if node.projectedValueTypes == nil: new(node.projectedValueTypes)
  node.projectedValueTypes[].add((shape, result))

proc rebaseResourceSignature(sig: ComponentFuncType,
                             mapping: ResourceTypeMapping): ComponentFuncType =
  result = sig
  if mapping.len == 0: return
  for i, kind in sig.params:
    if kind in ResourceValues:
      result.paramTypeIndices[i] = mappedHandle(mapping, sig.paramTypeIndices[i].uint16).int32
  if sig.paramArea != nil and sig.parameterResources() != {}:
    result.paramArea = new(CanonicalParams)
    result.paramArea[] = sig.paramArea[]
    for slot in result.paramArea.slots.mitems:
      if slot.resources != {}:
        slot = rebaseResourceSlot(slot, mapping)
  if sig.hasResult:
    if sig.resultType in ResourceValues:
      result.resultTypeIndex = mappedHandle(mapping, sig.resultTypeIndex.uint16).int32
    elif sig.resultShape != nil and sig.resultShape.resources != {}:
      result.resultShape = newSlot(rebaseResourceSlot(sig.resultShape[], mapping))

proc resourceNames(signature: ComponentFuncType,
                   handles: openArray[ResourceTypeAlias]): ResourceNames =
  for index in signatureResourceTypes(signature):
    let alias = lookupResourceType(handles, index.uint32)
    if alias < 0: componentFail("unknown component function resource type")
    if result == nil: new(result)
    result[].add(handles[alias].typeName)

proc matchResourceBindings(plan: ComponentPlan, exp: ComponentExport,
    expected: ComponentFuncType, expectedTypes: openArray[ResourceTypeAlias],
    arguments: openArray[uint16], substitute: bool): bool =
  let actualHandles = signatureResourceTypes(exp.signature)
  let expectedHandles = signatureResourceTypes(expected)
  if actualHandles.len != expectedHandles.len: return false
  for i, actualType in actualHandles:
    let actual = resourceOfExport(plan, exp, actualType.int32)
    let target = resourceIndex(expectedTypes, expectedHandles[i].uint32)
    if actual < 0 or target < 0: return false
    if substitute:
      if target >= arguments.len or arguments[target].int != actual + 1: return false
    elif actual != target: return false
  true

proc checkResourceMemberName(plan: ComponentPlan, exp: ComponentExport,
                             visible: openArray[NamedResourceType]) =
  let member = resourceMember(exp.name)
  if member.kind == rmNone: return
  let name = exp.name[member.first ..< member.dot]
  var handleType = -1'i32
  case member.kind
  of rmConstructor:
    if exp.signature.hasResult:
      if exp.signature.resultType == cpOwnedResource:
        handleType = exp.signature.resultTypeIndex
      elif exp.signature.resultType == cpResult:
        let ok = exp.signature.resultShape.cases[0]
        if ok.hasPayload and ok.payloadKind == cpOwnedResource:
          handleType = ok.shape.resourceType.int32
    if handleType < 0: componentFail("constructor must return an owned resource")
  of rmMethod:
    if exp.signature.params.len == 0 or exp.signature.params[0] != cpBorrowedResource or
        exp.signature.paramNames[0] != "self":
      componentFail("resource method requires a self borrow")
    handleType = exp.signature.paramTypeIndices[0]
  of rmStatic, rmNone: discard
  for item in visible:
    if item.name != name: continue
    if handleType < 0: return
    if resourceOfExport(plan, exp, handleType) != item.resourceIndex.int:
      componentFail("resource member signature must use its named resource")
    if exp.target == ctChild:
      var parameters: seq[uint16]
      if member.kind == rmConstructor:
        for i in 0 ..< exp.signature.params.len:
          collectResourceTypes(parameterSlot(exp.signature, i), parameters)
      if exp.resourceNames == nil or parameters.len >= exp.resourceNames[].len or
          exp.resourceNames[][parameters.len] != item.typeName:
        componentFail("resource member signature must use its named resource")
    else:
      let index = lookupResourceType(plan.handleTypes, handleType.uint32)
      if index < 0 or plan.handleTypes[index].typeName != item.typeName:
        componentFail("resource member signature must use its named resource")
    return
  componentFail("resource member names a type absent from its interface")

const StoredValueTypes = PrimitiveValues + ShapedValues + ResourceValues +
  {cpBytes, cpU32List, cpU64List}

proc typeDepth(slot: CanonicalSlot): int =
  case slot.kind
  of cpList, cpFixedList: 1 + typeDepth(slot.listElement[])
  of cpFuture, cpStream: (if slot.listElement == nil: 1 else: 1 + typeDepth(slot.listElement[]))
  of cpMap: typeDepth(slot.listElement[])
  of cpRecord, cpTuple: slot.recordShape.depth.int
  of cpOption, cpVariant, cpResult:
    result = 1
    for item in slot.cases:
      if item.hasPayload: result = max(result, 1 + typeDepth(caseSlot(item)))
    return
  else: 0

proc typeNodes(slot: CanonicalSlot): int =
  case slot.kind
  of cpList, cpFixedList: 1 + typeNodes(slot.listElement[])
  of cpFuture, cpStream: (if slot.listElement == nil: 1 else: 1 + typeNodes(slot.listElement[]))
  of cpMap: typeNodes(slot.listElement[])
  of cpRecord, cpTuple: slot.recordShape.typeNodes.int
  of cpOption, cpVariant, cpResult:
    result = 1
    for item in slot.cases:
      if item.hasPayload: result += typeNodes(caseSlot(item))
    return
  else: 1

proc newRecordShape(count: int): RecordShape =
  RecordShape(fields: newSeqOfCap[ComponentRecordField](count),
    layout: (0, 1), typeNodes: 1, depth: 1)

proc valueField(kind: ComponentPrim, index: int32, scope: ShapeScope): ComponentRecordField =
  result.kind = kind
  if kind in ShapedValues:
    result.shape = canonicalShape(index, scope.shapes)
  elif kind in ResourceValues:
    result.shape = newSlot(handleSlot(kind, index))
  elif kind == cpErrorContext:
    result.shape = newSlot(plainValueSlot(kind))

proc appendRecordField(record: RecordShape, field: sink ComponentRecordField,
                       checkSize = true) =
  let slot = fieldSlot(field)
  let layout = canonicalSlotLayout(slot)
  let offset = abiAlign(record.layout.size, layout.alignment)
  record.layout.size = offset + layout.size
  record.layout.alignment = max(record.layout.alignment, layout.alignment)
  let nodes = record.typeNodes.int + typeNodes(slot)
  if checkSize and record.layout.size >= MaxCanonicalValueBytes:
    componentFail("component type exceeds maximum byte size")
  if nodes > MaxIndirectParamBytes:
    componentFail("component record layout exceeds profile limit")
  let depth = 1 + typeDepth(slot)
  if depth > MaxValueTypeNesting:
    componentFail("component value type nesting exceeds profile limit")
  field.offset = offset.uint32
  record.depth = max(record.depth, depth.uint8)
  record.typeNodes = nodes.uint16
  record.flatWidth = min(MaxFlatParams + 1, record.flatWidth.int + flatSlotWidth(slot)).uint16
  record.hasPointers = record.hasPointers or hasPointerPayload(slot)
  record.resources = record.resources + slot.resources
  record.fields.add(move field)

proc finishRecordLayout(record: RecordShape) =
  record.layout.size = abiAlign(record.layout.size, record.layout.alignment)

proc readRecordShape(data: openArray[byte], pos: var int, stop: int,
    scope: var ShapeScope, kind: ComponentPrim): RecordShape =
  let count = takeCount(data, pos, stop, MaxComponentRecordFields)
  if count == 0: componentFail("empty component record or tuple")
  result = newRecordShape(count)
  for _ in 0 ..< count:
    var name: string
    if kind == cpRecord:
      name = takeLabel(data, pos, stop)
      for previous in result.fields:
        if sameCanonicalName(previous.name, name):
          componentFail("duplicate component record field")
    let value = takeValType(data, pos, stop, scope.kinds)
    var field = valueField(value.kind, value.index, scope)
    field.name = move name
    result.appendRecordField(move field)
  result.finishRecordLayout()

proc readCasePayload(item: var ComponentVariantCase, data: openArray[byte],
                     pos: var int, stop: int, scope: ShapeScope) =
  let payload = takeValType(data, pos, stop, scope.kinds)
  item.hasPayload = true
  item.payloadKind = payload.kind
  if payload.kind in ShapedValues:
    item.shape = canonicalShape(payload.index, scope.shapes)
  elif payload.kind in ResourceValues:
    item.shape = newSlot(handleSlot(payload.kind, payload.index))
  elif payload.kind == cpErrorContext:
    item.shape = newSlot(plainValueSlot(payload.kind))

proc saveVariant(scope: var ShapeScope, kind: ComponentPrim,
                 cases: sink seq[ComponentVariantCase]) =
  var shape = CanonicalSlot(kind: kind, cases: move cases)
  for item in shape.cases:
    if item.shape != nil:
      shape.resources = shape.resources + item.shape.resources
  if typeDepth(shape) > MaxValueTypeNesting:
    componentFail("component value type nesting exceeds profile limit")
  if typeNodes(shape) > MaxIndirectParamBytes:
    componentFail("component variant layout exceeds profile limit")
  validateCanonicalTypeSize(shape)
  scope.kinds.add(kind)
  scope.saveShape(shape)

proc readValueDefinition(data: openArray[byte], pos: var int, stop: int,
                         scope: var ShapeScope): bool =
  if pos >= stop: componentFail("truncated component type")
  if data[pos] in 0x73'u8 .. 0x7f'u8 or data[pos] == 0x64'u8:
    scope.kinds.add(takePrim(data, pos, stop))
  elif (data[pos] == 0x65'u8 and defined(wasmComponentFutures)) or
       (data[pos] == 0x66'u8 and defined(wasmComponentStreams)):
    let kind = if data[pos] == 0x66: cpStream else: cpFuture
    inc pos
    var shape = CanonicalSlot(kind: kind, resources: {ruEndpoint})
    case take(data, pos, stop)
    of 0: discard
    of 1:
      let payload = takeValType(data, pos, stop, scope.kinds)
      if kind == cpStream and payload.kind == cpChar:
        componentFail("stream element type cannot be char")
      shape.listElement = if payload.kind in ShapedValues:
        canonicalShape(payload.index, scope.shapes)
      else:
        newSlot(canonicalSlot(payload.kind, payload.index, scope.shapes))
      shape.resources = shape.resources + shape.listElement.resources
      if ruBorrow in shape.resources:
        componentFail(endpointName(kind) & " payload contains a borrowed resource")
      if typeDepth(shape) > MaxValueTypeNesting or typeNodes(shape) > MaxIndirectParamBytes:
        componentFail("canonical " & endpointName(kind) & " payload exceeds type shape limits")
    else: componentFail("invalid canonical " & endpointName(kind) & " payload option")
    scope.kinds.add(kind)
    scope.saveShape(move shape)
  elif data[pos] == 0x70'u8:
    inc pos
    let element = takeValType(data, pos, stop, scope.kinds)
    var shape = CanonicalSlot()
    case element.kind
    of cpU8: shape.kind = cpBytes
    of cpU32: shape.kind = cpU32List
    of cpU64: shape.kind = cpU64List
    else:
      shape.kind = cpList
      shape.listElement = if element.kind in ShapedValues:
        canonicalShape(element.index, scope.shapes)
      else:
        newSlot(canonicalSlot(element.kind, element.index, scope.shapes))
      shape.resources = shape.listElement.resources
      if typeDepth(shape) > MaxValueTypeNesting:
        componentFail("component value type nesting exceeds profile limit")
      if typeNodes(shape) > MaxIndirectParamBytes:
        componentFail("component list layout exceeds profile limit")
    scope.kinds.add(shape.kind)
    scope.saveShape(move shape)
  elif data[pos] == 0x67'u8 and defined(wasmComponentFixedLists):
    inc pos
    let element = takeValType(data, pos, stop, scope.kinds)
    let count = takeU32(data, pos, stop)
    if count == 0: componentFail("fixed-length list must have at least one element")
    let slot = if element.kind in ShapedValues:
      canonicalShape(element.index, scope.shapes)
    else:
      newSlot(canonicalSlot(element.kind, element.index, scope.shapes))
    let shape = CanonicalSlot(kind: cpFixedList, listLength: count,
      listElement: slot, resources: slot.resources)
    if typeDepth(shape) > MaxValueTypeNesting:
      componentFail("component value type nesting exceeds profile limit")
    if typeNodes(shape) > MaxIndirectParamBytes:
      componentFail("component list layout exceeds profile limit")
    validateCanonicalTypeSize(shape)
    scope.kinds.add(cpFixedList)
    scope.saveShape(shape)
  elif data[pos] == 0x63'u8:
    inc pos
    let key = takeValType(data, pos, stop, scope.kinds)
    if key.kind notin MapKeyTypes: componentFail("invalid map key type")
    let value = takeValType(data, pos, stop, scope.kinds)
    let field = valueField(value.kind, value.index, scope)
    if fieldSlot(field).resources != {}:
      componentFail("map value type cannot contain a handle")
    let entry = newRecordShape(2)
    entry.appendRecordField(ComponentRecordField(kind: key.kind))
    entry.appendRecordField(field, checkSize = false)
    entry.finishRecordLayout()
    scope.kinds.add(cpMap)
    scope.saveShape(CanonicalSlot(kind: cpMap,
      listElement: newSlot(CanonicalSlot(kind: cpTuple, recordShape: entry))))
  elif data[pos] in {0x72'u8, 0x6f'u8}:
    let kind = if data[pos] == 0x72'u8: cpRecord else: cpTuple
    inc pos
    let shape = readRecordShape(data, pos, stop, scope, kind)
    let slot = CanonicalSlot(kind: kind, recordShape: shape, resources: shape.resources)
    validateCanonicalTypeSize(slot)
    scope.kinds.add(kind)
    scope.saveShape(slot)
  elif data[pos] == 0x6e'u8:
    inc pos
    let count = takeCount(data, pos, stop, MaxComponentFlags)
    if count == 0: componentFail("empty component flags")
    var flags: seq[ComponentVariantCase]
    for _ in 0 ..< count:
      let name = takeLabel(data, pos, stop)
      for previous in flags:
        if sameCanonicalName(previous.name, name):
          componentFail("duplicate component flag")
      flags.add(ComponentVariantCase(name: name))
    scope.kinds.add(cpFlags)
    scope.saveShape(CanonicalSlot(kind: cpFlags, cases: move flags))
  elif data[pos] == 0x6b'u8:
    inc pos
    var cases = @[
      ComponentVariantCase(name: "none"),
      ComponentVariantCase(name: "some")]
    cases[1].readCasePayload(data, pos, stop, scope)
    scope.saveVariant(cpOption, move cases)
  elif data[pos] == 0x71'u8:
    inc pos
    let cases = takeCount(data, pos, stop, MaxComponentVariantCases)
    if cases == 0: componentFail("empty component variant")
    var variant: seq[ComponentVariantCase]
    for _ in 0 ..< cases:
      let name = takeLabel(data, pos, stop)
      for previous in variant:
        if sameCanonicalName(previous.name, name):
          componentFail("duplicate component variant case")
      let present = take(data, pos, stop)
      var item = ComponentVariantCase(name: name)
      case present
      of 0'u8: discard
      of 1'u8: item.readCasePayload(data, pos, stop, scope)
      else: componentFail("invalid component variant payload")
      if take(data, pos, stop) != 0:
        componentFail("unsupported component variant refines")
      variant.add(item)
    scope.saveVariant(cpVariant, move variant)
  elif data[pos] == 0x6d'u8:
    inc pos
    let count = takeCount(data, pos, stop, MaxComponentVariantCases)
    if count == 0: componentFail("empty component enum")
    var cases: seq[ComponentVariantCase]
    for _ in 0 ..< count:
      let name = takeLabel(data, pos, stop)
      for previous in cases:
        if sameCanonicalName(previous.name, name):
          componentFail("duplicate component enum case")
      cases.add(ComponentVariantCase(name: name))
    scope.kinds.add(cpEnum)
    scope.saveShape(CanonicalSlot(kind: cpEnum, cases: move cases))
  elif data[pos] == 0x6a'u8:
    inc pos
    var cases = @[
      ComponentVariantCase(name: "ok"),
      ComponentVariantCase(name: "error")]
    for i in 0 .. 1:
      case take(data, pos, stop)
      of 0'u8: discard
      of 1'u8: cases[i].readCasePayload(data, pos, stop, scope)
      else: componentFail("invalid component result payload")
    scope.saveVariant(cpResult, move cases)
  else:
    return false
  true

proc shapeAt(scope: ShapeScope, index: uint32): CanonicalSlot =
  if index >= scope.kinds.len.uint32 or scope.kinds[index.int] notin StoredValueTypes:
    componentFail("unknown component defined value type")
  canonicalSlot(scope.kinds[index.int], index.int32, scope.shapes)

proc addValueType(scope: var ShapeScope, shape: ref CanonicalSlot, visibility: TypeVisibility) =
  if scope.kinds.len >= MaxComponentTypes:
    componentFail("component type index-space limit")
  if shape.kind in ResourceValues:
    let index = if scope.handleTypes == nil: -1
      else: lookupResourceType(scope.handleTypes[], shape.resourceType.uint32)
    if index < 0: componentFail("unknown component value resource type")
    var alias = scope.handleTypes[][index]
    alias.typeIndex = scope.kinds.len.uint16
    scope.handleTypes[].add(alias)
  scope.visible[scope.kinds.len] = visibility
  scope.kinds.add(shape.kind)
  if shape.kind in ShapedValues:
    scope.setShape(shape)

proc readOuterTypeReference(data: openArray[byte], pos: var int, stop: int,
                            scope: var ShapeScope): OuterTypeReference =
  result.depth = takeU32(data, pos, stop)
  result.index = takeU32(data, pos, stop)
  result.target = addr scope
  for _ in 0'u32 ..< result.depth:
    result.crossedComponent = result.crossedComponent or result.target.componentBoundary
    result.crossedNamingScope = result.crossedNamingScope or result.target.corePlan != nil
    result.target = result.target.parent
    if result.target == nil: componentFail("unknown outer type scope")

proc readOuterCoreType(data: openArray[byte], pos: var int, stop: int, scope: var ShapeScope) =
  if take(data, pos, stop) != 2: componentFail("unsupported core type alias")
  let outer = readOuterTypeReference(data, pos, stop, scope)
  if outer.index >= outer.target.coreTypes.len.uint32:
    componentFail("unknown outer core type")
  let source = outer.target.coreTypes[outer.index.int]
  boundedAdd(scope.coreTypes, source, MaxComponentTypes)

proc outerResourceAlias(target: ptr ShapeScope, index: uint32): ptr ResourceTypeAlias =
  if target.resourceAliases != nil:
    let alias = lookupResourceType(target.resourceAliases[], index)
    if alias >= 0: return addr target.resourceAliases[][alias]

proc addNominalTypeAlias(scope: var ShapeScope, source: ResourceTypeAlias) =
  if scope.kinds.len >= MaxComponentTypes: componentFail("component type index-space limit")
  var alias = source
  alias.typeIndex = scope.kinds.len.uint16
  scope.resourceAliases[].add(alias)
  scope.kinds.add(cpResourceType)

proc outerValueShape(target: ptr ShapeScope, index: uint32): ref CanonicalSlot =
  if index >= target.kinds.len.uint32 or target.kinds[index.int] notin StoredValueTypes:
    componentFail("unknown component defined value type")
  if target.kinds[index.int] in ShapedValues:
    canonicalShape(index.int32, target.shapes)
  else:
    newSlot(shapeAt(target[], index))

proc lookupInterface(types: openArray[InterfaceType], index: uint32): int
proc lookupComponentType(types: openArray[ComponentTypeDefinition],
                         index: uint32): ref ComponentPlan
proc requireInterfaceNames(declared: InterfaceType, scope: ptr ShapeScope, forImport: bool)
proc validateResourceCaptures(plan: ComponentPlan) {.noinline.}

proc isInstanceType(scope: ShapeScope, index: uint32): bool =
  index < scope.kinds.len.uint32 and scope.kinds[index.int] == cpInterfaceType

proc instanceTypeAt(scope: ShapeScope, index: uint32): ref InterfaceType =
  let i = lookupInterface(scope.interfaceTypes[], index)
  new(result)
  result[] = scope.interfaceTypes[][i]

proc addInstanceTypeAlias(scope: var ShapeScope, shape: InterfaceType) =
  if scope.kinds.len >= MaxComponentTypes: componentFail("component type index-space limit")
  var alias = shape
  alias.typeIndex = scope.kinds.len.uint32
  scope.interfaceTypes[].add(move alias)
  scope.kinds.add(cpInterfaceType)
  scope.functionTypes[].add(ComponentFuncType())

proc addNamedInstanceType(types: var ExternalTypeSurface, item: sink NamedInstanceType) =
  if types == nil: new(types)
  if types.instances == nil: new(types.instances)
  boundedAdd(types.instances[], move item, MaxComponentTypes)

proc findExternalInstanceType(surface: ExternalTypeSurface, name: string): ref InterfaceType =
  let types = instancesIn(surface)
  if types != nil:
    for item in types[]:
      if item.name == name: return item.shape

proc requireExternalInstanceType(surface: ExternalTypeSurface, name: string): ref InterfaceType =
  result = findExternalInstanceType(surface, name)
  if result == nil: componentFail("missing instance type export: " & name)

proc isComponentType(scope: ShapeScope, index: uint32): bool =
  index < scope.kinds.len.uint32 and scope.kinds[index.int] == cpComponentType

proc addComponentTypeAlias(scope: var ShapeScope, contract: ref ComponentPlan) =
  if scope.kinds.len >= MaxComponentTypes: componentFail("component type index-space limit")
  scope.componentTypes[].add(ComponentTypeDefinition(index: scope.kinds.len.uint32,
    plan: contract))
  scope.kinds.add(cpComponentType)
  scope.functionTypes[].add(ComponentFuncType())

proc addNamedComponentType(types: var ExternalTypeSurface, item: sink NamedComponentType) =
  if types == nil: new(types)
  if types.components == nil: new(types.components)
  boundedAdd(types.components[], move item, MaxComponentTypes)

proc externComponentType(scope: var ShapeScope, index: uint32,
                         name: string): NamedComponentType =
  result = NamedComponentType(name: name, plan: lookupComponentType(scope.componentTypes[], index))
  scope.addComponentTypeAlias(result.plan)

proc addPlanComponentType(plan: var ComponentPlan, scope: var ShapeScope,
                          index: uint32, name: string, importing: bool) {.noinline.} =
  let declaration = externComponentType(scope, index, name)
  if plan.links == nil: new(plan.links)
  if importing: plan.links.typeImports.addNamedComponentType(declaration)
  else: plan.links.typeExports.addNamedComponentType(declaration)

proc addInterfaceResource(shape: var InterfaceType, enclosing: LexicalResource,
                          name: string): uint16 =
  if shape.resources == nil: new(shape.resources)
  if enclosing.depth == 0 and shape.resources.nominalScope == nil:
    new(shape.resources.nominalScope)
  result = shape.resources.enclosing.len.uint16
  boundedAdd(shape.resources.enclosing, enclosing, MaxComponentResourceTypes)
  shape.resources.names.add(name)

proc captureInterfaceResource(shape: var InterfaceType, enclosing: LexicalResource): uint16 =
  if shape.resources != nil:
    let existing = shape.resources.enclosing.find(enclosing)
    if existing >= 0: return existing.uint16
  shape.addInterfaceResource(enclosing, "")

proc contractResources(plan: ComponentPlan): ContractResources =
  if plan.links != nil: plan.links.contractResources else: nil

proc contractResourceCapture(plan: ComponentPlan, slot: int): LexicalResource =
  let resources = plan.contractResources()
  if resources != nil:
    for item in resources.captures:
      if item.slot.int == slot: return item.source

proc usesContractResource(plan: ComponentPlan, slot: uint16): bool =
  let resources = plan.contractResources()
  resources != nil and InterfaceResourceOrdinal(slot) in resources.used

proc captureContractResource(plan: var ComponentPlan, source: LexicalResource): uint16 =
  if plan.links.contractResources == nil: new(plan.links.contractResources)
  let resources = plan.links.contractResources
  for item in resources.captures:
    if item.source == source: return item.slot
  result = plan.resources.len.uint16
  boundedAdd(plan.resources, LocalResourcePlan(), MaxComponentResourceTypes)
  resources.captures.add((result, source))

proc captureTypeResource(scope: var ShapeScope, source: LexicalResource): uint16 =
  if scope.interfaceType != nil:
    return scope.interfaceType[].captureInterfaceResource(source)
  if scope.corePlan == nil or scope.componentBoundary:
    componentFail("outer type alias refers to a resource")
  scope.corePlan[].captureContractResource(source)

proc copyContractCaptures(contract: ref ComponentPlan): ref ComponentPlan =
  new(result)
  result[] = contract[]
  new(result.links)
  result.links[] = contract.links[]
  new(result.links.contractResources)
  result.links.contractResources[] = contract.links.contractResources[]

proc contractInScope(contract: ref ComponentPlan, scope: var ShapeScope,
                     extraDepth = 0'u16, crossedComponent = false): ref ComponentPlan {.noinline.} =
  result = contract
  let resources = contract[].contractResources()
  if resources == nil: return
  for i, item in resources.captures:
    if InterfaceResourceOrdinal(item.slot) notin resources.used: continue
    if crossedComponent: componentFail("outer type alias refers to a resource")
    let depth = item.source.depth + extraDepth
    if depth > 1:
      if result == contract: result = copyContractCaptures(contract)
      let local = scope.captureTypeResource((depth - 1, item.source.ordinal))
      result.links.contractResources.captures[i].source = (1'u16, local)

proc rebaseContractType(contract: ref ComponentPlan,
                        mapping: openArray[uint16]): ref ComponentPlan {.noinline.} =
  result = contract
  let resources = contract[].contractResources()
  if resources == nil: return
  for i, item in resources.captures:
    if InterfaceResourceOrdinal(item.slot) notin resources.used: continue
    let source = item.source
    if source.depth != 1 or source.ordinal.int >= mapping.len or mapping[source.ordinal] == 0:
      componentFail("unbound component type resource")
    let local = mapping[source.ordinal] - 1
    if local != source.ordinal:
      if result == contract: result = copyContractCaptures(contract)
      result.links.contractResources.captures[i].source.ordinal = local

proc markContractCaptures(contract: ref ComponentPlan, used: var ResourceOrdinals) =
  let resources = contract[].contractResources()
  if resources != nil:
    for item in resources.captures:
      if InterfaceResourceOrdinal(item.slot) in resources.used:
        if item.source.depth != 1: componentFail("unbound component type resource")
        used.incl(InterfaceResourceOrdinal(item.source.ordinal))

proc hasInterfaceResource(types: InterfaceResourceTypes, ordinal: int): bool =
  InterfaceResourceOrdinal(ordinal) in types.used

proc capturesResource(shape: InterfaceType, ordinal: int): bool =
  shape.resources.hasInterfaceResource(ordinal) and shape.resources.enclosing[ordinal].depth != 0

proc copyInstanceType(shape: ref InterfaceType): ref InterfaceType =
  new(result)
  result[] = shape[]
  new(result.resources)
  result.resources[] = shape.resources[]

proc rebaseInstanceType(shape: ref InterfaceType,
                        mapping: openArray[uint16]): ref InterfaceType {.noinline.} =
  result = shape
  if shape.resources == nil: return
  for i, capture in shape.resources.enclosing:
    if not shape[].capturesResource(i): continue
    if capture.depth != 1 or capture.ordinal.int >= mapping.len or mapping[capture.ordinal] == 0:
      componentFail("unbound instance type resource")
    let bound = mapping[capture.ordinal] - 1
    if bound != capture.ordinal:
      if result == shape: result = copyInstanceType(shape)
      result.resources.enclosing[i].ordinal = bound

proc instanceTypeInInterface(owner: var InterfaceType,
                             shape: ref InterfaceType): ref InterfaceType {.noinline.} =
  result = shape
  if owner.visibilityError.len == 0: owner.visibilityError = shape.visibilityError
  if shape.outerNames != nil:
    for name in shape.outerNames[]:
      if name.depth > 1: owner.addOuterName((name.depth - 1, name.visibility))
  if shape.resources == nil: return
  for i, capture in shape.resources.enclosing:
    if shape[].capturesResource(i) and capture.depth > 1:
      if result == shape: result = copyInstanceType(shape)
      result.resources.enclosing[i] = (1'u16, owner.captureInterfaceResource(
        (capture.depth - 1, capture.ordinal)))

proc addPlanInstanceType(plan: var ComponentPlan, scope: var ShapeScope,
    index: uint32, name: string, importing: bool) {.noinline.} =
  let shape = instanceTypeAt(scope, index)
  requireInterfaceNames(shape[], addr scope, forImport = importing)
  if shape.resources != nil:
    for i, capture in shape.resources.enclosing:
      if not shape[].capturesResource(i): continue
      if capture.depth != 1 or capture.ordinal.int >= plan.resources.len:
        componentFail("unknown enclosing instance type resource")
      if importing and plan.resources[capture.ordinal].importName.len == 0 and
          plan.contractResourceCapture(capture.ordinal.int).depth == 0:
        componentFail("local resource type found in instance type import")
  if plan.links == nil: new(plan.links)
  let member = NamedInstanceType(name: name, shape: shape)
  if importing: plan.links.typeImports.addNamedInstanceType(member)
  else: plan.links.typeExports.addNamedInstanceType(member)
  scope.addInstanceTypeAlias(shape[])

proc markInterfaceHandles(types: InterfaceResourceTypes, handles: openArray[uint16]) =
  for index in handles:
    let ordinal = resourceIndex(types.handleTypes, index.uint32)
    if ordinal < 0: componentFail("unknown interface value resource")
    types.used.incl(InterfaceResourceOrdinal(ordinal))

proc markInterfaceResources(shape: InterfaceType) {.noinline.} =
  let types = shape.resources
  for item in types.resourceTypes:
    types.used.incl(InterfaceResourceOrdinal(item.resourceIndex))
  for member in shape.methods:
    types.markInterfaceHandles(signatureResourceTypes(member.signature))
  if shape.functionTypes != nil:
    for item in shape.functionTypes[]:
      types.markInterfaceHandles(signatureResourceTypes(item.signature))
  for item in shape.valueTypes:
    var handles: seq[uint16]
    collectResourceTypes(item.shape[], handles)
    types.markInterfaceHandles(handles)
  if shape.children != nil:
    for child in shape.children[]:
      for index in child.resources:
        if index != 0: types.used.incl(InterfaceResourceOrdinal(index - 1))
  let instanceTypes = instancesIn(shape.typeExternals)
  if instanceTypes != nil:
    for item in instanceTypes[]:
      if item.shape.resources == nil: continue
      for i, capture in item.shape.resources.enclosing:
        if item.shape[].capturesResource(i):
          types.used.incl(InterfaceResourceOrdinal(capture.ordinal))
  let componentTypes = componentsIn(shape.typeExternals)
  if componentTypes != nil:
    for item in componentTypes[]: markContractCaptures(item.plan, types.used)
  if shape.components != nil:
    for item in shape.components[]: markContractCaptures(item.value.plan, types.used)

proc registerInstanceMember(parent: var InterfaceType, name: string,
    definition: InterfaceType): InterfaceTypeMember {.noinline.} =
  result.name = name
  result.definition = new(InterfaceType)
  result.definition[] = definition
  if parent.visibilityError.len == 0:
    parent.visibilityError = definition.visibilityError
  if definition.outerNames != nil:
    for capture in definition.outerNames[]:
      if capture.depth > 1:
        parent.addOuterName((capture.depth - 1, capture.visibility))
  if definition.resources != nil:
    for i, enclosing in definition.resources.enclosing:
      if not definition.resources.hasInterfaceResource(i):
        result.resources.add(0)
      elif enclosing.depth == 1:
        if parent.resources == nil or enclosing.ordinal.int >= parent.resources.enclosing.len:
          componentFail("unknown enclosing instance resource")
        result.resources.add(enclosing.ordinal + 1)
      elif enclosing.depth > 1:
        result.resources.add(parent.captureInterfaceResource(
          (enclosing.depth - 1, enclosing.ordinal)) + 1)
      else:
        result.resources.add(parent.addInterfaceResource((0'u16, 0'u16),
          definition.resources.names[i]) + 1)

proc readInstanceTypeMember(data: openArray[byte], pos: var int, stop: int,
    instances: openArray[InterfaceTypeMember]): tuple[source: ptr InterfaceTypeMember, name: string] =
  let index = takeU32(data, pos, stop)
  if index >= instances.len.uint32: componentFail("unknown instance in instance type")
  result = (unsafeAddr instances[index.int], takeName(data, pos, stop, allowEmpty = true))

proc instanceMemberHandleMapping(parent: var InterfaceType, source: InterfaceTypeMember,
    scope: var ShapeScope, handles: openArray[uint16]): ResourceTypeMapping =
  for index in handles:
    let alias = lookupResourceType(source.definition.resources.handleTypes, index.uint32)
    if alias < 0: componentFail("unknown instance value resource")
    let original = source.definition.resources.handleTypes[alias]
    let resource = source.resources[original.resourceIndex] - 1
    var target: uint16
    const SyntheticHandleStart = MaxComponentTypes + MaxComponentResourceTypes
    for handle in parent.resources.handleTypes:
      if handle.typeIndex.int >= SyntheticHandleStart and handle.resourceIndex == resource and
          handle.typeName == original.typeName and handle.visible and not handle.imported:
        target = handle.typeIndex
        break
    if target == 0:
      target = (SyntheticHandleStart + parent.resources.handleTypes.len).uint16
      parent.resources.handleTypes.add(ResourceTypeAlias(typeIndex: target,
        resourceIndex: resource, visible: true, typeName: original.typeName))
    result.add((index, target))
  if result.len != 0: scope.handleTypes = addr parent.resources.handleTypes

proc aliasInInterfaceType(data: openArray[byte], pos: var int, stop: int, sort: byte,
    parent: var InterfaceType, scope: var ShapeScope, instances: var seq[InterfaceTypeMember],
    aliases: var seq[ResourceTypeAlias]) {.noinline.} =
  let member = readInstanceTypeMember(data, pos, stop, instances)
  if sort == 5:
    if member.source.definition.children != nil:
      for inner in member.source.definition.children[]:
        if inner.name != member.name: continue
        var nested = InterfaceTypeMember(definition: inner.definition)
        for index in inner.resources:
          nested.resources.add(if index == 0: 0'u16 else: member.source.resources[index.int - 1])
        boundedAdd(instances, move nested, MaxComponentFunctions)
        return
    componentFail("unknown nested interface export: " & member.name)
  if scope.kinds.len >= MaxComponentTypes: componentFail("component type index-space limit")
  let definition = member.source.definition
  let shape = findExternalInstanceType(definition.typeExternals, member.name)
  if shape != nil:
    scope.addInstanceTypeAlias(rebaseInstanceType(shape, member.source.resources)[])
    return
  let componentTypes = componentsIn(definition.typeExternals)
  if componentTypes != nil:
    for item in componentTypes[]:
      if item.name != member.name: continue
      scope.addComponentTypeAlias(rebaseContractType(item.plan, member.source.resources))
      return
  if definition.functionTypes != nil:
    for item in definition.functionTypes[]:
      if item.name != member.name: continue
      let handles = signatureResourceTypes(item.signature)
      let mapping = instanceMemberHandleMapping(parent, member.source[], scope, handles)
      scope.addFunctionAlias(rebaseResourceSignature(item.signature, mapping),
        FunctionTypeOrigin(names: item.names))
      return
  if definition.resources != nil:
    for resource in definition.resources.resourceTypes:
      if resource.name != member.name: continue
      aliases.add(ResourceTypeAlias(typeIndex: scope.kinds.len.uint16,
        resourceIndex: member.source.resources[resource.resourceIndex.int] - 1,
        visible: true, typeName: resource.typeName))
      scope.kinds.add(cpResourceType)
      return
  for field in definition.valueTypes:
    if field.name != member.name: continue
    var value = field.shape
    if value.resources != {}:
      var handles: seq[uint16]
      collectResourceTypes(value[], handles)
      let mapping = instanceMemberHandleMapping(parent, member.source[], scope, handles)
      value = rebaseResourceShape(value, mapping, nil)
    scope.rememberShapeOrigin(value, field.namedOrigin())
    scope.addValueType(value, tvExported)
    return
  componentFail("unknown component instance type")

proc lexicalResource(target: ptr ShapeScope, reference: LexicalResource): LexicalResource =
  ## Normalize captures through intermediate type scopes to the same address
  ## that a direct reference to the original resource would use.
  var owner = target
  result = reference
  while true:
    var enclosing: LexicalResource
    if owner.interfaceType != nil:
      let resourceTypes = owner.interfaceType.resources
      if resourceTypes == nil or result.ordinal.int >= resourceTypes.enclosing.len:
        componentFail("unknown enclosing instance resource")
      enclosing = resourceTypes.enclosing[result.ordinal.int]
    elif owner.corePlan != nil:
      enclosing = owner.corePlan[].contractResourceCapture(result.ordinal.int)
    if enclosing.depth == 0: break
    result.depth += enclosing.depth
    result.ordinal = enclosing.ordinal
    for _ in 0'u16 ..< enclosing.depth:
      owner = owner.parent
      if owner == nil: componentFail("unknown enclosing instance resource")

proc bindLexicalInterfaceHandle(shape: var InterfaceType, alias: ResourceTypeAlias,
    enclosing: LexicalResource): uint16 =
  let ordinal = shape.captureInterfaceResource(enclosing)
  # Keep lexical aliases separate from local type indices and handles mapped
  # from aliased instances. A private handle must retain its visibility.
  const FirstLexicalHandle = MaxComponentTypes + MaxComponentResourceTypes
  for handle in shape.resources.handleTypes:
    if handle.typeIndex.int >= FirstLexicalHandle and handle.resourceIndex == ordinal and
        handle.visible == alias.visible and handle.imported == alias.imported and
        handle.typeName == alias.typeName:
      return handle.typeIndex
  result = (FirstLexicalHandle + shape.resources.handleTypes.len).uint16
  shape.resources.handleTypes.add(ResourceTypeAlias(typeIndex: result,
    resourceIndex: ordinal, visible: alias.visible, imported: alias.imported, typeName: alias.typeName))

proc requireLocalResourceCapture(outer: OuterTypeReference) =
  if outer.crossedComponent: componentFail("outer type alias refers to a resource")

proc bindOuterHandles(outer: OuterTypeReference, handles: openArray[uint16],
    scope: var ShapeScope): ResourceTypeMapping =
  let aliases = outer.target.handleTypes
  for index in handles:
    let source = if aliases == nil: -1 else: lookupResourceType(aliases[], index.uint32)
    if source < 0: componentFail("unknown outer value resource type")
    var alias = aliases[][source]
    if outer.crossedNamingScope:
      alias.visible = false
      alias.imported = false
    let capture = lexicalResource(outer.target, (outer.depth.uint16, alias.resourceIndex))
    if scope.interfaceType != nil:
      let target = scope.interfaceType[].bindLexicalInterfaceHandle(alias, capture)
      result.add((index, target))
      scope.handleTypes = addr scope.interfaceType.resources.handleTypes
    else:
      let ordinal = scope.captureTypeResource(capture)
      let target = scope.corePlan[].bindResourceHandleIndex(ordinal, tvPrivate, alias.typeName)
      result.add((index, target.uint16))

proc normalizeContractInterfaceCaptures(shape: var InterfaceType, owner: var ShapeScope) =
  if shape.resources == nil or owner.corePlan == nil or owner.componentBoundary: return
  var normalized: InterfaceResourceTypes
  for i, resource in shape.resources.enclosing:
    if not shape.capturesResource(i) or resource.depth <= 1: continue
    if normalized == nil:
      new(normalized)
      normalized[] = shape.resources[]
    normalized.enclosing[i] = (1'u16, owner.captureTypeResource((resource.depth - 1, resource.ordinal)))
  if normalized != nil: shape.resources = move normalized

proc addOuterInstanceType(scope: var ShapeScope, outer: OuterTypeReference) =
  let types = outer.target.interfaceTypes
  let source = lookupInterface(types[], outer.index)
  var definition = types[][source]
  if outer.depth != 0 and definition.outerNames != nil:
    new(definition.outerNames)
    for capture in types[][source].outerNames[]:
      definition.outerNames[].add((capture.depth + outer.depth.uint16, capture.visibility))
  if outer.depth != 0 and definition.resources != nil:
    var captured: InterfaceResourceTypes
    for i, entry in definition.resources.enclosing:
      if entry.depth == 0 or not definition.resources.hasInterfaceResource(i): continue
      if outer.crossedComponent: componentFail("outer type alias refers to a resource")
      if captured == nil:
        new(captured)
        captured[] = definition.resources[]
      captured.enclosing[i].depth += outer.depth.uint16
    if captured != nil: definition.resources = move captured
  normalizeContractInterfaceCaptures(definition, scope)
  definition.typeIndex = scope.kinds.len.uint32
  scope.interfaceTypes[].add(move definition)
  scope.kinds.add(cpInterfaceType)

proc addOuterFunctionType(scope: var ShapeScope, outer: OuterTypeReference): ComponentFuncType =
  let signature = addr outer.target.functionTypes[][outer.index.int]
  let handles = signatureResourceTypes(signature[])
  if handles.len != 0:
    requireLocalResourceCapture(outer)
    if outer.depth != 0:
      result = rebaseResourceSignature(signature[], bindOuterHandles(outer, handles, scope))
    else:
      result = signature[]
  else:
    result = signature[]
  var origin = functionTypeOrigin(outer.target, outer.index)
  if origin.scope != addr scope:
    origin.aliasIndex = scope.kinds.len.uint16
    if scope.functionOrigins == nil: new(scope.functionOrigins)
    scope.functionOrigins[].add(origin)
  scope.kinds.add(cpFunctionType)

proc readOuterTypeAlias(data: openArray[byte], pos: var int, stop: int,
    scope: var ShapeScope): ComponentFuncType {.noinline.} =
  let outer = readOuterTypeReference(data, pos, stop, scope)
  if outer.index >= outer.target.kinds.len.uint32:
    componentFail("unknown component defined value type")
  if scope.kinds.len >= MaxComponentTypes:
    componentFail("component type index-space limit")
  case outer.target.kinds[outer.index.int]
  of cpResourceType:
    requireLocalResourceCapture(outer)
    let resource = outerResourceAlias(outer.target, outer.index)
    if resource == nil: componentFail("unknown outer resource type")
    var alias = resource[]
    if outer.depth != 0:
      alias.resourceIndex = scope.captureTypeResource(lexicalResource(outer.target,
        (outer.depth.uint16, alias.resourceIndex)))
      if outer.crossedNamingScope:
        alias.visible = false
        alias.imported = false
    scope.addNominalTypeAlias(alias)
  of cpComponentType:
    let contract = lookupComponentType(outer.target.componentTypes[], outer.index)
    scope.componentTypes[].add(ComponentTypeDefinition(index: scope.kinds.len.uint32,
      plan: contractInScope(contract, scope, outer.depth.uint16, outer.crossedComponent)))
    scope.kinds.add(cpComponentType)
  of cpInterfaceType:
    scope.addOuterInstanceType(outer)
  of cpFunctionType:
    return scope.addOuterFunctionType(outer)
  else:
    var value = outerValueShape(outer.target, outer.index)
    if value.resources != {}:
      requireLocalResourceCapture(outer)
      if outer.depth != 0:
        var handles: seq[uint16]
        collectResourceTypes(value[], handles)
        let mapping = bindOuterHandles(outer, handles, scope)
        if scope.rebasedShapes == nil: new(scope.rebasedShapes)
        value = rebaseResourceShape(value, mapping, scope.rebasedShapes)
    let visible = if outer.crossedNamingScope: tvPrivate else: outer.target.visible[outer.index.int]
    let depth = if visible == tvPrivate: 0'u16
      else: outer.depth.uint16 + outer.target.outerNameDepth(outer.index.int)
    if value.kind in NamedValueTypes and depth != 0:
      if scope.outerValueNames == nil: new(scope.outerValueNames)
      scope.outerValueNames[].add((scope.kinds.len.uint16, depth))
    scope.addValueType(value, visible)

proc readInterfaceType(data: openArray[byte], pos: var int, stop: int,
                       typeIndex: uint32, parent: ptr ShapeScope, depth = 0): InterfaceType
proc readComponentContract(data: openArray[byte], pos: var int, stop: int,
                           parent: ptr ShapeScope): ref ComponentPlan

proc declareComponentType(data: openArray[byte], pos: var int, stop: int,
                          scope: var ShapeScope) {.noinline.} =
  inc pos
  let plan = contractInScope(readComponentContract(data, pos, stop, addr scope), scope)
  scope.componentTypes[].add(ComponentTypeDefinition(index: scope.kinds.len.uint32, plan: plan))
  scope.kinds.add(cpComponentType)

proc declareNestedInstanceType(data: openArray[byte], pos: var int, stop: int,
    typeIndex: uint32, scope: ptr ShapeScope, depth: int,
    nestedTypes: var seq[InterfaceType]) {.noinline.} =
  nestedTypes.add(readInterfaceType(data, pos, stop, typeIndex, scope, depth + 1))

proc declareNestedInstanceExport(data: openArray[byte], pos: var int, stop: int, name: string,
    parent: var InterfaceType, nestedTypes: openArray[InterfaceType],
    instances: var seq[InterfaceTypeMember]) {.noinline.} =
  let index = lookupInterface(nestedTypes, takeU32(data, pos, stop))
  let member = parent.registerInstanceMember(name, nestedTypes[index])
  if parent.children == nil: new(parent.children)
  parent.visibilityOrder.addMember(vmInstance, parent.children[].len)
  boundedAdd(parent.children[], member, MaxComponentFunctions)
  boundedAdd(instances, member, MaxComponentFunctions)

proc readInterfaceType(data: openArray[byte], pos: var int, stop: int,
                       typeIndex: uint32, parent: ptr ShapeScope, depth: int): InterfaceType =
  if depth >= MaxInstanceNesting: componentFail("instance type nesting limit")
  result.typeIndex = typeIndex
  let count = takeCount(data, pos, stop, MaxComponentFunctions)
  var types: seq[ComponentFuncType]
  var scope = ShapeScope(parent: parent, contractDepth: parent.contractDepth)
  var names: seq[string]
  var resourceTypes: seq[ResourceTypeAlias]
  var nestedTypes: seq[InterfaceType]
  var componentTypes: seq[ComponentTypeDefinition]
  var instances: seq[InterfaceTypeMember]
  scope.resourceAliases = addr resourceTypes
  scope.interfaceType = addr result
  scope.functionTypes = addr types
  scope.interfaceTypes = addr nestedTypes
  scope.componentTypes = addr componentTypes
  for _ in 0 ..< count:
    case take(data, pos, stop)
    of 0'u8:
      readCoreType(data, pos, stop, scope)
    of 1'u8:
      if types.len >= MaxComponentTypes:
        componentFail("component type index-space limit")
      if pos < stop and data[pos] == 0x3f:
        componentFail("resource definitions require a concrete component")
      if pos < stop and data[pos] == 0x42:
        inc pos
        declareNestedInstanceType(data, pos, stop, types.len.uint32, addr scope, depth, nestedTypes)
        types.add(ComponentFuncType())
        scope.kinds.add(cpInterfaceType)
      elif pos < stop and data[pos] == 0x41:
        declareComponentType(data, pos, stop, scope)
        types.add(ComponentFuncType())
      elif pos < stop and data[pos] in {0x69'u8, 0x68'u8}:
        let kind = if take(data, pos, stop) == 0x69'u8: cpOwnedResource
          else: cpBorrowedResource
        let target = lookupResourceType(resourceTypes, takeU32(data, pos, stop))
        if target < 0: componentFail("unknown interface resource type in handle")
        var alias = resourceTypes[target]
        alias.typeIndex = types.len.uint16
        result.resources.handleTypes.add(alias)
        scope.handleTypes = addr result.resources.handleTypes
        types.add(ComponentFuncType())
        scope.kinds.add(kind)
      elif readValueDefinition(data, pos, stop, scope):
        types.add(ComponentFuncType())
      else:
        var signature = readFuncType(data, pos, stop, scope.kinds)
        signature.configureCanonicalType(scope.shapes)
        types.add(move signature)
        scope.kinds.add(cpFunctionType)
    of 2'u8:
      let sort = take(data, pos, stop)
      if sort == 0:
        if take(data, pos, stop) != 0x10: componentFail("unsupported interface core alias")
        readOuterCoreType(data, pos, stop, scope)
        continue
      let kind = take(data, pos, stop)
      if sort in {3'u8, 5'u8} and kind == 0:
        aliasInInterfaceType(data, pos, stop, sort, result, scope, instances, resourceTypes)
        if sort == 3 and scope.kinds[^1] notin {cpFunctionType, cpComponentType, cpInterfaceType}:
          types.add(ComponentFuncType())
        continue
      if sort != 3 or kind != 2:
        componentFail("unsupported interface type alias")
      types.add(readOuterTypeAlias(data, pos, stop, scope))
    of 4'u8:
      let external = takeExternalName(data, pos, stop)
      let name = external.name
      for previous in names:
        if sameCanonicalName(previous, name):
          componentFail("duplicate interface export")
      names.add(name)
      case external.sort
      of 0'u8:
        let shape = readModuleTypeRef(data, pos, stop, scope)
        result.coreModules.addInstanceModule(NamedCoreModule(name: name,
          value: CoreModuleValue(shape: shape)))
      of 1'u8:
        let index = takeU32(data, pos, stop)
        if index >= types.len.uint32 or scope.kinds[index.int] != cpFunctionType or
            not supportedHostSignature(types[index.int], linkedResources = true):
          componentFail("invalid interface method type")
        requireVisibleFunctionType(scope, index)
        let signature = types[index.int]
        if result.resources != nil:
          let resourceScope = ComponentPlan(handleTypes: result.resources.handleTypes)
          resourceScope.requireVisibleResources(signature, deferred = addr result.visibilityError)
          checkResourceMemberName(resourceScope, ComponentExport(name: name,
            signature: signature), result.resources.resourceTypes)
        elif resourceMember(name).kind != rmNone:
          componentFail("resource member names a type absent from its interface")
        let visibleNames = functionTypeNames(addr scope, index)
        if visibleNames != nil or signatureResourceTypes(signature).len != 0:
          result.visibilityOrder.addMember(vmFunction, result.methods.len)
        result.methods.add(ComponentImport(name: name, signature: types[index.int],
          visibilityNames: visibleNames))
      of 3'u8:
        if types.len >= MaxComponentTypes:
          componentFail("component type index-space limit")
        let bound = take(data, pos, stop)
        if bound == 1:
          let index = result.addInterfaceResource((0'u16, 0'u16), name)
          let typeName = newResourceName()
          result.visibilityOrder.addMember(vmResource, result.resources.resourceTypes.len)
          boundedAdd(result.resources.resourceTypes, NamedResourceType(name: name,
            resourceIndex: index, typeName: typeName),
            MaxComponentResourceTypes)
          resourceTypes.add(ResourceTypeAlias(typeIndex: types.len.uint16,
            resourceIndex: index, visible: true, typeName: typeName))
          scope.kinds.add(cpResourceType)
          types.add(ComponentFuncType())
          continue
        if bound != 0:
          componentFail("unsupported interface type export bound")
        let index = takeU32(data, pos, stop)
        if scope.isInstanceType(index):
          let shape = instanceTypeInInterface(result, instanceTypeAt(scope, index))
          result.typeExternals.addNamedInstanceType(NamedInstanceType(name: name, shape: shape))
          scope.addInstanceTypeAlias(shape[])
          continue
        if scope.isComponentType(index):
          result.typeExternals.addNamedComponentType(externComponentType(scope, index, name))
          continue
        if scope.isFunctionType(index):
          result.typeExternals.addExportedFunctionType(result.visibilityOrder,
            externFunctionType(scope, index, name))
          continue
        let resource = lookupResourceType(resourceTypes, index)
        if resource >= 0:
          var alias = resourceTypes[resource]
          alias.typeIndex = types.len.uint16
          alias.visible = true
          alias.typeName = newResourceName()
          resourceTypes.add(alias)
          result.visibilityOrder.addMember(vmResource, result.resources.resourceTypes.len)
          boundedAdd(result.resources.resourceTypes, NamedResourceType(name: name,
            resourceIndex: alias.resourceIndex, typeName: alias.typeName),
            MaxComponentResourceTypes)
          scope.kinds.add(cpResourceType)
          types.add(ComponentFuncType())
          continue
        let value = shapeAt(scope, index)
        requireVisibleChildren(value, addr scope, false)
        if value.resources != {}:
          requireVisibleResourceSlot(result.resources.handleTypes, value, false,
            "interface value resource type is not exported", addr result.visibilityError)
        let shape = newSlot(value)
        scope.addValueType(shape, tvExported)
        types.add(ComponentFuncType())
        if shape.kind in ShapedValues or shape.resources != {}:
          result.visibilityOrder.addMember(vmType, result.valueTypes.len)
        result.valueTypes.add(NamedValueType(name: name, shape: shape))
      of 4'u8:
        let component = lookupComponentType(componentTypes, takeU32(data, pos, stop))
        result.components.addInstanceComponent(NamedComponentDefinition(name: name,
          value: ComponentArgument(plan: component)))
      of 5'u8:
        declareNestedInstanceExport(data, pos, stop, name, result, nestedTypes, instances)
      else: componentFail("unsupported interface type export sort")
    else: componentFail("unsupported interface type declaration")
  if result.resources != nil:
    markInterfaceResources(result)
    normalizeContractInterfaceCaptures(result, parent[])

proc lookupInterface(types: openArray[InterfaceType], index: uint32): int =
  for i, ty in types:
    if ty.typeIndex == index: return i
  componentFail("unknown component interface type")

proc requireInterfaceNames(declared: InterfaceType, scope: ptr ShapeScope,
                           forImport: bool) =
  if declared.visibilityError.len != 0: componentFail(declared.visibilityError)
  if declared.outerNames == nil: return
  for name in declared.outerNames[]:
    var owner = scope
    for _ in 1'u16 ..< name.depth:
      if owner.corePlan != nil or owner.parent == nil:
        componentFail("interface type refers to a name outside its component")
      owner = owner.parent
    if forImport and name.visibility != tvImported:
      componentFail("interface import depends on an exported value type")

proc addInterfaceImport(plan: var ComponentPlan, name: string,
                        declared: InterfaceType, scope: ptr ShapeScope): DeclaredInstance
proc addContractInterfaceExport(plan: var ComponentPlan, name: string,
                                declared: InterfaceType, scope: ptr ShapeScope): DeclaredInstance
proc addInstanceTypeAlias(data: openArray[byte], pos: var int, stop: int,
    plan: var ComponentPlan, scope: var ShapeScope, instances: openArray[DeclaredInstance])
proc lookupNestedInstance(links: ComponentLinks, source: DeclaredInstance,
                          name: string): DeclaredInstance

proc lookupComponentType(types: openArray[ComponentTypeDefinition],
                         index: uint32): ref ComponentPlan =
  for item in types:
    if item.index == index: return item.plan
  componentFail("unknown component contract type")

proc addComponentTypeImport(plan: var ComponentPlan, name: string,
    contract: ref ComponentPlan, interfaceImport = false): ComponentArgument =
  if plan.links == nil: new(plan.links)
  if plan.links.componentImports == nil: new(plan.links.componentImports)
  result = ComponentArgument(plan: contract,
    importIndex: (plan.links.componentImports[].len + 1).uint16)
  boundedAdd(plan.links.componentImports[], NamedComponentType(name: name, plan: contract,
    interfaceImport: interfaceImport), MaxComponentFunctions)

proc addComponentDefinitionExport(plan: var ComponentPlan, name: string,
                                  definition: ComponentArgument) =
  if plan.links == nil: new(plan.links)
  if plan.links.componentExports == nil: new(plan.links.componentExports)
  boundedAdd(plan.links.componentExports[],
    NamedComponentDefinition(name: name, value: definition), MaxComponentFunctions)

proc readComponentContract(data: openArray[byte], pos: var int, stop: int,
                           parent: ptr ShapeScope): ref ComponentPlan =
  ## A component type describes the surface used for validation and projection.
  ## Only an actual component definition supplies executable code.
  if parent.contractDepth.int >= MaxComponentContractNesting:
    componentFail("component contract nesting limit")
  result = new(ComponentPlan)
  result.instanceCount = 1
  result.links = ComponentLinks()
  var scope = ShapeScope(parent: parent, contractDepth: parent.contractDepth + 1)
  scope.corePlan = addr result[]
  var functions: seq[ComponentFuncType]
  var resourceAliases: seq[ResourceTypeAlias]
  scope.resourceAliases = addr resourceAliases
  scope.handleTypes = addr result.handleTypes
  var interfaceTypes: seq[InterfaceType]
  var componentTypes: seq[ComponentTypeDefinition]
  scope.componentTypes = addr componentTypes
  scope.functionTypes = addr functions
  scope.interfaceTypes = addr interfaceTypes
  var instances: seq[DeclaredInstance]
  var importNames, exportNames: seq[string]
  var resourceImports: seq[NamedResourceType]
  let count = takeCount(data, pos, stop, MaxComponentFunctions)
  for _ in 0 ..< count:
    let declaration = take(data, pos, stop)
    case declaration
    of 0'u8:
      readCoreType(data, pos, stop, scope)
    of 1'u8:
      if scope.kinds.len >= MaxComponentTypes:
        componentFail("component contract type index-space limit")
      if pos < stop and data[pos] == 0x3f:
        componentFail("resource definitions require a concrete component")
      if pos < stop and data[pos] == 0x41:
        declareComponentType(data, pos, stop, scope)
        functions.add(ComponentFuncType())
      elif pos < stop and data[pos] == 0x42:
        inc pos
        interfaceTypes.add(readInterfaceType(data, pos, stop, scope.kinds.len.uint32, addr scope))
        scope.kinds.add(cpInterfaceType)
        functions.add(ComponentFuncType())
      elif pos < stop and data[pos] in {0x69'u8, 0x68'u8}:
        let kind = if take(data, pos, stop) == 0x69'u8: cpOwnedResource
          else: cpBorrowedResource
        let resource = lookupResourceType(resourceAliases, takeU32(data, pos, stop))
        if resource < 0: componentFail("unknown resource type in component contract")
        var alias = resourceAliases[resource]
        alias.typeIndex = scope.kinds.len.uint16
        result.handleTypes.add(alias)
        scope.kinds.add(kind)
        functions.add(ComponentFuncType())
      elif readValueDefinition(data, pos, stop, scope):
        functions.add(ComponentFuncType())
      else:
        var signature = readFuncType(data, pos, stop, scope.kinds)
        signature.configureCanonicalType(scope.shapes)
        functions.add(move signature)
        scope.kinds.add(cpFunctionType)
    of 2'u8:
      let sort = take(data, pos, stop)
      if sort == 0:
        if take(data, pos, stop) != 0x10: componentFail("unsupported component contract core alias")
        readOuterCoreType(data, pos, stop, scope)
        continue
      if sort == 5:
        if take(data, pos, stop) != 0: componentFail("unsupported component contract instance alias")
        let index = takeU32(data, pos, stop)
        if index >= instances.len.uint32: componentFail("unknown component instance")
        let name = takeName(data, pos, stop, allowEmpty = true)
        boundedAdd(instances, lookupNestedInstance(result.links, instances[index.int], name),
          MaxComponentFunctions)
        continue
      if sort != 3 or scope.kinds.len >= MaxComponentTypes:
        componentFail("unsupported component contract type alias")
      case take(data, pos, stop)
      of 0'u8:
        addInstanceTypeAlias(data, pos, stop, result[], scope, instances)
      of 2'u8:
        functions.add(readOuterTypeAlias(data, pos, stop, scope))
      else: componentFail("unsupported component contract type alias")
    of 3'u8, 4'u8:
      let importing = declaration == 3
      let external = takeExternalName(data, pos, stop)
      let name = external.name
      template names: untyped = (if importing: addr importNames else: addr exportNames)[]
      for previous in names:
        if sameCanonicalName(previous, name):
          componentFail("duplicate component contract external name")
      names.add(name)
      case external.sort
      of 0'u8:
        let shape = readModuleTypeRef(data, pos, stop, scope)
        if importing:
          discard addCoreModuleImport(result[], name, shape)
        else:
          addCoreModuleExport(result[], name, CoreModuleValue(shape: shape))
      of 1'u8:
        let index = takeU32(data, pos, stop)
        if index >= functions.len.uint32 or scope.kinds[index.int] != cpFunctionType:
          componentFail("unknown component contract function type")
        let signature = functions[index.int]
        result[].requireVisibleResources(signature, forImport = importing, scope = addr scope)
        requireVisibleFunctionType(scope, index, forImport = importing)
        let visibleNames = functionTypeNames(addr scope, index)
        let fn = ComponentExport(name: name, signature: signature, visibilityNames: visibleNames,
          resourceNames: resourceNames(signature, result.handleTypes))
        if importing:
          checkResourceMemberName(result[], fn, resourceImports)
          result.imports.add(ComponentImport(name: name, signature: signature,
            visibilityNames: visibleNames))
        else:
          checkResourceMemberName(result[], fn, result.links.resourceExports)
          if visibleNames != nil or fn.resourceNames != nil:
            result.links.visibilityOrder.addMember(vmFunction, result.exports.len)
          result.exports.add(fn)
      of 3'u8:
        if scope.kinds.len >= MaxComponentTypes:
          componentFail("invalid component contract type export")
        let bound = take(data, pos, stop)
        let valueIndex = if bound == 0: takeU32(data, pos, stop) else: 0'u32
        var resource = if bound == 0: resourceIndex(resourceAliases, valueIndex) else: -1
        if bound == 1:
          resource = result.resources.len
          boundedAdd(result.resources, LocalResourcePlan(
            importName: if importing: name else: ""), MaxComponentResourceTypes)
        elif bound != 0:
          componentFail("invalid component contract type bound")
        if resource >= 0:
          if importing and result.resources[resource].importName.len == 0 and
              result[].contractResourceCapture(resource).depth == 0:
            componentFail("local resource type found in component contract imports")
          if importing and bound == 0:
            requireImportedResourceName(scope, resourceAliases[lookupResourceType(resourceAliases, valueIndex)])
          let typeName = newResourceName()
          let named = NamedResourceType(name: name, resourceIndex: resource.uint16, typeName: typeName)
          if importing:
            resourceImports.add(named)
            if bound == 0: result.links.resourceEqualityImports.add(named)
            else: result.resources[resource].importedTypeName = typeName
          else:
            result.links.visibilityOrder.addMember(vmResource, result.links.resourceExports.len)
            result.links.resourceExports.add(named)
          resourceAliases.add(ResourceTypeAlias(typeIndex: scope.kinds.len.uint16,
            resourceIndex: resource.uint16, visible: true, imported: importing,
            typeName: typeName))
          publishResourceName(addr scope, typeName, importing)
          scope.kinds.add(cpResourceType)
        elif scope.isFunctionType(valueIndex):
          addPlanFunctionType(result[], scope, valueIndex, name, importing)
          continue
        elif scope.isComponentType(valueIndex):
          addPlanComponentType(result[], scope, valueIndex, name, importing)
          continue
        elif scope.isInstanceType(valueIndex):
          addPlanInstanceType(result[], scope, valueIndex, name, importing)
          continue
        else:
          let value = shapeAt(scope, valueIndex)
          requireVisibleChildren(value, addr scope, importing)
          requireVisibleResourceSlot(result.handleTypes, value, importing,
            "component contract value resource type is not visible", scope = addr scope)
          let shape = newSlot(value)
          let named = NamedValueType(name: name, shape: shape)
          if importing: result.links.valueImports.add(named)
          else:
            if shape.kind in ShapedValues:
              result.links.visibilityOrder.addMember(vmType, result.links.valueExports.len)
            result.links.valueExports.add(named)
          scope.addValueType(shape, if importing: tvImported else: tvExported)
        functions.add(ComponentFuncType())
      of 4'u8:
        let contract = lookupComponentType(componentTypes, takeU32(data, pos, stop))
        if importing:
          discard addComponentTypeImport(result[], name, contract)
        else:
          addComponentDefinitionExport(result[], name, ComponentArgument(plan: contract))
      of 5'u8:
        let index = lookupInterface(interfaceTypes, takeU32(data, pos, stop))
        requireInterfaceNames(interfaceTypes[index], addr scope, forImport = importing)
        let instance = if importing:
            addInterfaceImport(result[], name, interfaceTypes[index], addr scope)
          else:
            result.links.visibilityOrder.addMember(vmInstance, result.links.interfaceExportCount())
            addContractInterfaceExport(result[], name, interfaceTypes[index], addr scope)
        boundedAdd(instances, instance, MaxComponentFunctions)
      else:
        componentFail("unsupported component contract external sort")
    else:
      componentFail("unsupported component contract declaration")
  validateResourceCaptures(result[])

proc childMethods(links: ComponentLinks,
    source: DeclaredInstance): ptr seq[ComponentExport] =
  let child = links.children[source.childIndex].plan
  if source.interfaceIndex == 0:
    addr child.exports
  else:
    addr child.links.exportedInterface(source.interfaceIndex).methods

proc addChildAlias(links: ComponentLinks, source: DeclaredInstance,
                   exportIndex: int): ComponentFunction =
  if not supportedHostSignature(childMethods(links, source)[][exportIndex].signature,
      linkedResources = true):
    componentFail("unsupported linked component signature")
  result = ComponentFunction(kind: fnChild, typeIndex: uint32.high,
    importIndex: links.aliases.len.uint32)
  boundedAdd(links.aliases, ChildExport(childIndex: source.childIndex.uint16,
    interfaceIndex: source.interfaceIndex, exportIndex: exportIndex.uint16),
    MaxComponentFunctions)

proc lookupMethod(links: ComponentLinks, source: DeclaredInstance,
                  name: string): ComponentFunction =
  if source.childIndex < 0:
    for item in source.methods:
      if item.name == name: return item.fn
  else:
    let methods = childMethods(links, source)
    for i, item in methods[]:
      if item.name == name: return addChildAlias(links, source, i)
  componentFail("unknown component instance function: " & name)

iterator nestedInstances(links: ComponentLinks, source: DeclaredInstance): NamedInstance =
  if source.childIndex < 0:
    if source.children != nil:
      for item in source.children[]: yield item
  else:
    let child = links.children[source.childIndex].plan
    if child.links != nil:
      if source.interfaceIndex == 0:
        for i in 0 ..< child.links.interfaceExportCount():
          let item = child.links.exportedInterface((i + 1).uint16)
          yield NamedInstance(name: item.name, value: DeclaredInstance(
            childIndex: source.childIndex, interfaceIndex: (i + 1).uint16,
            visibility: source.visibility))
      else:
        let surface = child.links.exportedInterface(source.interfaceIndex)
        if surface.children != nil:
          for index in surface.children[]:
            let item = child.links.exportedInterface(index)
            yield NamedInstance(name: item.name, value: DeclaredInstance(
              childIndex: source.childIndex, interfaceIndex: index, visibility: source.visibility))

proc lookupNestedInstance(links: ComponentLinks, source: DeclaredInstance,
                          name: string): DeclaredInstance =
  for item in nestedInstances(links, source):
    if item.name == name: return item.value
  componentFail("unknown nested interface export: " & name)

proc coreModuleExports(plan: ref ComponentPlan,
                       interfaceIndex: uint16): ptr seq[NamedCoreModule] =
  if plan.links == nil: return nil
  if interfaceIndex == 0:
    if plan.links.coreModules != nil: return addr plan.links.coreModules.exports
  else:
    let surface = plan.links.exportedInterface(interfaceIndex)
    if surface.coreModules != nil: return addr surface.coreModules[]

iterator instanceCoreModules(links: ComponentLinks,
    source: DeclaredInstance): NamedCoreModule =
  if source.childIndex < 0:
    if source.coreModules != nil:
      for item in source.coreModules[]: yield item
  else:
    let modules = coreModuleExports(links.children[source.childIndex].plan, source.interfaceIndex)
    if modules != nil:
      for i, item in modules[]:
        yield NamedCoreModule(name: item.name, value: CoreModuleValue(
          shape: item.value.moduleShape(), childIndex: (source.childIndex + 1).uint16,
          childInterface: source.interfaceIndex, childExport: i.uint16))

proc lookupInstanceModule(links: ComponentLinks, source: DeclaredInstance,
                           name: string): CoreModuleValue =
  for item in instanceCoreModules(links, source):
    if item.name == name: return item.value
  componentFail("unknown core module export: " & name)

proc componentDefinitionExports(plan: ref ComponentPlan,
    interfaceIndex: uint16): ref seq[NamedComponentDefinition] =
  if plan.links == nil: return nil
  if interfaceIndex == 0: plan.links.componentExports
  else: plan.links.exportedInterface(interfaceIndex).components

proc componentTypeInParent(links: ComponentLinks, source: DeclaredInstance,
                           contract: ref ComponentPlan): ref ComponentPlan =
  if source.childIndex < 0: return contract
  rebaseContractType(contract, links.children[source.childIndex].resourceArgs)

iterator instanceComponents(links: ComponentLinks,
    source: DeclaredInstance): NamedComponentDefinition =
  if source.childIndex < 0:
    if source.components != nil:
      for item in source.components[]: yield item
  else:
    let components = componentDefinitionExports(links.children[source.childIndex].plan,
      source.interfaceIndex)
    if components != nil:
      for i, item in components[]:
        yield NamedComponentDefinition(name: item.name, value: ComponentArgument(
          plan: componentTypeInParent(links, source, item.value.plan),
          childIndex: (source.childIndex + 1).uint16,
          childInterface: source.interfaceIndex, childExport: i.uint16))

proc lookupInstanceComponent(links: ComponentLinks, source: DeclaredInstance,
                              name: string): ComponentArgument =
  for item in instanceComponents(links, source):
    if item.name == name: return item.value
  componentFail("unknown component definition export: " & name)

proc bindResourceName(node: var ChildInstantiation, source, target: ResourceName) =
  if source == nil or target == nil: return
  if node.resourceNameBindings == nil: new(node.resourceNameBindings)
  node.resourceNameBindings[].add((source, target))

proc resourceNameInParent(node: var ChildInstantiation, name: ResourceName): ResourceName =
  if name == nil: return nil
  if node.resourceNameBindings != nil:
    for binding in node.resourceNameBindings[]:
      if binding.source == name: return binding.target
  result = newResourceName()
  node.bindResourceName(name, result)

iterator instanceResourceTypes(links: ComponentLinks,
    source: DeclaredInstance): NamedResourceType =
  if source.childIndex < 0:
    for item in source.resourceTypes: yield item
  else:
    let node = addr links.children[source.childIndex]
    let child = node.plan
    if child.links != nil:
      let resourceTypes = if source.interfaceIndex == 0:
          unsafeAddr child.links.resourceExports
        else:
          unsafeAddr child.links.exportedInterface(source.interfaceIndex).resourceTypes
      for item in resourceTypes[]:
        let index = item.resourceIndex.int
        if index >= node.resourceArgs.len or node.resourceArgs[index] == 0:
          componentFail("component interface has an unlinked resource type")
        yield NamedResourceType(name: item.name, resourceIndex: node.resourceArgs[index] - 1,
          typeName: node[].resourceNameInParent(item.typeName))

iterator instanceValueTypes(links: ComponentLinks,
    source: DeclaredInstance): NamedValueType =
  if source.childIndex < 0:
    for item in source.valueTypes: yield item
  else:
    let child = links.children[source.childIndex].plan
    if child.links != nil:
      let types = if source.interfaceIndex == 0:
          unsafeAddr child.links.valueExports
        else:
          unsafeAddr child.links.exportedInterface(source.interfaceIndex).valueTypes
      for item in types[]: yield item

proc instanceVisibilityOrder(links: ComponentLinks, source: DeclaredInstance): VisibilityOrder =
  if source.childIndex < 0: return source.visibilityOrder
  let child = links.children[source.childIndex].plan
  if child.links == nil: return nil
  if source.interfaceIndex == 0: child.links.visibilityOrder
  else: child.links.exportedInterface(source.interfaceIndex).visibilityOrder

proc instanceTypeExternals(links: ComponentLinks, source: DeclaredInstance): ExternalTypeSurface =
  if source.childIndex < 0: return source.typeExternals
  let child = links.children[source.childIndex].plan
  if child.links == nil: return nil
  if source.interfaceIndex == 0: child.links.typeExports
  else: child.links.exportedInterface(source.interfaceIndex).typeExternals

proc instanceTypeInParent(links: ComponentLinks, source: DeclaredInstance,
                          shape: ref InterfaceType): ref InterfaceType =
  if source.childIndex < 0: return shape
  rebaseInstanceType(shape, links.children[source.childIndex].resourceArgs)

iterator instanceFunctionTypes(links: ComponentLinks,
    source: DeclaredInstance): NamedFunctionType =
  let types = functionsIn(instanceTypeExternals(links, source))
  if types != nil:
    for item in types[]: yield item

proc findExternalComponentType(surface: ExternalTypeSurface, name: string): ref ComponentPlan =
  let types = componentsIn(surface)
  if types != nil:
    for item in types[]:
      if item.name == name: return item.plan

proc requireExternalComponentType(surface: ExternalTypeSurface, name: string): ref ComponentPlan =
  result = findExternalComponentType(surface, name)
  if result == nil: componentFail("missing component type: " & name)

proc findInstanceValueType(links: ComponentLinks, source: DeclaredInstance,
                           needed: NamedValueType): NamedValueType =
  for actual in instanceValueTypes(links, source):
    if actual.name != needed.name: continue
    if actual.shape[] != needed.shape[]:
      componentFail("component instance value type mismatch: " & needed.name)
    return actual
  componentFail("missing component instance value type: " & needed.name)

proc instanceHandlesInParent(plan: var ComponentPlan, source: DeclaredInstance,
    indices: openArray[uint16], visibility = tvImported): ResourceTypeMapping =
  let child = addr plan.links.children[source.childIndex]
  for index in indices:
    let handle = lookupResourceType(child.plan.handleTypes, index.uint32)
    let ordinal = if handle < 0: -1 else: child.plan.handleTypes[handle].resourceIndex.int
    if ordinal < 0 or ordinal >= child.resourceArgs.len or child.resourceArgs[ordinal] == 0:
      componentFail("unbound component value resource type")
    let local = child.resourceArgs[ordinal] - 1
    let name = child[].resourceNameInParent(child.plan.handleTypes[handle].typeName)
    result.add((index, plan.bindResourceHandleIndex(local, visibility, name).uint16))

proc valueTypeInParent(plan: var ComponentPlan, source: DeclaredInstance,
                       shape: ref CanonicalSlot): ref CanonicalSlot =
  if source.childIndex < 0: return shape
  let node = addr plan.links.children[source.childIndex]
  var indices: seq[uint16]
  if shape.resources != {}: collectResourceTypes(shape[], indices)
  let handles = instanceHandlesInParent(plan, source, indices, source.visibility)
  if node.valueTypeArguments != nil:
    return projectValueShape(shape, node[], handles)
  rebaseResourceShape(shape, handles, nil)

proc functionTypeInParent(plan: var ComponentPlan, source: DeclaredInstance,
                           signature: ComponentFuncType): ComponentFuncType =
  if source.childIndex < 0: return signature
  let indices = signatureResourceTypes(signature)
  if indices.len == 0: return signature
  rebaseResourceSignature(signature, instanceHandlesInParent(plan, source, indices, source.visibility))

proc functionNamesInParent(plan: var ComponentPlan, source: DeclaredInstance,
                           names: FunctionTypeNames): FunctionTypeNames =
  result = names
  if names == nil or source.childIndex < 0 or
      plan.links.children[source.childIndex].valueTypeArguments == nil: return
  for i, name in names[]:
    let shape = plan.valueTypeInParent(source, name.shape)
    if shape == name.shape: continue
    if result == names:
      new(result)
      result[] = names[]
    result[][i].shape = shape

proc componentFunctionNames(plan: var ComponentPlan, fn: ComponentFunction,
                            scope: ptr ShapeScope): FunctionTypeNames =
  if fn.typeIndex != uint32.high:
    return functionTypeNames(scope, fn.typeIndex)
  if fn.kind == fnChild:
    let alias = plan.links.aliases[fn.importIndex.int]
    let child = childFunctionExport(plan.links, fn.importIndex.int)
    return plan.functionNamesInParent(DeclaredInstance(childIndex: alias.childIndex.int),
      child.visibilityNames)
  plan.imports[fn.importIndex.int].visibilityNames

proc componentFunctionResources(plan: var ComponentPlan, fn: ComponentFunction,
    signature: ComponentFuncType, scope: ptr ShapeScope): ResourceNames =
  if fn.typeIndex != uint32.high:
    return resourceNames(scope.functionTypes[][fn.typeIndex.int], plan.handleTypes)
  if fn.kind == fnImport:
    return resourceNames(signature, plan.handleTypes)
  let alias = plan.links.aliases[fn.importIndex.int]
  let node = addr plan.links.children[alias.childIndex.int]
  let child = childFunctionExport(plan.links, fn.importIndex.int)
  if child.resourceNames != nil:
    new(result)
    for name in child.resourceNames[]:
      result[].add(node[].resourceNameInParent(name))

proc namedValueInParent(plan: var ComponentPlan, source: DeclaredInstance,
                        value: NamedValueType): NamedValueType =
  result = value
  result.shape = plan.valueTypeInParent(source, value.shape)
  if source.childIndex >= 0 and plan.links.children[source.childIndex].valueTypeArguments != nil:
    result.origin = nil
  else:
    result.origin = value.namedOrigin()

proc findInstanceFunctionType(links: ComponentLinks, source: DeclaredInstance,
                               name: string): NamedFunctionType =
  for item in instanceFunctionTypes(links, source):
    if item.name == name: return item
  componentFail("missing component instance function type: " & name)

proc matchTypeResourceBindings(parent: ComponentPlan, childTypes: openArray[ResourceTypeAlias],
    actualTypes, expectedTypes, resources: openArray[uint16], substitute = true): bool =
  if actualTypes.len != expectedTypes.len: return false
  for i, index in actualTypes:
    let source = resourceIndex(parent.handleTypes, index.uint32)
    let target = resourceIndex(childTypes, expectedTypes[i].uint32)
    if source < 0 or target < 0:
      return false
    if substitute:
      if target >= resources.len or resources[target].int != source + 1: return false
    elif target != source:
      return false
  true

proc matchValueResourceBindings(parent: ComponentPlan, childTypes: openArray[ResourceTypeAlias],
    actual, expected: CanonicalSlot, resources: openArray[uint16], substitute = true): bool =
  var actualTypes, expectedTypes: seq[uint16]
  collectResourceTypes(actual, actualTypes)
  collectResourceTypes(expected, expectedTypes)
  matchTypeResourceBindings(parent, childTypes, actualTypes, expectedTypes, resources, substitute)

proc requireInstanceResource(links: ComponentLinks, source: DeclaredInstance,
                             name: string): NamedResourceType =
  for item in instanceResourceTypes(links, source):
    if item.name == name: return item
  componentFail("missing component instance resource type: " & name)

type
  InterfaceProjection = object
    source: uint16
    methods: seq[int]
    coreModules: seq[int]
    components: seq[int]

  ComponentProjection = object
    imports: seq[int]            # provider import order to contract import order
    exports: seq[int]            # contract export order to provider export order
    interfaces: seq[InterfaceProjection]
    nestedInterfaces: seq[InterfaceProjection]
    moduleImports, moduleExports: seq[int]
    componentImports, componentExports: seq[int]
    resourceImports: seq[uint16] # provider ordinal to one-based contract ordinal
    resourceExports: seq[uint16] # abstract contract export ordinal to one-based provider ordinal
    nominalResources: bool      # instance type resources were bound before projection

  TypeResourceBindings = object
    projection: ptr ComponentProjection
    arguments: ptr seq[uint16] # required ordinal to one-based provided ordinal
    lexical: ptr LexicalResourceComparison
    importing: bool

  LexicalResourceComparison = object
    provided: ptr seq[CapturedResource]
    required: ptr seq[ResourceLocation]

proc componentImportCount(plan: ComponentPlan): int =
  if plan.links == nil or plan.links.componentImports == nil: 0
  else: plan.links.componentImports[].len

proc findComponentImport(components: openArray[NamedComponentType], name: string): int =
  for i, item in components:
    if not item.interfaceImport and item.name == name: return i
  -1

proc contractResource(plan: ComponentPlan, name: string, importing: bool): int =
  if importing:
    for i, item in plan.resources:
      if item.importInterface == 0 and item.importName == name: return i
    if plan.links != nil:
      for item in plan.links.resourceEqualityImports:
        if item.name == name: return item.resourceIndex.int
  elif plan.links != nil:
    for item in plan.links.resourceExports:
      if item.name == name: return item.resourceIndex.int
  -1

proc sameProviderResource(projection: ComponentProjection, a, b: int): bool =
  a == b or (projection.resourceImports[a] != 0 and
             projection.resourceImports[a] == projection.resourceImports[b])

proc matchesProjectedResource(projection: ComponentProjection, provided, required: int): bool =
  if provided < 0 or provided >= projection.resourceImports.len or
      required < 0 or required >= projection.resourceExports.len: return false
  let implementation = projection.resourceExports[required].int
  if implementation == 0:
    not projection.nominalResources and projection.resourceImports[provided].int == required + 1
  else:
    projection.sameProviderResource(provided, implementation - 1)

proc sameCaptureSource(resources: TypeResourceBindings, a, b: LexicalResource): bool =
  if a.depth != 1 or b.depth != 1: componentFail("unbound component type resource")
  if resources.arguments != nil:
    return b.ordinal.int < resources.arguments[].len and
      resources.arguments[][b.ordinal] == a.ordinal + 1
  if resources.projection != nil:
    if resources.importing:
      return resources.projection[].matchesProjectedResource(b.ordinal.int, a.ordinal.int)
    return resources.projection[].matchesProjectedResource(a.ordinal.int, b.ordinal.int)
  a.ordinal == b.ordinal

proc sameLexicalResource(lexical: LexicalResourceComparison, slot, required: uint16): bool =
  if required.int >= lexical.required[].len: return false
  let expected = lexical.required[][required]
  if expected.frame == nil: return false
  for item in lexical.provided[]:
    if item.slot == slot: return item.origin == expected

proc bindProjectedCaptures(projection: var ComponentProjection, provider, contract: ComponentPlan,
                           enclosing: TypeResourceBindings) {.noinline.} =
  let provided = provider.contractResources()
  let required = contract.contractResources()
  if provided == nil or required == nil: return
  for a in provided.captures:
    if InterfaceResourceOrdinal(a.slot) notin provided.used: continue
    for b in required.captures:
      if InterfaceResourceOrdinal(b.slot) notin required.used: continue
      let same = if enclosing.lexical != nil:
          sameLexicalResource(enclosing.lexical[], a.slot, b.source.ordinal)
        else: enclosing.sameCaptureSource(a.source, b.source)
      if not same: continue
      if projection.resourceImports[a.slot] == 0:
        projection.resourceImports[a.slot] = b.slot + 1
      if projection.resourceExports[b.slot] == 0:
        projection.resourceExports[b.slot] = a.slot + 1

proc requireContractFunction(provider, contract: ComponentPlan, actual: ComponentExport,
                             required: ComponentFuncType, projection: ComponentProjection) =
  if not matchComponentFunction(actual.signature, required):
    componentFail("component import function type mismatch: " & actual.name)
  let actualTypes = signatureResourceTypes(actual.signature)
  let requiredTypes = signatureResourceTypes(required)
  if actualTypes.len != requiredTypes.len:
    componentFail("component import function resource type mismatch: " & actual.name)
  for i, index in actualTypes:
    let fromType = resourceOfExport(provider, actual, index.int32)
    let toType = resourceIndex(contract.handleTypes, requiredTypes[i].uint32)
    if not projection.matchesProjectedResource(fromType, toType):
      componentFail("component import function resource type mismatch: " & actual.name)

proc requireContractValue(provider, contract: ComponentPlan, actual: NamedValueType,
                          required: ref CanonicalSlot, projection: ComponentProjection) =
  if required == nil or actual.shape[] != required[]:
    componentFail("component import value type mismatch: " & actual.name)
  var actualTypes, requiredTypes: seq[uint16]
  collectResourceTypes(actual.shape[], actualTypes)
  collectResourceTypes(required[], requiredTypes)
  if actualTypes.len != requiredTypes.len:
    componentFail("component import value resource type mismatch: " & actual.name)
  for i, index in actualTypes:
    let provided = resourceIndex(provider.handleTypes, index.uint32)
    let expected = resourceIndex(contract.handleTypes, requiredTypes[i].uint32)
    if not projection.matchesProjectedResource(provided, expected):
      componentFail("component import value resource type mismatch: " & actual.name)

proc findSurface[T: InterfaceImport | InterfaceExport | NamedComponentType | NamedComponentDefinition](
    list: openArray[T], name: string): int =
  for i, item in list:
    if item.name == name: return i
  -1

proc findNamedResource(list: openArray[NamedResourceType], name: string): int =
  for item in list:
    if item.name == name: return item.resourceIndex.int
  -1

proc findNamedValue(list: openArray[NamedValueType], name: string): ref CanonicalSlot =
  for item in list:
    if item.name == name: return item.shape

proc matchFunctionTypeSurface(provided, required: ref seq[NamedFunctionType],
    provider, contract: ComponentPlan, projection: ComponentProjection, importing = false) =
  let matched = if importing: provided else: required
  let available = if importing: required else: provided
  if matched == nil: return
  for need in matched[]:
    var found = false
    if available != nil:
      for have in available[]:
        if have.name != need.name: continue
        let source = if importing: unsafeAddr need else: unsafeAddr have
        let target = if importing: unsafeAddr have else: unsafeAddr need
        requireContractFunction(provider, contract,
          ComponentExport(name: source.name, signature: source.signature), target.signature, projection)
        found = true
        break
    if not found: componentFail("missing component function type: " & need.name)

proc bindProjectedImport(projection: var ComponentProjection, provided, required: int,
                         name: string) =
  let binding = projection.resourceImports[provided].int
  if binding != 0 and binding != required + 1:
    componentFail("component import resource equality mismatch: " & name)
  projection.resourceImports[provided] = (required + 1).uint16

proc bindProjectedExport(projection: var ComponentProjection, contract: ComponentPlan,
                         provided: int, required: NamedResourceType) =
  if provided < 0:
    componentFail("component import provider lacks resource export: " & required.name)
  let expected = required.resourceIndex.int
  if not projection.nominalResources and contract.resources[expected].importName.len == 0 and
      contract.contractResourceCapture(expected).depth == 0 and projection.resourceExports[expected] == 0:
    projection.resourceExports[expected] = (provided + 1).uint16
  elif not projection.matchesProjectedResource(provided, expected):
    componentFail("component import resource export type mismatch: " & required.name)

proc findNestedImport(parent: InterfaceImport, name: string): ptr InterfaceImport =
  if parent.children != nil:
    for i in 0 ..< parent.children[].len:
      if parent.children[][i].name == name: return unsafeAddr parent.children[][i]
  componentFail("component import requires nested interface: " & name)

proc bindProjectedInterfaceImport(projection: var ComponentProjection, provider: ComponentPlan,
    provided, required: InterfaceImport, depth: int) =
  if depth >= MaxInstanceNesting: componentFail("instance import nesting limit")
  for item in provided.resourceTypes:
    let resource = findNamedResource(required.resourceTypes, item.name)
    if resource < 0:
      componentFail("component import requires interface resource: " & item.name)
    if provider.contractResourceCapture(item.resourceIndex.int).depth != 0:
      if not projection.matchesProjectedResource(item.resourceIndex.int, resource):
        componentFail("component import resource equality mismatch: " & item.name)
    else:
      projection.bindProjectedImport(item.resourceIndex.int, resource, item.name)
  if provided.children != nil:
    for child in provided.children[]:
      let expected = findNestedImport(required, child.name)
      projection.bindProjectedInterfaceImport(provider, child, expected[], depth + 1)

proc projectComponentAtDepth(provider, contract: ComponentPlan, depth: int,
    remaining: var int, enclosing = TypeResourceBindings()): ComponentProjection

proc requireInstanceTypeSubtype(provided, required: ref InterfaceType,
    resources: TypeResourceBindings, depth: int, remaining: var int) {.noinline.}

proc matchExternalTypeSurface(provided, required: ExternalTypeSurface,
    projection: ptr ComponentProjection, depth: int, remaining: var int, importing = false) =
  let matched = componentsIn(if importing: provided else: required)
  let available = if importing: required else: provided
  if matched != nil:
    for item in matched[]:
      let bound = requireExternalComponentType(available, item.name)
      discard projectComponentAtDepth(bound[], item.plan[], depth + 1, remaining,
        TypeResourceBindings(projection: projection, importing: importing))
  let instances = instancesIn(if importing: provided else: required)
  if instances != nil:
    for item in instances[]:
      let bound = requireExternalInstanceType(available, item.name)
      requireInstanceTypeSubtype(bound, item.shape,
        TypeResourceBindings(projection: projection, importing: importing), depth + 1, remaining)

proc projectInterfaceImport(projection: var ComponentProjection,
    provider, contract: ComponentPlan, provided, required: InterfaceImport,
    depth, comparisonDepth: int, remaining: var int) =
  if depth >= MaxInstanceNesting: componentFail("instance import nesting limit")
  if provided.coreModules != nil:
    for item in provided.coreModules[]:
      let index = if required.coreModules == nil: -1
        else: findModuleName(required.coreModules[], item.name)
      if index < 0: componentFail("component import requires interface core module: " & item.name)
      let supplied = required.coreModules[][index].value
      requireModuleSubtype(supplied.shape, item.value.shape)
      projection.moduleImports[item.value.importIndex.int - 1] = supplied.importIndex.int - 1
  if provided.components != nil:
    for item in provided.components[]:
      let index = if required.components == nil: -1
        else: findSurface(required.components[], item.name)
      if index < 0: componentFail("component import requires interface component: " & item.name)
      let supplied = required.components[][index].value
      discard projectComponentAtDepth(supplied.plan[], item.value.plan[],
        comparisonDepth + 1, remaining, TypeResourceBindings(projection: addr projection, importing: true))
      projection.componentImports[item.value.importIndex.int - 1] = supplied.importIndex.int - 1
  for item in provided.valueTypes:
    requireContractValue(provider, contract, item, findNamedValue(required.valueTypes, item.name),
      projection)
  matchFunctionTypeSurface(provided.functionTypes, required.functionTypes,
    provider, contract, projection, importing = true)
  matchExternalTypeSurface(provided.typeExternals, required.typeExternals,
    addr projection, comparisonDepth, remaining, importing = true)
  for i in provided.firstBinding ..< provided.firstBinding + provided.bindingCount:
    let actual = unsafeAddr provider.imports[i]
    var found = false
    for j in required.firstBinding ..< required.firstBinding + required.bindingCount:
      let expected = unsafeAddr contract.imports[j]
      if actual.name != expected.name: continue
      requireContractFunction(provider, contract,
        ComponentExport(name: actual.name, signature: actual.signature),
        expected.signature, projection)
      projection.imports[i] = j
      found = true
      break
    if not found: componentFail("component import requires function: " & actual.name)
  if provided.children != nil:
    for child in provided.children[]:
      let expected = findNestedImport(required, child.name)
      projection.projectInterfaceImport(provider, contract, child, expected[],
        depth + 1, comparisonDepth, remaining)

proc findNestedExport(links: ComponentLinks, parent: InterfaceExport, name: string): uint16 =
  if parent.children != nil:
    for index in parent.children[]:
      if links.exportedInterface(index).name == name: return index
  componentFail("component import provider lacks nested interface export: " & name)

proc nestedInterfaceOffset(index: uint16): int =
  int(index and not NestedInterfaceIndex)

proc bindProjectedInterfaceExport(projection: var ComponentProjection,
    provider, contract: ComponentPlan, provided, required: uint16, depth: int) =
  if depth >= MaxInstanceNesting: componentFail("instance export nesting limit")
  let actual = provider.links.exportedInterface(provided)
  let expected = contract.links.exportedInterface(required)
  for item in expected.resourceTypes:
    projection.bindProjectedExport(contract, findNamedResource(actual.resourceTypes, item.name), item)
  if expected.children != nil:
    for child in expected.children[]:
      let member = contract.links.exportedInterface(child)
      let matched = findNestedExport(provider.links, actual[], member.name)
      projection.nestedInterfaces[nestedInterfaceOffset(child)].source = matched
      projection.bindProjectedInterfaceExport(provider, contract, matched, child, depth + 1)

proc projectInterfaceExport(projection: ComponentProjection, provider, contract: ComponentPlan,
    provided, required: uint16, comparisonDepth: int, remaining: var int): InterfaceProjection =
  let actual = provider.links.exportedInterface(provided)
  let expected = contract.links.exportedInterface(required)
  result.source = provided
  if expected.coreModules != nil:
    for item in expected.coreModules[]:
      let index = if actual.coreModules == nil: -1
        else: findModuleName(actual.coreModules[], item.name)
      if index < 0:
        componentFail("component import provider lacks interface core module: " & item.name)
      requireModuleSubtype(actual.coreModules[][index].value.moduleShape(), item.value.shape)
      result.coreModules.add(index)
  if expected.components != nil:
    for item in expected.components[]:
      let index = if actual.components == nil: -1
        else: findSurface(actual.components[], item.name)
      if index < 0:
        componentFail("component import provider lacks interface component: " & item.name)
      discard projectComponentAtDepth(actual.components[][index].value.plan[],
        item.value.plan[], comparisonDepth + 1, remaining,
        TypeResourceBindings(projection: unsafeAddr projection))
      result.components.add(index)
  for item in expected.valueTypes:
    let shape = findNamedValue(actual.valueTypes, item.name)
    if shape == nil: componentFail("component import provider lacks interface value: " & item.name)
    requireContractValue(provider, contract, NamedValueType(name: item.name, shape: shape),
      item.shape, projection)
  matchFunctionTypeSurface(actual.functionTypes, expected.functionTypes,
    provider, contract, projection)
  matchExternalTypeSurface(actual.typeExternals, expected.typeExternals,
    unsafeAddr projection, comparisonDepth, remaining)
  for item in expected.methods:
    var source = -1
    for j, providerMethod in actual.methods:
      if providerMethod.name == item.name:
        requireContractFunction(provider, contract, providerMethod, item.signature, projection)
        source = j
        break
    if source < 0: componentFail("component import provider lacks interface function: " & item.name)
    result.methods.add(source)

proc projectDefinitionTypes(projection: var ComponentProjection, provider: ComponentPlan,
    requiredLinks: ComponentLinks, depth: int, remaining: var int) {.noinline.} =
  if provider.componentImportCount() != 0:
    projection.componentImports.setLen(provider.links.componentImports[].len)
    for i, item in provider.links.componentImports[]:
      projection.componentImports[i] = -1
      if item.interfaceImport: continue
      let source = if requiredLinks.componentImports == nil: -1
        else: findComponentImport(requiredLinks.componentImports[], item.name)
      if source < 0: componentFail("component import requires component: " & item.name)
      # A caller authorized by the contract supplies the import. The
      # provider must accept every definition that satisfies that promise.
      let supplied = requiredLinks.componentImports[][source].plan
      discard projectComponentAtDepth(supplied[], item.plan[], depth + 1, remaining,
        TypeResourceBindings(projection: addr projection, importing: true))
      projection.componentImports[i] = source
  if requiredLinks.componentExports != nil:
    for item in requiredLinks.componentExports[]:
      let source = if provider.links == nil or provider.links.componentExports == nil: -1
        else: findSurface(provider.links.componentExports[], item.name)
      if source < 0: componentFail("component import provider lacks component export: " & item.name)
      let supplied = provider.links.componentExports[][source].value.plan
      discard projectComponentAtDepth(supplied[], item.value.plan[], depth + 1, remaining,
        TypeResourceBindings(projection: addr projection))
      projection.componentExports.add(source)

proc projectComponentAtDepth(provider, contract: ComponentPlan, depth: int,
                             remaining: var int, enclosing: TypeResourceBindings): ComponentProjection =
  if depth >= MaxComponentContractNesting or remaining == 0:
    componentFail("component contract comparison limit")
  dec remaining
  let requiredLinks = if contract.links == nil: ComponentLinks() else: contract.links
  let actual = if provider.links == nil: nil else: provider.links.coreModules
  let expected = requiredLinks.coreModules
  if actual != nil:
    result.moduleImports.setLen(actual.imports.len)
    for i, item in actual.imports:
      result.moduleImports[i] = -1
      if item.interfaceImport: continue
      let source = if expected == nil: -1 else: findModuleImport(expected.imports, item.name)
      if source < 0: componentFail("component import requires core module: " & item.name)
      requireModuleSubtype(expected.imports[source].value.shape, item.value.shape)
      result.moduleImports[i] = source
  if expected != nil:
    for item in expected.exports:
      let source = if actual == nil: -1 else: findModuleName(actual.exports, item.name)
      if source < 0: componentFail("component import provider lacks core module: " & item.name)
      requireModuleSubtype(actual.exports[source].value.moduleShape(), item.value.shape)
      result.moduleExports.add(source)
  result.resourceImports.setLen(provider.resources.len)
  result.resourceExports.setLen(contract.resources.len)
  result.bindProjectedCaptures(provider, contract, enclosing)
  for i, item in provider.resources:
    if item.importName.len == 0 or item.importInterface != 0: continue
    let required = contractResource(contract, item.importName, importing = true)
    if required < 0: componentFail("component import requires resource: " & item.importName)
    result.bindProjectedImport(i, required, item.importName)
  var importInterfaces: seq[int]
  if provider.links != nil:
    for iface in provider.links.interfaceImports:
      let index = findSurface(requiredLinks.interfaceImports, iface.name)
      if index < 0: componentFail("component import requires interface: " & iface.name)
      importInterfaces.add(index)
      let required = unsafeAddr requiredLinks.interfaceImports[index]
      result.bindProjectedInterfaceImport(provider, iface, required[], 0)
  if provider.links != nil:
    for item in provider.links.resourceEqualityImports:
      let required = contractResource(contract, item.name, importing = true)
      if required < 0 or result.resourceImports[item.resourceIndex.int].int != required + 1:
        componentFail("component import resource equality mismatch: " & item.name)
  for item in requiredLinks.resourceExports:
    result.bindProjectedExport(contract, contractResource(provider, item.name, importing = false), item)
  if requiredLinks.nestedInterfaceExports != nil:
    result.nestedInterfaces.setLen(requiredLinks.nestedInterfaceExports[].len)
  for i in 0 ..< requiredLinks.interfaceExportCount():
    let iface = requiredLinks.exportedInterface((i + 1).uint16)
    let index = if provider.links.interfaceExportCount() == 0: -1
      else: findSurface(provider.links.interfaceExports[], iface.name)
    if index < 0: componentFail("component import provider lacks interface export: " & iface.name)
    result.interfaces.add(InterfaceProjection(source: (index + 1).uint16))
    result.bindProjectedInterfaceExport(provider, contract, (index + 1).uint16, (i + 1).uint16, 0)
  result.projectDefinitionTypes(provider, requiredLinks, depth, remaining)
  result.imports.setLen(provider.imports.len)
  if provider.links != nil:
    for item in provider.links.valueImports:
      requireContractValue(provider, contract, item,
        findNamedValue(requiredLinks.valueImports, item.name), result)
    for i, iface in provider.links.interfaceImports:
      let expected = unsafeAddr requiredLinks.interfaceImports[importInterfaces[i]]
      result.projectInterfaceImport(provider, contract, iface, expected[], 0, depth, remaining)
    matchFunctionTypeSurface(provider.links.functionTypeImports, requiredLinks.functionTypeImports,
      provider, contract, result, importing = true)
    matchExternalTypeSurface(provider.links.typeImports, requiredLinks.typeImports,
      addr result, depth, remaining, importing = true)
  for source in result.componentImports:
    if source < 0: componentFail("unresolved component import definition")
  for source in result.moduleImports:
    if source < 0: componentFail("unresolved component import core module")
  for item in requiredLinks.valueExports:
    let actual = if provider.links == nil: nil else: findNamedValue(provider.links.valueExports, item.name)
    if actual == nil:
      componentFail("component import provider lacks value export: " & item.name)
    requireContractValue(provider, contract, NamedValueType(name: item.name, shape: actual),
      item.shape, result)
  let functionTypes = if provider.links == nil: nil else: provider.links.functionTypeExports
  matchFunctionTypeSurface(functionTypes, requiredLinks.functionTypeExports,
    provider, contract, result)
  let typeExports = if provider.links == nil: nil else: provider.links.typeExports
  matchExternalTypeSurface(typeExports, requiredLinks.typeExports, addr result, depth, remaining)
  for index, item in provider.imports:
    if item.interfaceIndex != 0: continue
    var source = -1
    for i, required in contract.imports:
      if item.name == required.name and required.interfaceIndex == 0:
        requireContractFunction(provider, contract,
          ComponentExport(name: item.name, signature: item.signature),
          required.signature, result)
        source = i
        break
    if source < 0: componentFail("component import requires function: " & item.name)
    result.imports[index] = source
  for item in contract.exports:
    var source = -1
    for i, actual in provider.exports:
      if item.name == actual.name:
        requireContractFunction(provider, contract, actual, item.signature, result)
        source = i
        break
    if source < 0: componentFail("component import provider lacks function export: " & item.name)
    result.exports.add(source)
  for i in 0 ..< result.interfaces.len:
    result.interfaces[i] = result.projectInterfaceExport(provider, contract,
      result.interfaces[i].source, (i + 1).uint16, depth, remaining)
  for i in 0 ..< result.nestedInterfaces.len:
    result.nestedInterfaces[i] = result.projectInterfaceExport(provider, contract,
      result.nestedInterfaces[i].source, NestedInterfaceIndex or i.uint16, depth, remaining)

proc projectComponent(provider, contract: ComponentPlan,
                      enclosing = TypeResourceBindings()): ComponentProjection =
  var remaining = MaxComponentContractComparisons
  projectComponentAtDepth(provider, contract, 0, remaining, enclosing)

proc requireComponentSubtype(provider, contract: ComponentPlan,
                             enclosing = TypeResourceBindings()) {.noinline.} =
  discard projectComponent(provider, contract, enclosing)

proc dynamicDefinition(value: ComponentArgument): bool =
  value.importIndex != 0 or value.childIndex != 0 or value.localIndex != 0 or
    value.captureIndex != 0

proc externalDefinition(value: ComponentArgument): bool =
  value.dynamicDefinition() or value.implementation != nil

proc ascribeComponent(value: var ComponentArgument, contract: ref ComponentPlan) =
  requireComponentSubtype(value.plan[], contract[])
  if not value.externalDefinition(): value.implementation = value.plan
  value.plan = contract

proc definitionAt(definitions: ComponentDefinitionScope, index: uint32): ComponentArgument =
  if index >= definitions.plans.len.uint32: componentFail("unknown component definition")
  for item in definitions.sources:
    if item.index.uint32 == index: return item.value
  ComponentArgument(plan: definitions.plans[index.int])

proc addDefinition(definitions: var ComponentDefinitionScope, value: ComponentArgument) =
  let index = definitions.plans.len.uint16
  boundedAdd(definitions.plans, value.plan, MaxComponentFunctions)
  if value.externalDefinition(): definitions.sources.add((index, value))

proc readInlineInstance(data: openArray[byte], pos: var int, stop: int,
                        functions: openArray[ComponentFunction],
                        resourceAliases: openArray[ResourceTypeAlias],
                        scope: ShapeScope, instances: openArray[DeclaredInstance]): DeclaredInstance =
  result.childIndex = -1
  let count = takeCount(data, pos, stop, MaxComponentFunctions)
  for _ in 0 ..< count:
    let external = takeExternalName(data, pos, stop)
    let name = external.name
    # Inline instances add no type indices and have no resource-name namespace.
    if resourceMember(name).kind != rmNone:
      componentFail("resource member names a type absent from its interface")
    for item in result.methods:
      if sameCanonicalName(item.name, name):
        componentFail("duplicate inline instance export")
    for item in result.resourceTypes:
      if sameCanonicalName(item.name, name):
        componentFail("duplicate inline instance export")
    for item in result.valueTypes:
      if sameCanonicalName(item.name, name):
        componentFail("duplicate inline instance export")
    if result.children != nil:
      for item in result.children[]:
        if sameCanonicalName(item.name, name):
          componentFail("duplicate inline instance export")
    if result.coreModules != nil:
      for item in result.coreModules[]:
        if sameCanonicalName(item.name, name):
          componentFail("duplicate inline instance export")
    if result.components != nil:
      for item in result.components[]:
        if sameCanonicalName(item.name, name):
          componentFail("duplicate inline instance export")
    if result.functionTypes != nil:
      for item in result.functionTypes[]:
        if sameCanonicalName(item.name, name):
          componentFail("duplicate inline instance export")
    let componentTypes = componentsIn(result.typeExternals)
    if componentTypes != nil:
      for item in componentTypes[]:
        if sameCanonicalName(item.name, name):
          componentFail("duplicate inline instance export")
    let instanceTypes = instancesIn(result.typeExternals)
    if instanceTypes != nil:
      for item in instanceTypes[]:
        if sameCanonicalName(item.name, name):
          componentFail("duplicate inline instance export")
    let sort = external.sort
    if sort == 0 and take(data, pos, stop) != 0x11:
      componentFail("unsupported inline instance core sort")
    let index = takeU32(data, pos, stop)
    case sort
    of 0'u8:
      let value = typedModuleValue(scope.corePlan[], scope.coreModuleValues[], index)
      result.coreModules.addInstanceModule(NamedCoreModule(name: name, value: value))
    of 1'u8:
      if index >= functions.len.uint32:
        componentFail("unknown inline instance function")
      result.visibilityOrder.addMember(vmFunction, result.methods.len)
      result.methods.add(NamedComponentMethod(name: name, fn: functions[index.int]))
    of 3'u8:
      if scope.isInstanceType(index):
        result.typeExternals.addNamedInstanceType(NamedInstanceType(name: name,
          shape: instanceTypeAt(scope, index)))
      elif scope.isComponentType(index):
        let contract = lookupComponentType(scope.componentTypes[], index)
        result.typeExternals.addNamedComponentType(NamedComponentType(name: name, plan: contract))
      elif scope.isFunctionType(index):
        result.typeExternals.addExportedFunctionType(result.visibilityOrder,
          namedFunctionType(unsafeAddr scope, index, name))
      else:
        let alias = lookupResourceType(resourceAliases, index)
        if alias < 0:
          let shape = outerValueShape(unsafeAddr scope, index)
          if shape.kind in ShapedValues or shape.resources != {}:
            result.visibilityOrder.addMember(vmType, result.valueTypes.len)
          result.valueTypes.add(NamedValueType(name: name, shape: shape))
        else:
          result.visibilityOrder.addMember(vmResource, result.resourceTypes.len)
          result.resourceTypes.add(NamedResourceType(name: name,
            resourceIndex: resourceAliases[alias].resourceIndex,
            typeName: resourceAliases[alias].typeName))
    of 4'u8:
      let value = scope.componentDefinitions[].definitionAt(index)
      result.components.addInstanceComponent(NamedComponentDefinition(name: name, value: value))
    of 5'u8:
      if index >= instances.len.uint32: componentFail("unknown inline instance")
      if result.children == nil: new(result.children)
      result.visibilityOrder.addMember(vmInstance, result.children[].len)
      boundedAdd(result.children[], NamedInstance(name: name, value: instances[index.int]),
        MaxComponentFunctions)
    else:
      componentFail("unsupported inline instance export sort")

type
  InstanceTypeBinding = object
    actual, expected: seq[uint16]
    error: string

  InstantiationTypeBindings = object
    valuesAndFunctions: seq[InstanceTypeBinding]
    instances: seq[tuple[actual, expected: ref InterfaceType]]
    components: seq[tuple[actual, expected: ref ComponentPlan]]

proc requireInstanceTypeSubtype(provided, required: ref InterfaceType,
                                resources = TypeResourceBindings())

proc collectValueBinding(bindings: var seq[InstanceTypeBinding],
    actual, expected: CanonicalSlot, name: string) =
  var binding = InstanceTypeBinding(error: "component instantiation value resource type mismatch: " & name)
  collectResourceTypes(actual, binding.actual)
  collectResourceTypes(expected, binding.expected)
  bindings.add(move binding)

proc bindValueType(node: var ChildInstantiation, expected, actual: ref CanonicalSlot) =
  if expected.kind notin ShapedValues or expected == actual: return
  if node.valueTypeArguments == nil: new(node.valueTypeArguments)
  node.valueTypeArguments[].add((expected, actual))

proc checkFunctionTypeBinding(bindings: var seq[InstanceTypeBinding], actual,
                               expected: ComponentFuncType, name: string) =
  if not matchComponentFunction(actual, expected):
    componentFail("component instantiation function type mismatch: " & name)
  let handles = signatureResourceTypes(expected)
  if handles.len != 0:
    bindings.add(InstanceTypeBinding(error: "component instantiation function resource type mismatch: " & name,
      actual: signatureResourceTypes(actual), expected: handles))

proc bindInstanceArgument(plan: var ComponentPlan, node: var ChildInstantiation,
    required: InterfaceImport, source: DeclaredInstance,
    typeBindings: var InstantiationTypeBindings, types: openArray[ComponentFuncType],
    coreInstances: openArray[CoreInstance], coreFunctions: openArray[CoreFunction],
    memories: openArray[CoreExportAlias], depth: int) =
  if depth >= MaxInstanceNesting: componentFail("instance argument nesting limit")
  if required.coreModules != nil:
    for item in required.coreModules[]:
      let available = lookupInstanceModule(plan.links, source, item.name)
      requireModuleSubtype(available.moduleShape(), item.value.shape)
      node.coreModuleArguments[][item.value.importIndex.int - 1] = available
  if required.components != nil:
    for item in required.components[]:
      let available = lookupInstanceComponent(plan.links, source, item.name)
      typeBindings.components.add((available.plan, item.value.plan))
      node.componentArguments.arguments[item.value.importIndex.int - 1] = available
  for item in required.valueTypes:
    let provided = findInstanceValueType(plan.links, source, item)
    let view = plan.valueTypeInParent(source, provided.shape)
    node.bindValueType(item.shape, view)
    if item.shape.resources != {}:
      typeBindings.valuesAndFunctions.collectValueBinding(view[], item.shape[], item.name)
  if required.functionTypes != nil:
    for item in required.functionTypes[]:
      let provided = findInstanceFunctionType(plan.links, source, item.name)
      let signature = plan.functionTypeInParent(source, provided.signature)
      typeBindings.valuesAndFunctions.checkFunctionTypeBinding(signature, item.signature, item.name)
  let requiredTypes = componentsIn(required.typeExternals)
  if requiredTypes != nil:
    let providedTypes = instanceTypeExternals(plan.links, source)
    for item in requiredTypes[]:
      let provided = requireExternalComponentType(providedTypes, item.name)
      typeBindings.components.add((componentTypeInParent(plan.links, source, provided), item.plan))
  let requiredInstances = instancesIn(required.typeExternals)
  if requiredInstances != nil:
    let providedTypes = instanceTypeExternals(plan.links, source)
    for item in requiredInstances[]:
      let provided = requireExternalInstanceType(providedTypes, item.name)
      typeBindings.instances.add((instanceTypeInParent(plan.links, source, provided), item.shape))
  for item in required.resourceTypes:
    let parentResource = requireInstanceResource(plan.links, source, item.name)
    let parentType = parentResource.resourceIndex + 1
    let previous = node.resourceArgs[item.resourceIndex.int]
    if previous != 0 and previous != parentType:
      componentFail("component instantiation resource equality mismatch")
    node.resourceArgs[item.resourceIndex.int] = parentType
    node.bindResourceName(item.typeName, parentResource.typeName)
  for i in required.firstBinding ..< required.firstBinding + required.bindingCount:
    let imp = unsafeAddr node.plan.imports[i]
    let fn = lookupMethod(plan.links, source, imp.name)
    var argument = describeFunction(fn, plan, types, coreInstances, coreFunctions, memories)
    argument.name = imp.name
    node.arguments[i] = move argument
  if required.children != nil:
    for member in required.children[]:
      let supplied = lookupNestedInstance(plan.links, source, member.name)
      bindInstanceArgument(plan, node, member, supplied, typeBindings, types,
        coreInstances, coreFunctions, memories, depth + 1)

proc readChildInstantiation(data: openArray[byte], pos: var int, stop: int,
    plan: var ComponentPlan, definitions: ComponentDefinitionScope,
    coreModules: var seq[CoreModuleValue],
    componentInstances: openArray[DeclaredInstance],
    types: openArray[ComponentFuncType], functions: openArray[ComponentFunction],
    coreInstances: openArray[CoreInstance], coreFunctions: openArray[CoreFunction],
    memories: openArray[CoreExportAlias], resourceAliases: openArray[ResourceTypeAlias],
    scope: ShapeScope):
    DeclaredInstance =
  let index = takeU32(data, pos, stop)
  let definition = definitions.definitionAt(index)
  let child = definition.plan
  var node = ChildInstantiation(plan: child, beforeCore: plan.instances.len)
  let componentImports = child[].componentImportCount()
  if definition.externalDefinition() or componentImports != 0:
    node.componentArguments = ComponentInstantiation(definition: definition,
      arguments: newSeq[ComponentArgument](componentImports))
  let instanceCount = plan.instanceCount.int + child.instanceCount.int
  if instanceCount > MaxComponentInstances:
    componentFail("component instance graph exceeds profile limit")
  let count = takeCount(data, pos, stop, MaxComponentFunctions)
  node.arguments.setLen(child.imports.len)
  node.resourceArgs.setLen(child.resources.len)
  let moduleExternals = if child.links == nil: nil else: child.links.coreModules
  if moduleExternals != nil and moduleExternals.imports.len > 0:
    new(node.coreModuleArguments)
    node.coreModuleArguments[].setLen(moduleExternals.imports.len)
  var names = newSeqOfCap[string](count)
  var equalityBindings: seq[uint16]
  var typeBindings: InstantiationTypeBindings
  if child.links != nil:
    equalityBindings.setLen(child.links.resourceEqualityImports.len)
  for _ in 0 ..< count:
    let name = takeName(data, pos, stop, allowEmpty = true)
    if name in names:
      componentFail("duplicate component instantiation argument")
    names.add(name)
    let sort = take(data, pos, stop)
    if sort == 0 and take(data, pos, stop) != 0x11:
      componentFail("unsupported component core argument sort")
    let index = takeU32(data, pos, stop)
    let resource = if sort == 3: resourceIndex(resourceAliases, index) else: -1
    case sort
    of 0'u8:
      let count = if coreModules.len == 0: plan.embeddedCount() else: coreModules.len
      if index >= count.uint32:
        componentFail("unknown core module argument")
    of 1'u8:
      if index >= functions.len.uint32:
        componentFail("unknown component instantiation function")
    of 5'u8:
      if index >= componentInstances.len.uint32:
        componentFail("unknown component instantiation instance")
    of 3'u8:
      if resource < 0 and not scope.isFunctionType(index) and not scope.isComponentType(index) and
          not scope.isInstanceType(index):
        discard shapeAt(scope, index)
    of 4'u8:
      if index >= definitions.plans.len.uint32:
        componentFail("unknown component instantiation definition")
    else: componentFail("unsupported component instantiation argument sort")
    if child.links != nil:
      if node.coreModuleArguments != nil:
        let i = findModuleImport(moduleExternals.imports, name)
        if i >= 0:
          if sort != 0: componentFail("component instantiation argument sort mismatch")
          let value = typedModuleValue(plan, coreModules, index)
          requireModuleSubtype(value.moduleShape(), moduleExternals.imports[i].value.shape)
          node.coreModuleArguments[][i] = value
      if child.links.componentImports != nil:
        for i, required in child.links.componentImports[]:
          if required.interfaceImport or required.name != name: continue
          if sort != 4:
            componentFail("component instantiation argument sort mismatch")
          let provider = definitions.definitionAt(index)
          typeBindings.components.add((provider.plan, required.plan))
          node.componentArguments.arguments[i] = provider
          break
      for iface in child.links.interfaceImports:
        if iface.name != name: continue
        if sort != 5:
          componentFail("component instantiation argument sort mismatch")
        bindInstanceArgument(plan, node, iface, componentInstances[index.int],
          typeBindings, types, coreInstances, coreFunctions, memories, 0)
        break
      for i, required in child.links.resourceEqualityImports:
        if required.name != name: continue
        if sort != 3 or resource < 0:
          componentFail("component instantiation argument sort mismatch")
        equalityBindings[i] = (resource + 1).uint16
        let alias = lookupResourceType(resourceAliases, index)
        node.bindResourceName(required.typeName, resourceAliases[alias].typeName)
        break
      for item in child.links.valueImports:
        if item.name != name: continue
        if sort != 3 or resource >= 0:
          componentFail("component instantiation argument sort mismatch")
        let provided = outerValueShape(unsafeAddr scope, index)
        if item.shape[] != provided[]:
          componentFail("component instantiation value type mismatch: " & name)
        node.bindValueType(item.shape, provided)
        if item.shape.resources != {}:
          typeBindings.valuesAndFunctions.collectValueBinding(provided[], item.shape[], name)
        break
      if child.links.functionTypeImports != nil:
        for item in child.links.functionTypeImports[]:
          if item.name != name: continue
          if sort != 3 or not scope.isFunctionType(index):
            componentFail("component instantiation argument sort mismatch")
          typeBindings.valuesAndFunctions.checkFunctionTypeBinding(types[index.int], item.signature, name)
          break
      let componentType = findExternalComponentType(child.links.typeImports, name)
      if componentType != nil:
        if sort != 3 or not scope.isComponentType(index):
          componentFail("component instantiation argument sort mismatch")
        typeBindings.components.add((lookupComponentType(scope.componentTypes[], index), componentType))
      let instanceType = findExternalInstanceType(child.links.typeImports, name)
      if instanceType != nil:
        if sort != 3 or not scope.isInstanceType(index):
          componentFail("component instantiation argument sort mismatch")
        typeBindings.instances.add((instanceTypeAt(scope, index), instanceType))
    for i, imp in child.imports:
      if imp.interfaceIndex != 0 or imp.name != name: continue
      if sort != 1:
        componentFail("component instantiation argument sort mismatch")
      var source = describeFunction(functions[index.int], plan, types,
        coreInstances, coreFunctions, memories)
      source.name = name
      node.arguments[i] = move source
      break
    for i, required in child.resources:
      if required.importInterface != 0 or required.importName != name: continue
      if sort != 3 or resource < 0:
        componentFail("component instantiation argument sort mismatch")
      if node.resourceArgs[i] != 0 and node.resourceArgs[i].int != resource + 1:
        componentFail("component instantiation resource equality mismatch")
      node.resourceArgs[i] = (resource + 1).uint16
      let alias = lookupResourceType(resourceAliases, index)
      node.bindResourceName(required.importedTypeName, resourceAliases[alias].typeName)
      break
  if plan.links == nil: new(plan.links)
  let childIndex = plan.links.children.len
  for i, resource in child.resources:
    let capture = child[].contractResourceCapture(i)
    if capture.depth != 0:
      if not child[].usesContractResource(i.uint16): continue
      if capture.depth != 1 or capture.ordinal.int >= plan.resources.len:
        componentFail("unbound component type resource")
      if node.resourceArgs[i] != 0 and node.resourceArgs[i] != capture.ordinal + 1:
        componentFail("component instantiation resource equality mismatch")
      node.resourceArgs[i] = capture.ordinal + 1
    elif resource.importName.len == 0:
      node.resourceArgs[i] = (plan.resources.len + 1).uint16
      boundedAdd(plan.resources, LocalResourcePlan(sourceChild: (childIndex + 1).uint16),
        MaxComponentResourceTypes)
    elif node.resourceArgs[i] == 0:
      componentFail("missing component instantiation resource argument")
  for i, actual in equalityBindings:
    let target = child.links.resourceEqualityImports[i].resourceIndex.int
    if actual == 0:
      componentFail("missing component instantiation resource argument")
    if node.resourceArgs[target] != actual:
      componentFail("component instantiation resource equality mismatch")
  for binding in typeBindings.valuesAndFunctions:
    if not matchTypeResourceBindings(plan, child.handleTypes, binding.actual,
        binding.expected, node.resourceArgs):
      componentFail(binding.error)
  for binding in typeBindings.instances:
    requireInstanceTypeSubtype(binding.actual, binding.expected,
      TypeResourceBindings(arguments: addr node.resourceArgs))
  for binding in typeBindings.components:
    requireComponentSubtype(binding.actual[], binding.expected[],
      TypeResourceBindings(arguments: addr node.resourceArgs))
  for i, argument in node.arguments:
    if argument.name.len == 0:
      componentFail("missing component instantiation argument")
    let required = child.imports[i].signature
    if not matchComponentFunction(argument.signature, required) or
        not matchResourceBindings(plan, argument, required, child.handleTypes,
          node.resourceArgs, substitute = true):
      componentFail("component instantiation argument type mismatch")
  if child.links != nil:
    if node.coreModuleArguments != nil:
      for i, item in moduleExternals.imports:
        let value = unsafeAddr node.coreModuleArguments[][i]
        if value.shape == nil and value.image == nil:
          componentFail("missing component core module argument: " & item.name)
    if child.links.componentImports != nil:
      for i, item in child.links.componentImports[]:
        if node.componentArguments.arguments[i].plan == nil:
          componentFail("missing component instantiation definition: " & item.name)
    for iface in child.links.interfaceImports:
      if iface.name notin names:
        componentFail("missing component instantiation argument")
    for item in child.links.valueImports:
      if item.name notin names:
        componentFail("missing component instantiation value type: " & item.name)
    if child.links.functionTypeImports != nil:
      for item in child.links.functionTypeImports[]:
        if item.name notin names:
          componentFail("missing component instantiation function type: " & item.name)
    let componentTypes = componentsIn(child.links.typeImports)
    if componentTypes != nil:
      for item in componentTypes[]:
        if item.name notin names:
          componentFail("missing component instantiation component type: " & item.name)
    let instanceTypes = instancesIn(child.links.typeImports)
    if instanceTypes != nil:
      for item in instanceTypes[]:
        if item.name notin names:
          componentFail("missing component instantiation instance type: " & item.name)
  result.childIndex = childIndex
  boundedAdd(plan.links.children, move node, MaxComponentFunctions)
  plan.instanceCount = instanceCount.uint8

proc readInstanceAlias(data: openArray[byte], pos: var int, stop: int,
    links: ComponentLinks, instances: var seq[DeclaredInstance],
    functions: var seq[ComponentFunction], sort: byte) =
  if take(data, pos, stop) != 0:
    componentFail("unsupported component instance alias")
  let index = takeU32(data, pos, stop)
  if index >= instances.len.uint32:
    componentFail("unknown component instance")
  let name = takeName(data, pos, stop, allowEmpty = true)
  if sort == 1:
    let fn = lookupMethod(links, instances[index.int], name)
    boundedAdd(functions, fn, MaxComponentFunctions)
    return
  let alias = lookupNestedInstance(links, instances[index.int], name)
  boundedAdd(instances, alias, MaxComponentFunctions)

proc addInstanceTypeAlias(data: openArray[byte], pos: var int, stop: int,
    plan: var ComponentPlan, scope: var ShapeScope, instances: openArray[DeclaredInstance]) =
  let index = takeU32(data, pos, stop)
  if index >= instances.len.uint32:
    componentFail("unknown component instance")
  let name = takeName(data, pos, stop, allowEmpty = true)
  let source = unsafeAddr instances[index.int]
  for resource in instanceResourceTypes(plan.links, source[]):
    if resource.name == name:
      scope.resourceAliases[].add(ResourceTypeAlias(typeIndex: scope.kinds.len.uint16,
        resourceIndex: resource.resourceIndex,
        visible: source.visibility != tvPrivate or resource.typeName in scope.publishedResources,
        imported: source.visibility == tvImported, typeName: resource.typeName))
      scope.kinds.add(cpResourceType)
      scope.functionTypes[].add(ComponentFuncType())
      return
  for item in instanceValueTypes(plan.links, source[]):
    if item.name == name:
      let view = plan.namedValueInParent(source[], item)
      scope.rememberShapeOrigin(view.shape, view.namedOrigin())
      scope.addValueType(view.shape, source.visibility)
      scope.functionTypes[].add(ComponentFuncType())
      return
  for item in instanceFunctionTypes(plan.links, source[]):
    if item.name == name:
      scope.addFunctionAlias(plan.functionTypeInParent(source[], item.signature),
        FunctionTypeOrigin(names: plan.functionNamesInParent(source[], item.names)))
      return
  let contract = findExternalComponentType(instanceTypeExternals(plan.links, source[]), name)
  if contract != nil:
    scope.addComponentTypeAlias(componentTypeInParent(plan.links, source[], contract))
    return
  let shape = findExternalInstanceType(instanceTypeExternals(plan.links, source[]), name)
  if shape != nil:
    scope.addInstanceTypeAlias(instanceTypeInParent(plan.links, source[], shape)[])
    return
  componentFail("unknown component instance type")

proc allocateInterfaceResources(plan: var ComponentPlan, declared: InterfaceType,
                                importInterface: uint16): seq[uint16] =
  if declared.resources != nil:
    for ordinal, enclosing in declared.resources.enclosing:
      if not declared.resources.hasInterfaceResource(ordinal):
        result.add(0)
      elif enclosing.depth != 0:
        if enclosing.depth != 1 or enclosing.ordinal.int >= plan.resources.len:
          componentFail("unknown enclosing instance resource")
        if importInterface != 0 and plan.resources[enclosing.ordinal.int].importName.len == 0 and
            plan.contractResourceCapture(enclosing.ordinal.int).depth == 0:
          componentFail("local resource type found in interface import")
        result.add(enclosing.ordinal + 1)
      else:
        result.add((plan.resources.len + 1).uint16)
        boundedAdd(plan.resources, LocalResourcePlan(
          importName: if importInterface == 0: "" else: declared.resources.names[ordinal],
          importInterface: importInterface), MaxComponentResourceTypes)

proc nestedResources(indices: openArray[uint16], outer: openArray[uint16]): seq[uint16] =
  for index in indices: result.add(if index == 0: 0'u16 else: outer[index.int - 1])

proc materializeExternalTypes(types: ExternalTypeSurface, handles: ResourceTypeMapping,
                              mapping: openArray[uint16]): ExternalTypeSurface {.noinline.} =
  result = types
  if types == nil: return
  if handles.len != 0 and types.functions != nil:
    result = ExternalTypeSurface(components: types.components, instances: types.instances)
    for item in types.functions[]:
      result.addNamedFunctionType(NamedFunctionType(name: item.name,
        signature: rebaseResourceSignature(item.signature, handles), names: item.names))
  if types.instances != nil:
    for i, item in types.instances[]:
      let shape = rebaseInstanceType(item.shape, mapping)
      if shape == item.shape: continue
      if result == types:
        result = ExternalTypeSurface(components: types.components, functions: types.functions,
          instances: types.instances)
      if result.instances == types.instances:
        new(result.instances)
        result.instances[] = types.instances[]
      result.instances[][i].shape = shape
  if types.components != nil:
    for i, item in types.components[]:
      let contract = rebaseContractType(item.plan, mapping)
      if contract == item.plan: continue
      if result == types:
        result = ExternalTypeSurface(components: types.components, functions: types.functions,
          instances: types.instances)
      if result.components == types.components:
        new(result.components)
        result.components[] = types.components[]
      result.components[][i].plan = contract

proc projectResourceNames(declared: InterfaceType, mapping: openArray[uint16],
                          names: var ResourceNameProjection) {.noinline.} =
  if declared.resources != nil:
    for item in declared.resources.resourceTypes:
      let slot = mapping[item.resourceIndex.int]
      if slot == 0 or item.typeName == nil: continue
      let ordinal = slot - 1
      if names == nil: new(names)
      var found = false
      for entry in names[]:
        if entry.source == item.typeName and entry.ordinal == ordinal:
          found = true
          break
      if not found: names[].add((item.typeName, ordinal, newResourceName()))
  if declared.children != nil:
    for child in declared.children[]:
      projectResourceNames(child.definition[], nestedResources(child.resources, mapping), names)

proc projectedResourceName(names: ResourceNameProjection, name: ResourceName,
                           ordinal: uint16): ResourceName =
  if names != nil:
    for entry in names[]:
      if entry.source == name and entry.ordinal == ordinal: return entry.target
  name

proc materializeResourceHandles(plan: var ComponentPlan, resources: InterfaceResourceTypes,
    mapping: openArray[uint16], visibility: TypeVisibility,
    names: ResourceNameProjection): ResourceTypeMapping {.noinline.} =
  if resources == nil: return
  for handle in resources.handleTypes:
    if not resources.hasInterfaceResource(handle.resourceIndex.int): continue
    let slot = mapping[handle.resourceIndex.int]
    if slot == 0: componentFail("unbound interface resource type")
    let local = slot - 1
    let name = projectedResourceName(names, handle.typeName, local)
    result.add((handle.typeIndex, plan.bindResourceHandleIndex(local, visibility, name).uint16))

proc materializeInterfaceTypes(plan: var ComponentPlan, declared: InterfaceType,
    instance: var DeclaredInstance, mapping: openArray[uint16],
    visibility: TypeVisibility, names: ResourceNameProjection): ResourceTypeMapping =
  instance.childIndex = -1
  instance.visibility = visibility
  instance.visibilityOrder = declared.visibilityOrder
  if declared.resources != nil:
    for item in declared.resources.resourceTypes:
      let local = mapping[item.resourceIndex.int] - 1
      instance.resourceTypes.add(NamedResourceType(name: item.name,
        resourceIndex: local, typeName: projectedResourceName(names, item.typeName, local)))
    result = materializeResourceHandles(plan, declared.resources, mapping, visibility, names)
  instance.valueTypes = declared.valueTypes
  if result.len > 0:
    for item in instance.valueTypes.mitems:
      if item.shape.resources != {}:
        item.origin = item.namedOrigin()
        item.shape = rebaseResourceShape(item.shape, result, nil)
  if declared.typeExternals != nil:
    instance.typeExternals = materializeExternalTypes(declared.typeExternals, result, mapping)

proc materializeInterfaceImport(plan: var ComponentPlan, name: string,
    declared: InterfaceType, mapping: openArray[uint16], index: uint16,
    instance: var DeclaredInstance, depth: int, remaining: var int,
    names: ResourceNameProjection, scope: ptr ShapeScope): InterfaceImport

proc materializeNestedImports(plan: var ComponentPlan, declared: InterfaceType,
    mapping: openArray[uint16], index: uint16, instance: var DeclaredInstance,
    surface: var InterfaceImport, depth: int, remaining: var int,
    names: ResourceNameProjection, scope: ptr ShapeScope) {.noinline.} =
  new(instance.children)
  new(surface.children)
  for member in declared.children[]:
    var child = NamedInstance(name: member.name)
    let requirement = materializeInterfaceImport(plan, member.name, member.definition[],
      nestedResources(member.resources, mapping), index, child.value, depth + 1, remaining,
      names, scope)
    surface.children[].add(requirement)
    instance.children[].add(move child)

proc materializeInterfaceImport(plan: var ComponentPlan, name: string,
    declared: InterfaceType, mapping: openArray[uint16], index: uint16,
    instance: var DeclaredInstance, depth: int, remaining: var int,
    names: ResourceNameProjection, scope: ptr ShapeScope): InterfaceImport =
  if depth >= MaxInstanceNesting: componentFail("instance import nesting limit")
  if remaining == 0: componentFail("instance import surface limit")
  dec remaining
  let handles = materializeInterfaceTypes(plan, declared, instance, mapping, tvImported, names)
  for item in instance.resourceTypes: publishResourceName(scope, item.typeName, importing = true)
  result = InterfaceImport(name: name,
    firstBinding: plan.imports.len, bindingCount: declared.methods.len,
    valueTypes: instance.valueTypes, resourceTypes: instance.resourceTypes,
    typeExternals: instance.typeExternals)
  if declared.coreModules != nil:
    for item in declared.coreModules[]:
      let value = addCoreModuleImport(plan, item.name, item.value.shape, interfaceImport = true)
      instance.coreModules.addInstanceModule(NamedCoreModule(name: item.name, value: value))
    result.coreModules = instance.coreModules
  if declared.components != nil:
    for item in declared.components[]:
      let contract = rebaseContractType(item.value.plan, mapping)
      let value = addComponentTypeImport(plan, item.name, contract, interfaceImport = true)
      instance.components.addInstanceComponent(NamedComponentDefinition(name: item.name, value: value))
    result.components = instance.components
  for methodImport in declared.methods:
    var signature = rebaseResourceSignature(methodImport.signature, handles)
    let fn = ComponentFunction(kind: fnImport, typeIndex: uint32.high,
      importIndex: plan.imports.len.uint32)
    instance.methods.add(NamedComponentMethod(name: methodImport.name, fn: fn))
    boundedAdd(plan.imports, ComponentImport(name: methodImport.name,
      signature: move signature, interfaceIndex: index,
      visibilityNames: methodImport.visibilityNames),
      MaxComponentFunctions)
  if declared.children != nil:
    materializeNestedImports(plan, declared, mapping, index, instance, result, depth, remaining,
      names, scope)

proc addInterfaceImport(plan: var ComponentPlan, name: string,
                        declared: InterfaceType, scope: ptr ShapeScope): DeclaredInstance =
  if plan.links == nil: new(plan.links)
  let index = (plan.links.interfaceImports.len + 1).uint16
  let bindings = plan.allocateInterfaceResources(declared, index)
  var names: ResourceNameProjection
  projectResourceNames(declared, bindings, names)
  var remaining = MaxComponentFunctions
  let required = materializeInterfaceImport(plan, name, declared, bindings, index, result, 0,
    remaining, names, scope)
  boundedAdd(plan.links.interfaceImports, required, MaxComponentFunctions)

proc materializeInterfaceDefinitions(components: ref seq[NamedComponentDefinition],
    mapping: openArray[uint16]): ref seq[NamedComponentDefinition] {.noinline.} =
  result = components
  for i, item in components[]:
    let contract = rebaseContractType(item.value.plan, mapping)
    if contract == item.value.plan: continue
    if result == components:
      new(result)
      result[] = components[]
    result[][i].value.plan = contract

proc materializeContractExport(plan: var ComponentPlan, name: string,
    declared: InterfaceType, mapping: openArray[uint16], instance: var DeclaredInstance,
    depth: int, names: ResourceNameProjection, scope: ptr ShapeScope = nil): InterfaceExport =
  if depth >= MaxInstanceNesting: componentFail("instance export nesting limit")
  let handles = materializeInterfaceTypes(plan, declared, instance, mapping, tvExported, names)
  if scope != nil:
    for item in instance.resourceTypes: publishResourceName(scope, item.typeName)
  instance.coreModules = declared.coreModules
  if declared.components != nil:
    instance.components = materializeInterfaceDefinitions(declared.components, mapping)
  result = InterfaceExport(name: name, resourceTypes: instance.resourceTypes,
    valueTypes: instance.valueTypes, coreModules: declared.coreModules, components: instance.components,
    typeExternals: instance.typeExternals, visibilityOrder: declared.visibilityOrder)
  for item in declared.methods:
    let signature = rebaseResourceSignature(item.signature, handles)
    result.methods.add(ComponentExport(name: item.name,
      signature: signature, visibilityNames: item.visibilityNames,
      resourceNames: resourceNames(signature, plan.handleTypes)))
  if declared.children != nil:
    new(instance.children)
    new(result.children)
    for member in declared.children[]:
      var child = NamedInstance(name: member.name)
      let surface = materializeContractExport(plan, member.name, member.definition[],
        nestedResources(member.resources, mapping), child.value, depth + 1, names, scope)
      result.children[].add(plan.links.appendNestedExport(surface))
      instance.children[].add(move child)

proc addContractInterfaceExport(plan: var ComponentPlan, name: string,
                                declared: InterfaceType, scope: ptr ShapeScope): DeclaredInstance =
  let bindings = plan.allocateInterfaceResources(declared, 0)
  var names: ResourceNameProjection
  projectResourceNames(declared, bindings, names)
  let surface = materializeContractExport(plan, name, declared, bindings, result, 0, names, scope)
  plan.links.appendInterfaceExport(surface)

proc comparisonInterfacePlan(shape: InterfaceType): ref ComponentPlan {.noinline.} =
  # Use the ordinary interface projection on a temporary export. Every used
  # resource keeps a separate ordinal so comparison can impose its identity.
  new(result)
  result.links = ComponentLinks()
  var mapping: seq[uint16]
  if shape.resources != nil:
    result.resources.setLen(shape.resources.enclosing.len)
    for i in 0 ..< result.resources.len:
      if not shape.resources.hasInterfaceResource(i):
        mapping.add(0)
        continue
      var index = (i + 1).uint16
      let capture = shape.resources.enclosing[i]
      if capture.depth != 0:
        for j, previous in mapping:
          if previous != 0 and shape.resources.enclosing[j] == capture:
            index = previous
            break
      mapping.add(index)
  var unused: DeclaredInstance
  let surface = materializeContractExport(result[], "", shape, mapping, unused, 0, nil)
  result.links.appendInterfaceExport(surface)

proc sameInstanceTypeResource(provided, required: InterfaceResourceTypes, actual, expected: int,
                              resources: TypeResourceBindings): bool =
  let a = provided.enclosing[actual]
  let b = required.enclosing[expected]
  if a.depth == 0 or b.depth == 0:
    return a.depth == b.depth and actual == expected and provided.nominalScope == required.nominalScope
  resources.sameCaptureSource(a, b)

proc requireInstanceTypeSubtype(provided, required: ref InterfaceType,
    resources: TypeResourceBindings, depth: int, remaining: var int) =
  if depth >= MaxComponentContractNesting or remaining == 0:
    componentFail("instance type comparison limit")
  dec remaining
  let actual = comparisonInterfacePlan(provided[])
  let expected = comparisonInterfacePlan(required[])
  var projection = ComponentProjection(nominalResources: true)
  projection.resourceImports.setLen(actual.resources.len)
  projection.resourceExports.setLen(expected.resources.len)
  if provided.resources != nil and required.resources != nil:
    for requiredIndex in 0 ..< expected.resources.len:
      if not required.resources.hasInterfaceResource(requiredIndex): continue
      for actualIndex in 0 ..< actual.resources.len:
        if provided.resources.hasInterfaceResource(actualIndex) and
            sameInstanceTypeResource(provided.resources, required.resources,
              actualIndex, requiredIndex, resources):
          projection.resourceExports[requiredIndex] = (actualIndex + 1).uint16
          break
  if expected.links.nestedInterfaceExports != nil:
    projection.nestedInterfaces.setLen(expected.links.nestedInterfaceExports[].len)
  projection.bindProjectedInterfaceExport(actual[], expected[], 1, 1, 0)
  discard projection.projectInterfaceExport(actual[], expected[], 1, 1, depth, remaining)
  for i, nested in projection.nestedInterfaces:
    discard projection.projectInterfaceExport(actual[], expected[],
      nested.source, NestedInterfaceIndex or i.uint16, depth, remaining)

proc requireInstanceTypeSubtype(provided, required: ref InterfaceType,
                                resources: TypeResourceBindings) =
  var remaining = MaxComponentContractComparisons
  requireInstanceTypeSubtype(provided, required, resources, 0, remaining)

proc buildInterfaceExport(plan: var ComponentPlan, name: string, source: DeclaredInstance,
    projection: var DeclaredInstance, annotation: ptr InterfaceType,
    annotationResources: openArray[uint16], names: ResourceNameProjection, scope: ptr ShapeScope,
    coreInstances: openArray[CoreInstance], coreFunctions: openArray[CoreFunction],
    memories: openArray[CoreExportAlias], depth: int): InterfaceExport

proc appendInterfaceChild(plan: var ComponentPlan, name: string, source: DeclaredInstance,
    annotation: ptr InterfaceType, bindings: openArray[uint16],
    names: ResourceNameProjection,
    parent: var InterfaceExport, projection: var DeclaredInstance,
    scope: ptr ShapeScope, coreInstances: openArray[CoreInstance],
    coreFunctions: openArray[CoreFunction], memories: openArray[CoreExportAlias],
    depth: int) {.noinline.} =
  var child = NamedInstance(name: name)
  let surface = buildInterfaceExport(plan, name, source, child.value,
    annotation, bindings, names, scope, coreInstances, coreFunctions, memories, depth + 1)
  if parent.children == nil:
    new(parent.children)
    new(projection.children)
  parent.children[].add(plan.links.appendNestedExport(surface))
  projection.children[].add(move child)

proc exportInterfaceModules(links: ComponentLinks, source: DeclaredInstance,
                            annotation: ptr InterfaceType): ref seq[NamedCoreModule] =
  if annotation == nil:
    for item in instanceCoreModules(links, source):
      result.addInstanceModule(item)
  elif annotation.coreModules != nil:
    for item in annotation.coreModules[]:
      var provided = lookupInstanceModule(links, source, item.name)
      requireModuleSubtype(provided.moduleShape(), item.value.shape)
      provided.shape = item.value.shape
      result.addInstanceModule(NamedCoreModule(name: item.name, value: provided))

proc exportInterfaceComponents(links: ComponentLinks, source: DeclaredInstance,
    annotation: ptr InterfaceType, resources: openArray[uint16]): ref seq[NamedComponentDefinition] {.noinline.} =
  if annotation == nil:
    for item in instanceComponents(links, source):
      result.addInstanceComponent(item)
  elif annotation.components != nil:
    for item in annotation.components[]:
      var provided = lookupInstanceComponent(links, source, item.name)
      provided.ascribeComponent(rebaseContractType(item.value.plan, resources))
      result.addInstanceComponent(NamedComponentDefinition(name: item.name, value: provided))

proc exportInterfaceTypes(plan: var ComponentPlan, source: DeclaredInstance,
    annotation: ptr InterfaceType, resources: openArray[uint16]): ExternalTypeSurface {.noinline.} =
  let actual = instanceTypeExternals(plan.links, source)
  if annotation == nil:
    let components = componentsIn(actual)
    if components != nil:
      for item in components[]:
        result.addNamedComponentType(NamedComponentType(name: item.name,
          plan: componentTypeInParent(plan.links, source, item.plan)))
    let instances = instancesIn(actual)
    if instances != nil:
      for item in instances[]:
        result.addNamedInstanceType(NamedInstanceType(name: item.name,
          shape: instanceTypeInParent(plan.links, source, item.shape)))
  else:
    let components = componentsIn(annotation.typeExternals)
    if components != nil:
      for item in components[]:
        let provided = componentTypeInParent(plan.links, source,
          requireExternalComponentType(actual, item.name))
        let expected = rebaseContractType(item.plan, resources)
        requireComponentSubtype(provided[], expected[])
        result.addNamedComponentType(NamedComponentType(name: item.name, plan: expected))
    let instances = instancesIn(annotation.typeExternals)
    if instances != nil:
      for item in instances[]:
        let provided = instanceTypeInParent(plan.links, source,
          requireExternalInstanceType(actual, item.name))
        let expected = rebaseInstanceType(item.shape, resources)
        requireInstanceTypeSubtype(provided, expected)
        result.addNamedInstanceType(NamedInstanceType(name: item.name, shape: expected))
  if annotation == nil:
    for item in instanceFunctionTypes(plan.links, source):
      result.addNamedFunctionType(NamedFunctionType(name: item.name,
        names: plan.functionNamesInParent(source, item.names),
        signature: plan.functionTypeInParent(source, item.signature)))
  elif annotation.functionTypes != nil:
    for expected in annotation.functionTypes[]:
      var provided = findInstanceFunctionType(plan.links, source, expected.name)
      provided.signature = plan.functionTypeInParent(source, provided.signature)
      if not matchComponentFunction(provided.signature, expected.signature):
        componentFail("component interface export function type mismatch: " & expected.name)
      if annotation.resources != nil and not matchResourceBindings(plan,
          ComponentExport(signature: provided.signature), expected.signature,
          annotation.resources.handleTypes, resources, substitute = true):
        componentFail("component interface export function resource type mismatch: " & expected.name)
      provided.names = expected.names
      result.addNamedFunctionType(move provided)

proc buildInterfaceExport(plan: var ComponentPlan, name: string, source: DeclaredInstance,
    projection: var DeclaredInstance, annotation: ptr InterfaceType,
    annotationResources: openArray[uint16], names: ResourceNameProjection, scope: ptr ShapeScope,
    coreInstances: openArray[CoreInstance], coreFunctions: openArray[CoreFunction],
    memories: openArray[CoreExportAlias], depth: int): InterfaceExport =
  if depth >= MaxInstanceNesting: componentFail("instance export nesting limit")
  projection.childIndex = -1
  projection.visibility = tvExported
  projection.visibilityOrder = if annotation == nil: instanceVisibilityOrder(plan.links, source)
    else: annotation.visibilityOrder
  var annotationHandles: ResourceTypeMapping
  if annotation == nil:
    if source.childIndex < 0:
      projection.methods = source.methods
    else:
      let methods = childMethods(plan.links, source)
      for i, item in methods[]:
        projection.methods.add(NamedComponentMethod(name: item.name,
          fn: addChildAlias(plan.links, source, i)))
    for resource in instanceResourceTypes(plan.links, source):
      projection.resourceTypes.add(resource)
    for item in instanceValueTypes(plan.links, source):
      projection.valueTypes.add(plan.namedValueInParent(source, item))
  else:
    if annotation.resources != nil:
      for item in annotation.resources.resourceTypes:
        var actual = requireInstanceResource(plan.links, source, item.name)
        if annotationResources[item.resourceIndex.int] != actual.resourceIndex + 1:
          componentFail("component interface export resource type mismatch")
        actual.typeName = projectedResourceName(names, item.typeName, actual.resourceIndex)
        projection.resourceTypes.add(move actual)
      annotationHandles = materializeResourceHandles(plan, annotation.resources,
        annotationResources, tvExported, names)
    for item in annotation.valueTypes:
      let actual = findInstanceValueType(plan.links, source, item)
      if item.shape.resources != {}:
        let view = plan.valueTypeInParent(source, actual.shape)
        if not matchValueResourceBindings(plan, annotation.resources.handleTypes,
            view[], item.shape[], annotationResources):
          componentFail("component interface export value resource type mismatch")
      let exposed = rebaseResourceShape(item.shape, annotationHandles, nil)
      projection.valueTypes.add(NamedValueType(name: item.name, shape: exposed,
        origin: item.namedOrigin()))
    for item in annotation.methods:
      projection.methods.add(NamedComponentMethod(name: item.name,
        fn: lookupMethod(plan.links, source, item.name)))
  projection.coreModules = exportInterfaceModules(plan.links, source, annotation)
  projection.components = exportInterfaceComponents(plan.links, source, annotation, annotationResources)
  projection.typeExternals = exportInterfaceTypes(plan, source, annotation, annotationResources)
  result = InterfaceExport(name: name, resourceTypes: projection.resourceTypes,
    valueTypes: projection.valueTypes, coreModules: projection.coreModules,
    components: projection.components, typeExternals: projection.typeExternals,
    visibilityOrder: projection.visibilityOrder)
  for i, item in projection.methods:
    var methodExport = describeFunction(item.fn, plan, scope.functionTypes[], coreInstances,
      coreFunctions, memories)
    if not supportedHostSignature(methodExport.signature, linkedResources = true):
      componentFail("unsupported component interface function type")
    if annotation != nil:
      let required = unsafeAddr annotation.methods[i].signature
      if not matchComponentFunction(methodExport.signature, required[]):
        componentFail("component interface export annotation type mismatch")
      if annotation.resources != nil and not matchResourceBindings(plan, methodExport,
          required[], annotation.resources.handleTypes, annotationResources, substitute = true):
        componentFail("component interface export resource type mismatch")
      methodExport.visibilityNames = annotation.methods[i].visibilityNames
      methodExport.resourceNames = resourceNames(
        rebaseResourceSignature(required[], annotationHandles), plan.handleTypes)
    else:
      methodExport.visibilityNames = plan.componentFunctionNames(item.fn, scope)
      methodExport.resourceNames = plan.componentFunctionResources(item.fn, methodExport.signature, scope)
    methodExport.name = item.name
    if annotation == nil:
      checkResourceMemberName(plan, methodExport, result.resourceTypes)
    result.methods.add(move methodExport)
  if annotation == nil:
    for member in nestedInstances(plan.links, source):
      appendInterfaceChild(plan, member.name, member.value, nil, [], nil, result, projection,
        scope, coreInstances, coreFunctions, memories, depth)
  elif annotation.children != nil:
    for member in annotation.children[]:
      let supplied = lookupNestedInstance(plan.links, source, member.name)
      appendInterfaceChild(plan, member.name, supplied, unsafeAddr member.definition[],
        nestedResources(member.resources, annotationResources), names, result, projection,
        scope, coreInstances, coreFunctions, memories, depth)

proc requireExportedNames(scope: ptr ShapeScope, visible: openArray[ptr NamedValueType],
                          names: FunctionTypeNames) =
  if names == nil: return
  for name in names[]:
    var found = false
    for item in visible:
      if item.shape == name.shape or originOfShape(item[].namedOrigin(), scope) == name.shape:
        found = true
        break
    if not found:
      requireVisibleReference(name.shape, scope, false, name.diagnostic)

proc requirePublishedResourceNames(scope: ptr ShapeScope, names: ResourceNames,
                                   diagnostic: string) =
  if names != nil:
    for name in names[]:
      if name notin scope.publishedResources: componentFail(diagnostic)

proc validateExportedTypes(plan: ComponentPlan, surface: ptr InterfaceExport,
    scope: ptr ShapeScope, visible: var seq[ptr NamedValueType]) {.noinline.} =
  let instances = instancesIn(surface.typeExternals)
  if instances != nil:
    for item in instances[]:
      requireInterfaceNames(item.shape[], scope, forImport = false)
  if surface.visibilityOrder == nil: return
  for step in surface.visibilityOrder[]:
    let index = step.index.int
    case step.member
    of vmType:
      let value = unsafeAddr surface.valueTypes[index]
      var names: FunctionTypeNames
      collectFunctionTypeNames(value[].namedOrigin()[], scope, names)
      requireExportedNames(scope, visible, names)
      requireVisibleResourceSlot(plan.handleTypes, value.shape[], false,
        "interface value resource type is not exported", scope = scope)
      if value.shape.kind in NamedValueTypes: visible.add(value)
    of vmResource:
      publishResourceName(scope, surface.resourceTypes[index].typeName)
    of vmFunction:
      let fn = unsafeAddr surface.methods[index]
      requireExportedNames(scope, visible, fn.visibilityNames)
      requirePublishedResourceNames(scope, fn.resourceNames,
        "interface method resource type is not exported")
    of vmFunctionType:
      let fn = unsafeAddr surface.functionTypes[][index]
      requireExportedNames(scope, visible, fn.names)
      requirePublishedResourceNames(scope, resourceNames(fn.signature, plan.handleTypes),
        "interface function type resource is not exported")
    of vmInstance:
      let child = plan.links.exportedInterface(surface.children[][index])
      validateExportedTypes(plan, child, scope, visible)

proc markNamedResources(resources: openArray[NamedResourceType], visible: var ResourceOrdinals) =
  for item in resources:
    visible.incl(InterfaceResourceOrdinal(item.resourceIndex))

proc markTypeCaptures(types: ExternalTypeSurface, used: var ResourceOrdinals) =
  let instances = instancesIn(types)
  if instances != nil:
    for item in instances[]:
      if item.shape.resources == nil: continue
      for i, capture in item.shape.resources.enclosing:
        if item.shape[].capturesResource(i):
          if capture.depth != 1: componentFail("unbound instance type resource")
          used.incl(InterfaceResourceOrdinal(capture.ordinal))
  let components = componentsIn(types)
  if components != nil:
    for item in components[]: markContractCaptures(item.plan, used)

proc markComponentCaptures(components: ref seq[NamedComponentDefinition],
                           used: var ResourceOrdinals) =
  if components != nil:
    for item in components[]: markContractCaptures(item.value.plan, used)

proc markInterfaceImportCaptures(surface: InterfaceImport, used: var ResourceOrdinals) =
  markNamedResources(surface.resourceTypes, used)
  markTypeCaptures(surface.typeExternals, used)
  # Component-valued imports are already in the plan's import list.
  if surface.children != nil:
    for item in surface.children[]: markInterfaceImportCaptures(item, used)

proc markInterfaceExportCaptures(surfaces: ref seq[InterfaceExport],
    visible, used: var ResourceOrdinals) =
  if surfaces != nil:
    for item in surfaces[]:
      markNamedResources(item.resourceTypes, visible)
      markTypeCaptures(item.typeExternals, used)
      markComponentCaptures(item.components, used)

proc validateResourceCaptures(plan: ComponentPlan) =
  let links = plan.links
  if links == nil: return
  var incoming, outgoing, visible: ResourceOrdinals
  markNamedResources(links.resourceEqualityImports, incoming)
  markTypeCaptures(links.typeImports, incoming)
  for item in links.interfaceImports: markInterfaceImportCaptures(item, incoming)
  if links.componentImports != nil:
    for item in links.componentImports[]: markContractCaptures(item.plan, incoming)
  markNamedResources(links.resourceExports, visible)
  markTypeCaptures(links.typeExports, outgoing)
  markComponentCaptures(links.componentExports, outgoing)
  markInterfaceExportCaptures(links.interfaceExports, visible, outgoing)
  markInterfaceExportCaptures(links.nestedInterfaceExports, visible, outgoing)
  for slot in incoming + outgoing + visible:
    if slot.int >= plan.resources.len: componentFail("unknown captured resource type")
    if plan.contractResourceCapture(slot.int).depth != 0:
      links.contractResources.used.incl(slot)
    elif plan.resources[slot].importName.len == 0:
      if slot in incoming: componentFail("local resource type found in imports")
      if slot notin visible:
        componentFail("local resource type found in export but not exported itself")

proc readInterfaceExport(data: openArray[byte], pos: var int, stop: int,
    name: string, plan: var ComponentPlan, instances: var seq[DeclaredInstance],
    interfaceTypes: openArray[InterfaceType],
    coreInstances: openArray[CoreInstance], coreFunctions: openArray[CoreFunction],
    memories: openArray[CoreExportAlias], scope: ptr ShapeScope) =
  let index = takeU32(data, pos, stop)
  if index >= instances.len.uint32: componentFail("unknown exported component instance")
  var annotation: ptr InterfaceType
  case take(data, pos, stop)
  of 0: discard
  of 1:
    if take(data, pos, stop) != 5:
      componentFail("component interface export annotation sort mismatch")
    annotation = unsafeAddr interfaceTypes[lookupInterface(interfaceTypes, takeU32(data, pos, stop))]
  else: componentFail("invalid component interface export annotation")
  if plan.links == nil: new(plan.links)
  var bindings: seq[uint16]
  var names: ResourceNameProjection
  if annotation != nil:
    requireInterfaceNames(annotation[], scope, forImport = false)
    if annotation.resources != nil:
      for ordinal, enclosing in annotation.resources.enclosing:
        if annotation.resources.hasInterfaceResource(ordinal) and enclosing.depth != 0:
          if enclosing.depth > 1: componentFail("unknown enclosing instance resource")
          bindings.add(enclosing.ordinal + 1)
        else:
          bindings.add(0)
    projectResourceNames(annotation[], bindings, names)
  var projection: DeclaredInstance
  let surface = buildInterfaceExport(plan, name, instances[index.int], projection,
    annotation, bindings, names, scope, coreInstances, coreFunctions, memories, 0)
  var visible: seq[ptr NamedValueType]
  validateExportedTypes(plan, unsafeAddr surface, scope, visible)
  plan.links.visibilityOrder.addMember(vmInstance, plan.links.interfaceExportCount())
  plan.links.appendInterfaceExport(surface)
  boundedAdd(instances, move projection, MaxComponentFunctions)

proc linkedImport(module: WasmModule, imp: Import,
    instances: openArray[CoreInstance], instance: ptr CoreInstance,
    coreFunctions: openArray[CoreFunction],
    aliases: array[ekTable .. ekTag, seq[CoreExportAlias]],
    plan: ComponentPlan, coreExports: openArray[seq[CoreExportType]]):
    CoreImportSource =
  let kind = ExportKind(ord(imp.kind))
  for arg in instance.args:
    if arg.name != imp.module: continue
    let source = unsafeAddr instances[arg.instanceIndex.int]
    var storeIndex: int
    var field: string
    if source.kind == ciModule:
      storeIndex = source.storeIndex.int
      field = imp.name
    else:
      storeIndex = -1
      for exp in source.exports:
        if exp.name != imp.name or exp.kind != kind: continue
        if kind == ekFunc:
          let target = unsafeAddr coreFunctions[exp.itemIndex.int]
          if target.kind == cfLower:
            let lowering = unsafeAddr plan.lowerings[target.loweringIndex.int]
            let ft = unsafeAddr module.types[imp.funcTypeIdx.int]
            let asyncLower = when defined(wasmComponentAsyncCallbacks): lowering.asyncLower
              else: false
            if lowering.kind in {clHost, clChild, clLocal}:
              let matches = if asyncLower:
                ft[].isPlainCoreFunction() and ft[] == plan.generatedCoreType(lowering[])
              else:
                signatureMatchesCore(loweringSignature(plan, lowering[]), ft[], forLower = true)
              if not matches:
                componentFail("canonical import type mismatch")
            elif ft[] != plan.generatedCoreType(lowering[]):
              if lowering.kind in {clContextGet, clContextSet}:
                componentFail("canonical context function type mismatch")
              componentFail("canonical resource function type mismatch")
            return CoreImportSource(instanceIndex: -1,
              itemIndex: target.loweringIndex.uint16)
          storeIndex = instances[target.coreInstance.int].storeIndex.int
          field = target.name
        else:
          let target = unsafeAddr aliases[kind][exp.itemIndex.int]
          storeIndex = instances[target.coreInstance.int].storeIndex.int
          field = target.name
        break
      if storeIndex < 0: break
    for index, ext in coreExports[storeIndex]:
      if ext.name != field: continue
      if not coreImportMatches(module, imp, ext):
        componentFail("core import type mismatch: " & imp.name)
      return CoreImportSource(instanceIndex: storeIndex.int16,
        itemIndex: index.uint16)
    break
  componentFail("unresolved core import: " & imp.module & "." & imp.name)

proc requireCanonicalRealloc(module: WasmModule, name: string) =
  for exp in module.exports:
    if exp.name == name and exp.kind == ekFunc:
      let ft = coreFuncType(module, exp.idx)
      if ft.params == @[vtI32, vtI32, vtI32, vtI32] and ft.results == @[vtI32]:
        return
      break
  componentFail("invalid canonical realloc function")

proc validateLift(module: WasmModule, exp: ComponentExport, storeIndex: uint8,
                  plan: ComponentPlan) =
  let source = storeIndex + 1
  if exp.coreSources[clsFunction] == source:
    validateCoreExport(module, exp)
  if exp.coreSources[clsRealloc] == source:
    module.requireCanonicalRealloc(exp.reallocName)
  when defined(wasmComponentAsyncCallbacks):
    if exp.callbackSource == source:
      var found = false
      for coreExp in module.exports:
        if coreExp.name != exp.callbackName or coreExp.kind != ekFunc: continue
        let ft = coreFuncType(module, coreExp.idx)
        found = ft.isPlainCoreFunction() and ft.params == @[vtI32, vtI32, vtI32] and
          ft.results == @[vtI32]
      if not found: componentFail("invalid canonical callback function")
  if exp.coreSources[clsPostReturn] == source:
    var postReturnValid = false
    var postReturnParams: seq[ValType]
    if exp.signature.hasResult:
      postReturnParams.add(coreResultType(exp.signature))
    for coreExp in module.exports:
      if coreExp.name != exp.postReturnName or coreExp.kind != ekFunc: continue
      let ft = coreFuncType(module, coreExp.idx)
      postReturnValid = ft.params == postReturnParams and ft.results.len == 0
    if not postReturnValid: componentFail("invalid canonical post-return function")

proc validateCoreGraph(plan: var ComponentPlan,
    instances: openArray[CoreInstance], coreFunctions: openArray[CoreFunction],
    aliases: array[ekTable .. ekTag, seq[CoreExportAlias]],
    functions: openArray[ComponentFunction], types: openArray[ComponentFuncType]) =
  var usedModules: array[MaxComponentCoreModules, bool]
  var coreExports: seq[seq[CoreExportType]]
  for i in 0 ..< instances.len:
    let instance = unsafeAddr instances[i]
    if instance.kind != ciModule: continue
    let storeIndex = instance.storeIndex.int
    let definition = unsafeAddr plan.instances[storeIndex]
    let module = if definition.external != nil:
        definition.external.source.shape[]
      else:
        usedModules[instance.moduleIndex.int] = true
        validatedCoreModule(plan.embeddedCoreBytes(instance.moduleIndex.int))
    for reference in coreFunctions:
      if reference.kind == cfAlias and reference.coreInstance == i.uint32:
        module.checkCoreAlias(reference.name, ekFunc)
    for kind in ekTable .. ekTag:
      for reference in aliases[kind]:
        if reference.coreInstance == i.uint32:
          module.checkCoreAlias(reference.name, kind)
    for imp in module.imports:
      let source = module.linkedImport(imp, instances, instance, coreFunctions,
        aliases, plan, coreExports)
      plan.instances[storeIndex].imports.add(source)
    for fn in functions:
      if fn.kind == fnLift:
        let lift = describeLift(fn, types, instances, coreFunctions, aliases[ekMemory])
        module.validateLift(lift, instance.storeIndex, plan)
    for lowering in plan.lowerings:
      if lowering.reallocSource == instance.storeIndex + 1:
        module.requireCanonicalRealloc(lowering.reallocName)
      when defined(wasmComponentThreads):
        if lowering.threadTable == instance.storeIndex + 1:
          var valid = false
          for exp in module.exports:
            if exp.name != lowering.threadTableName or exp.kind != ekTable: continue
            let table = module.coreExportType(exp).tableType
            valid = table.elemType == vtFuncRef
            when defined(wasmFunctionReferences):
              valid = valid and sameCoreReference(table.elementReference, CoreReferenceType())
            break
          if not valid: componentFail("canonical thread table must contain funcref")
    for resource in plan.resources:
      if resource.destructorSource != instance.storeIndex + 1: continue
      var valid = false
      for exp in module.exports:
        if exp.kind == ekFunc and exp.name == resource.destructorName:
          let ft = coreFuncType(module, exp.idx)
          valid = ft.params == @[vtI32] and ft.results.len == 0
          break
      if not valid: componentFail("invalid core resource destructor type")
    # The last instance's exports cannot be input to another instantiation.
    if storeIndex + 1 < plan.instances.len:
      var exports = newSeqOfCap[CoreExportType](module.exports.len)
      for exp in module.exports:
        exports.add(module.coreExportType(exp))
      coreExports.add(move exports)
  for index in 0 ..< plan.embeddedCount():
    if not usedModules[index]:
      discard validatedCoreModule(plan.embeddedCoreBytes(index))

proc lexicalLayout(plan: var ComponentPlan): LexicalLayout =
  if plan.links == nil: new(plan.links)
  if plan.links.lexical == nil: new(plan.links.lexical)
  plan.links.lexical

proc hasCaptures(plan: ref ComponentPlan): bool =
  if plan.links == nil or plan.links.lexical == nil: return false
  plan.links.lexical.componentCaptures.len != 0 or plan.links.lexical.moduleCaptures.len != 0

proc needsResourceFrames(plan: ComponentPlan): bool =
  plan.links != nil and plan.links.needsResourceFrames

proc declareLexicalDefinition(parent: var ComponentPlan,
    plan: ref ComponentPlan): ComponentArgument =
  result.plan = plan
  if plan[].needsResourceFrames():
    if parent.links == nil: new(parent.links)
    parent.links.needsResourceFrames = true
  if plan.hasCaptures():
    let layout = parent.lexicalLayout()
    boundedAdd(layout.definitions, LexicalDefinition(plan: plan,
      beforeChild: parent.links.children.len), MaxComponentFunctions)
    result.localIndex = layout.definitions.len.uint16

proc captureOuterModule(scope, owner: ptr ShapeScope, value: CoreModuleValue): CoreModuleValue =
  if scope == owner: return value
  let source = captureOuterModule(scope.parent, owner, value)
  let layout = scope.corePlan[].lexicalLayout()
  for i, existing in layout.moduleCaptures:
    if existing == source:
      return CoreModuleValue(shape: value.shape, captureIndex: (i + 1).uint16)
  boundedAdd(layout.moduleCaptures, source, MaxComponentFunctions)
  CoreModuleValue(shape: value.shape, captureIndex: layout.moduleCaptures.len.uint16)

proc captureComponentResources(scope: ptr ShapeScope,
    contract: ref ComponentPlan): ref ComponentPlan {.noinline.} =
  let captures = contract[].contractResources()
  if captures == nil or captures.used == {}: return contract
  let outer = scope.parent.corePlan
  if outer.links == nil: new(outer.links)
  outer.links.needsResourceFrames = true
  scope.corePlan.links.needsResourceFrames = true
  var mapping = newSeq[uint16](outer.resources.len)
  for item in captures.captures:
    if not contract[].usesContractResource(item.slot): continue
    if item.source.depth != 1 or item.source.ordinal.int >= mapping.len:
      componentFail("unbound outer component value resource")
    let slot = scope.corePlan[].captureContractResource(item.source)
    scope.corePlan.links.contractResources.live.incl(InterfaceResourceOrdinal(slot))
    mapping[item.source.ordinal] = slot + 1
  rebaseContractType(contract, mapping)

proc captureOuterComponent(scope, owner: ptr ShapeScope,
    value: ComponentArgument): ComponentArgument =
  if scope == owner: return value
  let source = captureOuterComponent(scope.parent, owner, value)
  let layout = scope.corePlan[].lexicalLayout()
  let contract = captureComponentResources(scope, source.plan)
  for i, existing in layout.componentCaptures:
    if existing == source:
      return ComponentArgument(plan: contract, captureIndex: (i + 1).uint16)
  boundedAdd(layout.componentCaptures, source, MaxComponentFunctions)
  ComponentArgument(plan: contract, captureIndex: layout.componentCaptures.len.uint16)

proc readCoreModuleAlias(data: openArray[byte], pos: var int, stop: int,
    plan: ComponentPlan, scope: var ShapeScope, instances: openArray[DeclaredInstance]): CoreModuleValue =
  case take(data, pos, stop)
  of 0:
    let index = takeU32(data, pos, stop)
    if index >= instances.len.uint32: componentFail("unknown component instance")
    let name = takeName(data, pos, stop, allowEmpty = true)
    result = lookupInstanceModule(plan.links, instances[index.int], name)
  of 2:
    let outer = readOuterTypeReference(data, pos, stop, scope)
    if outer.target.coreModuleValues == nil:
      componentFail("unknown outer core module")
    result = typedModuleValue(outer.target.corePlan[], outer.target.coreModuleValues[], outer.index)
    if outer.target != addr scope:
      if result.image == nil:
        result = captureOuterModule(addr scope, outer.target, result)
      else:
        result.embeddedIndex = 0
        result.shape = result.moduleShape()
  else: componentFail("unsupported core module alias")

proc readComponentDefinitionAlias(data: openArray[byte], pos: var int, stop: int,
    plan: ComponentPlan, scope: var ShapeScope, instances: openArray[DeclaredInstance]): ComponentArgument =
  case take(data, pos, stop)
  of 0:
    let index = takeU32(data, pos, stop)
    if index >= instances.len.uint32: componentFail("unknown component instance")
    let name = takeName(data, pos, stop, allowEmpty = true)
    result = lookupInstanceComponent(plan.links, instances[index.int], name)
  of 2:
    let outer = readOuterTypeReference(data, pos, stop, scope)
    if outer.target.componentDefinitions == nil: componentFail("unknown outer component definition")
    result = outer.target.componentDefinitions[].definitionAt(outer.index)
    if outer.crossedComponent:
      let captures = result.plan[].contractResources()
      if result.dynamicDefinition() or (captures != nil and captures.used != {}):
        result = captureOuterComponent(addr scope, outer.target, result)
  else: componentFail("unsupported component definition alias")

proc readComponentDefinitionExport(data: openArray[byte], pos: var int, stop: int,
    name: string, plan: var ComponentPlan, definitions: var ComponentDefinitionScope,
    types: openArray[ComponentTypeDefinition]) {.noinline.} =
  var definition = definitions.definitionAt(takeU32(data, pos, stop))
  case take(data, pos, stop)
  of 0: discard
  of 1:
    if take(data, pos, stop) != 4:
      componentFail("component definition export annotation sort mismatch")
    let annotation = lookupComponentType(types, takeU32(data, pos, stop))
    definition.ascribeComponent(annotation)
  else: componentFail("invalid component definition export annotation")
  addComponentDefinitionExport(plan, name, definition)
  definitions.addDefinition(definition)

proc readBoundComponentTypeExport(data: openArray[byte], pos: var int, stop: int,
    name: string, index: uint32, annotation: byte, plan: var ComponentPlan,
    scope: var ShapeScope) {.noinline.} =
  var visible = index
  case annotation
  of 0: discard
  of 1:
    if take(data, pos, stop) != 3 or take(data, pos, stop) != 0:
      componentFail("component type export annotation requires equality")
    visible = takeU32(data, pos, stop)
    if not scope.isComponentType(visible):
      componentFail("component type export annotation sort mismatch")
    let provided = lookupComponentType(scope.componentTypes[], index)
    let required = lookupComponentType(scope.componentTypes[], visible)
    requireComponentSubtype(provided[], required[])
  else: componentFail("invalid component type export annotation")
  addPlanComponentType(plan, scope, visible, name, importing = false)

proc readBoundInstanceTypeExport(data: openArray[byte], pos: var int, stop: int,
    name: string, index: uint32, annotation: byte, plan: var ComponentPlan,
    scope: var ShapeScope) {.noinline.} =
  var visible = index
  case annotation
  of 0: discard
  of 1:
    if take(data, pos, stop) != 3 or take(data, pos, stop) != 0:
      componentFail("instance type export annotation requires equality")
    visible = takeU32(data, pos, stop)
    if not scope.isInstanceType(visible):
      componentFail("instance type export annotation sort mismatch")
    requireInstanceTypeSubtype(instanceTypeAt(scope, index), instanceTypeAt(scope, visible))
  else: componentFail("invalid instance type export annotation")
  addPlanInstanceType(plan, scope, visible, name, importing = false)

proc requireValueTypeAscription(plan: ComponentPlan, scope: ShapeScope, index: uint32,
                                expected: CanonicalSlot) {.noinline.} =
  let actual = shapeAt(scope, index)
  if actual != expected:
    componentFail("value type export annotation shape mismatch")
  if expected.resources != {} and not matchValueResourceBindings(plan, plan.handleTypes,
      actual, expected, [], substitute = false):
    componentFail("value type export annotation resource mismatch")

proc readComponentTypeExport(data: openArray[byte], pos: var int, stop: int,
    name: string, plan: var ComponentPlan, scope: var ShapeScope) {.noinline.} =
  template types: untyped = scope.functionTypes[]
  template resourceAliases: untyped = scope.resourceAliases[]
  template valueKinds: untyped = scope.kinds
  let typeIndex = takeU32(data, pos, stop)
  if typeIndex >= types.len.uint32:
    componentFail("unsupported component type export")
  let annotation = take(data, pos, stop)
  if types.len >= MaxComponentTypes:
    componentFail("component type index-space limit")
  let target = typeIndex.int
  let kind = valueKinds[target]
  if kind == cpInterfaceType:
    readBoundInstanceTypeExport(data, pos, stop, name, typeIndex, annotation, plan, scope)
    return
  if kind == cpComponentType:
    readBoundComponentTypeExport(data, pos, stop, name, typeIndex, annotation, plan, scope)
    return
  if kind == cpFunctionType:
    var visible = typeIndex
    case annotation
    of 0: discard
    of 1:
      if take(data, pos, stop) != 3 or take(data, pos, stop) != 0:
        componentFail("function type export annotation requires equality")
      visible = takeU32(data, pos, stop)
      if not scope.isFunctionType(visible) or
          not matchComponentFunction(types[target], types[visible.int]) or
          not matchResourceBindings(plan, ComponentExport(signature: types[target]),
            types[visible.int], plan.handleTypes, [], substitute = false):
        componentFail("function type export annotation mismatch")
    else: componentFail("invalid function type export annotation")
    addPlanFunctionType(plan, scope, visible, name, importing = false)
    return
  var visible = typeIndex
  var abstractResource = false
  case annotation
  of 0: discard
  of 1:
    if take(data, pos, stop) != 3:
      componentFail("component type export annotation sort mismatch")
    case take(data, pos, stop)
    of 0:
      visible = takeU32(data, pos, stop)
      if visible >= valueKinds.len.uint32 or valueKinds[visible.int] != kind:
        componentFail("component type export annotation sort mismatch")
    of 1:
      if kind != cpResourceType:
        componentFail("component type export subtype bound requires a resource")
      abstractResource = true
    else: componentFail("invalid component type export bound")
  else: componentFail("invalid component type export annotation")
  if kind == cpResourceType:
    var resource = resourceIndex(resourceAliases, typeIndex)
    if resource < 0 or resource != resourceIndex(resourceAliases, visible):
      componentFail("resource type export annotation identity mismatch")
    if abstractResource:
      let source = resource
      resource = plan.resources.len
      boundedAdd(plan.resources, LocalResourcePlan(ascribedFrom: (source + 1).uint16),
        MaxComponentResourceTypes)
    let typeName = newResourceName()
    resourceAliases.add(ResourceTypeAlias(typeIndex: types.len.uint16,
      resourceIndex: resource.uint16, visible: true, typeName: typeName))
    if plan.links == nil: new(plan.links)
    plan.links.visibilityOrder.addMember(vmResource, plan.links.resourceExports.len)
    boundedAdd(plan.links.resourceExports, NamedResourceType(name: name,
      resourceIndex: resource.uint16, typeName: typeName),
      MaxComponentFunctions)
    publishResourceName(addr scope, typeName)
    valueKinds.add(kind)
  else:
    let value = shapeAt(scope, visible)
    if visible != typeIndex:
      requireValueTypeAscription(plan, scope, typeIndex, value)
    requireVisibleChildren(value, addr scope, false)
    requireVisibleResourceSlot(plan.handleTypes, value, false,
      "component value resource type is not exported", scope = addr scope)
    let shape = newSlot(value)
    if plan.links == nil: new(plan.links)
    if shape.kind in ShapedValues or shape.resources != {}:
      plan.links.visibilityOrder.addMember(vmType, plan.links.valueExports.len)
    boundedAdd(plan.links.valueExports, NamedValueType(name: name, shape: shape),
      MaxComponentFunctions)
    scope.addValueType(shape, tvExported)
  types.add(ComponentFuncType())

proc readComponentTypeImport(data: openArray[byte], pos: var int, stop: int,
    name: string, plan: var ComponentPlan, scope: var ShapeScope,
    resourceImports: var seq[NamedResourceType]) {.noinline.} =
  template types: untyped = scope.functionTypes[]
  template resourceAliases: untyped = scope.resourceAliases[]
  template valueKinds: untyped = scope.kinds
  let bound = take(data, pos, stop)
  if types.len >= MaxComponentTypes:
    componentFail("component type index-space limit")
  if bound == 1:
    let typeName = newResourceName()
    resourceImports.add(NamedResourceType(name: name,
      resourceIndex: plan.resources.len.uint16, typeName: typeName))
    resourceAliases.add(ResourceTypeAlias(typeIndex: types.len.uint16,
      resourceIndex: plan.resources.len.uint16, visible: true, imported: true, typeName: typeName))
    boundedAdd(plan.resources, LocalResourcePlan(importName: name, importedTypeName: typeName),
      MaxComponentResourceTypes)
    publishResourceName(addr scope, typeName, importing = true)
    types.add(ComponentFuncType())
    valueKinds.add(cpResourceType)
    return
  if bound != 0:
    componentFail("unsupported component type import bound")
  let typeIndex = takeU32(data, pos, stop)
  if scope.isFunctionType(typeIndex):
    addPlanFunctionType(plan, scope, typeIndex, name, importing = true)
    return
  if scope.isComponentType(typeIndex):
    addPlanComponentType(plan, scope, typeIndex, name, importing = true)
    return
  if scope.isInstanceType(typeIndex):
    addPlanInstanceType(plan, scope, typeIndex, name, importing = true)
    return
  let resource = resourceIndex(resourceAliases, typeIndex)
  if resource >= 0:
    if plan.resources[resource].importName.len == 0 and
        plan.contractResourceCapture(resource).depth == 0:
      componentFail("local resource type found in imports")
    requireImportedResourceName(scope, resourceAliases[lookupResourceType(resourceAliases, typeIndex)])
    if plan.links == nil: new(plan.links)
    let typeName = newResourceName()
    let named = NamedResourceType(name: name, resourceIndex: resource.uint16, typeName: typeName)
    resourceImports.add(named)
    boundedAdd(plan.links.resourceEqualityImports, named, MaxComponentFunctions)
    resourceAliases.add(ResourceTypeAlias(typeIndex: types.len.uint16,
      resourceIndex: resource.uint16, visible: true, imported: true, typeName: typeName))
    publishResourceName(addr scope, typeName, importing = true)
    types.add(ComponentFuncType())
    valueKinds.add(cpResourceType)
    return
  let value = shapeAt(scope, typeIndex)
  requireVisibleChildren(value, addr scope, true)
  requireVisibleResourceSlot(plan.handleTypes, value, true,
    "component value resource type is not imported", scope = addr scope)
  let shape = newSlot(value)
  if plan.links == nil: new(plan.links)
  boundedAdd(plan.links.valueImports, NamedValueType(name: name, shape: shape),
    MaxComponentFunctions)
  scope.addValueType(shape, tvImported)
  types.add(ComponentFuncType())

proc decodeComponentAtDepth(data: openArray[byte], depth: int,
                            parent: ptr ShapeScope = nil): ComponentPlan =
  ## Parse and validate the supported Component Model 0.2 binary subset.
  ## The section walk is bounded and all references must point backwards.
  if data.len < 8 or data.len > MaxComponentBytes or
      data[0] != 0 or data[1] != 0x61 or data[2] != 0x73 or
      data[3] != 0x6d or data[4] != 0x0d or data[5] != 0 or
      data[6] != 1 or data[7] != 0:
    componentFail("unsupported component header")
  result.instanceCount = 1
  var pos = 8
  var coreInstances: seq[CoreInstance]
  var coreFunctions: seq[CoreFunction]
  var aliases: array[ekTable .. ekTag, seq[CoreExportAlias]]
  var functions: seq[ComponentFunction]
  var types: seq[ComponentFuncType]
  var scope = ShapeScope(parent: parent, componentBoundary: true)
  var coreModuleValues: seq[CoreModuleValue]
  scope.coreModuleValues = addr coreModuleValues
  scope.corePlan = addr result
  template valueKinds: untyped = scope.kinds
  var importNames: seq[string]
  var exportNames: seq[string]
  var resourceImports: seq[NamedResourceType]
  var resourceAliases: seq[ResourceTypeAlias]
  scope.resourceAliases = addr resourceAliases
  scope.handleTypes = addr result.handleTypes
  var definitions: ComponentDefinitionScope
  scope.componentDefinitions = addr definitions
  var componentInstances: seq[DeclaredInstance]
  var interfaceTypes: seq[InterfaceType]
  var componentTypes: seq[ComponentTypeDefinition]
  scope.componentTypes = addr componentTypes
  scope.functionTypes = addr types
  scope.interfaceTypes = addr interfaceTypes
  while pos < data.len:
    let section = take(data, pos, data.len)
    let size = takeU32(data, pos, data.len)
    if size.uint64 > uint64(data.len - pos):
      componentFail("truncated component section")
    let stop = pos + size.int
    case section
    of 0'u8:
      discard takeName(data, pos, stop, allowEmpty = true)
      pos = stop
    of 1'u8:
      if size == 0 or result.embeddedCount() >= MaxComponentCoreModules:
        componentFail("component core module limit")
      var bytes = newSeq[byte](size.int)
      copyMem(addr bytes[0], unsafeAddr data[pos], size.int)
      pos = stop
      if result.coreBytes.len == 0: result.coreBytes = move bytes
      else: result.extraCoreBytes.add(move bytes)
      if coreModuleValues.len != 0:
        boundedAdd(coreModuleValues, CoreModuleValue(
          embeddedIndex: result.embeddedCount().uint8), MaxComponentFunctions)
    of 2'u8:
      let count = takeCount(data, pos, stop, MaxComponentFunctions)
      for _ in 0 ..< count:
        let kind = take(data, pos, stop)
        var instance: CoreInstance
        case kind
        of 0'u8:
          instance.kind = ciModule
          let moduleIndex = takeU32(data, pos, stop)
          var entry: CoreInstantiation
          if coreModuleValues.len == 0:
            if moduleIndex >= result.embeddedCount().uint32: componentFail("unknown core module")
            instance.moduleIndex = moduleIndex.uint8
            entry.moduleIndex = instance.moduleIndex
          else:
            if moduleIndex >= coreModuleValues.len.uint32: componentFail("unknown core module")
            let value = unsafeAddr coreModuleValues[moduleIndex.int]
            if value.embeddedIndex != 0 and value.shape == nil:
              instance.moduleIndex = value.embeddedIndex - 1
              entry.moduleIndex = instance.moduleIndex
            else:
              entry.external = ExternalCoreInstantiation(source: value[])
          instance.storeIndex = result.instances.len.uint8
          boundedAdd(result.instances, move entry, MaxComponentFunctions)
          let args = takeCount(data, pos, stop, MaxComponentFunctions)
          for _ in 0 ..< args:
            let name = takeName(data, pos, stop, allowEmpty = true)
            if take(data, pos, stop) != 0x12'u8:
              componentFail("unsupported core instance argument")
            let index = takeU32(data, pos, stop)
            if index >= coreInstances.len.uint32:
              componentFail("unknown core instance")
            for prev in instance.args:
              if prev.name == name:
                componentFail("duplicate core instance argument")
            instance.args.add((name, index))
        of 1'u8:
          instance.kind = ciInline
          let exports = takeCount(data, pos, stop, MaxComponentFunctions)
          for _ in 0 ..< exports:
            let name = takeName(data, pos, stop, allowEmpty = true)
            let sort = take(data, pos, stop)
            if sort > ord(ekTag).uint8:
              componentFail("unsupported inline core export sort")
            let kind = ExportKind(sort)
            let index = takeU32(data, pos, stop)
            let count = if kind == ekFunc: coreFunctions.len
              else: aliases[kind].len
            if index >= count.uint32:
              componentFail("unknown inline core external")
            for prev in instance.exports:
              if prev.name == name: componentFail("duplicate inline core export")
            instance.exports.add((name, kind, index))
        else: componentFail("unsupported core instance")
        boundedAdd(coreInstances, instance, MaxComponentFunctions)
    of 3'u8:
      let count = takeCount(data, pos, stop, MaxComponentTypes)
      for _ in 0 ..< count:
        readCoreType(data, pos, stop, scope)
    of 4'u8:
      if depth >= MaxComponentNesting or size < 8:
        componentFail("invalid or too deeply nested component")
      var child: ref ComponentPlan
      new(child)
      child[] = decodeComponentAtDepth(data.toOpenArray(pos, stop - 1), depth + 1, addr scope)
      definitions.addDefinition(result.declareLexicalDefinition(child))
      pos = stop
    of 5'u8:
      let count = takeCount(data, pos, stop, MaxComponentFunctions)
      for _ in 0 ..< count:
        let node = case take(data, pos, stop)
          of 0'u8: readChildInstantiation(data, pos, stop, result, definitions,
            coreModuleValues, componentInstances, types, functions, coreInstances, coreFunctions,
            aliases[ekMemory], resourceAliases, scope)
          of 1'u8: readInlineInstance(data, pos, stop, functions, resourceAliases, scope, componentInstances)
          else: componentFail("unsupported component instance")
        boundedAdd(componentInstances, node, MaxComponentFunctions)
    of 6'u8:
      let count = takeCount(data, pos, stop, MaxComponentFunctions)
      for _ in 0 ..< count:
        let sort = take(data, pos, stop)
        if sort == 4:
          let definition = readComponentDefinitionAlias(data, pos, stop, result, scope, componentInstances)
          definitions.addDefinition(definition)
          continue
        if sort in {1'u8, 5'u8}:
          readInstanceAlias(data, pos, stop, result.links, componentInstances,
            functions, sort)
          continue
        if sort == 3:
          if types.len >= MaxComponentTypes:
            componentFail("component type index-space limit")
          case take(data, pos, stop)
          of 0'u8:
            addInstanceTypeAlias(data, pos, stop, result, scope, componentInstances)
          of 2'u8:
            types.add(readOuterTypeAlias(data, pos, stop, scope))
          else: componentFail("unsupported component type alias")
          continue
        if sort != 0:
          componentFail("unsupported component alias")
        let coreSort = take(data, pos, stop)
        if coreSort == 0x10:
          readOuterCoreType(data, pos, stop, scope)
          continue
        if coreSort == 0x11:
          let value = readCoreModuleAlias(data, pos, stop, result, scope, componentInstances)
          result.startModuleNamespace(coreModuleValues)
          boundedAdd(coreModuleValues, value, MaxComponentFunctions)
          continue
        if coreSort > ord(ekTag).uint8:
          componentFail("unsupported core alias sort")
        let kind = ExportKind(coreSort)
        if take(data, pos, stop) != 1:
          componentFail("unsupported component alias")
        let instanceIndex = takeU32(data, pos, stop)
        if instanceIndex >= coreInstances.len.uint32:
          componentFail("unknown instantiated core module")
        let name = takeName(data, pos, stop, allowEmpty = true)
        let instance = addr coreInstances[instanceIndex.int]
        if instance.kind == ciModule:
          if kind == ekFunc:
            boundedAdd(coreFunctions, CoreFunction(kind: cfAlias,
              name: name, coreInstance: instanceIndex), MaxComponentFunctions)
          else:
            boundedAdd(aliases[kind], CoreExportAlias(name: name,
              coreInstance: instanceIndex), MaxComponentFunctions)
        else:
          var found = false
          for exp in instance.exports:
            if exp.name != name or exp.kind != kind: continue
            if kind == ekFunc:
              let source = coreFunctions[exp.itemIndex.int]
              boundedAdd(coreFunctions, source, MaxComponentFunctions)
            else:
              let source = aliases[kind][exp.itemIndex.int]
              boundedAdd(aliases[kind], source, MaxComponentFunctions)
            found = true
            break
          if not found: componentFail("invalid inline core export alias")
    of 7'u8:
      let count = takeCount(data, pos, stop, MaxComponentTypes)
      for _ in 0 ..< count:
        if types.len >= MaxComponentTypes:
          componentFail("component type index-space limit")
        if pos >= stop: componentFail("truncated component type")
        if data[pos] == 0x42'u8:
          inc pos
          interfaceTypes.add(readInterfaceType(data, pos, stop, types.len.uint32, addr scope))
          types.add(ComponentFuncType())
          valueKinds.add(cpInterfaceType)
        elif data[pos] == 0x41'u8:
          declareComponentType(data, pos, stop, scope)
          types.add(ComponentFuncType())
        elif data[pos] == 0x3f'u8:
          inc pos
          if take(data, pos, stop) != ord(vtI32).uint8:
            componentFail("unsupported resource representation")
          var resource: LocalResourcePlan
          case take(data, pos, stop)
          of 0'u8: discard
          of 1'u8:
            let idx = takeU32(data, pos, stop)
            if idx >= coreFunctions.len.uint32:
              componentFail("unknown core resource destructor")
            let dtor = unsafeAddr coreFunctions[idx.int]
            resource.destructorName = dtor.name
            resource.destructorSource = coreFunctionSource(dtor[], coreInstances)
            if dtor.kind == cfLower:
              result.requireGeneratedCoreType(dtor[],
                FuncType(params: @[vtI32]), "invalid core resource destructor type")
          else: componentFail("invalid resource destructor option")
          resourceAliases.add(ResourceTypeAlias(typeIndex: types.len.uint16,
            resourceIndex: result.resources.len.uint16, typeName: newResourceName()))
          boundedAdd(result.resources, move resource, MaxComponentResourceTypes)
          types.add(ComponentFuncType())
          valueKinds.add(cpResourceType)
        elif data[pos] in [0x69'u8, 0x68'u8]:
          let kind = if take(data, pos, stop) == 0x69'u8: cpOwnedResource
            else: cpBorrowedResource
          let target = lookupResourceType(resourceAliases, takeU32(data, pos, stop))
          if target < 0: componentFail("unknown resource type in handle")
          result.handleTypes.add(ResourceTypeAlias(typeIndex: types.len.uint16,
            resourceIndex: resourceAliases[target].resourceIndex,
            visible: resourceAliases[target].visible,
            imported: resourceAliases[target].imported,
            typeName: resourceAliases[target].typeName))
          types.add(ComponentFuncType())
          valueKinds.add(kind)
        elif readValueDefinition(data, pos, stop, scope):
          types.add(ComponentFuncType())
        else:
          var signature = readFuncType(data, pos, stop, valueKinds)
          signature.configureCanonicalType(scope.shapes)
          types.add(move signature)
          valueKinds.add(cpFunctionType)
    of 8'u8:
      let count = takeCount(data, pos, stop, MaxComponentFunctions)
      for _ in 0 ..< count:
        let opcode = take(data, pos, stop)
        case opcode
        of 0'u8:
          if take(data, pos, stop) != 0:
            componentFail("unsupported canonical lift sort")
          let coreIndex = takeU32(data, pos, stop)
          if coreIndex >= coreFunctions.len.uint32:
            componentFail("unknown core function alias")
          let optionCount = takeCount(data, pos, stop, 8)
          var memoryAlias = -1'i32
          var reallocFunction = -1'i32
          var postReturnFunction = -1'i32
          var sawEncoding = false
          var encoding = cseUtf8
          when defined(wasmComponentAsyncCallbacks):
            var callbackFunction = 0'u32
            var asyncLift = false
          for _ in 0 ..< optionCount:
            let option = take(data, pos, stop)
            case option
            of 0'u8 .. 2'u8:
              if sawEncoding: componentFail("duplicate canonical string encoding")
              sawEncoding = true
              encoding = CanonicalStringEncoding(option)
            of 3'u8:
              if memoryAlias >= 0: componentFail("duplicate canonical memory")
              let index = takeU32(data, pos, stop)
              if index >= aliases[ekMemory].len.uint32:
                componentFail("unknown canonical memory")
              memoryAlias = index.int32
            of 4'u8:
              if reallocFunction >= 0: componentFail("duplicate canonical realloc")
              let index = takeU32(data, pos, stop)
              if index >= coreFunctions.len.uint32:
                componentFail("unknown canonical realloc")
              reallocFunction = index.int32
            of 5'u8:
              if postReturnFunction >= 0:
                componentFail("duplicate canonical post-return")
              let index = takeU32(data, pos, stop)
              if index >= coreFunctions.len.uint32:
                componentFail("unknown canonical post-return")
              postReturnFunction = index.int32
            of 6'u8, 7'u8:
              when defined(wasmComponentAsyncCallbacks):
                if option == 6:
                  if asyncLift: componentFail("duplicate canonical async option")
                  asyncLift = true
                else:
                  if callbackFunction != 0: componentFail("duplicate canonical callback option")
                  let index = takeU32(data, pos, stop)
                  if index >= coreFunctions.len.uint32:
                    componentFail("unknown canonical callback function")
                  callbackFunction = index + 1
              else:
                componentFail("unsupported canonical option")
            else: componentFail("unsupported canonical option")
          let typeIndex = takeU32(data, pos, stop)
          if typeIndex >= types.len.uint32 or
              valueKinds[typeIndex.int] != cpFunctionType:
            componentFail("unknown component function type")
          let signature = unsafeAddr types[typeIndex.int]
          var needsMemory = signature[].hasMemoryType()
          when defined(wasmComponentAsyncCallbacks):
            if callbackFunction != 0 and not asyncLift:
              componentFail("canonical callback requires async lift")
            if asyncLift:
              if not signature[].isAsync:
                componentFail("canonical async option requires an async function type")
              if postReturnFunction >= 0:
                componentFail("canonical async lift forbids post-return")
              when not defined(wasmComponentStackful):
                if callbackFunction == 0:
                  componentFail("stackful canonical async lift is unsupported")
              needsMemory = signature[].hasMemoryParam() or
                (signature[].hasResult and (hasPointerPayload(resultSlot(signature[])) or
                  flatSlotWidth(resultSlot(signature[])) > MaxFlatParams))
              if callbackFunction != 0:
                let callback = unsafeAddr coreFunctions[callbackFunction.int - 1]
                if callback.kind == cfLower:
                  result.requireGeneratedCoreType(callback[],
                    FuncType(params: @[vtI32, vtI32, vtI32], results: @[vtI32]),
                    "invalid canonical callback function")
          if needsMemory and memoryAlias < 0:
            componentFail("composite signature needs canonical memory")
          if hasMemoryParam(types[typeIndex.int]) and
              reallocFunction < 0:
            componentFail("composite input needs canonical realloc")
          if reallocFunction >= 0 and memoryAlias < 0:
            componentFail("canonical realloc requires memory")
          let callee = unsafeAddr coreFunctions[coreIndex.int]
          if callee.kind == cfLower:
            let ft = result.generatedCoreType(result.lowerings[callee.loweringIndex.int])
            let callback = when defined(wasmComponentAsyncCallbacks): callbackFunction != 0
              else: false
            let stackful = when defined(wasmComponentStackful): asyncLift and not callback
              else: false
            if not signatureMatchesCore(signature[], ft, callback = callback, stackful = stackful):
              componentFail("canonical function type mismatch")
            result.markCoreFunctionReference(callee[])
          if reallocFunction >= 0 and coreFunctions[reallocFunction.int].kind == cfLower:
            result.requireGeneratedCoreType(coreFunctions[reallocFunction.int],
              FuncType(params: @[vtI32, vtI32, vtI32, vtI32], results: @[vtI32]),
              "invalid canonical realloc function")
          if postReturnFunction >= 0 and coreFunctions[postReturnFunction.int].kind == cfLower:
            let sig = unsafeAddr types[typeIndex.int]
            let expected = FuncType(params: if sig.hasResult: @[coreResultType(sig[])] else: @[])
            result.requireGeneratedCoreType(coreFunctions[postReturnFunction.int],
              expected, "invalid canonical post-return function")
          var lifted = ComponentFunction(kind: fnLift,
            coreFunction: coreIndex, typeIndex: typeIndex,
            memoryAlias: memoryAlias, reallocFunction: reallocFunction,
            postReturnFunction: postReturnFunction,
            stringEncoding: encoding)
          when defined(wasmComponentAsyncCallbacks): lifted.callbackFunction = callbackFunction
          when defined(wasmComponentStackful):
            lifted.stackful = asyncLift and callbackFunction == 0
          boundedAdd(functions, move lifted, MaxComponentFunctions)
        of 1'u8:
          if take(data, pos, stop) != 0:
            componentFail("unsupported canonical lower sort")
          let functionIndex = takeU32(data, pos, stop)
          if functionIndex >= functions.len.uint32:
            componentFail("unknown component import function")
          let fn = functions[functionIndex.int]
          var lowering = CoreLowering(targetIndex: fn.importIndex.uint16)
          case fn.kind
          of fnImport: lowering.kind = clHost
          of fnChild: lowering.kind = clChild
          of fnLift:
            lowering.kind = clLocal
            new(lowering.localTarget)
            lowering.localTarget[] = describeLift(fn, types, coreInstances,
              coreFunctions, aliases[ekMemory])
          let optionCount = takeCount(data, pos, stop, 8)
          var sawEncoding = false
          for _ in 0 ..< optionCount:
            let option = take(data, pos, stop)
            case option
            of 0'u8 .. 2'u8:
              if sawEncoding: componentFail("duplicate canonical string encoding")
              sawEncoding = true
              lowering.stringEncoding = CanonicalStringEncoding(option)
            of 3'u8:
              if lowering.memoryInstance != 0:
                componentFail("duplicate canonical memory")
              let index = takeU32(data, pos, stop)
              if index >= aliases[ekMemory].len.uint32:
                componentFail("unknown canonical lower memory")
              let source = aliases[ekMemory][index.int]
              lowering.memoryName = source.name
              lowering.memoryInstance =
                coreInstances[source.coreInstance.int].storeIndex + 1
            of 4'u8:
              if lowering.reallocSource != 0:
                componentFail("duplicate canonical realloc")
              let index = takeU32(data, pos, stop)
              if index >= coreFunctions.len.uint32:
                componentFail("unknown canonical lower realloc")
              let source = coreFunctions[index.int]
              lowering.reallocName = source.name
              lowering.reallocSource = coreFunctionSource(source, coreInstances)
              if source.kind == cfLower:
                result.requireGeneratedCoreType(source,
                  FuncType(params: @[vtI32, vtI32, vtI32, vtI32], results: @[vtI32]),
                  "invalid canonical realloc function")
            of 6'u8:
              when defined(wasmComponentAsyncCallbacks):
                if lowering.asyncLower: componentFail("duplicate canonical async option")
                if not loweringSignature(result, lowering).asyncSignature():
                  componentFail("canonical async option requires an async function type")
                lowering.asyncLower = true
              else:
                componentFail("unsupported canonical lower option")
            else:
              componentFail("unsupported canonical lower option")
          when defined(bl808lp) and not defined(wasmComponentLocalReentry):
            let asyncLocal = when defined(wasmComponentAsyncCallbacks): lowering.asyncLower
              else: false
            if lowering.kind == clLocal and not asyncLocal:
              componentFail("local canonical lowering requires an LP stack reservation")
          let signature = loweringSignature(result, lowering)
          if not supportedHostSignature(signature, linkedResources = true):
            componentFail("unsupported canonical lower signature")
          if lowering.kind == clChild:
            let referenced = signatureResourceTypes(signature)
            if referenced.len > 0:
              let exp = describeFunction(fn, result, types,
                coreInstances, coreFunctions, aliases[ekMemory])
              var mapping: ResourceTypeMapping
              for index in referenced:
                let local = resourceOfExport(result, exp, index.int32)
                if local < 0: componentFail("unbound canonical resource type")
                mapping.add((index, result.bindResourceHandleIndex(local.uint16).uint16))
              lowering.resourceSignature = new(ComponentFuncType)
              lowering.resourceSignature[] = rebaseResourceSignature(signature, mapping)
          var indirectResult = signature.resultUsesMemory()
          var indirectParams = signature.hasMemoryParam()
          when defined(wasmComponentAsyncCallbacks):
            if lowering.asyncLower:
              let asyncType = new(ComponentFuncType)
              asyncType[] = loweringSignature(result, lowering)
              asyncType[].configureAsyncParams()
              lowering.resourceSignature = asyncType
              indirectResult = signature.asyncResultArea()
              indirectParams = indirectParams or signature.flatParamCount() > MaxFlatAsyncParams
          if lowering.memoryInstance == 0:
            if cpString in signature.params or
                (signature.hasResult and signature.resultType == cpString):
              componentFail("string import needs canonical memory")
            if indirectParams or indirectResult:
              componentFail("indirect component import needs canonical memory")
          if signature.resultRequiresRealloc() and lowering.reallocSource == 0:
            if signature.resultType == cpString:
              componentFail("string import result needs canonical realloc")
            componentFail("component import result needs canonical realloc")
          if lowering.reallocSource != 0 and lowering.memoryInstance == 0:
            componentFail("canonical realloc requires memory")
          boundedAdd(coreFunctions, CoreFunction(kind: cfLower,
            loweringIndex: result.lowerings.len.uint32), MaxComponentFunctions)
          result.addLowering(move lowering)
        of 2'u8 .. 4'u8:
          let typeIndex = takeU32(data, pos, stop)
          let resource = resourceIndex(resourceAliases, typeIndex)
          if resource < 0:
            componentFail("canonical function requires a local resource type")
          if opcode != 3 and (result.resources[resource].importName.len != 0 or
              result.resources[resource].sourceChild != 0 or
              result.resources[resource].ascribedFrom != 0 or
              result.contractResourceCapture(resource).depth != 0):
            componentFail("canonical function requires a local resource type")
          boundedAdd(coreFunctions, CoreFunction(kind: cfLower,
            loweringIndex: result.lowerings.len.uint32), MaxComponentFunctions)
          result.addLowering(CoreLowering(
            kind: CoreLoweringKind(opcode - 1), targetIndex: resource.uint16))
        of 0x09'u8:
          when defined(wasmComponentAsyncCallbacks):
            let signature = new(ComponentFuncType)
            readComponentResult(data, pos, stop, valueKinds, signature[])
            signature[].configureCanonicalType(scope.shapes)
            var lowering = CoreLowering(kind: clTaskReturn, resourceSignature: signature)
            var sawEncoding = false
            let count = takeCount(data, pos, stop, 8)
            for _ in 0 ..< count:
              let option = take(data, pos, stop)
              case option
              of 0'u8 .. 2'u8:
                if sawEncoding: componentFail("duplicate canonical string encoding")
                sawEncoding = true
                lowering.stringEncoding = CanonicalStringEncoding(option)
              of 3'u8:
                if lowering.memoryInstance != 0: componentFail("duplicate canonical memory")
                let index = takeU32(data, pos, stop)
                if index >= aliases[ekMemory].len.uint32:
                  componentFail("unknown canonical task.return memory")
                let alias = unsafeAddr aliases[ekMemory][index.int]
                lowering.memoryInstance = coreInstances[alias.coreInstance.int].storeIndex + 1
                lowering.memoryName = alias.name
              else: componentFail("invalid canonical task.return option")
            if signature.hasResult:
              let slot = resultSlot(signature[])
              if (hasPointerPayload(slot) or flatSlotWidth(slot) > MaxFlatParams) and
                  lowering.memoryInstance == 0:
                componentFail("canonical task.return needs memory")
            boundedAdd(coreFunctions, CoreFunction(kind: cfLower,
              loweringIndex: result.lowerings.len.uint32), MaxComponentFunctions)
            result.addLowering(move lowering)
          else:
            componentFail("unsupported canonical definition")
        of 0x0a'u8, 0x0b'u8:
          when defined(wasmComponentContext) or defined(wasmComponentAsyncCallbacks):
            if take(data, pos, stop) != vtI32.ord.byte:
              componentFail("canonical context type must be i32")
            let slot = takeU32(data, pos, stop)
            if slot > (when defined(wasmComponentThreads): 1'u32 else: 0'u32):
              componentFail("canonical context slot out of range")
            boundedAdd(coreFunctions, CoreFunction(kind: cfLower,
              loweringIndex: result.lowerings.len.uint32), MaxComponentFunctions)
            var lowering = CoreLowering(kind: if opcode == 0x0a: clContextGet else: clContextSet)
            when defined(wasmComponentThreads): lowering.contextSlot = slot.uint8
            result.addLowering(move lowering)
          else:
            componentFail("unsupported canonical definition")
        of 0x0e'u8 .. 0x1b'u8, 0x2e'u8, 0x2f'u8:
          when ComponentEndpointsEnabled:
            let isStream = opcode <= 0x14 or opcode == 0x2e
            let kind = if isStream: cpStream else: cpFuture
            if not endpointEnabled(kind): componentFail("unsupported canonical definition")
            let name = endpointName(kind)
            let index = takeU32(data, pos, stop)
            if index >= valueKinds.len.uint32 or valueKinds[index.int] != kind:
              componentFail("canonical " & name & " operation requires a " & name & " type")
            var lowering = CoreLowering(endpointShape: canonicalShape(index.int32, scope.shapes),
              kind: case opcode
                of 0x0e, 0x15: clEndpointNew
                of 0x0f, 0x16: clEndpointRead
                of 0x10, 0x17: clEndpointWrite
                of 0x11, 0x18: clEndpointCancelRead
                of 0x12, 0x19: clEndpointCancelWrite
                of 0x13, 0x1a: clEndpointDropReadable
                of 0x14, 0x1b: clEndpointDropWritable
                else: clEndpointForward)
            if lowering.kind in {clEndpointCancelRead, clEndpointCancelWrite}:
              let mode = take(data, pos, stop)
              if mode > 1:
                componentFail("invalid canonical " & name & " cancellation async flag")
              lowering.asyncCancel = mode == 1
            elif lowering.kind in {clEndpointRead, clEndpointWrite}:
              var sawEncoding = false
              let optionCount = takeCount(data, pos, stop, 8)
              for _ in 0 ..< optionCount:
                let option = take(data, pos, stop)
                case option
                of 0'u8 .. 2'u8:
                  if sawEncoding: componentFail("duplicate canonical string encoding")
                  sawEncoding = true
                  lowering.stringEncoding = CanonicalStringEncoding(option)
                of 3:
                  if lowering.memoryInstance != 0: componentFail("duplicate canonical memory")
                  let memory = takeU32(data, pos, stop)
                  if memory >= aliases[ekMemory].len.uint32:
                    componentFail("unknown canonical " & name & " memory")
                  let source = unsafeAddr aliases[ekMemory][memory.int]
                  lowering.memoryName = source.name
                  lowering.memoryInstance = coreInstances[source.coreInstance.int].storeIndex + 1
                of 4:
                  if lowering.reallocSource != 0: componentFail("duplicate canonical realloc")
                  let function = takeU32(data, pos, stop)
                  if function >= coreFunctions.len.uint32:
                    componentFail("unknown canonical " & name & " realloc")
                  let source = unsafeAddr coreFunctions[function.int]
                  lowering.reallocName = source.name
                  lowering.reallocSource = coreFunctionSource(source[], coreInstances)
                  if source.kind == cfLower:
                    result.requireGeneratedCoreType(source[],
                      FuncType(params: @[vtI32, vtI32, vtI32, vtI32], results: @[vtI32]),
                      "invalid canonical realloc function")
                of 6:
                  if lowering.asyncCancel: componentFail("duplicate canonical async option")
                  lowering.asyncCancel = true
                else: componentFail("invalid canonical " & name & " copy option")
              when not defined(wasmComponentStackful):
                if not lowering.asyncCancel:
                  componentFail("synchronous " & name & " copy requires stackful execution")
              let payload = lowering.endpointShape.listElement
              if payload != nil and lowering.memoryInstance == 0:
                componentFail("typed " & name & " copy requires canonical memory")
              if lowering.reallocSource != 0 and lowering.memoryInstance == 0:
                componentFail("canonical realloc requires memory")
              if payload != nil and lowering.kind == clEndpointRead and hasPointerPayload(payload[]) and
                  lowering.reallocSource == 0:
                componentFail(name & " read payload requires canonical realloc")
            boundedAdd(coreFunctions, CoreFunction(kind: cfLower,
              loweringIndex: result.lowerings.len.uint32), MaxComponentFunctions)
            result.addLowering(move lowering)
          else:
            componentFail("unsupported canonical definition")
        of 0x1c'u8 .. 0x1e'u8:
          when defined(wasmComponentErrorContext):
            var lowering = CoreLowering(kind: case opcode
              of 0x1c: clErrorContextNew
              of 0x1d: clErrorContextDebugMessage
              else: clErrorContextDrop)
            if lowering.kind != clErrorContextDrop:
              var sawEncoding = false
              let optionCount = takeCount(data, pos, stop, 3)
              for _ in 0 ..< optionCount:
                let option = take(data, pos, stop)
                case option
                of 0'u8 .. 2'u8:
                  if sawEncoding: componentFail("duplicate canonical string encoding")
                  sawEncoding = true
                  lowering.stringEncoding = CanonicalStringEncoding(option)
                of 3:
                  if lowering.memoryInstance != 0: componentFail("duplicate canonical memory")
                  let memory = takeU32(data, pos, stop)
                  if memory >= aliases[ekMemory].len.uint32:
                    componentFail("unknown canonical error-context memory")
                  let source = unsafeAddr aliases[ekMemory][memory.int]
                  lowering.memoryName = source.name
                  lowering.memoryInstance = coreInstances[source.coreInstance.int].storeIndex + 1
                of 4:
                  if lowering.reallocSource != 0: componentFail("duplicate canonical realloc")
                  let function = takeU32(data, pos, stop)
                  if function >= coreFunctions.len.uint32:
                    componentFail("unknown canonical error-context realloc")
                  let source = unsafeAddr coreFunctions[function.int]
                  lowering.reallocName = source.name
                  lowering.reallocSource = coreFunctionSource(source[], coreInstances)
                  if source.kind == cfLower:
                    result.requireGeneratedCoreType(source[],
                      FuncType(params: @[vtI32, vtI32, vtI32, vtI32], results: @[vtI32]),
                      "invalid canonical realloc function")
                else: componentFail("invalid canonical error-context option")
              if lowering.memoryInstance == 0:
                componentFail("canonical error-context requires memory")
              if lowering.kind == clErrorContextDebugMessage and lowering.reallocSource == 0:
                componentFail("canonical error-context debug-message requires realloc")
            boundedAdd(coreFunctions, CoreFunction(kind: cfLower,
              loweringIndex: result.lowerings.len.uint32), MaxComponentFunctions)
            result.addLowering(move lowering)
          else: componentFail("component error-context is disabled")
        of 0x26'u8 .. 0x2d'u8:
          when defined(wasmComponentThreads):
            var lowering = CoreLowering(kind: case opcode
              of 0x26: clThreadIndex
              of 0x27: clThreadNewIndirect
              of 0x28: clThreadResumeLater
              of 0x29: clThreadSuspend
              of 0x2a: clThreadSuspendResume
              of 0x2b: clThreadYieldResume
              of 0x2c: clThreadSuspendPromote
              else: clThreadYieldPromote)
            if lowering.kind == clThreadNewIndirect:
              let typeIndex = takeU32(data, pos, stop)
              if typeIndex >= scope.coreTypes.len.uint32 or scope.coreTypes[typeIndex.int].module != nil:
                componentFail("invalid canonical thread function type")
              let ft = addr scope.coreTypes[typeIndex.int].function
              if ft[].isSharedCoreFunction() or ft.params != @[vtI32] or ft.results.len != 0:
                componentFail("canonical thread function must have type (i32) -> ()")
              lowering.threadClosure = ft.params[0]
              let table = takeU32(data, pos, stop)
              if table >= aliases[ekTable].len.uint32:
                componentFail("unknown canonical thread table")
              let source = addr aliases[ekTable][table.int]
              lowering.threadTable = coreInstances[source.coreInstance.int].storeIndex + 1
              lowering.threadTableName = source.name
            elif opcode >= 0x29 and take(data, pos, stop) != 0:
              componentFail("invalid canonical thread suspend sort")
            boundedAdd(coreFunctions, CoreFunction(kind: cfLower,
              loweringIndex: result.lowerings.len.uint32), MaxComponentFunctions)
            result.addLowering(move lowering)
          else:
            componentFail("unsupported canonical definition")
        of 0x40'u8 .. 0x42'u8:
          when defined(wasmComponentThreadSpawn):
            case take(data, pos, stop)
            of 0: discard  # Cooperative function on the component's core.
            of 1: componentFail("shared canonical threads require preemptive core support")
            else: componentFail("invalid canonical thread sharedness")
            var lowering = CoreLowering(kind: clThreadAvailableParallelism)
            if opcode != 0x42:
              let typeIndex = takeU32(data, pos, stop)
              if typeIndex >= scope.coreTypes.len.uint32 or scope.coreTypes[typeIndex.int].module != nil:
                componentFail("invalid canonical spawn function type")
              let signature = addr scope.coreTypes[typeIndex.int].function
              if signature.params != @[vtI32] or signature.results.len != 0:
                componentFail("canonical spawn function must have type (i32) -> ()")
              if signature[].isSharedCoreFunction():
                componentFail("cooperative canonical spawn function type must be unshared")
              if opcode == 0x41:
                let table = takeU32(data, pos, stop)
                if table >= aliases[ekTable].len.uint32:
                  componentFail("unknown canonical spawn table")
                componentFail("canonical thread.spawn-indirect requires a shared core table")
              lowering.kind = clThreadSpawnRef
              new(lowering.threadSignature)
              lowering.threadSignature[] = signature[]
            boundedAdd(coreFunctions, CoreFunction(kind: cfLower,
              loweringIndex: result.lowerings.len.uint32), MaxComponentFunctions)
            result.addLowering(move lowering)
          else: componentFail("canonical thread spawning is disabled")
        of 0x05'u8, 0x06'u8, 0x0c'u8, 0x0d'u8, 0x1f'u8 .. 0x25'u8:
          when defined(wasmComponentAsyncCallbacks):
            when not defined(wasmComponentStackful):
              if opcode in {0x0c'u8, 0x20'u8}:
                componentFail("unsupported canonical definition")
            var lowering = CoreLowering(kind: case opcode
              of 0x05: clTaskCancel
              of 0x06: clSubtaskCancel
              of 0x0c: clThreadYield
              of 0x0d: clSubtaskDrop
              of 0x1f: clWaitableSetNew
              of 0x20: clWaitableSetWait
              of 0x21: clWaitableSetPoll
              of 0x22: clWaitableSetDrop
              of 0x23: clWaitableJoin
              of 0x24: clBackpressureInc
              else: clBackpressureDec)
            if opcode == 0x06:
              let mode = take(data, pos, stop)
              if mode > 1: componentFail("invalid canonical subtask.cancel async flag")
              lowering.asyncCancel = mode == 1
            if opcode == 0x0c and take(data, pos, stop) != 0:
              componentFail("invalid canonical thread.yield sort")
            if opcode in {0x20'u8, 0x21'u8}:
              if take(data, pos, stop) != 0:
                componentFail("invalid canonical waitable-set.poll sort")
              let index = takeU32(data, pos, stop)
              if index >= aliases[ekMemory].len.uint32:
                componentFail("unknown canonical waitable-set.poll memory")
              let source = unsafeAddr aliases[ekMemory][index.int]
              lowering.memoryName = source.name
              lowering.memoryInstance = coreInstances[source.coreInstance.int].storeIndex + 1
            boundedAdd(coreFunctions, CoreFunction(kind: cfLower,
              loweringIndex: result.lowerings.len.uint32), MaxComponentFunctions)
            result.addLowering(move lowering)
          else:
            componentFail("unsupported canonical definition")
        else: componentFail("unsupported canonical definition")
    of 10'u8:
      let count = takeCount(data, pos, stop, MaxComponentFunctions)
      for _ in 0 ..< count:
        let external = takeExternalName(data, pos, stop)
        let name = external.name
        for previous in importNames:
          if sameCanonicalName(previous, name):
            componentFail("duplicate component import")
        boundedAdd(importNames, name, MaxComponentFunctions)
        result.rememberNameAttributes(external, importing = true)
        case external.sort
        of 0'u8:
          let shape = readModuleTypeRef(data, pos, stop, scope)
          let value = addCoreModuleImport(result, name, shape)
          result.startModuleNamespace(coreModuleValues)
          boundedAdd(coreModuleValues, value, MaxComponentFunctions)
        of 1'u8:
          let typeIndex = takeU32(data, pos, stop)
          if typeIndex >= types.len.uint32 or
              valueKinds[typeIndex.int] != cpFunctionType:
            componentFail("unknown component import type")
          if not supportedHostSignature(types[typeIndex.int], linkedResources = true):
            componentFail("unsupported component import signature")
          result.requireVisibleResources(types[typeIndex.int], forImport = true, scope = addr scope)
          requireVisibleFunctionType(scope, typeIndex, forImport = true)
          if resourceMember(name).kind != rmNone:
            checkResourceMemberName(result, ComponentExport(name: name,
              signature: types[typeIndex.int]), resourceImports)
          boundedAdd(functions, ComponentFunction(kind: fnImport,
            typeIndex: typeIndex, importIndex: result.imports.len.uint32),
            MaxComponentFunctions)
          boundedAdd(result.imports, ComponentImport(name: name,
            signature: types[typeIndex.int]), MaxComponentFunctions)
        of 5'u8:
          let index = lookupInterface(interfaceTypes, takeU32(data, pos, stop))
          requireInterfaceNames(interfaceTypes[index], addr scope, forImport = true)
          let source = addInterfaceImport(result, name, interfaceTypes[index], addr scope)
          boundedAdd(componentInstances, source, MaxComponentFunctions)
        of 4'u8:
          let contract = lookupComponentType(componentTypes, takeU32(data, pos, stop))
          definitions.addDefinition(addComponentTypeImport(result, name, contract))
        of 3'u8:
          readComponentTypeImport(data, pos, stop, name, result, scope, resourceImports)
        else: componentFail("unsupported component import sort")
    of 11'u8:
      let count = takeCount(data, pos, stop, MaxComponentFunctions)
      for _ in 0 ..< count:
        let external = takeExternalName(data, pos, stop)
        let name = external.name
        for previous in exportNames:
          if sameCanonicalName(previous, name):
            componentFail("duplicate component export")
        boundedAdd(exportNames, name, MaxComponentFunctions)
        result.rememberNameAttributes(external, importing = false)
        let sort = external.sort
        if sort == 4:
          readComponentDefinitionExport(data, pos, stop, name, result, definitions, componentTypes)
          continue
        if sort == 0:
          if take(data, pos, stop) != 0x11: componentFail("unsupported core export sort")
          let index = takeU32(data, pos, stop)
          var value = typedModuleValue(result, coreModuleValues, index)
          value.shape = value.moduleShape()
          case take(data, pos, stop)
          of 0: discard
          of 1:
            if take(data, pos, stop) != 0: componentFail("core module export annotation sort mismatch")
            let required = readModuleTypeRef(data, pos, stop, scope)
            requireModuleSubtype(value.shape, required)
            value.shape = required
          else: componentFail("invalid core module export annotation")
          addCoreModuleExport(result, name, value)
          boundedAdd(coreModuleValues, move value, MaxComponentFunctions)
          continue
        if sort == 5:
          readInterfaceExport(data, pos, stop, name, result, componentInstances,
            interfaceTypes, coreInstances, coreFunctions, aliases[ekMemory], addr scope)
          continue
        if sort == 3:
          readComponentTypeExport(data, pos, stop, name, result, scope)
          continue
        if sort != 1:
          componentFail("unsupported component export sort")
        let functionIndex = takeU32(data, pos, stop)
        if functionIndex >= functions.len.uint32:
          componentFail("unknown component function")
        let fn = functions[functionIndex.int]
        var exp = describeFunction(fn, result, types, coreInstances,
                                  coreFunctions, aliases[ekMemory])
        var scopeType = fn.typeIndex
        case take(data, pos, stop)
        of 0'u8: discard
        of 1'u8:
          if take(data, pos, stop) != 1:
            componentFail("component function export annotation sort mismatch")
          let index = takeU32(data, pos, stop)
          if index >= types.len.uint32 or valueKinds[index.int] != cpFunctionType or
              not supportedHostSignature(exp.signature, linkedResources = true) or
              not matchComponentFunction(exp.signature, types[index.int]) or
              not matchResourceBindings(result, exp, types[index.int], result.handleTypes,
                [], substitute = false):
            componentFail("component function export annotation type mismatch")
          if exp.target != ctChild:
            exp.signature = types[index.int]
          scopeType = index
        else: componentFail("invalid component function export annotation")
        exp.name = name
        if exp.target == ctImport and result.links == nil: new(result.links)
        if scopeType == uint32.high:
          exp.resourceNames = result.componentFunctionResources(fn, exp.signature, addr scope)
          requirePublishedResourceNames(addr scope, exp.resourceNames,
            "component function resource type is not exported")
        else:
          result.requireVisibleResources(types[scopeType.int], scope = addr scope)
          exp.resourceNames = resourceNames(types[scopeType.int], result.handleTypes)
        if result.links != nil:
          checkResourceMemberName(result, exp, result.links.resourceExports)
        elif resourceMember(name).kind != rmNone:
          componentFail("resource member names a type absent from its interface")
        if scopeType == uint32.high:
          exp.visibilityNames = result.componentFunctionNames(fn, addr scope)
          if exp.visibilityNames != nil:
            for name in exp.visibilityNames[]:
              requireVisibleReference(name.shape, addr scope, false, name.diagnostic)
        else:
          requireVisibleFunctionType(scope, scopeType)
          exp.visibilityNames = functionTypeNames(addr scope, scopeType)
        if exp.visibilityNames != nil or exp.resourceNames != nil:
          if result.links == nil: new(result.links)
          result.links.visibilityOrder.addMember(vmFunction, result.exports.len)
        boundedAdd(result.exports, move exp, MaxComponentFunctions)
        # Component exports add an alias to the function index space.
        var alias = fn
        alias.typeIndex = scopeType
        boundedAdd(functions, alias, MaxComponentFunctions)
    else:
      componentFail("unsupported component section")
    if pos != stop: componentFail("component section length mismatch")
  # These declaration tables are no longer needed once the link plan has
  # been built. Release them before decoding core modules for validation.
  reset(definitions)
  reset(componentInstances)
  reset(interfaceTypes)
  reset(componentTypes)
  reset(importNames)
  reset(exportNames)
  reset(resourceImports)
  reset(resourceAliases)
  reset(valueKinds)
  reset(scope.shapes)
  reset(scope.coreTypes)
  reset(coreModuleValues)
  validateResourceCaptures(result)
  result.validateCoreGraph(coreInstances, coreFunctions, aliases, functions, types)
  result.validated = true

proc decodeComponent*(data: openArray[byte]): ComponentPlan =
  decodeComponentAtDepth(data, 0)

proc lower(value: ComponentValue): WasmValue
proc lift(value: WasmValue, kind: ComponentPrim): ComponentValue
proc coreExport(instance: ComponentInstance, source: uint16,
                name: string, kind: ExportKind): int

const Utf16LengthTag = 0x80000000'u32

proc readCanonicalString(memory: var MemInst, offset, taggedCount: uint32,
                         encoding: CanonicalStringEncoding): string =
  let utf16 = encoding == cseUtf16 or
    (encoding == cseLatin1Utf16 and (taggedCount and Utf16LengthTag) != 0)
  let units = if encoding == cseLatin1Utf16: taggedCount and not Utf16LengthTag
    else: taggedCount
  let count = units.uint64 * (if utf16: 2'u64 else: 1'u64)
  if count > MaxComponentStringBytes.uint64:
    componentFail("canonical string length limit")
  if encoding != cseUtf8 and (offset and 1'u32) != 0:
    componentFail("unaligned canonical string pointer")
  var raw = newString(count.int)
  let dst = if count == 0: nil
    else: cast[ptr UncheckedArray[byte]](addr raw[0])
  memory.readMemoryBytes(offset.uint64, dst, count.uint32)
  if encoding == cseUtf8:
    if not validWasmName(raw):
      componentFail("invalid UTF-8 canonical string")
    return move raw
  var i = 0
  while i < raw.len:
    var scalar = uint32(ord(raw[i]))
    inc i
    if utf16:
      scalar = scalar or (uint32(ord(raw[i])) shl 8)
      inc i
      if scalar in 0xd800'u32 .. 0xdbff'u32:
        if i == raw.len: componentFail("missing UTF-16 low surrogate")
        let low = uint32(ord(raw[i])) or (uint32(ord(raw[i + 1])) shl 8)
        if low notin 0xdc00'u32 .. 0xdfff'u32:
          componentFail("invalid UTF-16 low surrogate")
        i += 2
        scalar = 0x10000'u32 + ((scalar - 0xd800'u32) shl 10) +
          (low - 0xdc00'u32)
      elif scalar in 0xdc00'u32 .. 0xdfff'u32:
        componentFail("unpaired UTF-16 low surrogate")
    result.appendUtf8Scalar(scalar)
    if result.len > MaxComponentStringBytes:
      componentFail("canonical string length limit")

template withFreshContext(execution, body: untyped): untyped =
  when defined(wasmComponentContext) or defined(wasmComponentAsyncCallbacks):
    block:
      let state: CanonicalExecutionState = execution
      let previous = state.context
      var context = 0'i32
      state.context = addr context
      defer: state.context = previous
      when defined(wasmComponentThreads):
        let previousSecond = state.contextSecond
        var contextSecond = 0'i32
        state.contextSecond = addr contextSecond
        defer: state.contextSecond = previousSecond
      when defined(wasmComponentAsyncCallbacks):
        let previousTask = state.callbackTask
        let previousScope = state.borrowScope
        state.callbackTask = nil
        state.borrowScope = 0
        defer:
          state.callbackTask = previousTask
          state.borrowScope = previousScope
      body
  else:
    body

proc canonicalRealloc(vm: var WasmVM, execution: CanonicalExecutionState,
    memoryAddress, reallocAddress: int, oldOffset, oldBytes: uint32,
    newBytes, alignment: int): uint32 =
  let previous = execution.mayLeave
  execution.mayLeave = false
  var allocated: seq[WasmValue]
  try:
    withFreshContext(execution):
      allocated = vm.execute(reallocAddress,
        [wasmI32(cast[int32](oldOffset)), wasmI32(cast[int32](oldBytes)),
         wasmI32(alignment.int32), wasmI32(newBytes.int32)])
  finally:
    execution.mayLeave = previous
  if allocated.len != 1 or allocated[0].kind != wvkI32:
    componentFail("canonical realloc returned invalid pointer")
  result = allocated[0].i32.uint32
  if (result and (alignment - 1).uint32) != 0:
    componentFail("unaligned canonical realloc result")
  vm.store.mems[memoryAddress].checkMemoryRange(result.uint64, newBytes.uint32)

proc allocCanonicalPayload(vm: var WasmVM, execution: CanonicalExecutionState,
    memoryAddress, reallocAddress: int, source: pointer,
    count, alignment: int): uint32 =
  result = vm.canonicalRealloc(execution, memoryAddress, reallocAddress,
    0, 0, count, alignment)
  vm.store.mems[memoryAddress].writeMemoryBytes(result.uint64,
    cast[ptr UncheckedArray[byte]](source), count.uint32)

proc storeCanonicalText(vm: var WasmVM, execution: CanonicalExecutionState,
    memoryAddress, reallocAddress: int, value: string,
    encoding: CanonicalStringEncoding): tuple[offset, units: uint32] =
  let source = if value.len == 0: nil else: unsafeAddr value[0]
  if encoding == cseUtf8:
    return (vm.allocCanonicalPayload(execution, memoryAddress, reallocAddress,
      source, value.len, 1), value.len.uint32)
  let initialBytes = if encoding == cseUtf16: value.len * 2 else: value.len
  result.offset = vm.canonicalRealloc(execution, memoryAddress, reallocAddress,
    0, 0, initialBytes, 2)
  var latinPrefix = ""
  if encoding == cseLatin1Utf16:
    var allLatin = true
    for scalar in value.utf8Scalars():
      if scalar > 255:
        allLatin = false
        break
      latinPrefix.add(char(scalar))
    if latinPrefix.len > 0:
      vm.store.mems[memoryAddress].writeMemoryBytes(result.offset.uint64,
        cast[ptr UncheckedArray[byte]](addr latinPrefix[0]), latinPrefix.len.uint32)
    if allLatin:
      if latinPrefix.len < initialBytes:
        result.offset = vm.canonicalRealloc(execution, memoryAddress, reallocAddress,
          result.offset, initialBytes.uint32, latinPrefix.len, 2)
      result.units = latinPrefix.len.uint32
      return
    result.offset = vm.canonicalRealloc(execution, memoryAddress, reallocAddress,
      result.offset, initialBytes.uint32, value.len * 2, 2)
  var encoded = ""
  template addUnit(unit: uint32) =
    encoded.add(char(unit and 0xff'u32))
    encoded.add(char(unit shr 8))
  for scalar in value.utf8Scalars():
    if scalar < 0x10000'u32:
      addUnit(scalar)
    else:
      let pair = scalar - 0x10000'u32
      addUnit(0xd800'u32 or (pair shr 10))
      addUnit(0xdc00'u32 or (pair and 0x3ff'u32))
  if encoded.len > MaxComponentStringBytes:
    componentFail("canonical string length limit")
  if encoded.len > 0:
    vm.store.mems[memoryAddress].writeMemoryBytes(result.offset.uint64,
      cast[ptr UncheckedArray[byte]](addr encoded[0]), encoded.len.uint32)
  let reserved = value.len * 2
  if encoded.len < reserved:
    result.offset = vm.canonicalRealloc(execution, memoryAddress, reallocAddress,
      result.offset, reserved.uint32, encoded.len, 2)
  result.units = (encoded.len div 2).uint32
  if encoding == cseLatin1Utf16:
    result.units = result.units or Utf16LengthTag

when defined(wasmComponentHostEndpoints):
  type EndpointLoweredHandle = object
    handle: uint32
    when defined(wasmComponentErrorContext):
      isErrorContext: bool
    case isResource: bool
    of true:
      resourceType: uint32
      resource: ComponentOwnedValue
      definer, graph: ComponentInstance
    else:
      token: ComponentEndpointValue
      endpoint: ComponentEndpoint
      shape: ref CanonicalSlot
      payloadResources: seq[EndpointResourceIdentity]

type AbiAccess {.byref.} = object
  vm: ptr WasmVM
  execution: CanonicalExecutionState
  memoryAddress, reallocAddress: int
  encoding: CanonicalStringEncoding
  resourceOwner: pointer
  when defined(wasmComponentHostEndpoints):
    endpointMoves: ptr seq[EndpointLoweredHandle]

proc lowerResourceHandle(access: AbiAccess, slot: CanonicalSlot,
                         value: ComponentValue): uint32
when ComponentEndpointsEnabled:
  proc lowerEndpointHandle(access: AbiAccess, slot: CanonicalSlot,
                         value: ComponentValue): uint32
  proc liftEndpointHandle(instance: ComponentInstance, slot: CanonicalSlot,
                        handle: uint32): ComponentValue
  proc validateEndpointValue(instance: ComponentInstance, slot: CanonicalSlot,
                           value: ComponentValue)

proc lowerFlatSlot(access: AbiAccess, slot: CanonicalSlot, value: ComponentValue,
                   lanes: var seq[WasmValue])

proc lowerAbiResult(access: AbiAccess, sig: ComponentFuncType, value: ComponentValue,
                    returnPointer: uint32): seq[WasmValue]

proc readIndirectArgs(memory: var MemInst, area: CanonicalParams, offset: uint32,
                      encoding: CanonicalStringEncoding): seq[ComponentValue]

proc readFlatArgs(access: AbiAccess, sig: ComponentFuncType,
                   args: openArray[WasmValue], offset: var int): seq[ComponentValue]

type LoweredResult = object
  access: ptr AbiAccess
  signature: ptr ComponentFuncType
  returnPointer: uint32
  values: ptr seq[WasmValue]

proc invokeFunction(instance: ComponentInstance, exp: ComponentExport,
    args: openArray[ComponentValue], guestEntry = false,
    destination: ptr LoweredResult = nil): seq[ComponentValue]

proc runPostReturn(instance: ComponentInstance, address: int, values: openArray[WasmValue]) =
  let previous = instance.execution.mayLeave
  instance.execution.mayLeave = false
  defer: instance.execution.mayLeave = previous
  if instance.vm.execute(address, values).len != 0:
    componentFail("canonical post-return result mismatch")

proc resolveLoweredResult(destination: ptr LoweredResult, returned: var seq[ComponentValue])

proc invokeResourceLowering(instance: ComponentInstance, callback: ComponentHostFunc,
    target: ComponentCallTarget, args: var seq[ComponentValue], destination: ptr LoweredResult)

proc usesResources(sig: ComponentFuncType): bool =
  sig.parameterResources() != {} or sig.hasResourceResult()

proc readLoweredArguments(access: AbiAccess, sig: ComponentFuncType,
    args: openArray[WasmValue], returnPointer: var uint32, asyncAbi = false): seq[ComponentValue] =
  var offset = 0
  let indirect = if asyncAbi: sig.flatParamCount() > MaxFlatAsyncParams else: sig.paramsUseMemoryArea()
  if indirect:
    if args.len == 0 or args[0].kind != wvkI32 or access.memoryAddress < 0:
      componentFail("canonical import argument count mismatch")
    result = readIndirectArgs(access.vm[].store.mems[access.memoryAddress],
      sig.paramArea, args[0].i32.uint32, access.encoding)
    offset = 1
  else:
    result = readFlatArgs(access, sig, args, offset)
  let indirectResult = when defined(wasmComponentAsyncCallbacks):
    if asyncAbi: sig.asyncResultArea() else: sig.resultUsesMemory()
  else: sig.resultUsesMemory()
  if offset + indirectResult.int != args.len:
    componentFail("canonical import argument count mismatch")
  if indirectResult: returnPointer = args[offset].i32.uint32

proc invokeLoweredTarget(callback: ComponentHostFunc, target: ComponentCallTarget,
    args: openArray[ComponentValue], destination: ptr LoweredResult) =
  if target != nil:
    let owner = cast[ComponentInstance](target.owner)
    discard owner.invokeFunction(target.entry[], args, guestEntry = true, destination = destination)
  else:
    var returned = callback(args)
    resolveLoweredResult(destination, returned)

proc makeLowering(callback: ComponentHostFunc, target: ComponentCallTarget, sig: ComponentFuncType,
                   execution: CanonicalExecutionState, vm: ptr WasmVM, memoryAddress, reallocAddress: int,
                   encoding: CanonicalStringEncoding, resourceOwner: pointer): HostFunc =
  ## A separate closure environment is required for each imported function.
  ## Capturing a loop variable would bind every import to the last callback.
  result = proc(args: openArray[WasmValue]): seq[WasmValue] =
    if not execution.mayLeave:
      componentFail("canonical host call during realloc or post-return")
    let access = AbiAccess(vm: vm, execution: execution, memoryAddress: memoryAddress,
      reallocAddress: reallocAddress, encoding: encoding, resourceOwner: resourceOwner)
    var returnPointer: uint32
    var componentArgs = readLoweredArguments(access, sig, args, returnPointer)
    var destination = LoweredResult(access: unsafeAddr access, signature: unsafeAddr sig,
      returnPointer: returnPointer, values: addr result)
    if resourceOwner != nil:
      invokeResourceLowering(cast[ComponentInstance](resourceOwner), callback,
        target, componentArgs, addr destination)
    else:
      invokeLoweredTarget(callback, target, componentArgs, addr destination)

when defined(wasmComponentThreads):
  proc invokeGuestDestructor(instance: ComponentInstance, address: int,
      representation: WasmValue): bool

proc dropLocalResource(ctx: pointer, representation: uint64): bool =
  let destructor = cast[ResourceDestructorContext](ctx)
  if destructor.address < 0: return false
  try:
    withFreshContext(destructor.execution):
      let value = wasmI32(cast[int32](representation.uint32))
      when defined(wasmComponentThreads):
        return cast[ComponentInstance](destructor.owner).invokeGuestDestructor(
          destructor.address, value)
      else:
        return destructor.vm[].execute(destructor.address, [value]).len == 0
  except CatchableError:
    return false

proc makeResourceBuiltin(state: LocalResourceState, execution: CanonicalExecutionState,
                         kind: CoreLoweringKind, typeIndex: uint32): HostFunc =
  result = proc(args: openArray[WasmValue]): seq[WasmValue] =
    if args.len != 1:
      componentFail("invalid canonical resource arguments")
    if kind != clResourceRep and not execution.mayLeave:
      componentFail("resource builtin called during realloc or post-return")
    let bits = args[0].i32.uint32
    var status: ComponentResourceStatus
    if kind == clResourceNew:
      var handle: uint32
      status = state.table.newOwned(typeIndex, bits.uint64, handle)
      if status == crOk: return @[wasmI32(cast[int32](handle))]
    else:
      if kind == clResourceRep:
        var representation: uint64
        status = state.table.representation(bits, typeIndex, representation)
        if status == crOk:
          return @[wasmI32(cast[int32](representation.uint32))]
      else:
        status = state.table.dropHandle(bits, typeIndex)
        if status == crOk: return
    componentFail("canonical resource operation failed: " & $status)

proc resourceOrigin(instance: ComponentInstance, index: uint32): ResourceBinding =
  if instance.links != nil and index < instance.links.resourceBindings.len.uint32:
    let binding = instance.links.resourceBindings[index.int]
    if binding.owner != nil: return binding
  ResourceBinding(owner: cast[pointer](instance), resourceIndex: index)

proc bindResource(instance: ComponentInstance, index: uint32, binding: ResourceBinding) =
  let definer = cast[ComponentInstance](binding.owner)
  let destructor = definer.resources.destructors[binding.resourceIndex.int]
  var canonicalType = index
  if definer == instance:
    canonicalType = binding.resourceIndex
  else:
    for i, previous in instance.links.resourceBindings:
      if i.uint32 != index and previous.owner == binding.owner and
          previous.resourceIndex == binding.resourceIndex:
        canonicalType = i.uint32
        break
  let status = instance.resources.table.bindResourceType(index, canonicalType,
    if destructor == nil: nil else: dropLocalResource, cast[pointer](destructor))
  if status != crOk:
    componentFail("resource type binding failed: " & $status)
  instance.links.resourceBindings[index.int] = binding
  instance.resources.destructors[index.int] = destructor

proc bindAscribedResources(instance: ComponentInstance, plan: ComponentPlan) {.noinline.} =
  ## An abstract export introduces a static type while retaining the original
  ## runtime resource. Child-backed implementations are bound once ready.
  for i, resource in plan.resources:
    if resource.ascribedFrom == 0 or instance.links.resourceBindings[i].owner != nil:
      continue
    let source = resource.ascribedFrom.int - 1
    let binding = instance.links.resourceBindings[source]
    if binding.owner != nil:
      instance.bindResource(i.uint32, binding)
    else:
      let definition = unsafeAddr plan.resources[source]
      if definition.ascribedFrom == 0 and definition.sourceChild == 0 and
          definition.importName.len == 0 and plan.contractResourceCapture(source).depth == 0:
        instance.bindResource(i.uint32,
          ResourceBinding(owner: cast[pointer](instance), resourceIndex: source.uint32))

proc initCanonicalHandles(instance: ComponentInstance) =
  if instance.resources != nil: return
  let capacity = when defined(bl808lp): 8'u32 else: MaxComponentResourceHandles.uint32
  new(instance.resources)
  if instance.resources.table.initResourceTable(capacity, reuseFreed = true) != crOk:
    componentFail("resource table initialization failed")

proc setupResources(instance: ComponentInstance, plan: ComponentPlan) =
  if plan.resources.len == 0: return
  instance.initCanonicalHandles()
  for i, resource in plan.resources:
    var context: ResourceDestructorContext
    if resource.destructorSource != 0:
      context = ResourceDestructorContext(vm: addr instance.vm, address: -1)
      when defined(wasmComponentThreads):
        context.owner = cast[pointer](instance)
      when defined(wasmComponentContext) or defined(wasmComponentAsyncCallbacks):
        context.execution = instance.execution
    var typeIndex: uint32
    if instance.resources.table.registerResourceType(i.uint64 + 1, crrI32,
        if context == nil: nil else: dropLocalResource,
        cast[pointer](context), typeIndex) != crOk:
      componentFail("resource type registration failed")
    instance.resources.destructors.add(context)
  if instance.links != nil:
    for i, binding in instance.links.resourceBindings:
      if binding.owner != nil:
        instance.bindResource(i.uint32, binding)
    instance.bindAscribedResources(plan)

proc isLocked(instance: ComponentInstance): bool =
  instance.locked or (instance.links != nil and instance.links.store.locked)

proc lockStore(instance: ComponentInstance) =
  instance.locked = true
  if instance.links != nil:
    instance.links.store.locked = true

when defined(wasmComponentThreads):
  proc threadAt(instance: ComponentInstance, id: uint32): ComponentGuestThread =
    let owner = cast[pointer](instance)
    for thread in instance.links.store.guestThreads:
      if thread.owner == owner and thread.id == id: return thread

  proc registerThread(instance: ComponentInstance, thread: ComponentGuestThread): bool =
    let store = instance.links.store
    if store.guestThreads.len >= MaxComponentGuestThreads: return false
    thread.owner = cast[pointer](instance)
    for id in 1'u32 .. MaxComponentGuestThreads.uint32:
      if instance.threadAt(id) == nil:
        thread.id = id
        store.guestThreads.add(thread)
        return true

  proc retireThread(instance: ComponentInstance, thread: ComponentGuestThread) =
    let store = instance.links.store
    for i, candidate in store.guestThreads:
      if candidate == thread:
        store.guestThreads.delete(i)
        if i < store.nextGuestThread: dec store.nextGuestThread
        return

  template withDirectGuestThread(instance, body: untyped): untyped =
    block:
      let owner: ComponentInstance = instance
      let invocation = ComponentInvocation(owner: cast[pointer](owner), state: ccsComplete)
      let thread = ComponentGuestThread(implicit: true, state: cgtRunning, invocation: invocation)
      if not owner.registerThread(thread):
        componentFail("component guest thread capacity exceeded")
      let previous = owner.execution.thread
      let previousContext = owner.execution.context
      let previousSecond = owner.execution.contextSecond
      owner.execution.thread = thread
      owner.execution.context = addr thread.context
      owner.execution.contextSecond = addr thread.contextSecond
      defer:
        owner.execution.thread = previous
        owner.execution.context = previousContext
        owner.execution.contextSecond = previousSecond
        owner.retireThread(thread)
      body

proc childExportAt(child: ComponentInstance, alias: ChildExport): ptr ComponentExport =
  if alias.interfaceIndex == 0:
    addr child.exports[alias.exportIndex.int]
  else:
    addr child.links.exportedInterface(alias.interfaceIndex)
      .methods[alias.exportIndex.int]

proc childCallTarget(instance: ComponentInstance, index: int): ComponentCallTarget =
  let alias = instance.links.aliases[index]
  let child = instance.links.children[alias.childIndex.int]
  ComponentCallTarget(owner: cast[pointer](child), entry: childExportAt(child, alias))

proc planCallTarget(instance: ComponentInstance, source: ref ComponentExport): ComponentCallTarget =
  ComponentCallTarget(owner: cast[pointer](instance), entry: addr source[], ownedEntry: source)

proc makeArgument(instance: ComponentInstance,
                  source: ComponentExport): ComponentHostBinding =
  case source.target
  of ctImport: result = instance.links.bindings[source.targetIndex.int]
  of ctChild: result.target = instance.childCallTarget(source.targetIndex.int)
  of ctCore:
    var entry: ref ComponentExport
    new(entry)
    entry[] = source
    result.target = instance.planCallTarget(entry)
  result.name = source.name
  result.signature = source.signature

proc instantiateComponentInStore(plan: ComponentPlan,
    selected: sink seq[ComponentHostBinding], memoryFactory: ComponentMemoryFactory,
    memoryFactoryContext: pointer, store: ComponentLinkStore,
    resourceBindings: sink seq[ResourceBinding]): ComponentInstance

proc bindAvailableCoreFunctions(instance: ComponentInstance,
    pending: ptr CanonicalInstantiations, beforeCore: int) {.noinline.}

proc instantiateChildren(instance: ComponentInstance, plan: ComponentPlan,
    beforeCore: int, memoryFactory: ComponentMemoryFactory,
    memoryFactoryContext: pointer, canonical: ptr CanonicalInstantiations) =
  if canonical != nil: instance.bindAvailableCoreFunctions(canonical, beforeCore)
  let links = plan.links
  if links == nil: return
  while instance.links.children.len < links.children.len:
    let node = unsafeAddr links.children[instance.links.children.len]
    if node.beforeCore != beforeCore: return
    var arguments = newSeqOfCap[ComponentHostBinding](node.arguments.len)
    for source in node.arguments:
      arguments.add(instance.makeArgument(source))
    var resourceBindings = newSeq[ResourceBinding](node.resourceArgs.len)
    for i, resource in node.resourceArgs:
      if node.plan.resources[i].importName.len > 0:
        resourceBindings[i] = instance.resourceOrigin((resource - 1).uint32)
    let child = instantiateComponentInStore(node.plan[], move arguments,
      memoryFactory, memoryFactoryContext, instance.links.store, move resourceBindings)
    instance.links.children.add(child)
    for i, resource in node.resourceArgs:
      if resource != 0 and node.plan.resources[i].importName.len == 0 and
          node.plan[].contractResourceCapture(i).depth == 0:
        instance.bindResource((resource - 1).uint32, child.resourceOrigin(i.uint32))
    for (childType, parentType) in node.resourceReexports:
      instance.bindResource(parentType.uint32, child.resourceOrigin(childType.uint32))
    instance.bindAscribedResources(plan)
    if canonical != nil: instance.bindAvailableCoreFunctions(canonical, beforeCore)

proc bindLinkedResources(instance: ComponentInstance, frame: LinkedResourceFrame) {.noinline.} =
  for item in frame.captures:
    let origin = item.origin
    if origin.frame == nil or origin.frame.owner == nil:
      componentFail("unresolved lexical resource owner")
    let owner = cast[ComponentInstance](origin.frame.owner)
    instance.links.resourceBindings[item.slot] = owner.resourceOrigin(origin.slot.uint32)
  if frame.local != nil: frame.local.owner = cast[pointer](instance)

when defined(wasmComponentContext) or defined(wasmComponentAsyncCallbacks):
  proc makeContextBuiltin(execution: CanonicalExecutionState, kind: CoreLoweringKind,
      slot = 0'u8): HostFunc =
    result = proc(args: openArray[WasmValue]): seq[WasmValue] =
      let cell = when defined(wasmComponentThreads):
        (if slot == 0: execution.context else: execution.contextSecond)
        else: execution.context
      if cell == nil:
        componentFail("canonical context has no active thread")
      if kind == clContextGet:
        if args.len != 0: componentFail("invalid canonical context arguments")
        return @[wasmI32(cell[])]
      if args.len != 1 or args[0].kind != wvkI32:
        componentFail("invalid canonical context arguments")
      cell[] = args[0].i32

when defined(wasmComponentAsyncCallbacks):
  proc resolveSubtask(task: ComponentSubtask, values: var seq[ComponentValue])

  proc returnFromCallback(instance: ComponentInstance, declared: ComponentFuncType,
      memoryAddress: int, encoding: CanonicalStringEncoding, args: openArray[WasmValue])
  proc makeAsyncBuiltin(instance: ComponentInstance, lowering: CoreLowering): HostFunc
  when defined(wasmComponentThreads):
    proc makeThreadBuiltin(instance: ComponentInstance, lowering: CoreLowering): HostFunc
  when ComponentEndpointsEnabled:
    proc makeEndpointBuiltin(instance: ComponentInstance, lowering: CoreLowering): HostFunc
  proc makeScheduledLowering(lowering: ComponentScheduledLowering): HostFunc

  proc makeTaskReturn(instance: ComponentInstance, lowering: CoreLowering): HostFunc =
    let owner = cast[pointer](instance)
    let signature = lowering.resourceSignature
    let encoding = lowering.stringEncoding
    let memory = if lowering.memoryInstance == 0: -1
      else: instance.coreExport(lowering.memoryInstance, lowering.memoryName, ekMemory)
    result = proc(args: openArray[WasmValue]): seq[WasmValue] =
      cast[ComponentInstance](owner).returnFromCallback(signature[], memory, encoding, args)

when defined(wasmComponentErrorContext):
  proc makeErrorContextBuiltin(instance: ComponentInstance, lowering: CoreLowering): HostFunc

proc bindLowering(instance: ComponentInstance, plan: ComponentPlan,
    lowering: CoreLowering, bindings: openArray[ComponentHostBinding]): HostFunc {.noinline.} =
  when defined(wasmComponentErrorContext):
    if lowering.kind in {clErrorContextNew .. clErrorContextDrop}:
      return makeErrorContextBuiltin(instance, lowering)
  when defined(wasmComponentContext) or defined(wasmComponentAsyncCallbacks):
    if lowering.kind in {clContextGet, clContextSet}:
      when defined(wasmComponentThreads):
        return makeContextBuiltin(instance.execution, lowering.kind, lowering.contextSlot)
      else:
        return makeContextBuiltin(instance.execution, lowering.kind)
  when defined(wasmComponentAsyncCallbacks):
    when defined(wasmComponentThreads):
      if lowering.kind in {clThreadIndex .. clThreadAvailableParallelism}:
        return makeThreadBuiltin(instance, lowering)
    when ComponentEndpointsEnabled:
      if lowering.kind in {clEndpointNew .. clEndpointForward}:
        return makeEndpointBuiltin(instance, lowering)
    if lowering.kind == clTaskReturn:
      return makeTaskReturn(instance, lowering)
    if lowering.kind in {clWaitableSetNew, clWaitableSetDrop, clWaitableSetPoll,
        clWaitableJoin, clSubtaskDrop, clBackpressureInc, clBackpressureDec,
        clTaskCancel, clSubtaskCancel, clWaitableSetWait, clThreadYield}:
      return makeAsyncBuiltin(instance, lowering)
  if lowering.kind notin {clHost, clChild, clLocal}:
    return makeResourceBuiltin(instance.resources, instance.execution, lowering.kind,
                               lowering.targetIndex.uint32)
  let memoryAddress = if lowering.memoryInstance == 0: -1
    else: instance.coreExport(lowering.memoryInstance, lowering.memoryName, ekMemory)
  let reallocAddress = if lowering.reallocSource == 0: -1
    else: instance.coreExport(lowering.reallocSource, lowering.reallocName, ekFunc)
  var callback: ComponentHostFunc
  let target = case lowering.kind
    of clHost:
      let binding = unsafeAddr bindings[lowering.targetIndex.int]
      callback = binding.callback
      binding.target
    of clChild: instance.childCallTarget(lowering.targetIndex.int)
    of clLocal: instance.planCallTarget(lowering.localTarget)
    else: nil   # Resource operations were bound above.
  let signature = loweringSignature(plan, lowering)
  when defined(wasmComponentAsyncCallbacks):
    let scheduledSync = when defined(wasmComponentStackful):
      not lowering.asyncLower and target != nil and signature.asyncSignature()
      else: false
    if lowering.asyncLower or scheduledSync:
      let scheduled = ComponentScheduledLowering(caller: cast[pointer](instance),
        callback: callback, target: target, signature: signature, memoryAddress: memoryAddress,
        reallocAddress: reallocAddress, encoding: lowering.stringEncoding)
      when defined(wasmComponentStackful): scheduled.synchronous = scheduledSync
      return makeScheduledLowering(scheduled)
  makeLowering(callback, target, signature, instance.execution, addr instance.vm,
    memoryAddress, reallocAddress, lowering.stringEncoding,
    if signature.usesResources(): cast[pointer](instance) else: nil)

proc bindAvailableCoreFunctions(instance: ComponentInstance,
    pending: ptr CanonicalInstantiations, beforeCore: int) =
  ## Generated functions can depend on a previous core instance or child.
  ## Publish them before starting the next consumer in declaration order.
  let plan = pending.plan
  let children = if instance.links == nil: 0 else: instance.links.children.len
  while pending.next < plan.lowerings.len:
    let index = pending.next
    let lowering = unsafeAddr plan.lowerings[index]
    if lowering.generatedReference:
      if lowering.afterCores.int > beforeCore or lowering.afterChildren.int > children:
        return
      let callback = bindLowering(instance, plan[], lowering[], pending.bindings[])
      let address = instance.vm.store.funcs.len
      instance.vm.store.funcs.add(FuncInst(isHost: true,
        funcType: plan[].generatedCoreType(lowering[]), hostFunc: callback))
      instance.generatedFunctions[][index] = address + 1
      let source = GeneratedCoreSource or index.uint16
      for i, resource in plan.resources:
        if resource.destructorSource == source:
          instance.resources.destructors[i].address = address
    inc pending.next

proc instantiateComponentInStore(plan: ComponentPlan,
    selected: sink seq[ComponentHostBinding], memoryFactory: ComponentMemoryFactory,
    memoryFactoryContext: pointer, store: ComponentLinkStore,
    resourceBindings: sink seq[ResourceBinding]): ComponentInstance =
  ## Typed component imports become core HostFunc bindings through canon lower.
  ## The existing interpreter remains the owner of the embedded core instance.
  if not plan.validated:
    componentFail("unvalidated component plan")
  when not defined(wasmChunkedMemory):
    if memoryFactory != nil:
      componentFail("chunked component memory is not compiled in")
  let execution = CanonicalExecutionState(mayLeave: true)
  var hostBindings = unsafeAddr selected
  result = ComponentInstance(handleTypes: plan.handleTypes, execution: execution)
  if plan.links != nil or store != nil or defined(wasmComponentAsyncCallbacks):
    new(result.links)
    result.links.store = if store == nil: ComponentLinkStore(root: cast[pointer](result)) else: store
    result.links.resourceBindings = move resourceBindings
    result.links.resourceBindings.setLen(plan.resources.len)
    if plan.links != nil:
      result.links.aliases = plan.links.aliases
      result.links.bindings = move selected
      hostBindings = addr result.links.bindings
      result.links.interfaceExports = plan.links.interfaceExports
      result.links.nestedInterfaceExports = plan.links.nestedInterfaceExports
      if plan.links.linkedResources != nil:
        result.bindLinkedResources(plan.links.linkedResources)
  result.setupResources(plan)
  var canonical: CanonicalInstantiations
  var pending: ptr CanonicalInstantiations
  for lowering in plan.lowerings:
    if lowering.generatedReference:
      new(result.generatedFunctions)
      result.generatedFunctions[].setLen(plan.lowerings.len)
      if plan.instances.len != 0:
        result.vm = initWasmVM()
        when defined(wasmChunkedMemory):
          if memoryFactory != nil:
            result.vm.setMemoryBackendFactory(memoryFactory, memoryFactoryContext)
      canonical = CanonicalInstantiations(plan: unsafeAddr plan, bindings: hostBindings)
      pending = addr canonical
      break
  try:
    for i in 0 ..< plan.instances.len:
      result.instantiateChildren(plan, i, memoryFactory, memoryFactoryContext, pending)
      if i == 0 and pending == nil:
        result.vm = initWasmVM()
        when defined(wasmChunkedMemory):
          if memoryFactory != nil:
            result.vm.setMemoryBackendFactory(memoryFactory, memoryFactoryContext)
      let node = unsafeAddr plan.instances[i]
      # Decode one module at a time. The plan's private bytes were validated
      # before any start function or supplied host callback could run.
      var module = if node.external == nil:
          decodeModule(plan.embeddedCoreBytes(node.moduleIndex.int),
            optimize = false, retainCustomSections = false, allowFunctionSubtyping = true)
        else:
          node.external.image.decodeCoreModule()
      when defined(bl808m0) or defined(bl808lp):
        if module.memories.len > 0 and memoryFactory == nil:
          componentFail("bounded memory backend required on this core")
      for exp in plan.exports:
        if exp.coreSources[clsFunction].int == i + 1:
          validateCoreExport(module, exp)
      var coreImports: seq[(string, string, ExternalVal)]
      var linkedImports: seq[StoreImport]
      for j in 0 ..< module.imports.len:
        let imp = unsafeAddr module.imports[j]
        var bindingIndex = j
        if node.external != nil:
          bindingIndex = -1
          for index, formal in node.external.source.shape.imports:
            if formal.module == imp.module and formal.name == imp.name:
              bindingIndex = index
              break
          if bindingIndex < 0: componentFail("unlinked core module import")
        let source = node.imports[bindingIndex]
        if source.instanceIndex < 0:
          let lowering = unsafeAddr plan.lowerings[source.itemIndex.int]
          if lowering.generatedReference:
            let reference = GeneratedCoreSource or source.itemIndex
            let address = result.coreExport(reference, "", ekFunc)
            linkedImports.add((imp.module, imp.name, ExternalStoreRef(kind: ekFunc, address: address)))
          else:
            let cb = bindLowering(result, plan, lowering[], hostBindings[])
            coreImports.add((imp.module, imp.name, ExternalVal(kind: ekFunc,
              funcType: module.types[imp.funcTypeIdx.int], hostFunc: cb)))
        else:
          let ordinal = source.instanceIndex.int
          let external = plan.instances[ordinal].external
          let exports = unsafeAddr result.vm.store.modules[ordinal].exports
          var exportIndex = source.itemIndex.int
          if external != nil:
            let name = external.source.shape.exports[exportIndex].name
            exportIndex = -1
            for index, candidate in exports[]:
              if candidate.name == name:
                exportIndex = index
                break
            if exportIndex < 0: componentFail("unlinked core module export")
          let target = unsafeAddr exports[][exportIndex]
          linkedImports.add((imp.module, imp.name,
            ExternalStoreRef(kind: target.kind, address: target.idx)))
      withFreshContext(result.execution):
        discard result.vm.instantiateOwned(move module, coreImports, linkedImports)
      for j, resource in plan.resources:
        if resource.destructorSource.int == i + 1:
          result.resources.destructors[j].address =
            result.coreExport(resource.destructorSource, resource.destructorName, ekFunc)
  except WasmTrap as e:
    componentFail("component instantiation trap: " & e.msg)
  result.instantiateChildren(plan, plan.instances.len,
    memoryFactory, memoryFactoryContext, pending)
  result.exports = plan.exports

proc requireHostBinding(needed: ComponentImport,
    bindings: openArray[ComponentHostBinding]): ComponentHostBinding =
  var found = false
  for binding in bindings:
    if binding.name != needed.name: continue
    if found or binding.signature.params != needed.signature.params or
        binding.signature.asyncSignature() != needed.signature.asyncSignature() or
        binding.signature.hasResult != needed.signature.hasResult or
        (needed.signature.hasResult and
         binding.signature.resultType != needed.signature.resultType) or
        binding.callback == nil:
      componentFail("component host import type mismatch")
    if needed.signature.paramArea != nil:
      for slot in needed.signature.paramArea.slots:
        if slot.recordShape != nil or slot.cases.len != 0 or slot.listElement != nil:
          if binding.signature.paramArea == nil or
              binding.signature.paramArea.slots != needed.signature.paramArea.slots:
            componentFail("component host aggregate parameter type mismatch")
          break
    if needed.signature.resultShape != nil and (binding.signature.resultShape == nil or
        binding.signature.resultShape[] != needed.signature.resultShape[]):
      componentFail("component host aggregate result type mismatch")
    result = binding
    found = true
  if not found: componentFail("unresolved component import: " & needed.name)

proc hasComponentArguments(plan: ComponentPlan): bool =
  for node in plan.instances:
    if node.external != nil: return true
  if plan.links == nil: return false
  if plan.links.componentImports != nil or plan.links.componentExports != nil or
      plan.links.coreModules != nil or plan.links.hasInterfaceDefinitions or
      plan.links.lexical != nil: return true
  for node in plan.links.children:
    if node.componentArguments != nil or node.plan[].hasComponentArguments():
      return true

type DefinitionBindings = object
  components: seq[BoundDefinition]
  modules: seq[CoreModuleImage]
  localDefinitions: seq[BoundDefinition]
  captures: DefinitionCaptures
  resources: seq[ResourceLocation]
  trackResources: bool

proc resourceLocation(bindings: DefinitionBindings, slot: uint16): ResourceLocation =
  if slot.int >= bindings.resources.len or bindings.resources[slot].frame == nil:
    componentFail("unresolved lexical resource")
  bindings.resources[slot]

proc openResourceFrame(plan: ComponentPlan,
    bindings: var DefinitionBindings): LinkedResourceFrame {.noinline.} =
  if not bindings.trackResources or plan.resources.len == 0: return nil
  bindings.resources.setLen(plan.resources.len)
  if bindings.captures != nil and bindings.captures.resources.len != 0:
    result = LinkedResourceFrame(captures: bindings.captures.resources)
    for item in result.captures:
      bindings.resources[item.slot] = item.origin
  for i, resource in plan.resources:
    if plan.contractResourceCapture(i).depth != 0:
      if InterfaceResourceOrdinal(i) in plan.links.contractResources.live:
        discard resourceLocation(bindings, i.uint16)
    elif resource.importName.len == 0 and resource.sourceChild == 0:
      if result == nil: new(result)
      if result.local == nil: new(result.local)
      bindings.resources[i] = (result.local, i.uint16)

proc selectHostComponent(name: string, contract: ref ComponentPlan,
    definitions: openArray[ComponentHostDefinition]): BoundDefinition =
  for binding in definitions:
    if binding.name != name: continue
    if result.plan != nil: componentFail("duplicate host component definition: " & name)
    if not binding.plan.validated: componentFail("unvalidated host component definition: " & name)
    # Match even imports the component never instantiates.
    requireComponentSubtype(binding.plan, contract[])
    result.plan = new(ComponentPlan)
    result.plan[] = binding.plan
  if result.plan == nil: componentFail("unresolved component definition: " & name)

proc resolveComponentArgument(argument: ComponentArgument,
    bindings: DefinitionBindings, links: ComponentLinks): BoundDefinition =
  if argument.importIndex != 0:
    if argument.importIndex.int > bindings.components.len:
      componentFail("unresolved component definition")
    return bindings.components[argument.importIndex.int - 1]
  if argument.captureIndex != 0:
    if bindings.captures == nil or argument.captureIndex.int > bindings.captures.components.len:
      componentFail("unresolved outer component definition")
    return bindings.captures.components[argument.captureIndex.int - 1]
  if argument.localIndex != 0:
    let index = argument.localIndex.int - 1
    if index >= bindings.localDefinitions.len or bindings.localDefinitions[index].plan == nil:
      componentFail("unresolved local component definition")
    return bindings.localDefinitions[index]
  if argument.childIndex != 0:
    let child = links.children[argument.childIndex.int - 1].plan
    let components = child.componentDefinitionExports(argument.childInterface)
    if components == nil or argument.childExport.int >= components[].len:
      componentFail("unresolved component definition export")
    let exported = unsafeAddr components[][argument.childExport.int]
    return BoundDefinition(plan: exported.value.plan, captures: exported.captures)
  BoundDefinition(plan: if argument.implementation != nil: argument.implementation else: argument.plan)

proc resolveCoreModule(source: CoreModuleValue, bindings: DefinitionBindings,
                       links: ComponentLinks): CoreModuleImage =
  if source.image != nil: return source.image
  if source.importIndex != 0:
    if source.importIndex.int > bindings.modules.len: componentFail("unresolved core module import")
    return bindings.modules[source.importIndex.int - 1]
  if source.captureIndex != 0:
    if bindings.captures == nil or source.captureIndex.int > bindings.captures.modules.len:
      componentFail("unresolved outer core module")
    return bindings.captures.modules[source.captureIndex.int - 1]
  if source.childIndex != 0:
    let child = links.children[source.childIndex.int - 1].plan
    let modules = child.coreModuleExports(source.childInterface)
    if modules != nil and source.childExport.int < modules[].len:
      let image = modules[][source.childExport.int].value.image
      if image != nil: return image
  componentFail("unresolved core module definition")

proc bindLexicalDefinitions(layout: LexicalLayout, beforeChild: int, next: var int,
    bindings: var DefinitionBindings, links: ComponentLinks) {.noinline.} =
  ## Resolve only preceding declarations. Retain values, not the parent plan
  ## or its mutable linking state, when a definition escapes its scope.
  while next < layout.definitions.len and layout.definitions[next].beforeChild <= beforeChild:
    let plan = layout.definitions[next].plan
    let lexical = plan.links.lexical
    let captures = DefinitionCaptures()
    for source in lexical.componentCaptures:
      captures.components.add(resolveComponentArgument(source, bindings, links))
    for source in lexical.moduleCaptures:
      captures.modules.add(resolveCoreModule(source, bindings, links))
    let resources = plan[].contractResources()
    if resources != nil:
      for item in resources.captures:
        if InterfaceResourceOrdinal(item.slot) notin resources.live: continue
        if item.source.depth != 1: componentFail("unbound outer component value resource")
        captures.resources.add((item.slot, resourceLocation(bindings, item.source.ordinal)))
    bindings.localDefinitions[next] = BoundDefinition(plan: plan, captures: captures)
    inc next

proc selectHostCoreModule(needed: NamedCoreModule,
    supplied: openArray[ComponentHostCoreModule]): CoreModuleImage =
  for binding in supplied:
    if binding.name != needed.name: continue
    if result != nil: componentFail("duplicate host core module: " & needed.name)
    if binding.bytes.len > MaxComponentBytes: componentFail("core module byte limit")
    result = CoreModuleImage(bytes: binding.bytes)
    requireModuleSubtype(CoreModuleValue(image: result).moduleShape(), needed.value.shape)
  if result == nil: componentFail("unresolved core module import: " & needed.name)

proc selectInterfaceDefinitions(needed: InterfaceImport,
    supplied: openArray[ComponentHostInterface], bindings: var DefinitionBindings) =
  var found = false
  for source in supplied:
    if source.name != needed.name: continue
    if found: componentFail("duplicate component host interface")
    found = true
    if needed.coreModules != nil:
      for item in needed.coreModules[]:
        bindings.modules[item.value.importIndex.int - 1] = selectHostCoreModule(item, source.coreModules)
    if needed.components != nil:
      for item in needed.components[]:
        bindings.components[item.value.importIndex.int - 1] =
          selectHostComponent(item.name, item.value.plan, source.components)
    if needed.children != nil:
      for child in needed.children[]:
        selectInterfaceDefinitions(child, source.interfaces, bindings)
  if not found: componentFail("unresolved component interface: " & needed.name)

proc selectHostDefinitions(plan: ComponentPlan, components: openArray[ComponentHostDefinition],
    modules: openArray[ComponentHostCoreModule],
    interfaces: openArray[ComponentHostInterface]): DefinitionBindings =
  if plan.links == nil: return
  var hasInterfaceDefinitions = false
  if plan.links.componentImports != nil:
    result.components.setLen(plan.links.componentImports[].len)
    for i, needed in plan.links.componentImports[]:
      if needed.interfaceImport:
        hasInterfaceDefinitions = true
      else:
        result.components[i] = selectHostComponent(needed.name, needed.plan, components)
  if plan.links.coreModules != nil:
    result.modules.setLen(plan.links.coreModules.imports.len)
    for i, needed in plan.links.coreModules.imports:
      if needed.interfaceImport:
        hasInterfaceDefinitions = true
      else:
        result.modules[i] = selectHostCoreModule(needed, modules)
  if hasInterfaceDefinitions:
    for needed in plan.links.interfaceImports:
      selectInterfaceDefinitions(needed, interfaces, result)

proc projectInterfaceView(provider, contract: ComponentLinks, projection: InterfaceProjection,
                          visibleIndex: uint16): InterfaceExport =
  let actual = provider.exportedInterface(projection.source)
  let visible = contract.exportedInterface(visibleIndex)
  result = InterfaceExport(name: actual.name, children: visible.children,
    methods: newSeqOfCap[ComponentExport](projection.methods.len))
  for index in projection.methods: result.methods.add(actual.methods[index])
  for i, index in projection.coreModules:
    var item = actual.coreModules[][index]
    item.value.shape = visible.coreModules[][i].value.shape
    result.coreModules.addInstanceModule(move item)
  for index in projection.components:
    result.components.addInstanceComponent(actual.components[][index])

proc projectInterfaceViews(links, contract: ComponentLinks, projection: ComponentProjection) =
  var top, nested: ref seq[InterfaceExport]
  if projection.interfaces.len > 0:
    new(top)
    for i, outgoing in projection.interfaces:
      top[].add(projectInterfaceView(links, contract, outgoing, (i + 1).uint16))
  if projection.nestedInterfaces.len > 0:
    new(nested)
    for i, outgoing in projection.nestedInterfaces:
      nested[].add(projectInterfaceView(links, contract, outgoing, NestedInterfaceIndex or i.uint16))
  links.interfaceExports = move top
  links.nestedInterfaceExports = move nested

proc resolveInterfaceDefinitions(table: ref seq[InterfaceExport],
    bindings: DefinitionBindings, links: ComponentLinks): ref seq[InterfaceExport] =
  if table == nil: return nil
  new(result)
  result[] = table[]
  for surface in result[].mitems:
    if surface.coreModules != nil:
      let original = surface.coreModules
      surface.coreModules = nil
      for originalItem in original[]:
        var item = originalItem
        item.value.image = resolveCoreModule(item.value, bindings, links)
        surface.coreModules.addInstanceModule(move item)
    if surface.components != nil:
      let original = surface.components
      surface.components = nil
      for item in original[]:
        let actual = resolveComponentArgument(item.value, bindings, links)
        surface.components.addInstanceComponent(NamedComponentDefinition(name: item.name,
          value: ComponentArgument(plan: actual.plan), captures: actual.captures))

proc enableResourceTracking(plan: ComponentPlan, bindings: var DefinitionBindings) =
  if plan.needsResourceFrames(): bindings.trackResources = true
  if bindings.trackResources: return
  for value in bindings.components:
    if value.plan[].needsResourceFrames():
      bindings.trackResources = true
      return

proc projectBoundComponent(provider: BoundDefinition, contract: ComponentPlan,
    bindings: var DefinitionBindings): ComponentProjection {.noinline.} =
  if provider.captures == nil or provider.captures.resources.len == 0:
    return projectComponent(provider.plan[], contract)
  var lexical = LexicalResourceComparison(provided: addr provider.captures.resources,
    required: addr bindings.resources)
  projectComponent(provider.plan[], contract, TypeResourceBindings(lexical: addr lexical))

proc projectChildResources(node: var ChildInstantiation, source: ChildInstantiation,
                           provider: ComponentPlan, projection: ComponentProjection) =
  node.resourceArgs = newSeq[uint16](projection.resourceImports.len)
  for j, formal in projection.resourceImports:
    if formal != 0 and provider.contractResourceCapture(j).depth == 0:
      node.resourceArgs[j] = source.resourceArgs[formal.int - 1]
  for formal, actual in projection.resourceExports:
    if actual == 0: continue
    let childType = actual - 1
    let parentType = source.resourceArgs[formal] - 1
    if provider.contractResourceCapture(childType.int).depth != 0:
      if source.plan[].contractResourceCapture(formal).depth == 0:
        node.resourceReexports.add((childType, parentType))
    elif node.resourceArgs[childType.int] == 0:
      node.resourceArgs[childType.int] = parentType + 1
    elif node.resourceArgs[childType.int] != parentType + 1:
      node.resourceReexports.add((childType, parentType))

proc resolveChildResourceInputs(node: ChildInstantiation, provider: ComponentPlan,
    parent: DefinitionBindings, child: var DefinitionBindings) =
  child.trackResources = parent.trackResources
  if not parent.trackResources or provider.resources.len == 0: return
  child.resources.setLen(provider.resources.len)
  for i, resource in provider.resources:
    if resource.importName.len == 0: continue
    if node.resourceArgs[i] == 0: componentFail("unresolved lexical resource import")
    child.resources[i] = resourceLocation(parent, node.resourceArgs[i] - 1)

proc resolveChildResourceOutputs(node: ChildInstantiation, child: DefinitionBindings,
                                 parent: var DefinitionBindings) =
  if not parent.trackResources: return
  for i, slot in node.resourceArgs:
    if slot != 0 and node.plan.resources[i].importName.len == 0 and
        node.plan[].contractResourceCapture(i).depth == 0:
      let origin = resourceLocation(child, i.uint16)
      parent.resources[slot - 1] = origin
  for (childType, parentType) in node.resourceReexports:
    parent.resources[parentType] = resourceLocation(child, childType)

proc resolveComponentArguments(plan: ComponentPlan, bindings: var DefinitionBindings,
    depth: int, total: var int): ComponentPlan =
  ## Resolve the graph before guest code runs. The projected export indices
  ## follow the contract while the provider retains its own type identities.
  if depth > MaxComponentNesting or total >= MaxComponentInstances:
    componentFail("specialized component graph exceeds profile limit")
  inc total
  if bindings.components.len != plan.componentImportCount():
    componentFail("unresolved component import")
  let externals = if plan.links == nil: nil else: plan.links.coreModules
  if bindings.modules.len != (if externals == nil: 0 else: externals.imports.len):
    componentFail("unresolved core module import")
  let lexical = if plan.links == nil: nil else: plan.links.lexical
  if lexical != nil:
    let capturedComponents = if bindings.captures == nil: 0 else: bindings.captures.components.len
    let capturedModules = if bindings.captures == nil: 0 else: bindings.captures.modules.len
    if capturedComponents != lexical.componentCaptures.len or
        capturedModules != lexical.moduleCaptures.len:
      componentFail("unresolved outer definition captures")
    bindings.localDefinitions.setLen(lexical.definitions.len)
  result = plan
  if plan.links != nil:
    result.links = ComponentLinks()
    result.links[] = plan.links[]
  enableResourceTracking(plan, bindings)
  if bindings.trackResources:
    let frame = openResourceFrame(plan, bindings)
    if frame != nil:
      if result.links == nil: new(result.links)
      result.links.linkedResources = frame
  let childCount = if plan.links == nil: 0 else: plan.links.children.len
  var nextDefinition = 0
  for i in 0 ..< childCount:
    if lexical != nil:
      bindLexicalDefinitions(lexical, i, nextDefinition, bindings, result.links)
    let source = unsafeAddr plan.links.children[i]
    var node = source[]
    var provider = BoundDefinition(plan: source.plan)
    if source.componentArguments != nil and source.componentArguments.definition.externalDefinition():
      provider = resolveComponentArgument(source.componentArguments.definition, bindings, result.links)
    let providerPlan = provider.plan
    let specialized = providerPlan != source.plan
    let projection = if specialized: projectBoundComponent(provider, source.plan[], bindings)
      else: ComponentProjection()
    var childBindings = DefinitionBindings(captures: provider.captures)
    if source.componentArguments != nil:
      if specialized:
        for incoming in projection.componentImports:
          childBindings.components.add(resolveComponentArgument(
            source.componentArguments.arguments[incoming], bindings, result.links))
      else:
        for argument in source.componentArguments.arguments:
          childBindings.components.add(resolveComponentArgument(argument, bindings, result.links))
    if source.coreModuleArguments != nil:
      if specialized:
        for incoming in projection.moduleImports:
          childBindings.modules.add(resolveCoreModule(source.coreModuleArguments[][incoming],
            bindings, result.links))
      else:
        for incoming in source.coreModuleArguments[]:
          childBindings.modules.add(resolveCoreModule(incoming, bindings, result.links))
    if specialized: projectChildResources(node, source[], providerPlan[], projection)
    resolveChildResourceInputs(node, providerPlan[], bindings, childBindings)
    node.plan = new(ComponentPlan)
    node.plan[] = resolveComponentArguments(providerPlan[], childBindings, depth + 1, total)
    resolveChildResourceOutputs(node, childBindings, bindings)
    if specialized:
      node.arguments = newSeqOfCap[ComponentExport](projection.imports.len)
      for incoming in projection.imports:
        node.arguments.add(source.arguments[incoming])
      node.plan.exports = newSeqOfCap[ComponentExport](projection.exports.len)
      for outgoing in projection.exports:
        node.plan.exports.add(providerPlan.exports[outgoing])
      if providerPlan.links.interfaceExportCount() > 0:
        if node.plan.links == providerPlan.links:
          node.plan.links = ComponentLinks()
          node.plan.links[] = providerPlan.links[]
        node.plan.links.projectInterfaceViews(source.plan.links, projection)
      if node.plan.links != nil and node.plan.links.coreModules != nil:
        let linked = node.plan.links.coreModules
        let projected = CoreModuleExternals()
        for index in projection.moduleExports:
          projected.exports.add(linked.exports[index])
        node.plan.links.coreModules = projected
      if node.plan.links != nil and node.plan.links.componentExports != nil:
        let linked = node.plan.links.componentExports
        new(node.plan.links.componentExports)
        for outgoing in projection.componentExports:
          node.plan.links.componentExports[].add(linked[][outgoing])
    node.componentArguments = nil
    node.coreModuleArguments = nil
    result.links.children[i] = move node
  if lexical != nil:
    bindLexicalDefinitions(lexical, childCount, nextDefinition, bindings, result.links)
  for node in result.instances.mitems:
    if node.external == nil: continue
    let source = node.external.source
    let image = resolveCoreModule(source, bindings, result.links)
    requireModuleSubtype(CoreModuleValue(image: image).moduleShape(), source.shape)
    node.external = ExternalCoreInstantiation(source: source, image: image)
  if externals != nil:
    result.links.coreModules = CoreModuleExternals()
    for item in externals.exports:
      var resolved = item
      resolved.value.image = resolveCoreModule(item.value, bindings, result.links)
      result.links.coreModules.exports.add(move resolved)
  if plan.links != nil and plan.links.hasInterfaceDefinitions:
    result.links.interfaceExports = resolveInterfaceDefinitions(plan.links.interfaceExports,
      bindings, result.links)
    result.links.nestedInterfaceExports = resolveInterfaceDefinitions(plan.links.nestedInterfaceExports,
      bindings, result.links)
  if plan.links != nil and plan.links.componentExports != nil:
    new(result.links.componentExports)
    for item in plan.links.componentExports[]:
      let actual = resolveComponentArgument(item.value, bindings, result.links)
      result.links.componentExports[].add(NamedComponentDefinition(name: item.name,
        value: ComponentArgument(plan: actual.plan), captures: actual.captures))

proc selectHostInterface(plan: ComponentPlan, needed: InterfaceImport,
    supplied: openArray[ComponentHostInterface], bindings: var seq[ComponentHostBinding]) =
  var found = false
  for source in supplied:
    if source.name != needed.name: continue
    if found: componentFail("duplicate component host interface")
    for i in needed.firstBinding ..< needed.firstBinding + needed.bindingCount:
      bindings[i] = requireHostBinding(plan.imports[i], source.functions)
    if needed.children != nil:
      for child in needed.children[]:
        selectHostInterface(plan, child, source.interfaces, bindings)
    found = true
  if not found: componentFail("unresolved component interface: " & needed.name)

proc selectHostBindings(plan: ComponentPlan, bindings: openArray[ComponentHostBinding],
    interfaces: openArray[ComponentHostInterface]): seq[ComponentHostBinding] =
  for resource in plan.resources:
    if resource.importName.len != 0:
      componentFail("unresolved component resource type: " & resource.importName)
  result.setLen(plan.imports.len)
  for i, needed in plan.imports:
    if needed.interfaceIndex == 0:
      result[i] = requireHostBinding(needed, bindings)
  if plan.links == nil: return
  if plan.links.resourceEqualityImports.len > 0:
    componentFail("unresolved component resource type: " &
      plan.links.resourceEqualityImports[0].name)
  for needed in plan.links.interfaceImports:
    selectHostInterface(plan, needed, interfaces, result)

proc instantiateComponent*(plan: ComponentPlan,
                           bindings: openArray[ComponentHostBinding],
                           interfaces: openArray[ComponentHostInterface],
                           memoryFactory: ComponentMemoryFactory = nil,
                           memoryFactoryContext: pointer = nil,
                           components: openArray[ComponentHostDefinition] = [],
                           coreModules: openArray[ComponentHostCoreModule] = []):
                           ComponentInstance =
  if plan.hasComponentArguments():
    var total = 0
    var supplied = selectHostDefinitions(plan, components, coreModules, interfaces)
    let linked = resolveComponentArguments(plan, supplied, 0, total)
    let selected = selectHostBindings(linked, bindings, interfaces)
    return instantiateComponentInStore(linked, selected, memoryFactory,
      memoryFactoryContext, nil, @[])
  let selected = selectHostBindings(plan, bindings, interfaces)
  instantiateComponentInStore(plan, selected, memoryFactory, memoryFactoryContext, nil, @[])

proc instantiateComponent*(plan: ComponentPlan,
                           bindings: openArray[ComponentHostBinding],
                           memoryFactory: ComponentMemoryFactory = nil,
                           memoryFactoryContext: pointer = nil,
                           components: openArray[ComponentHostDefinition] = [],
                           coreModules: openArray[ComponentHostCoreModule] = []):
                           ComponentInstance {.inline.} =
  instantiateComponent(plan, bindings, [], memoryFactory, memoryFactoryContext, components, coreModules)

proc instantiateComponent*(plan: ComponentPlan): ComponentInstance =
  let noBindings: seq[ComponentHostBinding] = @[]
  instantiateComponent(plan, noBindings)

when WasmAtomicWaitEnabled:
  proc setComponentAtomicClock*(instance: ComponentInstance, clock: WasmAtomicClock) =
    ## Configure the graph before running a component that can park on a
    ## finite core atomic wait.
    instance.vm.setWasmAtomicClock(clock)
    if instance.links != nil:
      for child in instance.links.children:
        child.setComponentAtomicClock(clock)

proc requireInactiveGraph(instance: ComponentInstance) =
  if instance.activeEntries != 0 or
      (instance.links != nil and instance.links.store.callDepth != 0):
    componentFail("cannot close an active component")
  if instance.outstandingOwners != 0:
    componentFail("component has live owned values")
  if instance.links != nil:
    for child in instance.links.children:
      requireInactiveGraph(child)

proc disposeGraphResources(instance: ComponentInstance) =
  if instance.links != nil:
    for i in countdown(instance.links.children.high, 0):
      disposeGraphResources(instance.links.children[i])
  if instance.resources != nil:
    let status = instance.resources.table.drainResourceTable()
    if status != crOk:
      componentFail("component resource cleanup failed: " & $status)

proc requireEmptyGraph(instance: ComponentInstance) =
  if instance.resources != nil and instance.resources.table.resourceStats().liveOwned != 0:
    componentFail("resource destructor left an owned handle during cleanup")
  if instance.links != nil:
    for child in instance.links.children:
      requireEmptyGraph(child)

when defined(wasmComponentErrorContext):
  proc clearErrorContextGraph(instance: ComponentInstance) =
    if instance.resources != nil: instance.resources.table.clearErrorContextHandles()
    if instance.links != nil:
      for child in instance.links.children: child.clearErrorContextGraph()

when WasmAtomicWaitEnabled:
  proc clearAtomicWaitGraph(instance: ComponentInstance) =
    instance.vm.clearWasmAtomicWaits()
    if instance.links != nil:
      for child in instance.links.children: child.clearAtomicWaitGraph()

when defined(wasmComponentAsyncCallbacks):
  proc abortBorrowScopes(instance: ComponentInstance, releaseSources: static bool) =
    let resources = instance.resources
    if resources != nil:
      when releaseSources:
        while resources.lendBatches.len != 0:
          cast[ptr ResourceLendBatchState](resources.lendBatches[^1])[].releaseLendBatch()
      else:
        while resources.taskBorrowScopes.len != 0:
          cast[ptr TaskBorrowScopeState](resources.taskBorrowScopes[^1])[].releaseTaskBorrows()
    if instance.links != nil:
      for child in instance.links.children: child.abortBorrowScopes(releaseSources)

  proc releaseAsyncGraph(instance: ComponentInstance) =
    for i, slot in instance.asyncSlots:
      let isEndpoint = when ComponentEndpointsEnabled: slot.endpoint != nil else: false
      when ComponentEndpointsEnabled:
        if isEndpoint: slot.endpoint[].detachEndpoint()
      if slot.waitSet != nil or slot.subtask != nil or isEndpoint:
        discard instance.resources.table.dropAsyncHandle(i.uint32 + 1)
    instance.asyncSlots.setLen(0)
    if instance.links != nil:
      for child in instance.links.children: child.releaseAsyncGraph()

proc closeComponent*(instance: ComponentInstance) =
  ## Dispose guest owners while their defining guest code can still run.
  if instance == nil: return
  if instance.isLocked:
    when WasmAtomicWaitEnabled:
      if instance.activeEntries == 0 and (instance.links == nil or
          (instance.links.store.callDepth == 0 and
           (when defined(wasmComponentAsyncCallbacks): instance.links.store.activeCallbackTurns == 0
            else: true))):
        instance.clearAtomicWaitGraph()
    when defined(wasmComponentErrorContext):
      if instance.activeEntries == 0 and (instance.links == nil or
          (instance.links.store.callDepth == 0 and
          (when defined(wasmComponentAsyncCallbacks): instance.links.store.activeCallbackTurns == 0
           else: true))):
        instance.clearErrorContextGraph()
    when defined(wasmComponentAsyncCallbacks):
      if instance.activeEntries == 0 and instance.links != nil and
          instance.links.store.activeCallbackTurns == 0 and instance.links.store.callDepth == 0:
        instance.abortBorrowScopes(true)
        instance.abortBorrowScopes(false)
        when ComponentEndpointsEnabled:
          instance.releaseAsyncGraph()
        when defined(wasmComponentThreads):
          instance.links.store.switchTarget = nil
          instance.links.store.guestThreads.setLen(0)
    return
  requireInactiveGraph(instance)
  when defined(wasmComponentAsyncCallbacks):
    instance.abortBorrowScopes(true)
    instance.abortBorrowScopes(false)
    if instance.links != nil: instance.links.store.pendingSubtasks.setLen(0)
  instance.activeEntries = 1
  defer:
    when WasmAtomicWaitEnabled: instance.clearAtomicWaitGraph()
    when defined(wasmComponentErrorContext): instance.clearErrorContextGraph()
    when defined(wasmComponentAsyncCallbacks):
      if instance.links != nil: instance.links.store.pendingSubtasks.setLen(0)
      instance.releaseAsyncGraph()
      when defined(wasmComponentThreads):
        if instance.links != nil:
          instance.links.store.switchTarget = nil
          instance.links.store.guestThreads.setLen(0)
    instance.activeEntries = 0
    instance.lockStore()
  disposeGraphResources(instance)
  requireEmptyGraph(instance)

proc componentValue*(kind: ComponentPrim, bits: uint64): ComponentValue =
  ComponentValue(kind: kind, bits: bits)

proc componentVariant*(caseIndex: uint32,
                       payload: openArray[ComponentValue] = []): ComponentValue =
  if payload.len > 1:
    componentFail("variant has multiple payload values")
  ComponentValue(kind: cpVariant, caseIndex: caseIndex, fields: @payload)

proc componentEnum*(caseIndex: uint32): ComponentValue =
  ComponentValue(kind: cpEnum, caseIndex: caseIndex)

proc componentTuple*(fields: openArray[ComponentValue]): ComponentValue =
  ComponentValue(kind: cpTuple, fields: @fields)

proc componentFlags*(bits: uint32): ComponentValue =
  ComponentValue(kind: cpFlags, bits: bits.uint64)

proc componentResult*(caseIndex: uint32,
                      payload: openArray[ComponentValue] = []): ComponentValue =
  if payload.len > 1:
    componentFail("result has multiple payload values")
  ComponentValue(kind: cpResult, caseIndex: caseIndex, fields: @payload)

proc componentOptionNone*(): ComponentValue =
  ComponentValue(kind: cpOption)

proc componentOptionSome*(payload: ComponentValue): ComponentValue =
  ComponentValue(kind: cpOption, caseIndex: 1,
    fields: @[payload])

proc componentString*(value: string): ComponentValue =
  if not validWasmName(value): componentFail("invalid UTF-8 component string")
  ComponentValue(kind: cpString, text: value)

when defined(wasmComponentErrorContext):
  proc componentErrorContext*(message = ""): ComponentValue =
    if message.len > MaxComponentStringBytes or not validWasmName(message):
      componentFail("invalid component error-context debug message")
    ComponentValue(kind: cpErrorContext, errorContext: newErrorContextValue(message))

  proc componentErrorContextMessage*(value: ComponentValue): string =
    if value.kind != cpErrorContext or value.errorContext == nil:
      componentFail("invalid component error-context value")
    value.errorContext.debugMessage()

proc componentBytes*(value: openArray[byte]): ComponentValue =
  if value.len > MaxComponentByteListBytes:
    componentFail("component byte list length limit")
  ComponentValue(kind: cpBytes, bytes: @value)

proc componentU32List*(value: openArray[uint32]): ComponentValue =
  if value.len > MaxComponentByteListBytes div 4:
    componentFail("component u32 list length limit")
  result.kind = cpU32List
  result.fields = newSeqOfCap[ComponentValue](value.len)
  for item in value:
    result.fields.add(ComponentValue(kind: cpU32, bits: item.uint64))

proc componentU64List*(value: openArray[uint64]): ComponentValue =
  if value.len > MaxComponentByteListBytes div 8:
    componentFail("component u64 list length limit")
  result.kind = cpU64List
  result.fields = newSeqOfCap[ComponentValue](value.len)
  for item in value:
    result.fields.add(ComponentValue(kind: cpU64, bits: item))

proc componentList*(values: openArray[ComponentValue]): ComponentValue =
  if values.len > MaxGenericListValues:
    componentFail("component list value limit")
  ComponentValue(kind: cpList, fields: @values)

proc checkFixedListValueCount(count: int) =
  if count == 0 or count > MaxGenericListValues:
    componentFail("component fixed-length list value limit")

proc componentFixedList*(values: sink seq[ComponentValue]): ComponentValue =
  checkFixedListValueCount(values.len)
  ComponentValue(kind: cpFixedList, fields: move values)

proc componentFixedList*(values: openArray[ComponentValue]): ComponentValue =
  checkFixedListValueCount(values.len)
  ComponentValue(kind: cpFixedList, fields: @values)

proc requireFixedListLength(slot: CanonicalSlot, value: ComponentValue) =
  if value.fields.len.uint64 != slot.listLength.uint64:
    componentFail("component fixed-length list length mismatch")
  checkFixedListValueCount(value.fields.len)

proc componentMap*(entries: openArray[ComponentValue]): ComponentValue =
  ## Accept key/value tuples in wire order. Duplicate entries are preserved.
  if entries.len > MaxGenericListValues:
    componentFail("component map value limit")
  for entry in entries:
    if entry.kind != cpTuple or entry.fields.len != 2 or entry.fields[0].kind notin MapKeyTypes:
      componentFail("invalid component map entry")
  ComponentValue(kind: cpMap, fields: @entries)

proc componentRecord*(fields: openArray[ComponentValue]): ComponentValue =
  if fields.len == 0 or fields.len > MaxComponentRecordFields:
    componentFail("component record field limit")
  ComponentValue(kind: cpRecord, fields: @fields)

proc canonicalF32(bits: uint32): uint32 {.inline.} =
  if (bits and 0x7f800000'u32) == 0x7f800000'u32 and
      (bits and 0x007fffff'u32) != 0:
    0x7fc00000'u32
  else: bits

proc canonicalF64(bits: uint64): uint64 {.inline.} =
  if (bits and 0x7ff0000000000000'u64) == 0x7ff0000000000000'u64 and
      (bits and 0x000fffffffffffff'u64) != 0:
    0x7ff8000000000000'u64
  else: bits

proc lower(value: ComponentValue): WasmValue =
  case value.kind
  of cpBool:
    if value.bits > 1: componentFail("invalid bool argument")
    wasmI32(value.bits.int32)
  of cpS8, cpU8:
    if value.kind == cpU8 and value.bits > 255:
      componentFail("u8 argument out of range")
    if value.kind == cpS8 and
        (cast[int64](value.bits) < -128 or cast[int64](value.bits) > 127):
      componentFail("s8 argument out of range")
    wasmI32(cast[int32](value.bits.uint32))
  of cpS16, cpU16:
    if value.kind == cpU16 and value.bits > 65535:
      componentFail("u16 argument out of range")
    if value.kind == cpS16 and
        (cast[int64](value.bits) < -32768 or cast[int64](value.bits) > 32767):
      componentFail("s16 argument out of range")
    wasmI32(cast[int32](value.bits.uint32))
  of cpS32, cpU32:
    if value.kind == cpU32 and value.bits > uint32.high.uint64:
      componentFail("u32 argument out of range")
    if value.kind == cpS32 and
        (cast[int64](value.bits) < int32.low.int64 or
         cast[int64](value.bits) > int32.high.int64):
      componentFail("s32 argument out of range")
    wasmI32(cast[int32](value.bits.uint32))
  of cpChar:
    if value.bits > 0x10ffff'u64 or
        value.bits in 0xd800'u64 .. 0xdfff'u64:
      componentFail("invalid Unicode scalar argument")
    wasmI32(value.bits.int32)
  of cpS64, cpU64: wasmI64(cast[int64](value.bits))
  of cpF32: wasmF32(cast[float32](canonicalF32(value.bits.uint32)))
  of cpF64: wasmF64(cast[float64](canonicalF64(value.bits)))
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap, cpFixedList, cpRecord, cpTuple, cpFlags, cpOption,
     cpVariant, cpEnum, cpResult, cpResourceType, cpInterfaceType, cpFunctionType, cpComponentType,
     cpOwnedResource, cpBorrowedResource, cpFuture, cpStream, cpErrorContext:
    componentFail("composite lowering requires canonical memory")

proc lift(value: WasmValue, kind: ComponentPrim): ComponentValue =
  result.kind = kind
  case kind
  of cpBool: result.bits = uint64(value.i32 != 0)
  of cpS8: result.bits = cast[uint64](cast[int8](value.i32).int64)
  of cpU8: result.bits = uint64(value.i32.uint32 and 0xff'u32)
  of cpS16: result.bits = cast[uint64](cast[int16](value.i32).int64)
  of cpU16: result.bits = uint64(value.i32.uint32 and 0xffff'u32)
  of cpS32: result.bits = cast[uint64](value.i32.int64)
  of cpU32: result.bits = value.i32.uint32.uint64
  of cpChar:
    let scalar = value.i32.uint32
    if scalar > 0x10ffff'u32 or
        scalar in 0xd800'u32 .. 0xdfff'u32:
      componentFail("invalid canonical Unicode scalar")
    result.bits = scalar.uint64
  of cpS64, cpU64: result.bits = cast[uint64](value.i64)
  of cpF32: result.bits = canonicalF32(cast[uint32](value.f32)).uint64
  of cpF64: result.bits = canonicalF64(cast[uint64](value.f64))
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap, cpFixedList, cpRecord, cpTuple, cpFlags, cpOption,
     cpVariant, cpEnum, cpResult, cpResourceType, cpInterfaceType, cpFunctionType, cpComponentType,
     cpOwnedResource, cpBorrowedResource, cpFuture, cpStream, cpErrorContext:
    componentFail("composite lifting requires canonical memory")

proc coreExport(instance: ComponentInstance, source: uint16,
                name: string, kind: ExportKind): int =
  if source == 0: componentFail("missing canonical core alias")
  if (source and GeneratedCoreSource) != 0:
    let index = int(source and not GeneratedCoreSource)
    if kind != ekFunc or instance.generatedFunctions == nil or
        index >= instance.generatedFunctions[].len or
        instance.generatedFunctions[][index] == 0:
      componentFail("missing instantiated canonical core function")
    return instance.generatedFunctions[][index] - 1
  for item in instance.vm.store.modules[source.int - 1].exports:
    if item.name == name and item.kind == kind: return item.idx
  componentFail("missing instantiated core export: " & name)

proc lowerPayload(instance: ComponentInstance, exp: ComponentExport,
                  source: pointer, count: int, args: var seq[WasmValue],
                  alignment = 1, elementCount = -1) =
  if exp.coreSources[clsMemory] == 0 or exp.coreSources[clsRealloc] == 0:
    componentFail("composite signature lacks canonical memory")
  if count < 0 or count > MaxComponentByteListBytes:
    componentFail("component payload length limit")
  if alignment notin [1, 2, 4, 8] or
      (elementCount >= 0 and elementCount > count):
    componentFail("invalid canonical payload layout")
  let allocAddr = instance.coreExport(exp.coreSources[clsRealloc],
                                     exp.reallocName, ekFunc)
  let memoryAddr = instance.coreExport(exp.coreSources[clsMemory],
                                      exp.memoryName, ekMemory)
  var offset: uint32
  try:
    offset = instance.vm.allocCanonicalPayload(instance.execution, memoryAddr,
      allocAddr, source, count, alignment)
  except CatchableError:
    instance.lockStore()
    raise
  args.add(wasmI32(cast[int32](offset)))
  args.add(wasmI32((if elementCount < 0: count else: elementCount).int32))

proc lowerString(instance: ComponentInstance, exp: ComponentExport,
                 value: ComponentValue, args: var seq[WasmValue]) =
  if value.text.len > MaxComponentStringBytes or not validWasmName(value.text):
    componentFail("invalid canonical string argument")
  let allocAddr = instance.coreExport(exp.coreSources[clsRealloc],
                                      exp.reallocName, ekFunc)
  let memoryAddr = instance.coreExport(exp.coreSources[clsMemory],
                                       exp.memoryName, ekMemory)
  try:
    let (offset, units) = instance.vm.storeCanonicalText(instance.execution,
      memoryAddr, allocAddr, value.text, exp.stringEncoding)
    args.add(wasmI32(cast[int32](offset)))
    args.add(wasmI32(cast[int32](units)))
  except CatchableError:
    instance.lockStore()
    raise

proc lowerBytes(instance: ComponentInstance, exp: ComponentExport,
                value: ComponentValue, args: var seq[WasmValue]) =
  instance.lowerPayload(exp,
    if value.bytes.len > 0: unsafeAddr value.bytes[0] else: nil,
    value.bytes.len, args)

proc encodeIntList(value: ComponentValue, width: int,
                   elementKind: ComponentPrim): seq[byte] =
  if value.fields.len > MaxComponentByteListBytes div width:
    componentFail("component integer list length limit")
  result = newSeq[byte](value.fields.len * width)
  for i, item in value.fields:
    if item.kind != elementKind or
        (width == 4 and item.bits > uint32.high.uint64):
      componentFail("component integer list element type mismatch")
    for j in 0 ..< width:
      result[i * width + j] = byte(item.bits shr (8 * j))

proc lowerIntList(instance: ComponentInstance, exp: ComponentExport,
                  value: ComponentValue, args: var seq[WasmValue],
                  width: int, elementKind: ComponentPrim) =
  let bytes = encodeIntList(value, width, elementKind)
  instance.lowerPayload(exp,
    if bytes.len > 0: unsafeAddr bytes[0] else: nil,
    bytes.len, args, alignment = width, elementCount = value.fields.len)

proc readCoreBytes(instance: ComponentInstance, exp: ComponentExport,
                   offset: uint32, dst: ptr UncheckedArray[byte],
                   count: uint32) =
  if exp.coreSources[clsMemory] == 0:
    componentFail("composite result lacks canonical memory")
  let memoryAddr = instance.coreExport(exp.coreSources[clsMemory],
                                      exp.memoryName, ekMemory)
  instance.vm.store.mems[memoryAddr].readMemoryBytes(offset.uint64, dst, count)

proc readPair(instance: ComponentInstance, exp: ComponentExport,
              value: WasmValue): tuple[offset, count: uint32] =
  if value.kind != wvkI32:
    componentFail("canonical payload result pointer type mismatch")
  if (cast[uint32](value.i32) and 3'u32) != 0:
    componentFail("unaligned canonical payload result")
  var pair: array[8, byte]
  instance.readCoreBytes(exp, cast[uint32](value.i32),
    cast[ptr UncheckedArray[byte]](addr pair[0]), 8)
  for i in 0 ..< 4:
    result.offset = result.offset or (pair[i].uint32 shl (8 * i))
    result.count = result.count or (pair[i + 4].uint32 shl (8 * i))

proc liftString(instance: ComponentInstance, exp: ComponentExport,
                value: WasmValue): ComponentValue =
  let (offset, count) = instance.readPair(exp, value)
  let memoryAddr = instance.coreExport(exp.coreSources[clsMemory],
                                      exp.memoryName, ekMemory)
  ComponentValue(kind: cpString, text:
    instance.vm.store.mems[memoryAddr].readCanonicalString(offset, count,
      exp.stringEncoding))

proc liftBytes(instance: ComponentInstance, exp: ComponentExport,
               value: WasmValue): ComponentValue =
  let (offset, count) = instance.readPair(exp, value)
  if count > MaxComponentByteListBytes.uint32:
    componentFail("canonical byte list result limit")
  result.kind = cpBytes
  result.bytes = newSeq[byte](count.int)
  if count > 0:
    instance.readCoreBytes(exp, offset,
      cast[ptr UncheckedArray[byte]](addr result.bytes[0]), count)
  else:
    instance.readCoreBytes(exp, offset, nil, 0)

proc readIntList(memory: var MemInst, offset, count: uint32,
                 width: int, listKind, elementKind: ComponentPrim): ComponentValue =
  if count > (MaxComponentByteListBytes div width).uint32:
    componentFail("canonical integer list result limit")
  if (offset and (width - 1).uint32) != 0:
    componentFail("unaligned canonical integer list result")
  var bytes = newSeq[byte](count.int * width)
  if bytes.len > 0:
    memory.readMemoryBytes(offset.uint64,
      cast[ptr UncheckedArray[byte]](addr bytes[0]), bytes.len.uint32)
  else:
    memory.checkMemoryRange(offset.uint64, 0)
  result.kind = listKind
  result.fields = newSeqOfCap[ComponentValue](count.int)
  for i in 0 ..< count.int:
    var bits = 0'u64
    for j in 0 ..< width:
      bits = bits or (bytes[i * width + j].uint64 shl (8 * j))
    result.fields.add(ComponentValue(kind: elementKind, bits: bits))

proc liftIntList(instance: ComponentInstance, exp: ComponentExport,
                 value: WasmValue, width: int, listKind,
                 elementKind: ComponentPrim): ComponentValue =
  let (offset, count) = instance.readPair(exp, value)
  let memoryAddress = instance.coreExport(exp.coreSources[clsMemory],
    exp.memoryName, ekMemory)
  readIntList(instance.vm.store.mems[memoryAddress], offset, count, width,
    listKind, elementKind)

proc recordScalarBytes(kind: ComponentPrim): int =
  case kind
  of cpBool, cpS8, cpU8: 1
  of cpS16, cpU16: 2
  of cpS32, cpU32, cpF32, cpChar, cpErrorContext: 4
  of cpS64, cpU64, cpF64: 8
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap, cpFixedList, cpRecord, cpTuple, cpFlags, cpOption,
     cpVariant, cpEnum, cpResult, cpResourceType, cpInterfaceType, cpFunctionType, cpComponentType,
     cpOwnedResource, cpBorrowedResource, cpFuture, cpStream:
    componentFail("nested composite record field unsupported")

proc readAbiInt(memory: var MemInst, offset: uint64, width: int): uint64 =
  var raw: array[8, byte]
  memory.readMemoryBytes(offset,
    cast[ptr UncheckedArray[byte]](addr raw[0]), width.uint32)
  for i in 0 ..< width:
    result = result or (raw[i].uint64 shl (8 * i))

proc writeAbiInt(memory: var MemInst, offset: uint64, width: int, value: uint64) =
  var raw: array[8, byte]
  for i in 0 ..< width:
    raw[i] = byte(value shr (8 * i))
  memory.writeMemoryBytes(offset,
    cast[ptr UncheckedArray[byte]](addr raw[0]), width.uint32)

when defined(wasmComponentErrorContext):
  proc errorContextAt(instance: ComponentInstance, handle: uint32): ComponentErrorContextValue =
    if instance != nil and instance.resources != nil:
      result = instance.resources.table.errorContextAt(handle)
    if result == nil: componentFail("invalid canonical error-context handle")

  proc lowerErrorContext(instance: ComponentInstance, value: ComponentValue): uint32 =
    if instance == nil or value.kind != cpErrorContext or value.errorContext == nil:
      componentFail("invalid component error-context value")
    instance.initCanonicalHandles()
    if not instance.resources.table.newErrorContextHandle(value.errorContext, result):
      componentFail("component error-context handle capacity exceeded")

  proc lowerErrorContext(access: AbiAccess, value: ComponentValue): uint32 =
    result = cast[ComponentInstance](access.resourceOwner).lowerErrorContext(value)
    when defined(wasmComponentHostEndpoints):
      if access.endpointMoves != nil:
        access.endpointMoves[].add(EndpointLoweredHandle(handle: result, isErrorContext: true))

  proc makeErrorContextBuiltin(instance: ComponentInstance, lowering: CoreLowering): HostFunc =
    let owner = cast[pointer](instance)
    let kind = lowering.kind
    let encoding = lowering.stringEncoding
    let memory = if lowering.memoryInstance == 0: -1
      else: instance.coreExport(lowering.memoryInstance, lowering.memoryName, ekMemory)
    let realloc = if lowering.reallocSource == 0: -1
      else: instance.coreExport(lowering.reallocSource, lowering.reallocName, ekFunc)
    result = proc(args: openArray[WasmValue]): seq[WasmValue] =
      let inst = cast[ComponentInstance](owner)
      if not inst.execution.mayLeave: componentFail("canonical error-context builtin cannot leave")
      let first = args[0].i32.uint32
      case kind
      of clErrorContextNew:
        let message = when defined(wasmComponentErrorContextMessages):
            inst.vm.store.mems[memory].readCanonicalString(first, args[1].i32.uint32, encoding)
          else: ""
        let handle = inst.lowerErrorContext(componentErrorContext(message))
        return @[wasmI32(cast[int32](handle))]
      of clErrorContextDebugMessage:
        let value = inst.errorContextAt(first)
        let address = args[1].i32.uint32.uint64
        if (address and 3) != 0: componentFail("unaligned canonical error-context return area")
        inst.vm.store.mems[memory].checkMemoryRange(address, 8)
        let (ptrValue, units) = inst.vm.storeCanonicalText(inst.execution,
          memory, realloc, value.debugMessage(), encoding)
        inst.vm.store.mems[memory].writeAbiInt(address, 4, ptrValue.uint64)
        inst.vm.store.mems[memory].writeAbiInt(address + 4, 4, units.uint64)
      of clErrorContextDrop:
        if inst.resources == nil or not inst.resources.table.dropErrorContextHandle(first):
          componentFail("invalid canonical error-context handle")
      else: componentFail("invalid canonical error-context builtin")

proc readAbiScalar(memory: var MemInst, offset: uint64,
                   kind: ComponentPrim): ComponentValue =
  let bits = readAbiInt(memory, offset, recordScalarBytes(kind))
  let scalar = case coreType(kind)
    of vtI32: wasmI32(cast[int32](bits.uint32))
    of vtI64: wasmI64(cast[int64](bits))
    of vtF32: wasmF32(cast[float32](bits.uint32))
    of vtF64: wasmF64(cast[float64](bits))
    else: componentFail("invalid canonical scalar")
  lift(scalar, kind)

proc variantLayout(cases: openArray[ComponentVariantCase], pointerBytes: int):
    tuple[size, alignment, payloadOffset: int] =
  if cases.len == 0 or cases.len > MaxComponentVariantCases:
    componentFail("invalid component variant layout")
  result.alignment = 1
  var maxPayloadBytes = 0
  for item in cases:
    if not item.hasPayload: continue
    let payload = canonicalSlotLayout(caseSlot(item), pointerBytes)
    result.alignment = max(result.alignment, payload.alignment)
    maxPayloadBytes = max(maxPayloadBytes, payload.size)
  result.payloadOffset = result.alignment
  result.size = (result.payloadOffset + maxPayloadBytes +
    result.alignment - 1) and not (result.alignment - 1)

type AbiListBudget = object
  valuesLeft: int
  bytesLeft: int

proc listBudget(): AbiListBudget =
  AbiListBudget(valuesLeft: MaxGenericListValues, bytesLeft: MaxComponentByteListBytes)

proc charge(budget: ptr AbiListBudget, values, bytes: uint64) =
  if budget != nil:
    if values > budget.valuesLeft.uint64 or bytes > budget.bytesLeft.uint64:
      componentFail("canonical list transfer exceeds profile limit")
    budget.valuesLeft -= values.int
    budget.bytesLeft -= bytes.int

proc readAbiArgument(memory: var MemInst, offset: uint64, slot: CanonicalSlot,
                     encoding: CanonicalStringEncoding,
                     budget: ptr AbiListBudget = nil): ComponentValue

proc readGenericList(memory: var MemInst, payload: uint64, count: uint32, kind: ComponentPrim,
    element: ref CanonicalSlot, encoding: CanonicalStringEncoding,
    budget: ptr AbiListBudget): ComponentValue =
  let layout = canonicalSlotLayout(element[])
  let bytes = count.uint64 * layout.size.uint64
  budget.charge(count.uint64, bytes)
  if (payload and (layout.alignment - 1).uint64) != 0:
    componentFail("unaligned canonical list pointer")
  memory.checkMemoryRange(payload, bytes.uint32)
  result = ComponentValue(kind: kind, fields: newSeqOfCap[ComponentValue](count.int))
  for i in 0 ..< count:
    let offset = payload + i.uint64 * layout.size.uint64
    result.fields.add(readAbiArgument(memory, offset, element[], encoding, budget))

proc readAbiPair(memory: var MemInst, payload, count: uint32, kind: ComponentPrim,
                 encoding: CanonicalStringEncoding,
                 listElement: ref CanonicalSlot = nil,
                 budget: ptr AbiListBudget = nil): ComponentValue =
  case kind
  of cpString:
    let tagged = encoding == cseLatin1Utf16
    let units = if tagged: count and not Utf16LengthTag else: count
    let utf16 = encoding == cseUtf16 or (tagged and (count and Utf16LengthTag) != 0)
    let bytes = units.uint64 * (if utf16: 2'u64 else: 1'u64)
    budget.charge(0, bytes)
    let value = memory.readCanonicalString(payload, count, encoding)
    if value.len.uint64 > bytes:
      budget.charge(0, value.len.uint64 - bytes)
    ComponentValue(kind: cpString, text: value)
  of cpBytes:
    if count > MaxComponentByteListBytes.uint32:
      componentFail("canonical byte list argument limit")
    budget.charge(0, count.uint64)
    memory.checkMemoryRange(payload.uint64, count)
    result.kind = cpBytes
    result.bytes = newSeq[byte](count.int)
    let address = if count == 0: nil else: addr result.bytes[0]
    memory.readMemoryBytes(payload.uint64, cast[ptr UncheckedArray[byte]](address), count)
    return
  of cpU32List:
    budget.charge(count.uint64, count.uint64 * 4)
    readIntList(memory, payload, count, 4, cpU32List, cpU32)
  of cpU64List:
    budget.charge(count.uint64, count.uint64 * 8)
    readIntList(memory, payload, count, 8, cpU64List, cpU64)
  of cpList, cpMap:
    if budget != nil:
      return readGenericList(memory, payload.uint64, count, kind, listElement, encoding, budget)
    var limit = listBudget()
    readGenericList(memory, payload.uint64, count, kind, listElement, encoding, addr limit)
  else: componentFail("invalid canonical leaf type")

proc readAbiLeaf(memory: var MemInst, offset: uint64, kind: ComponentPrim,
                 encoding: CanonicalStringEncoding,
                 budget: ptr AbiListBudget,
                 listElement: ref CanonicalSlot = nil): ComponentValue =
  if kind notin CanonicalPairs:
    return readAbiScalar(memory, offset, kind)
  let payload = readAbiInt(memory, offset, 4).uint32
  let count = readAbiInt(memory, offset + 4, 4).uint32
  readAbiPair(memory, payload, count, kind, encoding, listElement, budget)

proc takeFlatLane(args: openArray[WasmValue], offset: var int): WasmValue =
  if offset >= args.len:
    componentFail("canonical import argument count mismatch")
  result = args[offset]
  inc offset

proc readFlatPair(access: AbiAccess, first, last: WasmValue,
                  kind: ComponentPrim, listElement: ref CanonicalSlot = nil): ComponentValue =
  if access.memoryAddress < 0 or first.kind != wvkI32 or last.kind != wvkI32:
    componentFail("canonical import payload requires pointer and length")
  readAbiPair(access.vm[].store.mems[access.memoryAddress], first.i32.uint32,
    last.i32.uint32, kind, access.encoding, listElement)

proc narrowFlatLane(value: WasmValue, kind: ValType): WasmValue =
  case value.kind
  of wvkI32:
    if kind == vtF32:
      return wasmF32(cast[float32](value.i32.uint32))
  of wvkI64:
    case kind
    of vtI32: return wasmI32(cast[int32](value.i64.uint32))
    of vtF32: return wasmF32(cast[float32](value.i64.uint32))
    of vtF64: return wasmF64(cast[float64](value.i64))
    else: discard
  else: discard
  value

proc readFlatSlot(access: AbiAccess, slot: CanonicalSlot,
                  args: openArray[WasmValue], offset: var int,
                  joined = false): ComponentValue

proc readFlatVariant(access: AbiAccess, args: openArray[WasmValue], offset: var int,
                     slot: CanonicalSlot): ComponentValue =
  let tag = narrowFlatLane(takeFlatLane(args, offset), vtI32).i32.uint32
  if tag >= slot.cases.len.uint32:
    componentFail("canonical variant discriminant out of range")
  result = ComponentValue(kind: slot.kind, caseIndex: tag)
  let selected = slot.cases[tag.int]
  let after = offset + flatSlotWidth(slot) - 1
  if after > args.len:
    componentFail("canonical import argument count mismatch")
  if selected.hasPayload:
    result.fields.add(readFlatSlot(access, caseSlot(selected), args, offset, joined = true))
  offset = after

proc readFlatSlot(access: AbiAccess, slot: CanonicalSlot,
                  args: openArray[WasmValue], offset: var int,
                  joined: bool): ComponentValue =
  case slot.kind
  of cpFixedList:
    result = ComponentValue(kind: cpFixedList,
      fields: newSeqOfCap[ComponentValue](slot.listLength.int))
    for _ in 0 ..< slot.listLength:
      result.fields.add(readFlatSlot(access, slot.listElement[], args, offset, joined))
    return
  of cpRecord, cpTuple:
    result = ComponentValue(kind: slot.kind,
      fields: newSeqOfCap[ComponentValue](slot.recordShape.fields.len))
    for field in slot.recordShape.fields:
      if not joined and field.shape == nil and field.kind notin CanonicalPairs:
        result.fields.add(lift(takeFlatLane(args, offset), field.kind))
      else:
        result.fields.add(readFlatSlot(access, fieldSlot(field), args, offset, joined))
    return
  of cpVariant, cpOption, cpResult, cpEnum:
    readFlatVariant(access, args, offset, slot)
  of cpFlags:
    let bits = narrowFlatLane(takeFlatLane(args, offset), vtI32).i32.uint32
    ComponentValue(kind: cpFlags, bits: (bits and flagMask(slot.cases.len)).uint64)
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap:
    let first = narrowFlatLane(takeFlatLane(args, offset), vtI32)
    let last = narrowFlatLane(takeFlatLane(args, offset), vtI32)
    readFlatPair(access, first, last, slot.kind, slot.listElement)
  of cpOwnedResource, cpBorrowedResource, cpFuture, cpStream, cpErrorContext:
    let bits = narrowFlatLane(takeFlatLane(args, offset), vtI32).i32.uint32
    ComponentValue(kind: slot.kind, bits: bits)
  else:
    let lane = takeFlatLane(args, offset)
    lift(if joined: narrowFlatLane(lane, coreType(slot.kind)) else: lane, slot.kind)

proc readFlatArgs(access: AbiAccess, sig: ComponentFuncType,
                   args: openArray[WasmValue], offset: var int): seq[ComponentValue] =
  result = newSeqOfCap[ComponentValue](sig.params.len)
  for i, kind in sig.params:
    if kind in ShapedValues:
      result.add(readFlatSlot(access, sig.paramArea.slots[i], args, offset))
    elif kind in CanonicalPairs:
      let first = takeFlatLane(args, offset)
      let last = takeFlatLane(args, offset)
      result.add(readFlatPair(access, first, last, kind))
    elif kind in {cpOwnedResource, cpBorrowedResource, cpErrorContext}:
      result.add(ComponentValue(kind: kind, bits: takeFlatLane(args, offset).i32.uint32))
    else:
      result.add(lift(takeFlatLane(args, offset), kind))

proc readAbiArgument(memory: var MemInst, offset: uint64, slot: CanonicalSlot,
                     encoding: CanonicalStringEncoding,
                     budget: ptr AbiListBudget): ComponentValue =
  case slot.kind
  of cpFixedList:
    if budget != nil:
      return readGenericList(memory, offset, slot.listLength, slot.kind,
        slot.listElement, encoding, budget)
    var limit = listBudget()
    return readGenericList(memory, offset, slot.listLength, slot.kind,
      slot.listElement, encoding, addr limit)
  of cpRecord, cpTuple:
    budget.charge(slot.recordShape.fields.len.uint64, 0)
    result = ComponentValue(kind: slot.kind,
      fields: newSeqOfCap[ComponentValue](slot.recordShape.fields.len))
    for field in slot.recordShape.fields:
      let address = offset + field.offset.uint64
      if field.shape == nil:
        result.fields.add(readAbiLeaf(memory, address, field.kind, encoding, budget))
      else:
        result.fields.add(readAbiArgument(memory, address, field.shape[], encoding, budget))
    return
  of cpFlags:
    let count = slot.cases.len
    ComponentValue(kind: cpFlags,
      bits: readAbiInt(memory, offset, flagBytes(count)) and flagMask(count).uint64)
  of cpOption, cpVariant, cpEnum, cpResult:
    let index = readAbiInt(memory, offset, 1).uint32
    if index >= slot.cases.len.uint32:
      componentFail("canonical variant discriminant out of range")
    result = ComponentValue(kind: slot.kind, caseIndex: index)
    let selected = slot.cases[index.int]
    if selected.hasPayload:
      budget.charge(1, 0)
      let layout = variantLayout(slot.cases)
      let address = offset + layout.payloadOffset.uint64
      if selected.shape == nil:
        result.fields.add(readAbiLeaf(memory, address, selected.payloadKind, encoding, budget))
      else:
        result.fields.add(readAbiArgument(memory, address, selected.shape[], encoding, budget))
    return
  of cpOwnedResource, cpBorrowedResource, cpFuture, cpStream, cpErrorContext:
    ComponentValue(kind: slot.kind, bits: readAbiInt(memory, offset, 4))
  else:
    readAbiLeaf(memory, offset, slot.kind, encoding, budget, slot.listElement)

proc liftAggregate(instance: ComponentInstance, exp: ComponentExport,
                   value: WasmValue, shape: CanonicalSlot): ComponentValue =
  if flatSlotWidth(shape) == 1:
    var lane = 0
    return readFlatSlot(AbiAccess(memoryAddress: -1), shape, [value], lane)
  if value.kind != wvkI32:
    componentFail("invalid canonical record return pointer")
  let layout = canonicalSlotLayout(shape)
  let pointer = cast[uint32](value.i32)
  if (pointer and (layout.alignment - 1).uint32) != 0:
    if shape.kind == cpFixedList: componentFail("unaligned canonical fixed-length list result")
    componentFail("unaligned canonical record result")
  let memoryAddress = instance.coreExport(exp.coreSources[clsMemory],
    exp.memoryName, ekMemory)
  instance.vm.store.mems[memoryAddress].checkMemoryRange(pointer.uint64, layout.size.uint32)
  readAbiArgument(instance.vm.store.mems[memoryAddress], pointer.uint64,
    shape, exp.stringEncoding)

proc readIndirectArgs(memory: var MemInst, area: CanonicalParams, offset: uint32,
                      encoding: CanonicalStringEncoding): seq[ComponentValue] =
  if (offset and (area.layout.alignment - 1).uint32) != 0:
    componentFail("unaligned canonical argument area")
  memory.checkMemoryRange(offset.uint64, area.layout.size.uint32)
  result = newSeqOfCap[ComponentValue](area.slots.len)
  for slot in area.slots:
    result.add(readAbiArgument(memory, offset.uint64 + slot.offset.uint64, slot, encoding))

proc writeAbiScalar(memory: var MemInst, offset: uint64, value: ComponentValue) =
  let scalar = lower(value)
  let bits = case scalar.kind
    of wvkI32: scalar.i32.uint32.uint64
    of wvkI64: cast[uint64](scalar.i64)
    of wvkF32: cast[uint32](scalar.f32).uint64
    of wvkF64: cast[uint64](scalar.f64)
    else: componentFail("invalid canonical scalar")
  writeAbiInt(memory, offset, recordScalarBytes(value.kind), bits)

proc allocateAbiList(access: AbiAccess, value: ComponentValue):
    tuple[offset, count: uint32] =
  if value.kind == cpBytes:
    if value.bytes.len > MaxComponentByteListBytes:
      componentFail("component byte list length limit")
    let source = if value.bytes.len == 0: nil else: unsafeAddr value.bytes[0]
    return (access.vm[].allocCanonicalPayload(access.execution, access.memoryAddress,
      access.reallocAddress, source, value.bytes.len, 1), value.bytes.len.uint32)
  let width = if value.kind == cpU32List: 4 else: 8
  let kind = if width == 4: cpU32 else: cpU64
  let bytes = encodeIntList(value, width, kind)
  let source = if bytes.len == 0: nil else: unsafeAddr bytes[0]
  (access.vm[].allocCanonicalPayload(access.execution, access.memoryAddress,
    access.reallocAddress, source, bytes.len, width), value.fields.len.uint32)

proc writeAbiArgument(access: AbiAccess, offset: uint64, slot: CanonicalSlot,
                      value: ComponentValue, budget: ptr AbiListBudget = nil)

proc writeGenericList(access: AbiAccess, element: ref CanonicalSlot,
    values: openArray[ComponentValue], budget: ptr AbiListBudget):
    tuple[offset, count: uint32] =
  let layout = canonicalSlotLayout(element[])
  let bytes = values.len.uint64 * layout.size.uint64
  budget.charge(values.len.uint64, bytes)
  result.count = values.len.uint32
  result.offset = access.vm[].canonicalRealloc(access.execution, access.memoryAddress,
    access.reallocAddress, 0, 0, bytes.int, layout.alignment)
  for i, item in values:
    let offset = result.offset.uint64 + i.uint64 * layout.size.uint64
    writeAbiArgument(access, offset, element[], item, budget)

proc allocateAbiPair(access: AbiAccess, value: ComponentValue,
                     listElement: ref CanonicalSlot = nil,
                     budget: ptr AbiListBudget = nil): tuple[offset, count: uint32] =
  case value.kind
  of cpString:
    if value.text.len > MaxComponentStringBytes or not validWasmName(value.text):
      componentFail("invalid canonical string argument")
    # The string codec may reserve twice the UTF-8 input before shrinking.
    budget.charge(0, value.text.len.uint64 * (if access.encoding == cseUtf8: 1'u64 else: 2'u64))
    let (offset, units) = access.vm[].storeCanonicalText(access.execution, access.memoryAddress,
      access.reallocAddress, value.text, access.encoding)
    (offset: offset, count: units)
  of cpBytes:
    budget.charge(0, value.bytes.len.uint64)
    allocateAbiList(access, value)
  of cpU32List, cpU64List:
    let width = if value.kind == cpU32List: 4'u64 else: 8'u64
    budget.charge(value.fields.len.uint64, value.fields.len.uint64 * width)
    allocateAbiList(access, value)
  of cpList, cpMap:
    if budget != nil:
      return writeGenericList(access, listElement, value.fields, budget)
    var limit = listBudget()
    writeGenericList(access, listElement, value.fields, addr limit)
  else:
    componentFail("invalid canonical pair type")

proc writeAbiLeaf(access: AbiAccess, offset: uint64, value: ComponentValue,
                  budget: ptr AbiListBudget, listElement: ref CanonicalSlot = nil) =
  if value.kind notin CanonicalPairs:
    writeAbiScalar(access.vm[].store.mems[access.memoryAddress], offset, value)
    return
  let pair = allocateAbiPair(access, value, listElement, budget)
  writeAbiInt(access.vm[].store.mems[access.memoryAddress], offset, 4, pair.offset.uint64)
  writeAbiInt(access.vm[].store.mems[access.memoryAddress], offset + 4, 4, pair.count.uint64)

proc writeAbiArgument(access: AbiAccess, offset: uint64, slot: CanonicalSlot,
                      value: ComponentValue, budget: ptr AbiListBudget) =
  if slot.kind != value.kind:
    componentFail("canonical value type mismatch")
  case slot.kind
  of cpFixedList:
    requireFixedListLength(slot, value)
    let stride = canonicalSlotLayout(slot.listElement[]).size.uint64
    var limit: AbiListBudget
    let activeBudget = if budget != nil: budget else:
      limit = listBudget()
      addr limit
    activeBudget.charge(slot.listLength.uint64, slot.listLength.uint64 * stride)
    for i, field in value.fields:
      writeAbiArgument(access, offset + i.uint64 * stride, slot.listElement[], field, activeBudget)
  of cpRecord, cpTuple:
    if value.fields.len != slot.recordShape.fields.len:
      componentFail("component record field count mismatch")
    budget.charge(value.fields.len.uint64, 0)
    for i, field in slot.recordShape.fields:
      if value.fields[i].kind != field.kind:
        componentFail("component record field type mismatch")
      let address = offset + field.offset.uint64
      if field.shape == nil:
        writeAbiLeaf(access, address, value.fields[i], budget)
      else:
        writeAbiArgument(access, address, field.shape[], value.fields[i], budget)
  of cpOption, cpVariant, cpEnum, cpResult:
    if value.caseIndex >= slot.cases.len.uint32:
      componentFail("component variant case out of range")
    let selected = slot.cases[value.caseIndex.int]
    if value.fields.len != selected.hasPayload.int:
      componentFail("component variant payload count mismatch")
    writeAbiInt(access.vm[].store.mems[access.memoryAddress], offset, 1, value.caseIndex.uint64)
    if selected.hasPayload:
      budget.charge(1, 0)
      if value.fields[0].kind != selected.payloadKind:
        componentFail("component variant payload type mismatch")
      let layout = variantLayout(slot.cases)
      let address = offset + layout.payloadOffset.uint64
      if selected.shape == nil:
        writeAbiLeaf(access, address, value.fields[0], budget)
      else:
        writeAbiArgument(access, address, selected.shape[], value.fields[0], budget)
  of cpFlags:
    let count = slot.cases.len
    if (value.bits and not flagMask(count).uint64) != 0:
      componentFail("component flags argument out of range")
    writeAbiInt(access.vm[].store.mems[access.memoryAddress],
      offset, flagBytes(count), value.bits)
  of cpOwnedResource, cpBorrowedResource:
    writeAbiInt(access.vm[].store.mems[access.memoryAddress],
      offset, 4, lowerResourceHandle(access, slot, value).uint64)
  of cpErrorContext:
    when defined(wasmComponentErrorContext):
      writeAbiInt(access.vm[].store.mems[access.memoryAddress],
        offset, 4, access.lowerErrorContext(value).uint64)
    else: componentFail("component error-context is disabled")
  of cpFuture, cpStream:
    when ComponentEndpointsEnabled:
      writeAbiInt(access.vm[].store.mems[access.memoryAddress],
        offset, 4, lowerEndpointHandle(access, slot, value).uint64)
    else: componentFail("canonical endpoint values are disabled")
  else:
    writeAbiLeaf(access, offset, value, budget, slot.listElement)

proc lowerAbiResult(access: AbiAccess, sig: ComponentFuncType, value: ComponentValue,
                    returnPointer: uint32): seq[WasmValue] =
  if sig.resultUsesMemory():
    let slot = if sig.resultShape == nil: CanonicalSlot(kind: sig.resultType)
      else: sig.resultShape[]
    let layout = canonicalSlotLayout(slot)
    if (returnPointer and (layout.alignment - 1).uint32) != 0:
      if sig.resultType == cpString:
        componentFail("unaligned canonical string return area")
      componentFail("unaligned canonical return area")
    access.vm[].store.mems[access.memoryAddress].checkMemoryRange(
      returnPointer.uint64, layout.size.uint32)
    writeAbiArgument(access, returnPointer.uint64, slot, value)
    return
  case sig.resultType
  of cpRecord, cpTuple:
    result = newSeqOfCap[WasmValue](1)
    lowerFlatSlot(access, sig.resultShape[], value, result)
    return
  of cpFlags:
    if (value.bits and not flagMask(sig.resultShape.cases.len).uint64) != 0:
      componentFail("component flags result out of range")
    @[wasmI32(cast[int32](value.bits.uint32))]
  of cpOption, cpVariant, cpEnum, cpResult:
    if value.caseIndex >= sig.resultShape.cases.len.uint32 or value.fields.len != 0:
      componentFail("component variant result shape mismatch")
    @[wasmI32(value.caseIndex.int32)]
  of cpOwnedResource:
    @[wasmI32(cast[int32](lowerResourceHandle(access, resultSlot(sig), value)))]
  of cpErrorContext:
    when defined(wasmComponentErrorContext):
      @[wasmI32(cast[int32](access.lowerErrorContext(value)))]
    else: componentFail("component error-context is disabled")
  of cpFuture, cpStream:
    when ComponentEndpointsEnabled:
      @[wasmI32(cast[int32](lowerEndpointHandle(access, resultSlot(sig), value)))]
    else: componentFail("canonical endpoint values are disabled")
  else:
    @[lower(value)]

proc widenFlatLane(value: WasmValue, kind: ValType): WasmValue =
  case kind
  of vtI32:
    if value.kind == wvkF32:
      return wasmI32(cast[int32](value.f32))
  of vtI64:
    case value.kind
    of wvkI32: return wasmI64(value.i32.uint32.int64)
    of wvkF32: return wasmI64(cast[uint32](value.f32).int64)
    of wvkF64: return wasmI64(cast[int64](value.f64))
    else: discard
  else: discard
  value

proc emptyFlatLane(kind: ValType): WasmValue =
  case kind
  of vtI32: wasmI32(0)
  of vtI64: wasmI64(0)
  of vtF32: wasmF32(0)
  of vtF64: wasmF64(0)
  else: componentFail("invalid component variant payload type")

proc lowerVariant(access: AbiAccess, slot: CanonicalSlot,
                  value: ComponentValue, args: var seq[WasmValue]) =
  if value.caseIndex >= slot.cases.len.uint32:
    componentFail("component variant case out of range")
  let selected = slot.cases[value.caseIndex.int]
  if value.fields.len != selected.hasPayload.int:
    componentFail("component variant payload count mismatch")
  args.add(wasmI32(value.caseIndex.int32))
  let start = args.len
  if selected.hasPayload:
    lowerFlatSlot(access, caseSlot(selected), value.fields[0], args)
  let active = args.len - start
  for lane in 1 ..< flatSlotWidth(slot):
    let kind = flatLaneType(slot, lane)
    if lane <= active:
      let index = start + lane - 1
      args[index] = widenFlatLane(args[index], kind)
    else:
      args.add(emptyFlatLane(kind))

proc lowerFlatSlot(access: AbiAccess, slot: CanonicalSlot, value: ComponentValue,
                   lanes: var seq[WasmValue]) =
  if slot.kind != value.kind:
    componentFail("canonical value type mismatch")
  case slot.kind
  of cpFixedList:
    requireFixedListLength(slot, value)
    for field in value.fields:
      lowerFlatSlot(access, slot.listElement[], field, lanes)
  of cpRecord, cpTuple:
    if value.fields.len != slot.recordShape.fields.len:
      componentFail("component record field count mismatch")
    for i, field in slot.recordShape.fields:
      if field.kind != value.fields[i].kind:
        componentFail("component record field type mismatch")
      if field.shape == nil and field.kind notin CanonicalPairs:
        lanes.add(lower(value.fields[i]))
      else:
        lowerFlatSlot(access, fieldSlot(field), value.fields[i], lanes)
  of cpOption, cpVariant, cpEnum, cpResult:
    lowerVariant(access, slot, value, lanes)
  of cpFlags:
    if (value.bits and not flagMask(slot.cases.len).uint64) != 0:
      componentFail("component flags argument out of range")
    lanes.add(wasmI32(cast[int32](value.bits.uint32)))
  of cpString, cpBytes, cpU32List, cpU64List, cpList, cpMap:
    let (offset, count) = allocateAbiPair(access, value, slot.listElement)
    lanes.add(wasmI32(cast[int32](offset)))
    lanes.add(wasmI32(cast[int32](count)))
  of cpOwnedResource, cpBorrowedResource:
    lanes.add(wasmI32(cast[int32](lowerResourceHandle(access, slot, value))))
  of cpErrorContext:
    when defined(wasmComponentErrorContext):
      lanes.add(wasmI32(cast[int32](access.lowerErrorContext(value))))
    else: componentFail("component error-context is disabled")
  of cpFuture, cpStream:
    when ComponentEndpointsEnabled:
      lanes.add(wasmI32(cast[int32](lowerEndpointHandle(access, slot, value))))
    else: componentFail("canonical endpoint values are disabled")
  else:
    lanes.add(lower(value))

proc liftVariant(instance: ComponentInstance, exp: ComponentExport,
                 value: WasmValue, shape: CanonicalSlot): ComponentValue =
  if value.kind != wvkI32:
    componentFail("invalid canonical variant result")
  let pointer = value.i32.uint32
  if flatSlotWidth(shape) == 1:
    if pointer >= shape.cases.len.uint32:
      componentFail("canonical variant discriminant out of range")
    return ComponentValue(kind: shape.kind, caseIndex: pointer)
  let layout = variantLayout(shape.cases)
  if (pointer and (layout.alignment - 1).uint32) != 0:
    componentFail("unaligned canonical variant result")
  let address = instance.coreExport(exp.coreSources[clsMemory], exp.memoryName, ekMemory)
  instance.vm.store.mems[address].checkMemoryRange(pointer.uint64, layout.size.uint32)
  readAbiArgument(instance.vm.store.mems[address], pointer.uint64, shape, exp.stringEncoding)

proc borrowComponentResource*(value: ComponentValue): ComponentValue =
  if value.kind != cpOwnedResource or not value.ownsResource or value.resource == nil or
      not value.resource.live or value.resource.owner.isLocked:
    componentFail("invalid component owned value")
  ComponentValue(kind: cpBorrowedResource, resource: value.resource)

proc consumeOwner(owner: ComponentOwnedValue) =
  if owner.lends != 0:
    componentFail("cannot remove owned resource while borrowed")
  dec owner.owner.outstandingOwners
  owner.live = false
  owner.owner = nil

proc transferOwner(instance: ComponentInstance, typeIndex: uint32,
                   resource: ComponentOwnedValue): uint32 =
  if resource.lends != 0:
    componentFail("cannot remove owned resource while borrowed")
  let status = instance.resources.table.newOwned(typeIndex,
    resource.representation, result)
  if status != crOk:
    componentFail("component resource transfer failed: " & $status)
  consumeOwner(resource)
  resource.graph = nil

proc dropComponentResource*(value: ComponentValue) =
  if value.kind != cpOwnedResource or not value.ownsResource or value.resource == nil or
      not value.resource.live:
    componentFail("invalid component owned value")
  let instance = value.resource.owner
  if instance.activeEntries != 0 or instance.isLocked:
    componentFail("component resource owner cannot run")
  let resource = value.resource
  consumeOwner(resource)
  instance.activeEntries = 1
  defer:
    instance.activeEntries = 0
    resource.graph = nil
  let status = instance.resources.table.destroyRepresentation(
    resource.resourceIndex, resource.representation)
  if status != crOk:
    instance.lockStore()
    componentFail("component resource drop failed: " & $status)

proc resourceDefiner(resource: ComponentOwnedValue): ComponentInstance {.inline.} =
  when defined(wasmComponentAsyncCallbacks):
    if resource.borrowOwner != nil: return cast[ComponentInstance](resource.borrowOwner)
  resource.owner

proc matchesResourceIdentity(instance: ComponentInstance, index: int,
                             resource: ComponentOwnedValue): bool =
  if index < 0 or resource == nil or not resource.live or
      instance.resources == nil:
    return false
  let definer = resource.resourceDefiner()
  if definer == nil or definer.isLocked: return false
  let binding = instance.resourceOrigin(index.uint32)
  cast[pointer](definer) == binding.owner and
    resource.resourceIndex == binding.resourceIndex

type ResourceLeafVisitor = proc(slot: CanonicalSlot, value: var ComponentValue) {.closure.}

proc visitResourceLeaves(slot: CanonicalSlot, value: var ComponentValue,
                         visit: ResourceLeafVisitor) =
  if value.kind != slot.kind:
    componentFail("component argument type mismatch")
  if slot.resources == {}: return
  case slot.kind
  of cpOwnedResource, cpBorrowedResource, cpFuture, cpStream, cpErrorContext:
    visit(slot, value)
  of cpFixedList:
    requireFixedListLength(slot, value)
    for item in value.fields.mitems:
      visitResourceLeaves(slot.listElement[], item, visit)
  of cpList, cpMap:
    if value.fields.len > MaxGenericListValues:
      componentFail("canonical list transfer exceeds profile limit")
    for item in value.fields.mitems:
      visitResourceLeaves(slot.listElement[], item, visit)
  of cpRecord, cpTuple:
    if value.fields.len != slot.recordShape.fields.len:
      componentFail("component record field count mismatch")
    for i, field in slot.recordShape.fields:
      visitResourceLeaves(fieldSlot(field), value.fields[i], visit)
  of cpOption, cpVariant, cpResult:
    if value.caseIndex >= slot.cases.len.uint32:
      componentFail("component variant discriminant out of range")
    let selected = slot.cases[value.caseIndex.int]
    if value.fields.len != selected.hasPayload.int:
      componentFail("component variant payload count mismatch")
    if selected.hasPayload:
      visitResourceLeaves(caseSlot(selected), value.fields[0], visit)
  else: discard

proc checkArgumentKinds(signature: ComponentFuncType, args: openArray[ComponentValue]) =
  for i, kind in signature.params:
    if kind != args[i].kind:
      componentFail("component argument type mismatch")

type PreparedResources = object
  owners, borrows: seq[ComponentOwnedValue]
  foreignBorrows: uint32
  when defined(wasmComponentErrorContext):
    errorContexts: uint32
  when ComponentEndpointsEnabled:
    endpointValues: seq[ComponentEndpointValue]

proc preparedHandleCount(prepared: PreparedResources): uint32 =
  result = prepared.owners.len.uint32 + prepared.foreignBorrows
  when defined(wasmComponentErrorContext): result += prepared.errorContexts
  when ComponentEndpointsEnabled:
    result += prepared.endpointValues.len.uint32

proc requireHandleCapacity(instance: ComponentInstance, count: uint32) =
  if count == 0: return
  instance.initCanonicalHandles()
  if not instance.resources.table.hasResourceCapacity(count):
    componentFail("component resource table capacity exceeded")

proc collectHostResource(instance: ComponentInstance, slot: CanonicalSlot,
                         value: ComponentValue, prepared: var PreparedResources) =
  when defined(wasmComponentErrorContext):
    if slot.kind == cpErrorContext:
      if value.errorContext == nil: componentFail("invalid component error-context value")
      inc prepared.errorContexts
      return
  when ComponentEndpointsEnabled:
    if slot.kind in {cpFuture, cpStream}:
      instance.validateEndpointValue(slot, value)
      if value.endpoint in prepared.endpointValues:
        componentFail("canonical " & endpointName(slot.kind) & " endpoint supplied more than once")
      prepared.endpointValues.add(value.endpoint)
      return
  let resource = value.resource
  let expected = resourceIndex(instance.handleTypes, slot.resourceType.uint32)
  if not instance.matchesResourceIdentity(expected, resource):
    componentFail("component resource argument type or owner mismatch")
  if value.ownsResource != (slot.kind == cpOwnedResource):
    componentFail("component resource argument ownership mismatch")
  if resource in prepared.owners:
    componentFail("resource supplied as both owner and alias")
  if slot.kind == cpOwnedResource:
    if resource.lends != 0:
      componentFail("cannot remove owned resource while borrowed")
    if resource in prepared.borrows:
      componentFail("resource supplied as both owner and alias")
    prepared.owners.add(resource)
  else:
    prepared.borrows.add(resource)
    if resource.resourceDefiner() != instance:
      inc prepared.foreignBorrows

proc collectHostResources(instance: ComponentInstance, sig: ComponentFuncType,
                          args: var seq[ComponentValue]): PreparedResources =
  var prepared: PreparedResources
  let collect = proc(slot: CanonicalSlot, value: var ComponentValue) =
    instance.collectHostResource(slot, value, prepared)
  for i in 0 ..< args.len:
    visitResourceLeaves(parameterSlot(sig, i), args[i], collect)
  move prepared

proc pinBorrowArguments(prepared: PreparedResources) =
  for resource in prepared.borrows:
    inc resource.lends

proc unpinBorrowArguments(prepared: PreparedResources) =
  for resource in prepared.borrows:
    dec resource.lends

proc liftOwned(instance: ComponentInstance, value: WasmValue,
               typeIndex: int32): ComponentValue =
  let index = resourceIndex(instance.handleTypes, typeIndex.uint32)
  if index < 0: componentFail("unknown canonical handle type")
  let origin = instance.resourceOrigin(index.uint32)
  let definer = cast[ComponentInstance](origin.owner)
  if definer.outstandingOwners >= definer.resources.table.resourceStats().capacity.int:
    componentFail("component host ownership capacity exceeded")
  var representation: uint64
  let status = instance.resources.table.takeOwnedRepresentation(
    value.i32.uint32, index.uint32, representation)
  if status != crOk:
    componentFail("canonical resource lift failed: " & $status)
  inc definer.outstandingOwners
  let root = if instance.links == nil: nil else: instance.links.store.root
  # A detached host owner keeps the defining guest's graph alive for its
  # destructor, including sibling bindings stored as weak references.
  let graph = if root == cast[pointer](definer): nil else: cast[ComponentInstance](root)
  ComponentValue(kind: cpOwnedResource, ownsResource: true,
    resource: ComponentOwnedValue(
    owner: definer, graph: graph, resourceIndex: origin.resourceIndex,
    representation: representation, live: true))

proc lowerBorrow(instance: ComponentInstance, index: uint32,
                 resource: ComponentOwnedValue): uint32 =
  let origin = instance.resourceOrigin(index)
  if origin.owner == cast[pointer](instance):
    return resource.representation.uint32
  var scope = instance.activeEntries.uint32
  when defined(wasmComponentAsyncCallbacks):
    if instance.execution.borrowScope != 0: scope = instance.execution.borrowScope
  let status = instance.resources.table.newScopedBorrow(index, scope,
    resource.representation, result)
  if status != crOk:
    componentFail("canonical resource borrow failed: " & $status)

proc decodeResourceLeaf(instance: ComponentInstance, slot: CanonicalSlot,
    value: var ComponentValue, lends: var seq[ResourceLend], scheduled = false) =
  let handle = value.bits.uint32
  when defined(wasmComponentErrorContext):
    if slot.kind == cpErrorContext:
      value = ComponentValue(kind: cpErrorContext, errorContext: instance.errorContextAt(handle))
      return
  when ComponentEndpointsEnabled:
    if slot.kind in {cpFuture, cpStream}:
      value = instance.liftEndpointHandle(slot, handle)
      return
  let typeIndex = slot.resourceType.int32
  if slot.kind == cpOwnedResource:
    value = instance.liftOwned(wasmI32(cast[int32](handle)), typeIndex)
    return
  let index = resourceIndex(instance.handleTypes, typeIndex.uint32)
  if index < 0: componentFail("unknown canonical handle type")
  var representation: uint64
  let status = instance.resources.table.lendRepresentation(handle, index.uint32, representation)
  if status != crOk: componentFail("canonical resource lend failed: " & $status)
  let origin = instance.resourceOrigin(index.uint32)
  let token = ComponentOwnedValue(
    resourceIndex: origin.resourceIndex, representation: representation, live: true)
  var lend = ResourceLend(handle: handle, token: token)
  when defined(wasmComponentAsyncCallbacks):
    let scope = instance.resources.table.borrowScopeForHandle(handle)
    lend.sourceScope = instance.resources.findBorrowScope(scope)
    if scheduled: token.borrowOwner = origin.owner
    else: token.owner = cast[ComponentInstance](origin.owner)
  else:
    token.owner = cast[ComponentInstance](origin.owner)
  lends.add(move lend)
  value = ComponentValue(kind: cpBorrowedResource, resource: token)

proc decodeOwnedResult(instance: ComponentInstance, slot: CanonicalSlot,
                       value: var ComponentValue) =
  var lends: seq[ResourceLend]
  let decode = proc(leaf: CanonicalSlot, value: var ComponentValue) =
    instance.decodeResourceLeaf(leaf, value, lends)
  visitResourceLeaves(slot, value, decode)

when defined(wasmComponentAsyncCallbacks):
  proc checkTaskBorrows(instance: ComponentInstance) =
    let id = instance.execution.borrowScope
    if id != 0 and instance.resources.table.hasScopedBorrows(id):
      componentFail("borrow handles still remain at the end of the call")

  proc returnTaskResult(task: var CanonicalCallbackTask) =
    if task.subtask != nil:
      cast[ComponentSubtask](task.subtask).resolveSubtask(task.values)
      task.values.setLen(0)
    task.resolution = ccrReturned

  proc returnFromCallback(instance: ComponentInstance, declared: ComponentFuncType,
      memoryAddress: int, encoding: CanonicalStringEncoding, args: openArray[WasmValue]) =
    let task = instance.execution.callbackTask
    if not instance.execution.mayLeave or task == nil:
      componentFail("canonical task.return requires an active async task")
    if task.resolution in {ccrReturned, ccrCancelled}:
      componentFail("canonical task already resolved")
    instance.checkTaskBorrows()
    if task.memoryAddress != memoryAddress or task.encoding != encoding:
      componentFail("canonical task.return options mismatch")
    let expected = task.signature
    if declared.hasResult != expected.hasResult:
      componentFail("canonical task.return type mismatch")
    if declared.hasResult:
      let slot = resultSlot(declared)
      let target = resultSlot(expected[])
      if slot != target: componentFail("canonical task.return type mismatch")
      if target.resources != {}:
        var providedTypes, expectedTypes: seq[uint16]
        collectResourceTypes(slot, providedTypes)
        collectResourceTypes(target, expectedTypes)
        if providedTypes.len != expectedTypes.len:
          componentFail("canonical task.return resource type mismatch")
        for i, provided in providedTypes:
          let actualId = resourceIndex(instance.handleTypes, provided.uint32)
          let expectedId = resourceIndex(instance.handleTypes, expectedTypes[i].uint32)
          if actualId < 0 or expectedId < 0 or
              instance.resourceOrigin(actualId.uint32) != instance.resourceOrigin(expectedId.uint32):
            componentFail("canonical task.return resource type mismatch")
      let width = flatSlotWidth(slot)
      if args.len != (if width > MaxFlatParams: 1 else: width):
        componentFail("canonical task.return argument count mismatch")
      var value: ComponentValue
      if width > MaxFlatParams:
        let layout = canonicalSlotLayout(slot)
        let offset = args[0].i32.uint32
        if (offset and (layout.alignment - 1).uint32) != 0:
          componentFail("unaligned canonical task.return area")
        let mem = addr instance.vm.store.mems[memoryAddress]
        mem[].checkMemoryRange(offset.uint64, layout.size.uint32)
        value = readAbiArgument(mem[], offset.uint64, slot, encoding)
      else:
        let access = AbiAccess(vm: addr instance.vm, execution: instance.execution,
          memoryAddress: memoryAddress, encoding: encoding)
        var offset = 0
        value = readFlatSlot(access, slot, args, offset)
      if expected[].hasResourceResult(): instance.decodeOwnedResult(target, value)
      task.values.add(move value)
    elif args.len != 0:
      componentFail("canonical task.return argument count mismatch")
    task[].returnTaskResult()

proc lowerResourceHandle(access: AbiAccess, slot: CanonicalSlot,
                         value: ComponentValue): uint32 =
  if access.resourceOwner == nil or value.resource == nil:
    componentFail("canonical resource lowering requires an active component")
  let instance = cast[ComponentInstance](access.resourceOwner)
  let index = resourceIndex(instance.handleTypes, slot.resourceType.uint32)
  if index < 0: componentFail("unknown canonical handle type")
  if slot.kind != cpOwnedResource:
    return instance.lowerBorrow(index.uint32, value.resource)
  let resource = value.resource
  when defined(wasmComponentHostEndpoints):
    if access.endpointMoves != nil:
      var receipt = EndpointLoweredHandle(isResource: true, resourceType: index.uint32,
        resource: resource, definer: resource.owner, graph: resource.graph)
      result = instance.transferOwner(index.uint32, resource)
      receipt.handle = result
      access.endpointMoves[].add(move receipt)
      return
  instance.transferOwner(index.uint32, resource)

proc validateHostResourceResult(instance: ComponentInstance, slot: CanonicalSlot,
                                value: var ComponentValue): uint32 =
  if slot.resources == {}: return 0
  var prepared: PreparedResources
  let collect = proc(leaf: CanonicalSlot, value: var ComponentValue) =
    instance.collectHostResource(leaf, value, prepared)
  visitResourceLeaves(slot, value, collect)
  prepared.preparedHandleCount()

proc resolveLoweredResult(destination: ptr LoweredResult, returned: var seq[ComponentValue]) =
  let sig = destination.signature
  if returned.len != sig.hasResult.int:
    componentFail("canonical import result count mismatch")
  if not sig.hasResult: return
  if returned[0].kind != sig.resultType:
    componentFail("canonical import result type mismatch")
  let access = destination.access
  if access.resourceOwner != nil and sig[].hasResourceResult():
    let instance = cast[ComponentInstance](access.resourceOwner)
    instance.requireHandleCapacity(instance.validateHostResourceResult(resultSlot(sig[]), returned[0]))
  destination.values[] = lowerAbiResult(access[], sig[], returned[0], destination.returnPointer)

proc invokeResourceLowering(instance: ComponentInstance, callback: ComponentHostFunc,
    target: ComponentCallTarget, args: var seq[ComponentValue], destination: ptr LoweredResult) =
  var lends: seq[ResourceLend]
  defer: instance.resources.releaseLends(lends)
  let decode = proc(slot: CanonicalSlot, value: var ComponentValue) =
    instance.decodeResourceLeaf(slot, value, lends)
  for i in 0 ..< args.len:
    visitResourceLeaves(parameterSlot(destination.signature[], i), args[i], decode)
  invokeLoweredTarget(callback, target, args, destination)

proc prepareIndirectArguments(instance: ComponentInstance, exp: ComponentExport,
                              args: openArray[ComponentValue]): seq[WasmValue] =
  let area = exp.signature.paramArea
  let access = AbiAccess(vm: addr instance.vm, execution: instance.execution,
    memoryAddress: instance.coreExport(exp.coreSources[clsMemory], exp.memoryName, ekMemory),
    reallocAddress: instance.coreExport(exp.coreSources[clsRealloc], exp.reallocName, ekFunc),
    encoding: exp.stringEncoding, resourceOwner: cast[pointer](instance))
  try:
    let base = instance.vm.canonicalRealloc(access.execution, access.memoryAddress,
      access.reallocAddress, 0, 0, area.layout.size, area.layout.alignment)
    for i, arg in args:
      let slot = unsafeAddr area.slots[i]
      writeAbiArgument(access, base.uint64 + slot.offset.uint64, slot[], arg)
    result = @[wasmI32(cast[int32](base))]
  except WasmTrap as error:
    instance.lockStore()
    componentFail("canonical indirect argument trap: " & error.msg)
  except CatchableError:
    instance.lockStore()
    raise

proc lowerList(instance: ComponentInstance, exp: ComponentExport, element: ref CanonicalSlot,
               value: ComponentValue, args: var seq[WasmValue]) =
  let access = AbiAccess(vm: addr instance.vm, execution: instance.execution,
    memoryAddress: instance.coreExport(exp.coreSources[clsMemory], exp.memoryName, ekMemory),
    reallocAddress: instance.coreExport(exp.coreSources[clsRealloc], exp.reallocName, ekFunc),
    encoding: exp.stringEncoding, resourceOwner: cast[pointer](instance))
  try:
    let (offset, count) = allocateAbiPair(access, value, element)
    args.add(wasmI32(cast[int32](offset)))
    args.add(wasmI32(cast[int32](count)))
  except WasmTrap as e:
    instance.lockStore()
    componentFail("canonical list allocation trap: " & e.msg)
  except CatchableError:
    instance.lockStore()
    raise

proc liftList(instance: ComponentInstance, exp: ComponentExport,
              value: WasmValue): ComponentValue =
  let (offset, count) = instance.readPair(exp, value)
  let memoryAddress = instance.coreExport(exp.coreSources[clsMemory], exp.memoryName, ekMemory)
  readAbiPair(instance.vm.store.mems[memoryAddress], offset, count,
    exp.signature.resultType, exp.stringEncoding, exp.signature.resultShape.listElement)

proc lowerAggregate(instance: ComponentInstance, exp: ComponentExport, slot: CanonicalSlot,
                    value: ComponentValue, args: var seq[WasmValue]) =
  let memory = exp.coreSources[clsMemory]
  let realloc = exp.coreSources[clsRealloc]
  let access = AbiAccess(vm: addr instance.vm, execution: instance.execution,
    memoryAddress: (if memory == 0: -1 else: instance.coreExport(memory, exp.memoryName, ekMemory)),
    reallocAddress: (if realloc == 0: -1 else: instance.coreExport(realloc, exp.reallocName, ekFunc)),
    encoding: exp.stringEncoding, resourceOwner: cast[pointer](instance))
  try:
    lowerFlatSlot(access, slot, value, args)
  except WasmTrap as error:
    instance.lockStore()
    componentFail("canonical aggregate allocation trap: " & error.msg)
  except CatchableError:
    instance.lockStore()
    raise

proc prepareCoreArguments(instance: ComponentInstance, exp: ComponentExport,
    args: openArray[ComponentValue]): seq[WasmValue] =
  var coreArgs: seq[WasmValue]
  if exp.signature.paramsUseMemoryArea():
    coreArgs = instance.prepareIndirectArguments(exp, args)
  else:
    coreArgs = newSeqOfCap[WasmValue](args.len * 2)
    for i, arg in args:
      if arg.kind in ResourceValues:
        let handle = lowerResourceHandle(AbiAccess(resourceOwner: cast[pointer](instance)),
          parameterSlot(exp.signature, i), arg)
        coreArgs.add(wasmI32(cast[int32](handle)))
      elif arg.kind == cpErrorContext:
        when defined(wasmComponentErrorContext):
          coreArgs.add(wasmI32(cast[int32](instance.lowerErrorContext(arg))))
        else: componentFail("component error-context is disabled")
      elif arg.kind == cpString:
        try:
          instance.lowerString(exp, arg, coreArgs)
        except WasmTrap as e:
          componentFail("canonical string allocation trap: " & e.msg)
      elif arg.kind == cpBytes:
        try:
          instance.lowerBytes(exp, arg, coreArgs)
        except WasmTrap as e:
          componentFail("canonical byte list allocation trap: " & e.msg)
      elif arg.kind in {cpU32List, cpU64List}:
        try:
          instance.lowerIntList(exp, arg, coreArgs,
            if arg.kind == cpU32List: 4 else: 8,
            if arg.kind == cpU32List: cpU32 else: cpU64)
        except WasmTrap as e:
          componentFail("canonical integer list allocation trap: " & e.msg)
      elif arg.kind in {cpList, cpMap}:
        instance.lowerList(exp, exp.signature.paramArea.slots[i].listElement, arg, coreArgs)
      elif arg.kind in {cpRecord, cpTuple, cpFixedList, cpFuture, cpStream} + CanonicalVariants:
        instance.lowerAggregate(exp, exp.signature.paramArea.slots[i], arg, coreArgs)
      elif arg.kind == cpFlags:
        if (arg.bits and not flagMask(exp.signature.paramArea.slots[i].cases.len).uint64) != 0:
          componentFail("component flags argument out of range")
        coreArgs.add(wasmI32(cast[int32](arg.bits.uint32)))
      else:
        coreArgs.add(lower(arg))
  move coreArgs

proc liftCoreResults(instance: ComponentInstance, exp: ComponentExport,
    values: openArray[WasmValue]): seq[ComponentValue] =
  if values.len != exp.signature.hasResult.int:
    componentFail("canonical result arity mismatch")
  if values.len == 0: return
  let value = values[0]
  case exp.signature.resultType
  of cpOwnedResource:
    result.add(ComponentValue(kind: cpOwnedResource, bits: value.i32.uint32))
  of cpFuture, cpStream, cpErrorContext:
    result.add(ComponentValue(kind: exp.signature.resultType, bits: value.i32.uint32))
  of cpString: result.add(instance.liftString(exp, value))
  of cpBytes: result.add(instance.liftBytes(exp, value))
  of cpU32List, cpU64List:
    result.add(instance.liftIntList(exp, value,
      if exp.signature.resultType == cpU32List: 4 else: 8,
      exp.signature.resultType,
      if exp.signature.resultType == cpU32List: cpU32 else: cpU64))
  of cpList, cpMap:
    result.add(instance.liftList(exp, value))
  of cpRecord, cpTuple, cpFixedList:
    result.add(instance.liftAggregate(exp, value, exp.signature.resultShape[]))
  of cpFlags:
    if value.kind != wvkI32: componentFail("canonical flags result type mismatch")
    result.add(ComponentValue(kind: cpFlags,
      bits: (value.i32.uint32 and flagMask(exp.signature.resultShape.cases.len)).uint64))
  of cpOption, cpVariant, cpEnum, cpResult:
    result.add(instance.liftVariant(exp, value, exp.signature.resultShape[]))
  else:
    result.add(lift(value, exp.signature.resultType))
  if exp.signature.hasResourceResult():
    instance.decodeOwnedResult(resultSlot(exp.signature), result[0])

proc finishLift(instance: ComponentInstance, exp: ComponentExport,
    values: openArray[WasmValue]) =
  if exp.coreSources[clsPostReturn] != 0:
    let address = instance.coreExport(exp.coreSources[clsPostReturn], exp.postReturnName, ekFunc)
    instance.runPostReturn(address, values)

when defined(wasmComponentThreads):
  proc invokeSynchronousGuestCore(instance: ComponentInstance, address: int,
      args: openArray[WasmValue]): seq[WasmValue]

  proc invokeGuestDestructor(instance: ComponentInstance, address: int,
      representation: WasmValue): bool =
    let store = instance.links.store
    if instance.activeEntries.int >= MaxComponentCallDepth or
        store.callDepth >= MaxComponentCallDepth:
      componentFail("component call depth exceeds profile limit")
    inc instance.activeEntries
    inc store.callDepth
    defer:
      dec store.callDepth
      dec instance.activeEntries
    withDirectGuestThread(instance):
      result = instance.invokeSynchronousGuestCore(address, [representation]).len == 0

proc invokePreparedLift(instance: ComponentInstance, exp: ComponentExport,
    args: openArray[ComponentValue], foreignBorrows: uint32,
    destination: ptr LoweredResult): seq[ComponentValue] =
  let coreArgs = instance.prepareCoreArguments(exp, args)
  let address = instance.coreExport(exp.coreSources[clsFunction], exp.coreName, ekFunc)
  try:
    let values = when defined(wasmComponentThreads):
        instance.invokeSynchronousGuestCore(address, coreArgs)
      else: instance.vm.execute(address, coreArgs)
    if foreignBorrows > 0 and instance.resources.table.hasScopedBorrows(instance.activeEntries.uint32):
      componentFail("canonical call returned with a live borrow handle")
    result = instance.liftCoreResults(exp, values)
    # Resolving a synchronous guest call includes lowering into the caller.
    if destination != nil: resolveLoweredResult(destination, result)
    instance.finishLift(exp, values)
  except WasmTrap as e:
    instance.lockStore()
    componentFail("component core trap: " & e.msg)
  except CatchableError:
    instance.lockStore()
    raise

proc invokeLiftedResources(instance: ComponentInstance, exp: ComponentExport,
    args: openArray[ComponentValue], destination: ptr LoweredResult): seq[ComponentValue] =
  var inspect = @args
  let prepared = instance.collectHostResources(exp.signature, inspect)
  instance.requireHandleCapacity(prepared.preparedHandleCount())
  pinBorrowArguments(prepared)
  defer:
    if prepared.foreignBorrows > 0:
      discard instance.resources.table.endBorrowScope(instance.activeEntries.uint32)
    unpinBorrowArguments(prepared)
  try:
    result = instance.invokePreparedLift(exp, args, prepared.foreignBorrows, destination)
  except CatchableError:
    instance.lockStore()
    raise

when defined(wasmComponentAsyncCallbacks):
  proc stackfulLift(exp: ComponentExport): bool {.inline.} =
    when defined(wasmComponentStackful): exp.stackful
    else: false

  proc usesAsyncLiftAbi(exp: ComponentExport): bool {.inline.} =
    exp.callbackSource != 0 or exp.stackfulLift()

  proc scheduledLift(exp: ComponentExport): bool {.inline.} =
    exp.target == ctCore and (exp.usesAsyncLiftAbi() or (when defined(wasmComponentStackful):
      exp.signature.asyncSignature() and ruBorrow notin exp.signature.parameterResources()
      else: false))

  proc invokeImmediateCallback(instance: ComponentInstance, entry: ptr ComponentExport,
      args: openArray[ComponentValue], destination: ptr LoweredResult): seq[ComponentValue]

proc invokeLifted(instance: ComponentInstance, exp: ComponentExport,
    args: openArray[ComponentValue], guestEntry: bool,
    destination: ptr LoweredResult): seq[ComponentValue] =
  when defined(wasmComponentAsyncCallbacks):
    if exp.usesAsyncLiftAbi():
      if destination == nil: componentFail("canonical callback requires a polled invocation")
      return instance.invokeImmediateCallback(unsafeAddr exp, args, destination)
  if instance.activeEntries != 0 and not guestEntry:
    componentFail("canonical reentry into active component")
  if not instance.execution.mayLeave:
    componentFail("canonical entry during realloc or post-return")
  if instance.activeEntries.int >= MaxComponentCallDepth:
    instance.lockStore()
    componentFail("component call depth exceeds profile limit")
  checkArgumentKinds(exp.signature, args)
  inc instance.activeEntries
  defer: dec instance.activeEntries
  withFreshContext(instance.execution):
    template invokeDirect() =
      if exp.signature.parameterResources() != {}:
        result = instance.invokeLiftedResources(exp, args, destination)
      else:
        result = instance.invokePreparedLift(exp, args, 0, destination)
    when defined(wasmComponentThreads):
      withDirectGuestThread(instance): invokeDirect()
    else: invokeDirect()

proc resolveInvocationTarget(instance: ComponentInstance, exp: ptr ComponentExport):
    tuple[owner: ComponentInstance, entry: ptr ComponentExport] =
  var owner = instance
  var entry = exp
  while true:
    case entry.target
    of ctCore: break
    of ctChild:
      let target = owner.links.aliases[entry.targetIndex.int]
      owner = owner.links.children[target.childIndex.int]
      entry = childExportAt(owner, target)
    of ctImport:
      let target = owner.links.bindings[entry.targetIndex.int].target
      if target == nil: break
      owner = cast[ComponentInstance](target.owner)
      entry = target.entry
  (owner, entry)

proc invokeFunction(instance: ComponentInstance, exp: ComponentExport,
    args: openArray[ComponentValue], guestEntry: bool,
    destination: ptr LoweredResult): seq[ComponentValue] =
  let (owner, entry) = instance.resolveInvocationTarget(unsafeAddr exp)
  if owner.isLocked:
    componentFail("component store locked after trap")
  if args.len != entry.signature.params.len:
    componentFail("component argument count mismatch")
  let store = if owner.links == nil: nil else: owner.links.store
  if store != nil:
    if store.callDepth >= MaxComponentCallDepth:
      owner.lockStore()
      componentFail("component call depth exceeds profile limit")
    inc store.callDepth
  defer:
    if store != nil: dec store.callDepth
  case entry.target
  of ctCore:
    result = owner.invokeLifted(entry[], args, guestEntry, destination)
  of ctChild:
    componentFail("unresolved component function alias")
  of ctImport:
    checkArgumentKinds(entry.signature, args)
    var prepared: PreparedResources
    if entry.signature.parameterResources() != {}:
      var inspect = @args
      prepared = owner.collectHostResources(entry.signature, inspect)
    pinBorrowArguments(prepared)
    defer: unpinBorrowArguments(prepared)
    try:
      result = owner.links.bindings[entry.targetIndex.int].callback(args)
      if result.len != entry.signature.hasResult.int or
          (entry.signature.hasResult and result[0].kind != entry.signature.resultType):
        componentFail("component host export result type mismatch")
      if entry.signature.hasResourceResult():
        discard owner.validateHostResourceResult(resultSlot(entry.signature), result[0])
      if destination != nil: resolveLoweredResult(destination, result)
    except CatchableError:
      owner.lockStore()
      raise

proc exportedComponentMethod(instance: ComponentInstance, path: openArray[string],
    methodName: string): ptr ComponentExport =
  if instance == nil or instance.links == nil or path.len == 0:
    componentFail("unknown component interface")
  if instance.isLocked: componentFail("component store locked after trap")
  if instance.links.interfaceExportCount() == 0: componentFail("unknown component interface")
  let root = findSurface(instance.links.interfaceExports[], path[0])
  if root < 0: componentFail("unknown component interface")
  var surface = instance.links.exportedInterface((root + 1).uint16)
  for i in 1 ..< path.len:
    var next: ptr InterfaceExport
    if surface.children != nil:
      for id in surface.children[]:
        let child = instance.links.exportedInterface(id)
        if child.name == path[i]:
          next = child
          break
    if next == nil: componentFail("unknown nested component interface: " & path[i])
    surface = next
  for i, methodExport in surface.methods:
    if methodExport.name == methodName: return addr surface.methods[i]
  componentFail("unknown component interface function")

when defined(wasmComponentAsyncCallbacks):
  const RunnableCallback = {ccsReady, ccsYielded, ccsWaiting, ccsCoreWaiting} +
    (when defined(wasmComponentThreads): {ccsThreadsWaiting} else: {})
  const TaskCancelledEvent = 6'u32

  type ComponentAsyncEvent = tuple[code, handle, state: uint32]

  proc resolved(task: ComponentSubtask): bool =
    task.state notin {cstStarting, cstStarted}

  proc publishSubtaskState(task: ComponentSubtask, state: ComponentSubtaskState) =
    task.state = state
    task.eventPending = task.handle != 0

  proc deliverResolution(task: ComponentSubtask) =
    task.lenders = nil
    task.delivered = true

  proc asyncSlot(instance: ComponentInstance, handle: uint32): ptr ComponentAsyncSlot =
    if handle == 0 or handle > instance.asyncSlots.len.uint32:
      componentFail("invalid canonical async handle")
    addr instance.asyncSlots[handle.int - 1]

  proc waitableSet(instance: ComponentInstance, handle: uint32): ComponentWaitSet =
    result = instance.asyncSlot(handle).waitSet
    if result == nil: componentFail("invalid canonical callback waitable set")

  proc subtaskAt(instance: ComponentInstance, handle: uint32): ComponentSubtask =
    result = instance.asyncSlot(handle).subtask
    if result == nil: componentFail("invalid canonical subtask handle")

  proc newAsyncSlot(instance: ComponentInstance, value: sink ComponentAsyncSlot): uint32 =
    instance.initCanonicalHandles()
    if not instance.resources.table.newAsyncHandle(result):
      componentFail("component async handle capacity exceeded")
    if result > instance.asyncSlots.len.uint32: instance.asyncSlots.setLen(result.int)
    instance.asyncSlots[result.int - 1] = move value

  proc releaseAsyncSlot(instance: ComponentInstance, handle: uint32) =
    if not instance.resources.table.dropAsyncHandle(handle):
      componentFail("invalid canonical async handle")
    instance.asyncSlots[handle.int - 1] = ComponentAsyncSlot()

  proc pendingEvent(instance: ComponentInstance, waitSet: uint32): ptr ComponentAsyncSlot =
    for slot in instance.asyncSlots.mitems:
      let task = slot.subtask
      if task != nil and task.joined == waitSet and task.eventPending:
        return addr slot
      when ComponentEndpointsEnabled:
        let endpoint = slot.endpoint
        if endpoint != nil and endpoint.joined == waitSet and endpoint.eventPending:
          return addr slot

  proc takeSubtaskEvent(task: ComponentSubtask): ComponentAsyncEvent =
    task.eventPending = false
    if task.resolved(): task.deliverResolution()
    (1'u32, task.handle, task.state.ord.uint32)

  when ComponentEndpointsEnabled:
    proc takeEndpointEvent(endpoint: ComponentEndpoint): ComponentAsyncEvent =
      let isStream = endpoint.shape.kind == cpStream
      result.code = (if isStream: 2'u32 else: 4'u32) + endpoint.writable.uint32
      result.handle = endpoint.handle
      if not isStream and endpoint.eventProgress != 0:
        endpoint.state = fcDone
      elif endpoint.other == nil:
        endpoint.state = fcDone
        result.state = 1
      else:
        if endpoint.state == fcCancelling: result.state = 2
        endpoint.state = fcIdle
      if isStream: result.state = result.state or (endpoint.eventProgress shl 4)
      endpoint.eventPending = false
      endpoint.buffer.active = false
      when defined(wasmComponentHostEndpoints): endpoint.buffer.host = nil

  proc takeEvent(instance: ComponentInstance, waitSet: uint32): ComponentAsyncEvent =
    let slot = instance.pendingEvent(waitSet)
    if slot == nil: return
    when ComponentEndpointsEnabled:
      if slot.endpoint != nil: return slot.endpoint.takeEndpointEvent()
    slot.subtask.takeSubtaskEvent()

  proc joinAsyncWaitable(instance: ComponentInstance, joined: var uint32, id: uint32) =
    let next = if id == 0: nil else: instance.waitableSet(id)
    if joined != 0: dec instance.waitableSet(joined).members
    joined = id
    if next != nil: inc next.members

  proc joinWaitable(instance: ComponentInstance, task: ComponentSubtask, id: uint32) =
    if task.cancelling: componentFail("canonical subtask is being cancelled")
    when defined(wasmComponentStackful):
      if task.cancelWaiter != nil and task.cancelWaiter[]:
        componentFail("canonical subtask is being cancelled")
    instance.joinAsyncWaitable(task.joined, id)

  when ComponentEndpointsEnabled:
    func sameEndpointType(left, right: CanonicalSlot): bool =
      if left.kind != right.kind: return false
      if left.listElement == right.listElement: return true
      left.listElement != nil and right.listElement != nil and
        left.listElement[] == right.listElement[]

    proc endpointResourceIdentity(instance: ComponentInstance,
        shape: CanonicalSlot): seq[EndpointResourceIdentity] =
      if ruOwn notin shape.resources: return
      var handles: seq[uint16]
      collectResourceTypes(shape, handles)
      for handle in handles:
        let index = resourceIndex(instance.handleTypes, handle.uint32)
        if index < 0: componentFail("unknown canonical endpoint payload resource type")
        let binding = instance.resourceOrigin(index.uint32)
        let definer = cast[ComponentInstance](binding.owner)
        result.add((definer.resources, binding.resourceIndex))

    proc endpointAt(instance: ComponentInstance, handle: uint32,
        shape: CanonicalSlot, writable: bool): ComponentEndpoint =
      result = instance.asyncSlot(handle).endpoint
      if result == nil or result.writable != writable or
          not sameEndpointType(result.shape[], shape):
        componentFail("canonical " & endpointName(shape.kind) & " endpoint type mismatch")
      if instance.endpointResourceIdentity(result.shape[]) != instance.endpointResourceIdentity(shape):
        componentFail("canonical " & endpointName(shape.kind) & " endpoint type mismatch")

    proc liftEndpointHandle(instance: ComponentInstance, slot: CanonicalSlot,
                          handle: uint32): ComponentValue =
      let endpoint = instance.endpointAt(handle, slot, writable = false)
      if endpoint.state != fcIdle or endpoint.joined != 0:
        componentFail("canonical " & endpointName(slot.kind) &
          " transfer requires an idle, unjoined reader")
      let token = ComponentEndpointValue(endpoint: endpoint,
        payloadResources: instance.endpointResourceIdentity(slot))
      endpoint.owner = nil
      endpoint.handle = 0
      instance.releaseAsyncSlot(handle)
      ComponentValue(kind: slot.kind, endpoint: token)

    proc validateEndpointValue(instance: ComponentInstance, slot: CanonicalSlot,
                             value: ComponentValue) =
      let token = value.endpoint
      if token == nil or token.endpoint == nil:
        componentFail("canonical " & endpointName(slot.kind) & " endpoint was already consumed or is invalid")
      let endpoint = token.endpoint
      if endpoint.owner != nil or endpoint.writable or endpoint.state != fcIdle or
          not sameEndpointType(endpoint.shape[], slot) or
          token.payloadResources != instance.endpointResourceIdentity(slot):
        componentFail("canonical " & endpointName(slot.kind) & " endpoint type or owner mismatch")

    proc dropLiftedEndpoint(value: ComponentValue, kind: ComponentPrim) =
      if value.kind != kind or value.endpoint == nil or value.endpoint.endpoint == nil:
        componentFail("canonical " & endpointName(kind) & " endpoint was already consumed or is invalid")
      if value.endpoint.endpoint.state in {fcCopying, fcCancelling}:
        componentFail("cannot drop a pending canonical " & endpointName(kind) & " endpoint")
      value.endpoint.endpoint[].detachEndpoint()
      value.endpoint.endpoint = nil
      value.endpoint.payloadResources.setLen(0)

    when defined(wasmComponentFutures):
      proc dropComponentFuture*(value: ComponentValue) =
        ## Release an unconsumed readable future held by the embedding.
        value.dropLiftedEndpoint(cpFuture)

    when defined(wasmComponentStreams):
      proc dropComponentStream*(value: ComponentValue) =
        ## Release an unconsumed readable stream held by the embedding.
        value.dropLiftedEndpoint(cpStream)

    proc lowerEndpointHandle(access: AbiAccess, slot: CanonicalSlot,
                           value: ComponentValue): uint32 =
      if access.resourceOwner == nil:
        componentFail("canonical endpoint lowering requires an active component")
      let instance = cast[ComponentInstance](access.resourceOwner)
      instance.validateEndpointValue(slot, value)
      let endpoint = value.endpoint.endpoint
      result = instance.newAsyncSlot(ComponentAsyncSlot(endpoint: endpoint))
      when defined(wasmComponentHostEndpoints):
        if access.endpointMoves != nil:
          access.endpointMoves[].add(EndpointLoweredHandle(handle: result, isResource: false,
            token: value.endpoint, endpoint: endpoint, shape: endpoint.shape,
            payloadResources: value.endpoint.payloadResources))
      endpoint.owner = access.resourceOwner
      endpoint.handle = result
      endpoint.shape = newSlot(slot)
      # Every lift creates a separate ticket. A copy of an older value
      # remains consumed even after the endpoint crosses another boundary.
      value.endpoint.endpoint = nil
      value.endpoint.payloadResources.setLen(0)

    proc hasEndpointWaiter(endpoint: ComponentEndpoint): bool =
      when defined(wasmComponentStackful):
        endpoint.syncWaiter != nil and endpoint.syncWaiter[]
      else: false

    const EndpointNumbers = {cpU8, cpS8, cpU16, cpS16, cpU32, cpS32, cpU64, cpS64, cpF32, cpF64}
    const MaxEndpointBufferLength = (1'u32 shl 28) - 1

    func remaining(buffer: EndpointGuestBuffer): uint32 =
      buffer.count - buffer.progress

    proc notifyEndpoint(endpoint: ptr ComponentEndpointState, progress: uint32) =
      endpoint.eventProgress = progress
      endpoint.eventPending = true

    func bufferOffset(buffer: EndpointGuestBuffer, stride: uint64): uint64 =
      buffer.offset.uint64 + buffer.progress.uint64 * stride

    proc liftEndpointBuffer(writer: ptr ComponentEndpointState, buffer: EndpointGuestBuffer,
        count: uint32, stride: uint64): ComponentValue =
      let source = cast[ComponentInstance](writer.owner)
      let sourceShape = writer.shape.listElement
      var budget = listBudget()
      result = readGenericList(source.vm.store.mems[buffer.memoryAddress],
        buffer.bufferOffset(stride), count, cpList, sourceShape, buffer.encoding, addr budget)
      if sourceShape.resources != {}:
        source.decodeOwnedResult(CanonicalSlot(kind: cpList, listElement: sourceShape,
          resources: sourceShape.resources), result)

    when defined(wasmComponentHostEndpoints):
      proc rollbackEndpointLowering(dest: ComponentInstance, moves: var seq[EndpointLoweredHandle]) =
        for i in countdown(moves.high, 0):
          let receipt = addr moves[i]
          when defined(wasmComponentErrorContext):
            if receipt.isErrorContext:
              if not dest.resources.table.dropErrorContextHandle(receipt.handle):
                componentFail("could not roll back component error-context handle")
              continue
          if receipt.isResource:
            var representation: uint64
            let status = dest.resources.table.takeOwnedRepresentation(
              receipt.handle, receipt.resourceType, representation)
            if status != crOk: componentFail("could not roll back component resource handle")
            receipt.resource.owner = move receipt.definer
            receipt.resource.graph = move receipt.graph
            receipt.resource.live = true
            inc receipt.resource.owner.outstandingOwners
          else:
            dest.releaseAsyncSlot(receipt.handle)
            receipt.endpoint.owner = nil
            receipt.endpoint.handle = 0
            receipt.endpoint.shape = move receipt.shape
            receipt.token.endpoint = move receipt.endpoint
            receipt.token.payloadResources = move receipt.payloadResources

    proc lowerEndpointBuffer(reader: ptr ComponentEndpointState, buffer: EndpointGuestBuffer,
        values: var ComponentValue, count: uint32, stride: uint64, transactional = false) =
      let dest = cast[ComponentInstance](reader.owner)
      let payload = reader.shape.listElement
      if payload.resources != {}:
        let destList = CanonicalSlot(kind: cpList, listElement: payload,
          resources: payload.resources)
        dest.requireHandleCapacity(dest.validateHostResourceResult(destList, values))
      var access = AbiAccess(vm: addr dest.vm, execution: dest.execution,
        memoryAddress: buffer.memoryAddress, reallocAddress: buffer.reallocAddress,
        encoding: buffer.encoding, resourceOwner: reader.owner)
      let offset = buffer.bufferOffset(stride)
      var budget = listBudget()
      (addr budget).charge(count.uint64, count.uint64 * stride)
      template storeValues() =
        for i, value in values.fields:
          writeAbiArgument(access, offset + i.uint64 * stride, payload[], value, addr budget)
      when defined(wasmComponentHostEndpoints):
        if transactional and payload.resources != {}:
          var moves: seq[EndpointLoweredHandle]
          access.endpointMoves = addr moves
          try:
            storeValues()
          except CatchableError:
            dest.rollbackEndpointLowering(moves)
            raise
          return
      storeValues()

    proc copyEndpointElements(reader, writer: ptr ComponentEndpointState,
        incoming, outgoing: EndpointGuestBuffer, count: uint32) =
      let payload = reader.shape.listElement
      if payload == nil: return
      let source = cast[ComponentInstance](writer.owner)
      let dest = cast[ComponentInstance](reader.owner)
      let stride = canonicalSlotLayout(payload[]).size.uint64
      when defined(wasmComponentHostEndpoints):
        if outgoing.host != nil or incoming.host != nil:
          var values: ComponentValue
          if outgoing.host == nil:
            values = liftEndpointBuffer(writer, outgoing, count, stride)
          else:
            values = ComponentValue(kind: cpList, fields: newSeqOfCap[ComponentValue](count.int))
            for i in 0 ..< count.int:
              values.fields.add(outgoing.host.values[outgoing.progress.int + i])
          if incoming.host == nil:
            lowerEndpointBuffer(reader, incoming, values, count, stride, transactional = true)
          else:
            for value in values.fields.mitems: incoming.host.values.add(move value)
          if outgoing.host != nil:
            for i in 0 ..< count.int:
              reset(outgoing.host.values[outgoing.progress.int + i])
          return
      let src = outgoing.bufferOffset(stride)
      let dst = incoming.bufferOffset(stride)
      if payload.kind in EndpointNumbers:
        let backwards = source == dest and incoming.memoryAddress == outgoing.memoryAddress and
          dst > src and dst - src < count.uint64 * stride
        for i in 0 ..< count:
          let displacement = (if backwards: count - 1 - i else: i).uint64 * stride
          let value = readAbiScalar(source.vm.store.mems[outgoing.memoryAddress],
            src + displacement, payload.kind)
          writeAbiInt(dest.vm.store.mems[incoming.memoryAddress], dst + displacement,
            stride.int, value.bits)
        return
      var values = liftEndpointBuffer(writer, outgoing, count, stride)
      lowerEndpointBuffer(reader, incoming, values, count, stride)

    proc beginEndpointCopy(endpoint: ptr ComponentEndpointState, pending: EndpointGuestBuffer) =
      endpoint.state = fcCopying
      let other = endpoint.other
      if other == nil: return  # Its drop already placed an event on this end.
      if not other.buffer.active:
        endpoint.buffer = pending
        return
      let payload = endpoint.shape.listElement
      if endpoint.owner != nil and endpoint.owner == other.owner and payload != nil and
          payload.kind notin EndpointNumbers:
        componentFail("a local " & endpointName(endpoint.shape.kind) &
          " rendezvous requires a unit or numeric payload")
      let count = min(pending.remaining(), other.buffer.remaining())
      if count != 0:
        if endpoint.writable: copyEndpointElements(other, endpoint, other.buffer, pending, count)
        else: copyEndpointElements(endpoint, other, pending, other.buffer, count)
        other.buffer.progress += count
        other.notifyEndpoint(other.buffer.progress)
        other.buffer.active = other.buffer.remaining() != 0
        endpoint.notifyEndpoint(pending.progress + count)
      elif pending.remaining() != 0 or (not endpoint.writable and other.buffer.remaining() == 0):
        # A pending zero-length peer is notified. When both are zero the
        # writer is always the one that is notified first.
        other.notifyEndpoint(0)
        other.buffer.active = false
        endpoint.buffer = pending
      else:
        endpoint.notifyEndpoint(0)

    proc copyEndpoint(instance: ComponentInstance, endpoint: ComponentEndpoint,
        buffer: EndpointGuestBuffer, asynchronous: bool): seq[WasmValue] =
      let kind = endpoint.shape.kind
      if endpoint.state != fcIdle:
        componentFail("canonical " & endpointName(kind) & " endpoint is not idle")
      if not asynchronous and endpoint.joined != 0:
        componentFail("synchronous " & endpointName(kind) & " copy cannot use a joined endpoint")
      if buffer.count > MaxEndpointBufferLength:
        componentFail("canonical stream buffer length out of range")
      let payload = endpoint.shape.listElement
      if payload != nil:
        let layout = canonicalSlotLayout(payload[])
        if buffer.offset.uint64 mod layout.alignment.uint64 != 0:
          componentFail("unaligned canonical " & endpointName(kind) & " buffer")
        let bytes = buffer.count.uint64 * layout.size.uint64
        if bytes > uint32.high: componentFail("canonical endpoint buffer size out of range")
        instance.vm.store.mems[buffer.memoryAddress].checkMemoryRange(
          buffer.offset.uint64, bytes.uint32)
      (addr endpoint[]).beginEndpointCopy(buffer)
      if endpoint.eventPending:
        return @[wasmI32(cast[int32](endpoint.takeEndpointEvent().state))]
      if asynchronous: return @[wasmI32(-1)]
      when defined(wasmComponentStackful):
        if instance.vm.canSuspendHostCall():
          let registration = new(ref ComponentCoreReservation)
          new(registration.exclusive)
          registration.exclusive[] = true
          endpoint.syncWaiter = registration.exclusive
          return instance.vm.suspendHostCall(WasmHostWait(
            ready: proc(): bool = endpoint.eventPending,
            finish: proc(): seq[WasmValue] =
              registration.exclusive[] = false
              @[wasmI32(cast[int32](endpoint.takeEndpointEvent().state))]))
      componentFail("cannot block a synchronous task before returning")

    proc cancelEndpointCopy(endpoint: ComponentEndpoint) =
      endpoint.state = fcCancelling
      if not endpoint.eventPending: (addr endpoint[]).notifyEndpoint(0)

    when defined(wasmComponentHostEndpoints):
      type HostPayloadResources = seq[tuple[index: uint16, identity: EndpointResourceIdentity]]

      proc requireHostEndpoint(token: ComponentHostEndpoint): ComponentEndpoint =
        if token == nil or token.endpoint == nil or token.endpoint.owner != nil:
          componentFail("invalid or consumed host endpoint")
        token.endpoint

      proc hostGuestPeer(endpoint: ComponentEndpoint): ComponentInstance =
        if endpoint.other == nil or endpoint.other.owner == nil: return nil
        result = cast[ComponentInstance](endpoint.other.owner)
        if result.isLocked:
          # Dropping the guest end publishes a notification on the host end.
          endpoint.other[].detachEndpoint()
          result = nil

      proc hostEndpoint*(value: ComponentValue): ComponentHostEndpoint =
        ## Any alias obtained here shares the readable value's ownership.
        if not endpointEnabled(value.kind) or value.endpoint == nil:
          componentFail("expected a readable endpoint value")
        discard value.endpoint.requireHostEndpoint()
        value.endpoint

      proc newHostPair(shape: ref CanonicalSlot, resources: seq[EndpointResourceIdentity]):
          tuple[readable: ComponentValue, writable: ComponentHostEndpoint] =
        if not endpointEnabled(shape.kind): componentFail("expected an enabled endpoint type")
        let reader = ComponentEndpoint(shape: shape)
        let writer = ComponentEndpoint(shape: shape, writable: true)
        reader.other = addr writer[]
        writer.other = addr reader[]
        (ComponentValue(kind: shape.kind, endpoint: ComponentEndpointValue(
          endpoint: reader, payloadResources: resources)),
          ComponentEndpointValue(endpoint: writer, payloadResources: resources))

      proc newComponentEndpointPair*(kind: ComponentPrim):
          tuple[readable: ComponentValue, writable: ComponentHostEndpoint] =
        ## Create a unit future or stream.
        newHostPair(newSlot(CanonicalSlot(kind: kind, resources: {ruEndpoint})), @[])

      proc newComponentEndpointPair*(kind, element: ComponentPrim):
          tuple[readable: ComponentValue, writable: ComponentHostEndpoint] =
        ## Create an endpoint with a primitive payload.
        if element notin PrimitiveValues or (kind == cpStream and element == cpChar) or
            (element == cpErrorContext and not defined(wasmComponentErrorContext)):
          componentFail("invalid primitive endpoint payload")
        let payload = plainValueSlot(element)
        newHostPair(newSlot(CanonicalSlot(kind: kind, resources: {ruEndpoint} + payload.resources,
          listElement: newSlot(payload))), @[])

      proc newComponentEndpointPair*(instance: ComponentInstance, name: string,
          parameter: int, path: openArray[string] = []):
          tuple[readable: ComponentValue, writable: ComponentHostEndpoint] =
        ## Use the declared type of an export parameter, or its result at -1.
        if instance == nil or instance.isLocked: componentFail("component cannot provide an endpoint type")
        var exportEntry: ptr ComponentExport
        if path.len != 0:
          exportEntry = instance.exportedComponentMethod(path, name)
        else:
          for i, entry in instance.exports:
            if entry.name == name:
              exportEntry = addr instance.exports[i]
              break
        if exportEntry == nil: componentFail("unknown component export")
        let (owner, entry) = instance.resolveInvocationTarget(exportEntry)
        let sig = addr entry.signature
        let slot = if parameter == -1 and sig.hasResult: resultSlot(sig[])
          elif parameter >= 0 and parameter < sig.params.len: parameterSlot(sig[], parameter)
          else: componentFail("component endpoint signature index out of range")
        if not endpointEnabled(slot.kind): componentFail("expected an enabled endpoint type")
        newHostPair(newSlot(slot), owner.endpointResourceIdentity(slot))

      proc hostResourceIdentity(resources: HostPayloadResources, index: uint16):
          EndpointResourceIdentity =
        for item in resources:
          if item.index == index: return item.identity
        componentFail("unknown host endpoint resource type")

      proc validateBufferedResource(slot: CanonicalSlot, value: ComponentValue,
          resources: HostPayloadResources, prepared: var PreparedResources) =
        when defined(wasmComponentErrorContext):
          if slot.kind == cpErrorContext:
            if value.errorContext == nil: componentFail("invalid component error-context value")
            return
        if slot.kind in {cpFuture, cpStream}:
          let token = value.hostEndpoint()
          let endpoint = token.requireHostEndpoint()
          if endpoint.state != fcIdle or endpoint.writable or not sameEndpointType(endpoint.shape[], slot):
            componentFail("host endpoint payload type or state mismatch")
          var indices: seq[uint16]
          collectResourceTypes(slot, indices)
          var expected: seq[EndpointResourceIdentity]
          for index in indices: expected.add(resources.hostResourceIdentity(index))
          if token.payloadResources != expected or token in prepared.endpointValues:
            componentFail("host endpoint payload resource identity or ownership mismatch")
          prepared.endpointValues.add(token)
          return
        let owner = value.resource
        if slot.kind != cpOwnedResource or not value.ownsResource or owner == nil or
            not owner.live or owner.owner == nil or owner.owner.isLocked or owner.lends != 0 or
            owner in prepared.owners or (owner.owner.resources, owner.resourceIndex) !=
              resources.hostResourceIdentity(slot.resourceType):
          componentFail("host endpoint resource payload type or ownership mismatch")
        prepared.owners.add(owner)

      proc checkHostPayload(slot: CanonicalSlot, value: ComponentValue, budget: ptr AbiListBudget) =
        if value.kind != slot.kind: componentFail("host endpoint payload type mismatch")
        case slot.kind
        of cpRecord, cpTuple:
          if value.fields.len != slot.recordShape.fields.len:
            componentFail("host endpoint record field count mismatch")
          budget.charge(value.fields.len.uint64, 0)
          for i, field in slot.recordShape.fields:
            checkHostPayload(fieldSlot(field), value.fields[i], budget)
        of cpFixedList, cpList, cpMap:
          if slot.kind == cpFixedList: requireFixedListLength(slot, value)
          let stride = canonicalSlotLayout(slot.listElement[]).size.uint64
          budget.charge(value.fields.len.uint64, value.fields.len.uint64 * stride)
          for field in value.fields: checkHostPayload(slot.listElement[], field, budget)
        of cpOption, cpVariant, cpEnum, cpResult:
          if value.caseIndex >= slot.cases.len.uint32:
            componentFail("host endpoint variant case out of range")
          let selected = slot.cases[value.caseIndex.int]
          if value.fields.len != selected.hasPayload.int:
            componentFail("host endpoint variant payload count mismatch")
          if selected.hasPayload:
            budget.charge(1, 0)
            checkHostPayload(caseSlot(selected), value.fields[0], budget)
        of cpFlags:
          if (value.bits and not flagMask(slot.cases.len).uint64) != 0:
            componentFail("host endpoint flags out of range")
        of cpString:
          if value.text.len > MaxComponentStringBytes or not validWasmName(value.text):
            componentFail("invalid host endpoint string")
          budget.charge(0, value.text.len.uint64)
        of cpBytes:
          if value.bytes.len > MaxComponentByteListBytes: componentFail("host endpoint byte list limit")
          budget.charge(0, value.bytes.len.uint64)
        of cpU32List, cpU64List:
          let width = if slot.kind == cpU32List: 4 else: 8
          let kind = if slot.kind == cpU32List: cpU32 else: cpU64
          let bytes = value.fields.len.uint64 * width.uint64
          if bytes > MaxComponentByteListBytes.uint64: componentFail("host endpoint integer list limit")
          budget.charge(value.fields.len.uint64, bytes)
          for item in value.fields:
            if item.kind != kind: componentFail("host endpoint integer list type mismatch")
            discard lower(item)
        of cpOwnedResource, cpFuture, cpStream, cpErrorContext: discard
        else: discard lower(value)

      proc moveBufferedResource(slot: CanonicalSlot, value: var ComponentValue) =
        # Only the buffer owns these values after submission. On cancel or
        # partial completion the unused suffix transfers back to the caller.
        if slot.kind == cpErrorContext: return
        if slot.kind in {cpFuture, cpStream}:
          let original = value.endpoint
          value.endpoint = ComponentEndpointValue(endpoint: move original.endpoint,
            payloadResources: move original.payloadResources)
        else:
          let original = value.resource
          value.resource = ComponentOwnedValue(owner: move original.owner,
            graph: move original.graph, resourceIndex: original.resourceIndex,
            representation: original.representation, live: true)
          original.live = false   # The owner's outstanding count moves with the value.

      proc snapshotHostValues(token: ComponentHostEndpoint, payload: CanonicalSlot,
          source: openArray[ComponentValue]): seq[ComponentValue] =
        result = @source
        var budget = listBudget()
        let stride = canonicalSlotLayout(payload).size.uint64
        (addr budget).charge(source.len.uint64, source.len.uint64 * stride)
        for value in result: checkHostPayload(payload, value, addr budget)
        if payload.resources == {}: return
        var indices: seq[uint16]
        collectResourceTypes(payload, indices)
        var resources: HostPayloadResources
        for i, index in indices:
          resources.add((index, token.payloadResources[i]))
        var prepared: PreparedResources
        let validate = proc(slot: CanonicalSlot, value: var ComponentValue) =
          validateBufferedResource(slot, value, resources, prepared)
        for value in result.mitems: visitResourceLeaves(payload, value, validate)
        for value in result.mitems: visitResourceLeaves(payload, value, moveBufferedResource)

      proc pollComponentEndpoint*(token: ComponentHostEndpoint): ComponentEndpointResult =
        ## Consumes one notification. A pending result does not release the buffer.
        let endpoint = token.requireHostEndpoint()
        discard endpoint.hostGuestPeer()
        if not endpoint.eventPending:
          result.status = if endpoint.state == fcCopying: cesPending else: cesIdle
          return
        let progress = endpoint.eventProgress
        let code = endpoint.takeEndpointEvent().state and 0x0f
        result.count = progress
        result.status = case code
          of 0: cesCompleted
          of 1: cesDropped
          else: cesCancelled
        let operation = move token.operation
        if operation == nil: return
        if endpoint.writable:
          for i in progress.int ..< operation.values.len:
            result.values.add(move operation.values[i])
        else:
          result.values = move operation.values

      proc prepareHostCopy(token: ComponentHostEndpoint, writable: bool,
          count: uint32): ComponentEndpoint =
        result = token.requireHostEndpoint()
        if result.state != fcIdle or result.writable != writable:
          componentFail("host endpoint copy requires an idle endpoint in the requested direction")
        if count > MaxEndpointBufferLength or (result.shape.kind == cpFuture and count != 1):
          componentFail("invalid host endpoint copy length")
        if result.shape.listElement != nil and count > MaxGenericListValues.uint32:
          componentFail("host endpoint buffer exceeds profile limit")
        let peer = result.hostGuestPeer()
        if peer != nil and not peer.execution.mayLeave:
          componentFail("host endpoint cannot enter canonical realloc or post-return")

      proc beginHostCopy(token: ComponentHostEndpoint, endpoint: ComponentEndpoint,
          count: uint32, buffer: ComponentHostBuffer): ComponentEndpointResult =
        token.operation = buffer
        try:
          (addr endpoint[]).beginEndpointCopy(
            EndpointGuestBuffer(count: count, active: true, host: buffer))
        except CatchableError as error:
          if endpoint.other != nil and endpoint.other.owner != nil:
            cast[ComponentInstance](endpoint.other.owner).lockStore()
          endpoint[].detachEndpoint()
          (addr endpoint[]).notifyEndpoint(0)
          if error of WasmTrap: componentFail("component endpoint copy trap: " & error.msg)
          raise
        token.pollComponentEndpoint()

      proc readComponentEndpoint*(token: ComponentHostEndpoint,
          count = 1'u32): ComponentEndpointResult =
        let endpoint = token.prepareHostCopy(false, count)
        let buffer = ComponentHostBuffer()
        if endpoint.shape.listElement != nil:
          buffer.values = newSeqOfCap[ComponentValue](count.int)
        token.beginHostCopy(endpoint, count, buffer)

      proc writeComponentEndpoint*(token: ComponentHostEndpoint,
          values: openArray[ComponentValue]): ComponentEndpointResult =
        if values.len > MaxGenericListValues: componentFail("host endpoint buffer exceeds profile limit")
        let endpoint = token.prepareHostCopy(true, values.len.uint32)
        let payload = endpoint.shape.listElement
        if payload == nil: componentFail("use writeComponentUnits for a unit payload")
        let buffer = ComponentHostBuffer(values: token.snapshotHostValues(payload[], values))
        token.beginHostCopy(endpoint, values.len.uint32, buffer)

      proc writeComponentUnits*(token: ComponentHostEndpoint,
          count = 1'u32): ComponentEndpointResult =
        let endpoint = token.prepareHostCopy(true, count)
        if endpoint.shape.listElement != nil: componentFail("expected a unit endpoint payload")
        token.beginHostCopy(endpoint, count, ComponentHostBuffer())

      proc cancelComponentEndpoint*(token: ComponentHostEndpoint): ComponentEndpointResult =
        let endpoint = token.requireHostEndpoint()
        if endpoint.state != fcCopying: componentFail("host endpoint has no copy to cancel")
        endpoint.cancelEndpointCopy()
        token.pollComponentEndpoint()

      proc closeComponentEndpoint*(token: ComponentHostEndpoint) =
        ## A pending copy must be consumed or cancelled before explicit close.
        let endpoint = token.requireHostEndpoint()
        if endpoint.state in {fcCopying, fcCancelling}:
          componentFail("cannot close a pending host endpoint")
        endpoint[].detachEndpoint()
        token.endpoint = nil
        token.payloadResources.setLen(0)

    proc dropEndpoint(instance: ComponentInstance, endpoint: ComponentEndpoint) =
      instance.joinAsyncWaitable(endpoint.joined, 0)
      endpoint[].detachEndpoint()
      instance.releaseAsyncSlot(endpoint.handle)

    proc forwardEndpoint(instance: ComponentInstance, reader, writer: ComponentEndpoint) =
      if reader.state != fcIdle or writer.state != fcIdle or reader.joined != 0 or writer.joined != 0:
        componentFail("canonical " & endpointName(reader.shape.kind) &
          " forward requires idle, unjoined endpoints")
      let source = reader.other
      let dest = writer.other
      if source == nil or dest == nil or source == addr writer[]:
        instance.dropEndpoint(reader)
        instance.dropEndpoint(writer)
        return
      reader.other = nil
      writer.other = nil
      source.other = dest
      dest.other = source
      if source.buffer.active and dest.buffer.active:
        let first = if dest.buffer.remaining() < source.buffer.remaining(): dest else: source
        let buffer = first.buffer
        first.buffer.active = false
        first.beginEndpointCopy(buffer)
      instance.releaseAsyncSlot(reader.handle)
      instance.releaseAsyncSlot(writer.handle)

    proc makeEndpointBuiltin(instance: ComponentInstance, lowering: CoreLowering): HostFunc =
      let owner = cast[pointer](instance)
      let kind = lowering.kind
      let shape = lowering.endpointShape
      let asynchronous = lowering.asyncCancel
      let memoryAddress = if lowering.memoryInstance == 0: -1
        else: instance.coreExport(lowering.memoryInstance, lowering.memoryName, ekMemory)
      let reallocAddress = if lowering.reallocSource == 0: -1
        else: instance.coreExport(lowering.reallocSource, lowering.reallocName, ekFunc)
      let encoding = lowering.stringEncoding
      result = proc(args: openArray[WasmValue]): seq[WasmValue] =
        let inst = cast[ComponentInstance](owner)
        if not inst.execution.mayLeave:
          componentFail("canonical " & endpointName(shape.kind) & " builtin cannot leave")
        if kind == clEndpointNew:
          inst.initCanonicalHandles()
          if not inst.resources.table.hasResourceCapacity(2):
            componentFail("component async handle capacity exceeded")
          let reader = ComponentEndpoint(shape: shape, owner: owner)
          let writer = ComponentEndpoint(shape: shape, owner: owner, writable: true)
          reader.handle = inst.newAsyncSlot(ComponentAsyncSlot(endpoint: reader))
          writer.handle = inst.newAsyncSlot(ComponentAsyncSlot(endpoint: writer))
          reader.other = addr writer[]
          writer.other = addr reader[]
          return @[wasmI64(cast[int64](reader.handle.uint64 or (writer.handle.uint64 shl 32)))]
        let writable = kind in {clEndpointWrite, clEndpointCancelWrite, clEndpointDropWritable}
        let endpoint = inst.endpointAt(args[0].i32.uint32, shape[], writable)
        case kind
        of clEndpointRead, clEndpointWrite:
          let count = if shape.kind == cpStream: args[2].i32.uint32 else: 1'u32
          return inst.copyEndpoint(endpoint, EndpointGuestBuffer(memoryAddress: memoryAddress,
            reallocAddress: reallocAddress, offset: args[1].i32.uint32, encoding: encoding,
            count: count, active: true), asynchronous)
        of clEndpointCancelRead, clEndpointCancelWrite:
          if endpoint.state != fcCopying or endpoint.hasEndpointWaiter() or
              (not asynchronous and endpoint.joined != 0):
            componentFail("canonical " & endpointName(shape.kind) & " copy cannot be cancelled")
          endpoint.cancelEndpointCopy()
          return @[wasmI32(cast[int32](endpoint.takeEndpointEvent().state))]
        of clEndpointDropReadable, clEndpointDropWritable:
          if endpoint.state in {fcCopying, fcCancelling}:
            componentFail("cannot drop a pending canonical " & endpointName(shape.kind) & " endpoint")
          if shape.kind == cpFuture and writable and endpoint.state != fcDone:
            componentFail("cannot drop future write end without first writing a value")
          inst.dropEndpoint(endpoint)
        of clEndpointForward:
          inst.forwardEndpoint(endpoint, inst.endpointAt(args[1].i32.uint32, shape[], true))
        else: componentFail("invalid canonical endpoint builtin")

  proc leaveWait(registration: var ComponentWaitRegistration) =
    if registration.waitSet == nil: return
    dec registration.waitSet.waiters
    registration.waitSet = nil
    registration.id = 0

  proc storeWaitableEvent(instance: ComponentInstance, memoryAddress: int,
      offset: uint64, event: ComponentAsyncEvent): seq[WasmValue] =
    if (offset and 3) != 0: componentFail("unaligned canonical waitable event area")
    let memory = addr instance.vm.store.mems[memoryAddress]
    memory[].checkMemoryRange(offset, 8)
    writeAbiInt(memory[], offset, 4, event.handle)
    writeAbiInt(memory[], offset + 4, 4, event.state)
    @[wasmI32(event.code.int32)]

  when defined(wasmComponentStackful):
    proc waitForSubtaskCancel(instance: ComponentInstance,
        task: ComponentSubtask): seq[WasmValue] =
      let registration = new(ref ComponentCoreReservation)
      new(registration.exclusive)
      registration.exclusive[] = true
      task.cancelWaiter = registration.exclusive
      instance.vm.suspendHostCall(WasmHostWait(
        ready: proc(): bool = task.resolved(),
        finish: proc(): seq[WasmValue] =
          registration.exclusive[] = false
          @[wasmI32(task.takeSubtaskEvent().state.int32)]))

    proc waitForSet(instance: ComponentInstance, memoryAddress: int,
        id: uint32, offset: uint64): seq[WasmValue] =
      let set = instance.waitableSet(id)
      if instance.pendingEvent(id) != nil:
        return instance.storeWaitableEvent(memoryAddress, offset, instance.takeEvent(id))
      if not instance.vm.canSuspendHostCall():
        componentFail("cannot block a synchronous task before returning")
      let registration = new(ref ComponentWaitRegistration)
      inc set.waiters
      registration.id = id
      registration.waitSet = set
      let owner = cast[pointer](instance)
      instance.vm.suspendHostCall(WasmHostWait(
        ready: proc(): bool =
          cast[ComponentInstance](owner).pendingEvent(registration.id) != nil,
        finish: proc(): seq[WasmValue] =
          let inst = cast[ComponentInstance](owner)
          let id = registration.id
          registration[].leaveWait()
          inst.storeWaitableEvent(memoryAddress, offset, inst.takeEvent(id))))

  proc cancelSubtask(task: ComponentSubtask, asynchronous: bool): int32

  when defined(wasmComponentThreads):
    proc guestThreadReady(thread: ComponentGuestThread, switching = false): bool

    proc pauseGuestThread(instance: ComponentInstance, yielding: bool,
                         next: ComponentGuestThread = nil): seq[WasmValue] =
      if not instance.vm.canSuspendHostCall():
        componentFail("cannot block a synchronous task before returning")
      let thread = instance.execution.thread
      thread.state = if yielding: cgtReady else: cgtSuspended
      if next != nil:
        next.state = cgtReady
        instance.links.store.switchTarget = next
      let saved = cast[pointer](thread)
      instance.vm.suspendHostCall(WasmHostWait(
        ready: proc(): bool = cast[ComponentGuestThread](saved).state in {cgtReady, cgtRunning},
        finish: proc(): seq[WasmValue] = @[wasmI32(0)]))

    proc makeThreadBuiltin(instance: ComponentInstance, lowering: CoreLowering): HostFunc =
      let owner = cast[pointer](instance)
      let kind = lowering.kind
      let closureType = lowering.threadClosure
      let tableAddress = if kind == clThreadNewIndirect:
          instance.coreExport(lowering.threadTable, lowering.threadTableName, ekTable)
        else: -1
      when defined(wasmComponentThreadSpawn):
        let signature = lowering.threadSignature
      result = proc(args: openArray[WasmValue]): seq[WasmValue] =
        if kind == clThreadAvailableParallelism:
          return @[wasmI32(1)]
        let inst = cast[ComponentInstance](owner)
        let thread = inst.execution.thread
        if not inst.execution.mayLeave or thread == nil:
          componentFail("canonical thread builtin has no active guest thread")
        case kind
        of clThreadIndex:
          return @[wasmI32(thread.id.int32)]
        of clThreadNewIndirect, clThreadSpawnRef:
          let spawning = kind == clThreadSpawnRef
          let value = if spawning: args[0] else:
            block:
              let index = args[0].i32.uint32
              let table = addr inst.vm.store.tables[tableAddress]
              if index >= table.elems.len.uint32:
                componentFail("canonical thread table index out of bounds")
              table.elems[index.int]
          if value.kind != wvkFuncRef or value.funcRef < 0:
            if spawning: componentFail("canonical thread.spawn-ref target is null")
            componentFail("canonical thread table entry is null")
          let address = value.funcRef.int
          if address >= inst.vm.store.funcs.len:
            componentFail("invalid canonical thread table function reference")
          let function = addr inst.vm.store.funcs[address]
          if spawning:
            when defined(wasmComponentThreadSpawn):
              if not function.funcType.matchesCoreFunctionType(signature[]):
                componentFail("canonical thread.spawn-ref target has the wrong function type")
            else: componentFail("canonical thread spawning is disabled")
          elif function.funcType.params != @[closureType] or function.funcType.results.len != 0:
            componentFail("canonical thread table entry has the wrong function type")
          let newThread = ComponentGuestThread(invocation: thread.invocation,
            core: ComponentCoreTurn(address: address), closure: args[1],
            state: if spawning: cgtReady else: cgtSuspended)
          if not inst.registerThread(newThread):
            if spawning: componentFail("canonical thread.spawn-ref capacity exceeded")
            return @[wasmI32(-1)]
          inc thread.invocation.explicitThreads
          return @[wasmI32(newThread.id.int32)]
        of clThreadSuspend:
          return inst.pauseGuestThread(false)
        of clThreadResumeLater, clThreadSuspendResume, clThreadYieldResume,
            clThreadSuspendPromote, clThreadYieldPromote:
          let target = inst.threadAt(args[0].i32.uint32)
          if target == nil: componentFail("unknown canonical thread index")
          if target == thread: componentFail("cannot switch to the current canonical thread")
          let promote = kind in {clThreadSuspendPromote, clThreadYieldPromote}
          if not promote and target.state != cgtSuspended:
            componentFail("canonical thread is not suspended")
          if kind == clThreadResumeLater:
            target.state = cgtReady
          else:
            let next = if not promote or target.guestThreadReady(switching = true): target else: nil
            return inst.pauseGuestThread(kind in {clThreadYieldResume, clThreadYieldPromote}, next)
        else: componentFail("invalid canonical thread builtin")

  proc makeAsyncBuiltin(instance: ComponentInstance, lowering: CoreLowering): HostFunc =
    let owner = cast[pointer](instance)
    let kind = lowering.kind
    let asynchronous = lowering.asyncCancel
    let memoryAddress = if lowering.memoryInstance == 0: -1
      else: instance.coreExport(lowering.memoryInstance, lowering.memoryName, ekMemory)
    result = proc(args: openArray[WasmValue]): seq[WasmValue] =
      let inst = cast[ComponentInstance](owner)
      if kind notin {clBackpressureInc, clBackpressureDec} and not inst.execution.mayLeave:
        componentFail("canonical async builtin cannot leave")
      case kind
      of clWaitableSetNew:
        return @[wasmI32(inst.newAsyncSlot(ComponentAsyncSlot(waitSet: ComponentWaitSet())).int32)]
      of clWaitableSetDrop:
        let id = args[0].i32.uint32
        let waitSet = inst.waitableSet(id)
        if waitSet.members != 0 or waitSet.waiters != 0:
          componentFail("canonical waitable set is in use")
        inst.releaseAsyncSlot(id)
      of clWaitableJoin:
        let handle = args[0].i32.uint32
        let id = args[1].i32.uint32
        when ComponentEndpointsEnabled:
          let endpoint = inst.asyncSlot(handle).endpoint
          if endpoint != nil:
            if endpoint.hasEndpointWaiter():
              componentFail("cannot join a synchronously awaited canonical " &
                endpointName(endpoint.shape.kind))
            inst.joinAsyncWaitable(endpoint.joined, id)
            return
        inst.joinWaitable(inst.subtaskAt(handle), id)
      of clWaitableSetPoll:
        let id = args[0].i32.uint32
        discard inst.waitableSet(id)
        let offset = args[1].i32.uint32.uint64
        return inst.storeWaitableEvent(memoryAddress, offset, inst.takeEvent(id))
      of clWaitableSetWait:
        when defined(wasmComponentStackful):
          return inst.waitForSet(memoryAddress, args[0].i32.uint32, args[1].i32.uint32.uint64)
        else: componentFail("invalid canonical async builtin")
      of clThreadYield:
        when defined(wasmComponentStackful):
          if inst.vm.canSuspendHostCall():
            when defined(wasmComponentThreads):
              if inst.execution.thread != nil: return inst.pauseGuestThread(true)
            return inst.vm.suspendHostCall(WasmHostWait(
              ready: proc(): bool = true,
              finish: proc(): seq[WasmValue] = @[wasmI32(0)]))
          return @[wasmI32(0)]
        else: componentFail("invalid canonical async builtin")
      of clTaskCancel:
        let task = inst.execution.callbackTask
        if task == nil or task.resolution != ccrCancelDelivered:
          componentFail("canonical task.cancel requires a delivered cancellation")
        inst.checkTaskBorrows()
        cast[ComponentSubtask](task.subtask).publishSubtaskState(cstCancelledBeforeReturn)
        task.resolution = ccrCancelled
      of clSubtaskCancel:
        let task = inst.subtaskAt(args[0].i32.uint32)
        let state = task.cancelSubtask(asynchronous)
        when defined(wasmComponentStackful):
          if state == -1 and not asynchronous:
            return inst.waitForSubtaskCancel(task)
        return @[wasmI32(state)]
      of clSubtaskDrop:
        let id = args[0].i32.uint32
        let task = inst.subtaskAt(id)
        if not task.delivered: componentFail("canonical subtask result has not been delivered")
        inst.joinWaitable(task, 0)
        task.handle = 0
        inst.releaseAsyncSlot(id)
      of clBackpressureInc:
        if inst.backpressure == uint16.high: componentFail("canonical backpressure overflow")
        inc inst.backpressure
      of clBackpressureDec:
        if inst.backpressure == 0: componentFail("canonical backpressure underflow")
        dec inst.backpressure
      else: componentFail("invalid canonical async builtin")

  proc queueCallback(instance: ComponentInstance, exported: ptr ComponentExport,
      args: openArray[ComponentValue]): ComponentInvocation =
    let (owner, entry) = instance.resolveInvocationTarget(exported)
    if not entry[].scheduledLift(): componentFail("component export is not a polled canonical lift")
    if args.len != entry.signature.params.len: componentFail("component argument count mismatch")
    checkArgumentKinds(entry.signature, args)
    var task = CanonicalCallbackTask(memoryAddress: -1, encoding: entry.stringEncoding)
    if entry.coreSources[clsMemory] != 0:
      task.memoryAddress = owner.coreExport(entry.coreSources[clsMemory], entry.memoryName, ekMemory)
    result = ComponentInvocation(owner: cast[pointer](owner),
      entry: entry[], args: @args, task: move task)
    result.task.signature = addr result.entry.signature

  proc hasCallbackExport*(instance: ComponentInstance, name: string): bool =
    ## True for an async export that can be driven using pollCallback.
    if instance == nil: return false
    for i, exported in instance.exports:
      if exported.name == name:
        return instance.resolveInvocationTarget(addr instance.exports[i]).entry[].scheduledLift()

  proc beginCallback*(instance: ComponentInstance, name: string,
      args: openArray[ComponentValue]): ComponentCallback =
    ## Queue a typed callback invocation. Guest execution begins on poll.
    if instance == nil: componentFail("unknown component export")
    if instance.isLocked: componentFail("component store locked after trap")
    for i, exported in instance.exports:
      if exported.name == name:
        return ComponentCallback(graph: instance,
          invocation: instance.queueCallback(addr instance.exports[i], args))
    componentFail("unknown component export")

  proc beginCallback*(instance: ComponentInstance, path: openArray[string], name: string,
      args: openArray[ComponentValue]): ComponentCallback =
    ComponentCallback(graph: instance,
      invocation: instance.queueCallback(instance.exportedComponentMethod(path, name), args))

  when defined(wasmComponentStackful):
    proc coreTurnAvailable(instance: ComponentInstance, invocation: ComponentInvocation = nil): bool =
      let exclusive = instance.pausedExclusive
      exclusive == nil or not exclusive[] or
        (invocation != nil and (invocation.entry.stackful or
          (invocation.core != nil and invocation.core.reservation.exclusive == exclusive)))

    proc resumeGuestCore(turn: ComponentCoreTurn, instance: ComponentInstance,
        args: openArray[WasmValue], lanes: var seq[WasmValue]): bool =
      instance.vm.swapWasmExecutionArena(turn.arena)
      defer: instance.vm.swapWasmExecutionArena(turn.arena)
      while true:
        lanes = instance.vm.executeSlice(turn.address, args, turn.continuation, uint32.high)
        case turn.continuation.status
        of wesComplete: return true
        of wesHostBlocked, wesAtomicBlocked, wesYielded: return false
        of wesMemoryBlocked:
          when defined(wasmChunkedMemory):
            if instance.vm.serviceExecutionMemoryFault(turn.continuation) == lmOk: continue
          componentFail("canonical core memory fault could not be serviced")
        else: componentFail("invalid canonical core continuation state")

    proc runCoreTurn(invocation: ComponentInvocation, instance: ComponentInstance,
        address: int, args: openArray[WasmValue], lanes: var seq[WasmValue]): bool =
      if invocation.core == nil:
        invocation.core = ComponentCoreTurn(arena: initWasmExecutionArena(), address: address)
      let turn = invocation.core
      when defined(wasmComponentThreads):
        # Readiness can be queried by a promotion from inside this turn.
        if not invocation.entry.stackful and turn.reservation.exclusive == nil:
          new(turn.reservation.exclusive)
          turn.reservation.exclusive[] = true
          instance.pausedExclusive = turn.reservation.exclusive
      if turn.resumeGuestCore(instance, args, lanes):
        invocation.core = nil
        return true
      when not defined(wasmComponentThreads):
        if not invocation.entry.stackful and turn.reservation.exclusive == nil:
          new(turn.reservation.exclusive)
          turn.reservation.exclusive[] = true
          instance.pausedExclusive = turn.reservation.exclusive
      invocation.state = ccsCoreWaiting

  proc callbackRunnable(invocation: ComponentInvocation, guestTurn = false): bool =
    let instance = cast[ComponentInstance](invocation.owner)
    if invocation.state notin RunnableCallback or
        (not guestTurn and instance.activeEntries != 0 and not invocation.entry.stackfulLift()):
      return false
    when defined(wasmComponentStackful):
      if not instance.coreTurnAvailable(invocation): return false
    case invocation.state
    of ccsReady: instance.backpressure == 0 and
      (instance.execution.context == nil or invocation.entry.stackfulLift())
    of ccsWaiting:
      invocation.task.resolution == ccrCancelPending or
        instance.pendingEvent(invocation.waiting.id) != nil
    of ccsCoreWaiting:
      when defined(wasmComponentStackful):
        instance.vm.executionRunnable(invocation.core.continuation)
      else: false
    of ccsThreadsWaiting: false
    else: true

  when defined(wasmComponentThreads):
    proc guestThreadReady(thread: ComponentGuestThread, switching = false): bool =
      if thread.implicit and thread.directResults == nil:
        return thread.state in {cgtReady, cgtWaiting} and
          thread.invocation.callbackRunnable(guestTurn = switching)
      case thread.state
      of cgtReady: true
      of cgtWaiting:
        let instance = cast[ComponentInstance](thread.owner)
        instance.vm.executionRunnable(thread.core.continuation)
      else: false

    proc settleGuestThreadTask(invocation: ComponentInvocation) =
      if invocation.state == ccsThreadsWaiting and invocation.explicitThreads == 0:
        invocation.state = if invocation.task.resolution in {ccrReturned, ccrCancelled}:
          ccsComplete else: ccsUnresolved

    proc finishImplicitThread(instance: ComponentInstance, thread: ComponentGuestThread) =
      let invocation = thread.invocation
      if invocation.state in {ccsComplete, ccsUnresolved, ccsTrapped}:
        instance.retireThread(thread)
        invocation.implicitId = 0
        if invocation.state != ccsTrapped and invocation.explicitThreads != 0:
          invocation.state = ccsThreadsWaiting
      elif thread.state == cgtRunning: thread.state = cgtWaiting

  proc pinTaskBorrows(instance: ComponentInstance, prepared: var PreparedResources):
      TaskBorrowScope =
    if prepared.borrows.len == 0: return nil
    let resources = instance.resources
    var id = 0'u32
    if prepared.foreignBorrows != 0:
      # Keep stackful scopes disjoint from the small synchronous nesting IDs.
      const FirstTaskScope = 0x80000000'u32
      while true:
        resources.nextBorrowScope =
          if resources.nextBorrowScope < FirstTaskScope or resources.nextBorrowScope == uint32.high:
            FirstTaskScope
          else: resources.nextBorrowScope + 1
        id = resources.nextBorrowScope
        if resources.findBorrowScope(id) == nil: break
    prepared.pinBorrowArguments()
    result = TaskBorrowScope(resources: resources, id: id, pins: move prepared.borrows)
    resources.taskBorrowScopes.add(cast[pointer](result))

  proc pollCallbackCore(invocation: ComponentInvocation, guestTurn = false): ComponentCallbackState =
    ## A blocking host import saves guest frames in the current turn's arena.
    if invocation.state notin RunnableCallback: return invocation.state
    let instance = cast[ComponentInstance](invocation.owner)
    if instance.isLocked: componentFail("component store locked after trap")
    if not instance.execution.mayLeave or
        (not guestTurn and instance.activeEntries != 0 and not invocation.entry.stackfulLift()):
      componentFail("canonical callback cannot enter an active component")
    if not invocation.callbackRunnable(guestTurn): return invocation.state
    let entry = addr invocation.entry
    var prepared: PreparedResources
    if invocation.state == ccsReady and entry.signature.parameterResources() != {}:
      prepared = instance.collectHostResources(entry.signature, invocation.args)
      instance.requireHandleCapacity(prepared.preparedHandleCount())
    let store = instance.links.store
    if store.activeCallbackTurns.int >= MaxComponentCallDepth:
      componentFail("component callback depth exceeds profile limit")
    inc instance.activeEntries
    inc store.activeCallbackTurns
    let execution = instance.execution
    let previous = execution.context
    let previousTask = execution.callbackTask
    let previousScope = execution.borrowScope
    when defined(wasmComponentThreads):
      let previousThread = execution.thread
      let previousSecond = execution.contextSecond
      if invocation.implicitId == 0:
        let thread = ComponentGuestThread(implicit: true, invocation: invocation)
        if not instance.registerThread(thread):
          dec instance.activeEntries
          dec store.activeCallbackTurns
          componentFail("component guest thread capacity exceeded")
        invocation.implicitId = thread.id
      let thread = instance.threadAt(invocation.implicitId)
      thread.state = cgtRunning
      execution.thread = thread
      execution.contextSecond = addr thread.contextSecond
    if invocation.state == ccsReady and prepared.borrows.len != 0:
      invocation.borrows = instance.pinTaskBorrows(prepared)
    execution.context = addr invocation.context
    execution.callbackTask = if entry[].usesAsyncLiftAbi(): addr invocation.task else: nil
    execution.borrowScope = if invocation.borrows == nil: 0'u32 else: invocation.borrows.id
    defer:
      execution.callbackTask = previousTask
      execution.borrowScope = previousScope
      execution.context = previous
      when defined(wasmComponentThreads):
        execution.thread = previousThread
        execution.contextSecond = previousSecond
        instance.finishImplicitThread(thread)
      dec instance.activeEntries
      dec store.activeCallbackTurns
    try:
      var lanes: seq[WasmValue]
      var callbackAddress = -1
      template executeCore(address: int, args: untyped) =
        when defined(wasmComponentStackful):
          if not invocation.runCoreTurn(instance, address, args, lanes): return invocation.state
        else:
          lanes = instance.vm.execute(address, args)
      if invocation.state == ccsCoreWaiting:
        executeCore(-1, [])
      elif invocation.state == ccsReady:
        let address = instance.coreExport(entry.coreSources[clsFunction], entry.coreName, ekFunc)
        let args = instance.prepareCoreArguments(entry[], invocation.args)
        invocation.args.setLen(0)
        executeCore(address, args)
      else:
        callbackAddress = instance.coreExport(entry.callbackSource, entry.callbackName, ekFunc)
        var event: ComponentAsyncEvent
        if invocation.task.resolution == ccrCancelPending:
          invocation.task.resolution = ccrCancelDelivered
          event.code = TaskCancelledEvent
        elif invocation.state == ccsWaiting:
          event = instance.takeEvent(invocation.waiting.id)
        invocation.waiting.leaveWait()
        executeCore(callbackAddress, [wasmI32(event.code.int32),
          wasmI32(event.handle.int32), wasmI32(event.state.int32)])
      when defined(wasmComponentStackful):
        if not entry[].usesAsyncLiftAbi():
          instance.checkTaskBorrows()
          invocation.task.values = instance.liftCoreResults(entry[], lanes)
          invocation.task.returnTaskResult()
          instance.finishLift(entry[], lanes)
          invocation.state = ccsComplete
          return invocation.state
      if entry[].stackfulLift():
        if lanes.len != 0: componentFail("invalid canonical stackful core result")
        invocation.state = if invocation.task.resolution in {ccrReturned, ccrCancelled}:
          ccsComplete else: ccsUnresolved
        return invocation.state
      template callbackCode(): uint32 =
        if lanes.len != 1 or lanes[0].kind != wvkI32:
          componentFail("invalid canonical callback result")
        lanes[0].i32.uint32 and 0xF
      var code = callbackCode()
      if (code == 1 or code == 2) and invocation.task.resolution == ccrCancelPending:
        # A nested core call may request cancellation during this turn. Deliver
        # it before releasing exclusivity or checking the returned wait set.
        if callbackAddress < 0:
          callbackAddress = instance.coreExport(entry.callbackSource, entry.callbackName, ekFunc)
        invocation.task.resolution = ccrCancelDelivered
        executeCore(callbackAddress, [wasmI32(TaskCancelledEvent.int32), wasmI32(0), wasmI32(0)])
        code = callbackCode()
      case code
      of 0:
        invocation.state = if invocation.task.resolution in {ccrReturned, ccrCancelled}:
          ccsComplete else: ccsUnresolved
      of 1: invocation.state = ccsYielded
      of 2:
        let id = lanes[0].i32.uint32 shr 4
        let waitSet = instance.waitableSet(id)
        inc waitSet.waiters
        invocation.waiting.id = id
        invocation.waiting.waitSet = waitSet
        invocation.state = ccsWaiting
      else: componentFail("invalid canonical callback code")
    except CatchableError as err:
      when defined(wasmComponentStackful): invocation.core = nil
      invocation.borrows = nil
      invocation.waiting.leaveWait()
      invocation.args.setLen(0)
      invocation.task.values.setLen(0)
      invocation.state = ccsTrapped
      instance.lockStore()
      if err of WasmTrap: componentFail("component core trap: " & err.msg)
      raise
    invocation.state

  when defined(wasmComponentThreads):
    proc runScheduledGuestThread(thread: ComponentGuestThread) =
      let instance = cast[ComponentInstance](thread.owner)
      let invocation = thread.invocation
      if thread.implicit and thread.directResults == nil:
        discard invocation.pollCallbackCore(guestTurn = true)
        return
      let store = instance.links.store
      let execution = instance.execution
      if not execution.mayLeave or store.activeCallbackTurns.int >= MaxComponentCallDepth:
        componentFail("canonical guest thread cannot enter the component")
      inc instance.activeEntries
      inc store.activeCallbackTurns
      let previous = execution.context
      let previousTask = execution.callbackTask
      let previousScope = execution.borrowScope
      let previousThread = execution.thread
      let previousSecond = execution.contextSecond
      execution.thread = thread
      execution.context = addr thread.context
      execution.contextSecond = addr thread.contextSecond
      execution.callbackTask = if invocation.entry.usesAsyncLiftAbi(): addr invocation.task else: nil
      execution.borrowScope = if invocation.borrows == nil: 0'u32 else: invocation.borrows.id
      let entering = thread.core.continuation.status == wesReady
      thread.state = cgtRunning
      defer:
        execution.thread = previousThread
        execution.context = previous
        execution.contextSecond = previousSecond
        execution.callbackTask = previousTask
        execution.borrowScope = previousScope
        dec instance.activeEntries
        dec store.activeCallbackTurns
      try:
        if thread.directResults != nil:
          if thread.core.resumeGuestCore(instance, [], thread.directResults[]):
            thread.state = cgtFinished
          elif thread.state == cgtRunning: thread.state = cgtWaiting
          return
        var lanes: seq[WasmValue]
        if entering: thread.core.arena = initWasmExecutionArena()
        let finished = if entering: thread.core.resumeGuestCore(instance, [thread.closure], lanes)
          else: thread.core.resumeGuestCore(instance, [], lanes)
        if finished:
          instance.retireThread(thread)
          dec invocation.explicitThreads
          invocation.settleGuestThreadTask()
        elif thread.state == cgtRunning: thread.state = cgtWaiting
      except CatchableError as error:
        invocation.state = ccsTrapped
        instance.lockStore()
        if error of WasmTrap: componentFail("component core trap: " & error.msg)
        raise

    proc drainGuestThreadSwitches(store: ComponentLinkStore) =
      while store.switchTarget != nil:
        let thread = move store.switchTarget
        thread.runScheduledGuestThread()

    proc invokeSynchronousGuestCore(instance: ComponentInstance, address: int,
        args: openArray[WasmValue]): seq[WasmValue] =
      ## Only this instance's ready threads can make progress for a sync lift.
      let thread = instance.execution.thread
      let store = instance.links.store
      thread.core = ComponentCoreTurn(arena: initWasmExecutionArena(), address: address)
      thread.directResults = addr result
      defer:
        when WasmAtomicWaitEnabled:
          if thread.core.continuation.status == wesAtomicBlocked:
            instance.vm.swapWasmExecutionArena(thread.core.arena)
            try: instance.vm.abortExecution(thread.core.continuation)
            finally: instance.vm.swapWasmExecutionArena(thread.core.arena)
        thread.directResults = nil
        thread.core = nil
      if thread.core.resumeGuestCore(instance, args, result): return
      if thread.state == cgtRunning: thread.state = cgtWaiting
      store.drainGuestThreadSwitches()
      while thread.state != cgtFinished:
        var next: ComponentGuestThread
        let count = store.guestThreads.len
        for step in 0 ..< count:
          let index = (store.nextGuestThread + step) mod count
          let candidate = store.guestThreads[index]
          if candidate.owner == thread.owner and candidate.guestThreadReady(switching = true):
            store.nextGuestThread = index + 1
            next = candidate
            break
        if next == nil: componentFail("cannot block a synchronous task before returning")
        next.runScheduledGuestThread()
        store.drainGuestThreadSwitches()

  proc pollCallbackTurn(invocation: ComponentInvocation): ComponentCallbackState =
    result = invocation.pollCallbackCore()
    when defined(wasmComponentThreads):
      let inst = cast[ComponentInstance](invocation.owner)
      inst.links.store.drainGuestThreadSwitches()
      result = invocation.state

  proc callbackResultReady(invocation: ComponentInvocation): bool =
    invocation != nil and invocation.task.resolution == ccrReturned and not invocation.resultTaken and
      invocation.state != ccsTrapped

  proc takeCallbackResult(invocation: ComponentInvocation): seq[ComponentValue] =
    if not invocation.callbackResultReady(): componentFail("component callback result unavailable")
    invocation.resultTaken = true
    invocation.borrows = nil
    move invocation.task.values

  proc callbackResultReady*(handle: ComponentCallback): bool =
    handle != nil and handle.invocation.callbackResultReady()

  proc takeCallbackResult*(handle: ComponentCallback): seq[ComponentValue] =
    if handle == nil: componentFail("invalid component callback")
    handle.invocation.takeCallbackResult()

  proc accessForLowering(lowering: ComponentScheduledLowering): AbiAccess =
    let caller = cast[ComponentInstance](lowering.caller)
    AbiAccess(vm: addr caller.vm, execution: caller.execution,
      memoryAddress: lowering.memoryAddress, reallocAddress: lowering.reallocAddress,
      encoding: lowering.encoding, resourceOwner: lowering.caller)

  proc resolveSubtask(task: ComponentSubtask, values: var seq[ComponentValue]) =
    let lowering = task.lowering
    let sig = addr lowering.signature
    when defined(wasmComponentStackful):
      if lowering.synchronous:
        let access = lowering.accessForLowering()
        var destination = LoweredResult(access: unsafeAddr access, signature: sig,
          returnPointer: task.returnPointer, values: addr task.flatResults)
        resolveLoweredResult(addr destination, values)
        task.publishSubtaskState(cstReturned)
        return
    if values.len != sig.hasResult.int or
        (sig.hasResult and values[0].kind != sig.resultType):
      componentFail("canonical async result mismatch")
    if sig[].asyncResultArea():
      let access = lowering.accessForLowering()
      let slot = resultSlot(sig[])
      let layout = canonicalSlotLayout(slot)
      let offset = task.returnPointer.uint64
      if (offset and (layout.alignment - 1).uint64) != 0:
        componentFail("unaligned canonical async return area")
      access.vm[].store.mems[access.memoryAddress].checkMemoryRange(offset, layout.size.uint32)
      if slot.resources != {}:
        let caller = cast[ComponentInstance](lowering.caller)
        caller.requireHandleCapacity(caller.validateHostResourceResult(slot, values[0]))
      writeAbiArgument(access, offset, slot, values[0])
    task.publishSubtaskState(cstReturned)

  proc resolveScheduledCallee(lowering: ComponentScheduledLowering):
      tuple[owner: ComponentInstance, entry: ptr ComponentExport] =
    let target = lowering.target
    if target != nil:
      return cast[ComponentInstance](target.owner).resolveInvocationTarget(target.entry)

  proc canStartScheduledLift(callee: ComponentInstance, entry: ptr ComponentExport): bool =
    if callee == nil: return true
    when defined(wasmComponentStackful):
      if entry.target == ctImport: return true
    if callee.backpressure != 0 or not callee.execution.mayLeave: return false
    if entry[].stackfulLift(): return true
    if callee.activeEntries != 0 or callee.execution.context != nil: return false
    when defined(wasmComponentStackful):
      callee.coreTurnAvailable()
    else:
      true

  proc subtaskRunnable(task: ComponentSubtask): bool =
    if task.state == cstStarting:
      let (callee, entry) = task.lowering.resolveScheduledCallee()
      if callee == nil: return true
      if not callee.canStartScheduledLift(entry): return false
      for pending in callee.links.store.pendingSubtasks:
        if pending == task: break
        if pending.state == cstStarting:
          let (earlier, earlierEntry) = pending.lowering.resolveScheduledCallee()
          # Preserve FIFO among entrants that can acquire their required lock.
          if earlier == callee and earlier.canStartScheduledLift(earlierEntry):
            return false
      return true
    task.call != nil and (task.call.callbackRunnable() or
      (when defined(wasmComponentThreads): task.call.state notin RunnableCallback else: false))

  proc startSubtask(task: ComponentSubtask) {.noinline.} =
    let lowering = task.lowering
    let caller = cast[ComponentInstance](lowering.caller)
    let access = lowering.accessForLowering()
    let asynchronous = when defined(wasmComponentStackful): not lowering.synchronous else: true
    var args = readLoweredArguments(access, lowering.signature, task.arguments,
      task.returnPointer, asyncAbi = asynchronous)
    task.arguments.setLen(0)
    if lowering.signature.parameterResources() != {}:
      if ruBorrow in lowering.signature.parameterResources():
        task.lenders = ResourceLendBatch(resources: caller.resources)
        caller.resources.lendBatches.add(cast[pointer](task.lenders))
      var lends: seq[ResourceLend]
      let decode = proc(slot: CanonicalSlot, value: var ComponentValue) =
        if task.lenders != nil:
          caller.decodeResourceLeaf(slot, value, task.lenders.lends, scheduled = true)
        else:
          caller.decodeResourceLeaf(slot, value, lends)
      for i in 0 ..< args.len:
        visitResourceLeaves(parameterSlot(lowering.signature, i), args[i], decode)
    task.publishSubtaskState(cstStarted)
    let (callee, entry) = lowering.resolveScheduledCallee()
    if entry != nil and entry[].scheduledLift():
      task.call = callee.queueCallback(entry, args)
      task.call.task.subtask = cast[pointer](task)
    else:
      var values = if entry == nil: lowering.callback(args)
        else: callee.invokeFunction(entry[], args, guestEntry = true)
      task.resolveSubtask(values)

  proc advanceSubtask(task: ComponentSubtask) =
    if task.state == cstStarting: task.startSubtask()
    if task.call == nil: return
    let state = task.call.pollCallbackTurn()
    if task.resolved(): task.call.borrows = nil
    if state notin RunnableCallback:
      if state == ccsUnresolved: task.unresolvedBorrows = move task.call.borrows
      task.call = nil

  proc removeSubtask(store: ComponentLinkStore, task: ComponentSubtask) =
    for i, pending in store.pendingSubtasks:
      if pending == task:
        store.pendingSubtasks.delete(i)
        if i < store.nextSubtask: dec store.nextSubtask
        return

  proc cancelSubtask(task: ComponentSubtask, asynchronous: bool): int32 =
    if task.delivered or task.cancellationRequested or task.joined != 0:
      componentFail("canonical subtask cannot be cancelled")
    if not task.resolved():
      let caller = cast[ComponentInstance](task.lowering.caller)
      task.cancellationRequested = true
      task.cancelling = true
      defer: task.cancelling = false
      if task.state == cstStarting:
        task.arguments.setLen(0)
        task.publishSubtaskState(cstCancelledBeforeStart)
      elif task.call != nil:
        task.call.task.resolution = ccrCancelPending
        if task.call.state in {ccsYielded, ccsWaiting} and task.call.callbackRunnable():
          # Resume only the cancelled child during OnCancel.
          task.advanceSubtask()
      if not task.resolved():
        if not asynchronous:
          when defined(wasmComponentStackful):
            if caller.vm.canSuspendHostCall(): return -1
          componentFail("blocking canonical subtask.cancel requires stackful suspension")
        return -1
      if task.call == nil: caller.links.store.removeSubtask(task)
    int32(task.takeSubtaskEvent().state)

  proc makeScheduledLowering(lowering: ComponentScheduledLowering): HostFunc =
    result = proc(args: openArray[WasmValue]): seq[WasmValue] =
      let caller = cast[ComponentInstance](lowering.caller)
      if not caller.execution.mayLeave:
        when defined(wasmComponentStackful):
          if lowering.synchronous:
            componentFail("canonical host call during realloc or post-return")
        componentFail("canonical async lower cannot leave")
      let store = caller.links.store
      if store.pendingSubtasks.len + store.startingSubtasks >= MaxComponentAsyncTasks:
        componentFail("component async task capacity exceeded")
      let task = ComponentSubtask(lowering: lowering, arguments: @args)
      if task.subtaskRunnable():
        inc store.startingSubtasks
        defer: dec store.startingSubtasks
        task.advanceSubtask()
      let keepRunning = task.state == cstStarting or task.call != nil
      when defined(wasmComponentStackful):
        if lowering.synchronous:
          if not task.resolved() and not caller.vm.canSuspendHostCall():
            componentFail("cannot block a synchronous task before returning")
          if keepRunning: store.pendingSubtasks.add(task)
          if task.resolved():
            task.deliverResolution()
            return move task.flatResults
          return caller.vm.suspendHostCall(WasmHostWait(
            ready: proc(): bool = task.resolved(),
            finish: proc(): seq[WasmValue] =
              task.deliverResolution()
              move task.flatResults))
      if task.state != cstReturned:
        task.handle = caller.newAsyncSlot(ComponentAsyncSlot(subtask: task))
      else:
        task.deliverResolution()
      if keepRunning: store.pendingSubtasks.add(task)
      @[wasmI32((task.state.ord.uint32 or (task.handle shl 4)).int32)]

  proc invokeImmediateCallback(instance: ComponentInstance, entry: ptr ComponentExport,
      args: openArray[ComponentValue], destination: ptr LoweredResult): seq[ComponentValue] =
    let store = instance.links.store
    if store.pendingSubtasks.len + store.startingSubtasks >= MaxComponentAsyncTasks:
      componentFail("component async task capacity exceeded")
    inc store.startingSubtasks
    defer: dec store.startingSubtasks
    let invocation = instance.queueCallback(entry, args)
    let state = invocation.pollCallbackTurn()
    if not invocation.callbackResultReady():
      when defined(wasmComponentStackful):
        if not destination.access.vm[].canSuspendHostCall():
          componentFail("cannot block a synchronous task before returning")
      componentFail("canonical synchronous lower cannot block on an unresolved callback")
    result = invocation.takeCallbackResult()
    resolveLoweredResult(destination, result)
    if state in RunnableCallback:
      store.pendingSubtasks.add(ComponentSubtask(call: invocation, state: cstReturned))

  proc pumpComponentTasks(instance: ComponentInstance, exclude: ComponentInvocation = nil): bool =
    ## Advance one runnable guest subtask in store order, including a task
    ## that continues after its result has been delivered to the caller.
    if instance == nil or instance.links == nil or instance.isLocked: return false
    let store = instance.links.store
    if store.pumping or store.startingSubtasks != 0 or store.activeCallbackTurns != 0 or
        store.callDepth != 0:
      return false
    let count = store.pendingSubtasks.len
    for step in 0 ..< count:
      let index = (store.nextSubtask + step) mod count
      let task = store.pendingSubtasks[index]
      if not task.subtaskRunnable(): continue
      store.pumping = true
      defer: store.pumping = false
      try:
        store.nextSubtask = index + 1
        task.advanceSubtask()
        if task.state != cstStarting and task.call == nil:
          store.removeSubtask(task)
      except CatchableError as error:
        instance.lockStore()
        if error of WasmTrap: componentFail("component core trap: " & error.msg)
        raise
      return true
    when defined(wasmComponentThreads):
      let threadCount = store.guestThreads.len
      for step in 0 ..< threadCount:
        let index = (store.nextGuestThread + step) mod threadCount
        let thread = store.guestThreads[index]
        if thread.implicit and thread.invocation == exclude: continue
        if not thread.guestThreadReady(): continue
        store.pumping = true
        defer: store.pumping = false
        store.nextGuestThread = index + 1
        thread.runScheduledGuestThread()
        store.drainGuestThreadSwitches()
        return true

  proc pollComponentTasks*(instance: ComponentInstance): bool =
    instance.pumpComponentTasks()

  proc pollCallback*(handle: ComponentCallback): ComponentCallbackState =
    if handle == nil: componentFail("invalid component callback")
    let invocation = handle.invocation
    if invocation.state notin RunnableCallback: return invocation.state
    let instance = cast[ComponentInstance](invocation.owner)
    if instance.isLocked: componentFail("component store locked after trap")
    let store = instance.links.store
    if store.activeCallbackTurns != 0 or store.callDepth != 0:
      componentFail("cannot poll a callback from an active component call")
    let yieldedThread = when defined(wasmComponentThreads):
        let thread = instance.threadAt(invocation.implicitId)
        thread != nil and thread.state == cgtReady
      else: false
    if invocation.state == ccsYielded or yieldedThread or not invocation.callbackRunnable():
      discard instance.pumpComponentTasks(invocation)
    invocation.pollCallbackTurn()

proc invoke*(instance: ComponentInstance, name: string,
             args: openArray[ComponentValue]): seq[ComponentValue] =
  ## Invoke the typed export directly, following any component function aliases
  ## to the instance where the function was defined.
  if instance != nil:
    if instance.isLocked:
      componentFail("component store locked after trap")
    for i in 0 ..< instance.exports.len:
      if instance.exports[i].name == name:
        return instance.invokeFunction(instance.exports[i], args)
  componentFail("unknown component export")

proc invokeInterface*(instance: ComponentInstance, name, methodName: string,
                      args: openArray[ComponentValue]): seq[ComponentValue] =
  ## Invoke a typed function exported under the named instance.
  instance.invokeFunction(instance.exportedComponentMethod([name], methodName)[], args)

proc invokeInterface*(instance: ComponentInstance, path: openArray[string], methodName: string,
                      args: openArray[ComponentValue]): seq[ComponentValue] =
  ## Invoke a function under a path of instance exports.
  instance.invokeFunction(instance.exportedComponentMethod(path, methodName)[], args)
