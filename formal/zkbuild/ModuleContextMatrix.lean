import ModuleProgram
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.ModuleContextMatrix
open CircuitShape GadgetShape DeclarationMatrix ModuleProgram
abbrev Fields := List Linear
structure Element where
  fields : Fields
  offset : Fields
  items : List Fields
  deriving Inhabited
structure Record where
  flat : Bool
  ownedCode : Nat
  elementCode : Nat
  startFirst : Nat
  startLast : Nat
  counts : Fields
  memories : List Fields
  tables : List Fields
  globals : List Fields
  elements : List Element
  items : List Fields
  datas : List Fields
  exports : List Fields
  unique : List Fields
  bodies : List Fields
  bulk : List Fields
  heads : Fields
  banks : List Nat
  programs : List Program
  deriving Inhabited
structure Acc where
  objects : List ReadOnlyMatrix.Entry := []
  sources : List ReadOnlyMatrix.Entry := []
  declarations : List ReadOnlyMatrix.Entry := []
  typeEntries : List ReadOnlyMatrix.Entry := []
  typeQueries : List ReadOnlyMatrix.Entry := []
  parents : List Fields := []
  children : List Fields := []
  deriving Inhabited

def field (r : Fields) (i : Nat) := get r i
def counter (r : Record) (i : Nat) := field r.counts i
def bank (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) := tables.getD (r.banks.getD i 0) default
def entryFields (e : ReadOnlyMatrix.Entry) := [e.active,e.address,e.value]
def normalized (rows : List Fields) := rows.map (List.map normalizeLinear)
def normalizedEntries (rows : List ReadOnlyMatrix.Entry) := normalized (rows.map entryFields)
def require (condition : Bool) (message : String) : Eval Unit := if condition then pure () else throw message

def prefixRule (matrix : Shape) (p : Program) (active previous : Linear) : Eval Unit := do
  boolean matrix p active
  raw matrix (gate active (sub o previous))
def bounded (matrix : Shape) (p : Program) (active index count : Linear) : Eval Unit := do
  let distance ← mul matrix p active (sub (sub count index) o)
  let _ ← range matrix p distance 32
  pure ()
def limit (matrix : Shape) (p : Program) (r : Fields) (memory : Bool) : Eval Unit := do
  let active := field r 0
  let maximum := field r 1
  let low := field r 2
  let high := field r 3
  boolean matrix p active
  boolean matrix p maximum
  let _ ← range matrix p low 32
  let _ ← range matrix p high 32
  raw matrix (gate (sub o active) (maximum++low++high))
  raw matrix (gate (sub o maximum) high)
  let delta ← mul matrix p maximum (sub high low)
  let _ ← range matrix p delta 32
  if memory then
    let l ← mul matrix p active (sub (n 65536) low)
    let _ ← range matrix p l 17
    let h ← mul matrix p maximum (sub (n 65536) high)
    let _ ← range matrix p h 17
  pure ()

def object (matrix : Shape) (p : Program) (entries : List ReadOnlyMatrix.Entry) (index : Nat) (active key : Linear) : Eval ReadOnlyMatrix.Entry := do
  require (decide (index < entries.length)) "missing context object query"
  let q := entries.getD index default
  let address ← mul matrix p active key
  require (decide (normalizedEntries [q] = normalizedEntries [⟨active,address,q.value⟩])) "context object query mismatch"
  pure ⟨active,address,q.value⟩
def source (matrix : Shape) (p : Program) (index : Nat) (active function : Linear) : Eval (ReadOnlyMatrix.Entry × ReadOnlyMatrix.Entry) := do
  let value ← mul matrix p active (o++scale function 2)
  let address ← mul matrix p active function
  pure (⟨o,n index,value⟩,⟨active,address,active⟩)

def expression (matrix : Shape) (p : Program) (r : Record) (objects : List ReadOnlyMatrix.Entry)
    (row : Fields) (expected available : Linear) (acc : Acc) : Eval Acc := do
  let active := field row 0
  let count := field row 1
  let opcode := field row 2
  let immediate := field row 3
  let vectors := field row 4
  boolean matrix p active
  for (value,width) in [(count,32),(opcode,16),(immediate,32),(vectors,32)] do
    let _ ← range matrix p value width
  for value in [count,opcode,immediate,vectors] do
    raw matrix (gate (sub o active) value)
  raw matrix (gate active (sub count o))
  let mut selectors := []
  let mut total := z
  for opcodeValue in ConstantSourceMatrix.opcodes do
    let isOpcode ← zero matrix p (sub opcode (n opcodeValue))
    let selected ← mul matrix p active isOpcode
    selectors := selectors++[selected]
    total := total++selected
  eq matrix p active total
  let mut typeSum := z
  for i in List.range 5 do
    typeSum := typeSum++scale (field selectors i) (Int.ofNat i)
  let nullFunction ← zero matrix p (sub immediate (n 112))
  let nullExternal ← zero matrix p (sub immediate (n 111))
  raw matrix (gate (field selectors 5) (sub (nullFunction++nullExternal) o))
  let nullType ← mul matrix p (field selectors 5) (scale nullFunction 5++scale nullExternal 6)
  typeSum := typeSum++nullType++scale (field selectors 6) 5
  bounded matrix p (field selectors 6) immediate (counter r 0)
  bounded matrix p (field selectors 4) immediate vectors
  bounded matrix p (field selectors 7) immediate available
  let declared ← object matrix p objects acc.objects.length (field selectors 7) (scale immediate 2)
  let _ ← range matrix p declared.value 3
  let globalType ← mul matrix p (field selectors 7) declared.value
  typeSum := typeSum++globalType
  raw matrix (gate active (sub expected typeSum))
  let (origin,query) ← source matrix p acc.sources.length (field selectors 6) immediate
  pure {acc with objects := acc.objects++[declared],sources := acc.sources++[origin],declarations := acc.declarations++[query]}

def before (matrix : Shape) (p : Program) (r : Record) (objectEntries signatures objects elementQueries : List ReadOnlyMatrix.Entry) : Eval Acc := do
  for i in [0,1,2,3,4,5,6,7,9] do
    let _ ← range matrix p (counter r i) 32
  eq matrix p (counter r 12) (counter r 4)
  eq matrix p (counter r 0) (counter r 11)
  for value in [sub (counter r 0) (counter r 4),sub (counter r 2) (counter r 5),
      sub (counter r 3) (counter r 6),sub (counter r 10) (counter r 7)] do
    let _ ← range matrix p value 32
  let mut functions := z
  let mut types := z
  for entry in signatures do
    let bits ← range matrix p entry.address 33
    let typeEntry ← mul matrix p entry.active (field bits 0)
    let functionEntry := sub entry.active typeEntry
    let index ← select matrix p (field bits 0) types functions
    raw matrix (gate entry.active (sub (sub entry.address (scale index 2)) (field bits 0)))
    functions ← materialize matrix p (functions++functionEntry)
    types ← materialize matrix p (types++typeEntry)
  eq matrix p functions (counter r 0)
  eq matrix p types (counter r 1)
  let mut tables := z
  let mut globals := z
  for entry in objectEntries do
    let bits ← range matrix p entry.address 33
    let tableEntry ← mul matrix p entry.active (field bits 0)
    let globalEntry := sub entry.active tableEntry
    let index ← select matrix p (field bits 0) tables globals
    raw matrix (gate entry.active (sub (sub entry.address (scale index 2)) (field bits 0)))
    let values ← range matrix p entry.value 4
    let tag := sub entry.value (scale (field values 3) 8)
    let invalid ← zero matrix p (sub tag (n 7))
    eq matrix p invalid z
    let reference ← mul matrix p (sub tag (n 5)) (sub tag (n 6))
    raw matrix (gate tableEntry reference)
    raw matrix (gate tableEntry (field values 3))
    tables ← materialize matrix p (tables++tableEntry)
    globals ← materialize matrix p (globals++globalEntry)
  eq matrix p globals (counter r 2)
  eq matrix p tables (counter r 3)
  let mut bodies := z
  let mut previous := o
  for i in List.range r.bodies.length do
    let row := r.bodies.getD i []
    prefixRule matrix p (field row 0) previous
    raw matrix (gate (field row 0) (sub (sub (field row 1) (counter r 4)) (n i)))
    bodies ← materialize matrix p (bodies++field row 0)
    previous := field row 0
  eq matrix p bodies (sub (counter r 0) (counter r 4))
  let mut memoryCount := z
  previous := o
  for row in r.memories do
    prefixRule matrix p (field row 0) previous
    limit matrix p row true
    memoryCount ← materialize matrix p (memoryCount++field row 0)
    previous := field row 0
  eq matrix p memoryCount (counter r 10)
  boolean matrix p memoryCount
  let mut tableCount := z
  previous := o
  for row in r.tables do
    prefixRule matrix p (field row 0) previous
    limit matrix p row false
    tableCount ← materialize matrix p (tableCount++field row 0)
    previous := field row 0
  eq matrix p tableCount (counter r 3)
  let mut acc : Acc := {}
  let mut definedGlobals := z
  previous := o
  for i in List.range r.globals.length do
    let row := r.globals.getD i []
    prefixRule matrix p (field row 0) previous
    let declared ← object matrix p objects acc.objects.length (field row 0) (scale (counter r 5++n i) 2)
    acc := {acc with objects := acc.objects++[declared]}
    let bits ← range matrix p declared.value 4
    acc ← expression matrix p r objects row (sub declared.value (scale (field bits 3) 8)) (counter r 5++n i) acc
    definedGlobals ← materialize matrix p (definedGlobals++field row 0)
    previous := field row 0
  eq matrix p definedGlobals (sub (counter r 2) (counter r 5))
  previous := o
  for i in List.range r.elements.length do
    let row := r.elements.getD i default
    let entry := r.bulk.getD i []
    let active := field row.fields 0
    let mode := field row.fields 1
    let index := field row.fields 2
    let count := field row.fields 3
    let tag := field entry 2
    prefixRule matrix p active previous
    eq matrix p active (field entry 0)
    raw matrix (gate active (sub (field entry 1) (n i)))
    eq matrix p (field row.fields 4) tag
    let _ ← range matrix p count 32
    raw matrix (gate (sub o active) count)
    acc := {acc with typeEntries := acc.typeEntries++[⟨active,scale active (Int.ofNat i),tag⟩],parents := acc.parents++[[active,count,z,count]]}
    let _ ← range matrix p mode 2
    let invalid ← zero matrix p (sub mode (n 3))
    eq matrix p invalid z
    let _ ← range matrix p index 32
    raw matrix (gate (sub o active) mode)
    let enabled ← zero matrix p (sub mode o)
    let activeMode ← mul matrix p active enabled
    raw matrix (gate (sub o activeMode) index)
    let tableType ← object matrix p objects acc.objects.length activeMode (scale index 2++o)
    acc := {acc with objects := acc.objects++[tableType]}
    raw matrix (gate activeMode (sub tableType.value tag))
    eq matrix p (field row.offset 0) activeMode
    acc ← expression matrix p r objects row.offset z (counter r 2) acc
    let mut last := active
    let mut itemCount := z
    for item in row.items do
      prefixRule matrix p (field item 0) last
      acc ← expression matrix p r objects item tag (counter r 2) acc
      last := field item 0
      itemCount := itemCount++field item 0
    if !r.flat then eq matrix p count itemCount
    previous := active
  if r.flat then
    for row in r.items do
      let i := acc.typeQueries.length
      -- The lookup value was allocated before the expression and is an input
      -- to the checked immutable element-type table.
      require (decide (i < elementQueries.length)) "missing element type query"
      let query := (elementQueries.getD i default).value
      acc := {acc with typeQueries := acc.typeQueries++[⟨field row 2,field row 0,query⟩]}
      acc ← expression matrix p r objects (row.drop 2 |>.take 5) query (counter r 2) acc
      let finish ← mul matrix p (field row 2) (field row 1++o)
      acc := {acc with children := acc.children++[[field row 2,field row 0,field row 1,field row 1,finish]]}
  pure acc

structure Result where
  acc : Acc
  signatures : List ReadOnlyMatrix.Entry
  exportEntries : List ReadOnlyMatrix.Entry
  exportQueries : List ReadOnlyMatrix.Entry
  sourceQueries : List ReadOnlyMatrix.Entry
  deriving Inhabited

def after (matrix : Shape) (p : Program) (r : Record) (objects references sources : List ReadOnlyMatrix.Entry) (acc0 : Acc) : Eval Result := do
  let mut acc := acc0
  let mut dataCount := z
  let mut previous := o
  for row in r.datas do
    let active := field row 0
    let passive := field row 1
    let index := field row 2
    prefixRule matrix p active previous
    boolean matrix p passive
    raw matrix (gate (sub o active) passive)
    let _ ← range matrix p index 32
    let enabled := sub active passive
    raw matrix (gate enabled (sub o (counter r 10)))
    eq matrix p index z
    eq matrix p (field row 3) enabled
    acc ← expression matrix p r objects (row.drop 3) z (counter r 2) acc
    dataCount ← materialize matrix p (dataCount++active)
    previous := active
  eq matrix p dataCount (counter r 13)
  boolean matrix p (counter r 8)
  raw matrix (gate (sub o (counter r 8)) (counter r 9))
  bounded matrix p (counter r 8) (counter r 9) (counter r 0)
  let address ← mul matrix p (counter r 8) (scale (counter r 9) 2)
  let signatures : List ReadOnlyMatrix.Entry := [⟨counter r 8,address,z⟩]
  let mut exports := []
  let mut exportCount := z
  previous := o
  for i in List.range r.exports.length do
    let row := r.exports.getD i []
    let active := field row 0
    let kind := field row 1
    let index := field row 2
    prefixRule matrix p active previous
    let _ ← range matrix p kind 2
    let _ ← range matrix p index 32
    raw matrix (gate (sub o active) (kind++index))
    for j in List.range 4 do
      let same ← zero matrix p (sub kind (n j))
      let enabled ← mul matrix p active same
      let counts := [counter r 0,counter r 3,counter r 10,counter r 2]
      bounded matrix p enabled index (field counts j)
    let same ← zero matrix p (sub kind (n 0))
    let function ← mul matrix p active same
    let (origin,query) ← source matrix p acc.sources.length function index
    acc := {acc with sources := acc.sources++[origin],declarations := acc.declarations++[query]}
    let address ← mul matrix p active (n i)
    let value ← mul matrix p active (field r.heads i)
    exports := exports++[⟨active,address,value⟩]
    exportCount ← materialize matrix p (exportCount++active)
    previous := active
  let mut queries := []
  let mut uniqueCount := z
  for row in r.unique do
    queries := queries++[⟨field row 0,field row 2,field row 1⟩]
    uniqueCount ← materialize matrix p (uniqueCount++field row 0)
  eq matrix p uniqueCount exportCount
  let mut sourceQueries := []
  for i in List.range references.length do
    let row := references.getD i default
    require (decide (i < sources.length)) "missing source-origin query"
    let q := sources.getD i default
    let value ← mul matrix p row.active (o++scale row.address 2)
    sourceQueries := sourceQueries++[⟨row.active,q.address,value⟩]
  pure ⟨acc,signatures,exports,queries,sourceQueries⟩

def constantFields (r : ConstantSourceMatrix.Record) : Fields := (List.range 5).map (fun i => ConstantSourceMatrix.field r (i+3))
def limitEntries (rows : List Fields) (flags : Bool) :=
  (List.range rows.length).map fun i =>
    let row := rows.getD i []
    (⟨field row 0,scale (field row 0) (Int.ofNat i),if flags then field row 1 else field row 2++scale (field row 3) (Int.ofNat (2^32))⟩ : ReadOnlyMatrix.Entry)
def sourceLinks (tables : List ReadOnlyMatrix.Record) (space : SignatureNamespace.Record)
    (imports : ImportMatrix.Record) (graph : NameGraphMatrix.Record) (scalar : ScalarPayloadMatrix.Record)
    (segments : SegmentPayloadMatrix.Record) (cs : List ConstantSourceMatrix.Record) (r : Record) : Bool :=
  decide (r.counts.length = 14 ∧ r.banks.length = 6 ∧ (∀ i ∈ r.banks, i < tables.length) ∧
    r.flat = segments.flat ∧ r.exports.length ≤ r.heads.length ∧ r.bulk.length = r.elements.length ∧
    (r.memories++r.tables).all (fun row => row.length == 4) = true ∧
    r.globals.all (fun row => row.length == 5) = true ∧
    r.elements.all (fun row => row.fields.length == 5 && row.offset.length == 5 && row.items.all (fun item => item.length == 5)) = true ∧
    r.items.all (fun row => row.length == 7) = true ∧ r.datas.all (fun row => row.length == 8) = true ∧
    (r.exports++r.unique++r.bodies++r.bulk).all (fun row => row.length == 3) = true) &&
  decide (normalized [[counter r 0,counter r 1,counter r 4,counter r 5,counter r 6,counter r 7,counter r 12]] =
    normalized [[space.functions,space.types,space.importedFunctions,imports.importedGlobals,imports.importedTables,imports.importedMemories,space.firstFunction]]) &&
  decide (normalizedEntries (bank tables r 0).entries = normalizedEntries (ImportMatrix.table tables imports 1).entries ∧
    normalizedEntries (bank tables r 1).entries = normalizedEntries (space.rows.map (·.entry)) ∧
    r.heads.map normalizeLinear = (graph.roots.map (·.head)).map normalizeLinear) &&
  decide (normalizedEntries (limitEntries r.memories false) = normalizedEntries (ImportMatrix.table tables imports 3).entries ∧
    normalizedEntries (limitEntries r.memories true) = normalizedEntries (ImportMatrix.table tables imports 4).entries ∧
    normalizedEntries (limitEntries r.tables false) = normalizedEntries (ImportMatrix.table tables imports 5).entries ∧
    normalizedEntries (limitEntries r.tables true) = normalizedEntries (ImportMatrix.table tables imports 6).entries) &&
  decide (normalized r.globals = normalized ((ScalarPayloadMatrix.getRows scalar 2).map (fun row => constantFields (ScalarPayloadMatrix.constAt cs row))) ∧
    normalized r.exports = normalized ((ScalarPayloadMatrix.getRows scalar 3).map (fun row => [row.active,field row.fields 0,field row.fields 1]))) &&
  decide (r.elements.length = segments.elements.length ∧
    (List.range r.elements.length).all (fun i =>
      let row := r.elements.getD i default
      let src := segments.elements.getD i default
      let b := r.bulk.getD i []
      decide (normalized [[field row.fields 0,field row.fields 1,field row.fields 2,field row.fields 3,field b 2],row.offset] =
        normalized [[SegmentPayloadMatrix.f src 0,SegmentPayloadMatrix.f src 3,SegmentPayloadMatrix.f src 4,SegmentPayloadMatrix.f src 10,SegmentPayloadMatrix.f src 8],constantFields (SegmentPayloadMatrix.constAt cs src 0)] ∧
        normalized row.items = normalized ((src.constants.drop 1).map (fun j => constantFields (cs.getD j default))))) = true) &&
  decide (normalized r.items = normalized (segments.items.map (fun row => [SegmentPayloadMatrix.f row 1,SegmentPayloadMatrix.f row 2]++constantFields (SegmentPayloadMatrix.constAt cs row 0))) ∧
    normalized r.datas = normalized (segments.datas.map (fun row => [SegmentPayloadMatrix.f row 0,SegmentPayloadMatrix.f row 4,SegmentPayloadMatrix.f row 5]++constantFields (SegmentPayloadMatrix.constAt cs row 0))))

def ownedStart (r : OwnedMatrix.Record) :=
  match r.parents.head? with
  | some row => row.firstGate
  | none => match r.children.head? with | some row => row.firstGate | none => r.closeStart
def tableEnd (r : ReadOnlyMatrix.Record) := (r.memory.rows.getLast?).map (·.lastGate) |>.getD r.preludeEnd

def outputLinks (tables : List ReadOnlyMatrix.Record) (r : Record) (result : Result) : Bool :=
  decide (normalizedEntries (bank tables r 0).queries = normalizedEntries result.acc.objects ∧
    normalizedEntries (bank tables r 1).queries = normalizedEntries result.signatures ∧
    normalizedEntries (bank tables r 2).entries = normalizedEntries result.acc.sources ∧
    normalizedEntries (bank tables r 2).queries = normalizedEntries result.sourceQueries ∧
    normalizedEntries (bank tables r 3).queries = normalizedEntries result.acc.declarations ∧
    normalizedEntries (bank tables r 4).entries = normalizedEntries result.exportEntries ∧
    normalizedEntries (bank tables r 4).queries = normalizedEntries result.exportQueries ∧
    normalizedEntries (bank tables r 5).entries = normalized r.unique ∧ (bank tables r 5).queries.length = 0) &&
  ((List.range 6).all fun i =>
    let table := bank tables r i
    let shape := [(33,4),(33,64),(32,33),(32,1),(32,32),(32,32)].getD i (0,0)
    decide (table.memory.addressBits = shape.1 ∧ table.memory.valueBits = shape.2))

def replay (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (owned : List OwnedMatrix.Record) (r : Record) : Except String (Result × List State) := do
  let p := r.programs.getD 0 default
  let objectEntries := (bank tables r 0).entries
  let signatureEntries := (bank tables r 1).entries
  let queries := (bank tables r 0).queries
  let references := (bank tables r 3).entries
  let sources := (bank tables r 2).queries
  let elementTable := tables.getD (r.elementCode-1) default
  let (acc,s) ← (before matrix p r objectEntries signatureEntries queries elementTable.queries).run (init p)
  if r.flat then
    if r.programs.length != 2 || !decide (finished p s) then throw "module first program extent rejected"
    if r.ownedCode == 0 || r.ownedCode > owned.length || r.elementCode == 0 || r.elementCode > tables.length then throw "module element bridge indices rejected"
    let stream := owned.getD (r.ownedCode-1) default
    let next := r.programs.getD 1 default
    if !decide (normalized (stream.parents.map (·.fields)) = normalized acc.parents ∧
        normalized (stream.children.map (·.fields)) = normalized acc.children ∧
        normalizedEntries elementTable.entries = normalizedEntries acc.typeEntries ∧
        normalizedEntries elementTable.queries = normalizedEntries acc.typeQueries ∧
        elementTable.memory.addressBits = 32 ∧ elementTable.memory.valueBits = 3 ∧
        p.lastGate = ownedStart stream ∧ next.firstGate = tableEnd elementTable) then throw "module element bridge rejected"
    let (result,last) ← (after matrix next r queries references sources acc).run (init next)
    if !decide (finished next last) then throw "module final program extent rejected"
    if next.lastGate != (bank tables r 0).firstGate then throw "module final table boundary rejected"
    pure (result,[s,last])
  else
    if r.programs.length != 1 || r.ownedCode != 0 || r.elementCode != 0 || r.items.length != 0 then throw "legacy module layout rejected"
    let (result,last) ← (after matrix p r queries references sources acc).run s
    if !decide (finished p last) then throw "legacy module program extent rejected"
    if p.lastGate != (bank tables r 0).firstGate then throw "legacy module final table boundary rejected"
    pure (result,[last])

def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (owned : List OwnedMatrix.Record) (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (graph : NameGraphMatrix.Record) (scalar : ScalarPayloadMatrix.Record) (segments : SegmentPayloadMatrix.Record)
    (cs : List ConstantSourceMatrix.Record) (r : Record) : Bool :=
  sourceLinks tables space imports graph scalar segments cs r &&
  MemoryEvidence.checkSpan matrix r.startFirst r.startLast
    [eqGate (get body.envelope.outputs 32) (counter r 8),eqGate (get body.envelope.outputs 33) (counter r 9)] &&
  match replay matrix tables owned r with
  | .error _ => false
  | .ok (result,states) => outputLinks tables r result && states.all (auditState matrix)
end ZkBuild.ModuleContextMatrix
