import StructuredOrigins
import LookupReferenceFast
import InstructionMetadata
set_option autoImplicit false
namespace ZkBuild.RuntimeContextMatrix
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix
structure Record where
  catalog : InstructionDecodeMatrix.Catalog
  stages : List DynamicTypingMatrix.Stage
  bindFirst : Nat
  bindLast : Nat
  deriving Inhabited

def stage (r : Record) (kind : Nat) := (r.stages.find? (fun s => s.kind == kind)).getD default

def canonicalTable (r : LookupEmbedded.Record) : Bool :=
  decide (16 ≤ 16) && (List.range (2^16)).all (fun input =>
    let evaluated := LookupReferenceFast.evaluate r.columns r.root r.nodes input
    (List.range r.columns).all (fun field => decide
      (LookupReferenceFast.read evaluated.sums field = Int.ofNat ((InstructionMetadata.payload input).getD field 0))))
theorem canonicalTable_exact (r : LookupEmbedded.Record) :
    canonicalTable r = LookupEmbedded.checkTable r 16 (fun code field => Int.ofNat ((InstructionMetadata.payload code).getD field 0)) := by
  simp only [canonicalTable,LookupEmbedded.checkTable,LookupReferenceFast.evaluate_eq]

def catalogCheck (catalog : InstructionDecodeMatrix.Catalog) : Bool :=
  let views := catalog.map InstructionDecodeMatrix.tableView
  decide ((views.map (·.id)).Nodup) && match views.head? with
  | none => false
  | some first => first.columns == 7 && canonicalTable (InstructionDecodeMatrix.viewRecord first) &&
    views.all (fun r => decide (r.columns = first.columns ∧ r.root = first.root ∧ r.nodes = first.nodes))

def lookup (matrix : Shape) (catalog : InstructionDecodeMatrix.Catalog) (p : Program) (opcode : Linear) : Eval (List Linear) := do
  let state ← get
  require (decide (state.usedBlocks < p.blocks.length)) "missing memory metadata lookup"
  let b := p.blocks.getD state.usedBlocks default
  let r := InstructionDecodeMatrix.lookupRecord catalog b.index
  require (decide (b.kind = 2 ∧ b.firstOperation = state.base.used ∧ b.lastOperation = state.base.used ∧
    b.firstGate = state.base.gate ∧ b.firstGate = r.range.call.firstGate ∧ b.lastGate = r.lastGate ∧
    r.columns = 7 ∧ (catalog.map Prod.fst).contains b.index = true ∧ ModuleProgram.sameInputs [opcode] [r.input])) "memory metadata lookup interface rejected"
  require (LookupEmbedded.check matrix r) "memory metadata lookup matrix rejected"
  set {state with base := {state.base with gate := b.lastGate},usedBlocks := state.usedBlocks+1}
  pure r.outputs

def memory (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (catalog : InstructionDecodeMatrix.Catalog)
    (s : DynamicTypingMatrix.Stage) : Eval (List Fields) := do
  let p := s.program
  let count := f (rowAt s.auxiliary 0) 0
  boolean matrix p count
  let mut queries := []
  for i in List.range s.rows.length do
    let row := eventAt s i
    let begin := f (flagsAt s i) 1
    let primary := f (rowAt s.inputs i) 0
    let secondary := f (rowAt s.inputs i) 1
    let rule ← lookup matrix catalog p (f row 8)
    let bits ← range matrix p primary 32
    let _ ← range matrix p secondary 32
    raw matrix (gate (sub o begin) primary)
    raw matrix (gate (sub o begin) secondary)
    let required ← mul matrix p begin (f rule 0)
    raw matrix (gate required (sub o count))
    let indexed ← mul matrix p begin (f rule 4)
    raw matrix (gate indexed primary)
    let alignment ← select matrix p (f rule 2) primary secondary
    let argument ← mul matrix p begin (f rule 1)
    let gap ← mul matrix p argument (sub (f rule 3) alignment)
    let _ ← range matrix p gap 3
    let mut low : Linear := []
    for width in [1,2,3,4] do
      low := low++scale (f bits (width-1)) (Int.ofNat (2^(width-1)))
      let selected ← zero matrix p (sub (f rule 6) (n width))
      let lane ← mul matrix p begin selected
      raw matrix (gate lane (sub primary low))
    let active ← mul matrix p begin (f rule 5)
    let address ← mul matrix p active (f row 1)
    let value := ((bank tables s 0).queries.getD i default).value
    queries := queries++[[active,address,value]]
    let available ← mul matrix p active (sub (sub value primary) o)
    let _ ← range matrix p available 32
  pure queries

def bulk (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) : Eval (List (List Fields)) := do
  let p := s.program
  let environment := rowAt s.auxiliary 0
  let memoryCount := f environment 0
  let hasData := f environment 1
  let dataCount := f environment 2
  let declared := f environment 3
  boolean matrix p memoryCount
  boolean matrix p hasData
  let _ ← range matrix p dataCount 32
  let _ ← range matrix p declared 32
  raw matrix (gate (sub o hasData) declared)
  raw matrix (gate hasData (sub declared dataCount))
  for i in List.range (bank tables s 0).entries.length do
    let entry := (bank tables s 0).entries.getD i default
    raw matrix (gate entry.active (sub entry.address (n i)))
    let kind ← mul matrix p (sub entry.value (n 5)) (sub entry.value (n 6))
    raw matrix (gate entry.active kind)
  let mut elements := []
  let mut destinations := []
  let mut sources := []
  for i in List.range s.rows.length do
    let row := eventAt s i
    let begin := f (flagsAt s i) 1
    let primary := f (rowAt s.inputs i) 0
    let secondary := f (rowAt s.inputs i) 1
    let _ ← range matrix p (f row 8) 16
    let _ ← range matrix p primary 32
    let _ ← range matrix p secondary 32
    raw matrix (gate (sub o begin) primary)
    raw matrix (gate (sub o begin) secondary)
    let mut codes := []
    for code in [264,265,266,267,268,269,270] do
      let flag ← zero matrix p (sub (f row 8) (n code))
      codes := codes++[flag]
    let usesData ← mul matrix p begin (f codes 0++f codes 1)
    raw matrix (gate usesData (sub o hasData))
    let available ← mul matrix p usesData (sub (sub dataCount primary) o)
    let _ ← range matrix p available 32
    let usesMemory ← mul matrix p begin (f codes 0++f codes 2++f codes 3)
    raw matrix (gate usesMemory (sub o memoryCount))
    let defaultMemory ← mul matrix p begin (f codes 2++f codes 3)
    raw matrix (gate defaultMemory primary)
    let defaultSource ← mul matrix p begin (f codes 0++f codes 2)
    raw matrix (gate defaultSource secondary)
    let active ← mul matrix p begin (f codes 4++f codes 5)
    let element ← StructuredMatrix.readQuery matrix p active primary (entry ((bank tables s 0).queries.getD i default))
    elements := elements++[element]
    let targetIndex ← select matrix p (f codes 4) secondary primary
    let active ← mul matrix p begin (f codes 4++f codes 6)
    let destination ← StructuredMatrix.readQuery matrix p active (scale targetIndex 2++o) (entry ((bank tables s 1).queries.getD i default))
    destinations := destinations++[destination]
    let active ← mul matrix p begin (f codes 6)
    let source ← StructuredMatrix.readQuery matrix p active (scale secondary 2++o) (entry ((bank tables s 1).queries.getD (s.rows.length+i) default))
    sources := sources++[source]
    let valid ← mul matrix p (sub (f destination 2) (n 5)) (sub (f destination 2) (n 6))
    raw matrix (gate (f destination 0) valid)
    let valid ← mul matrix p (sub (f source 2) (n 5)) (sub (f source 2) (n 6))
    raw matrix (gate (f source 0) valid)
    let initialized ← mul matrix p begin (f codes 4)
    raw matrix (gate initialized (sub (f element 2) (f destination 2)))
    raw matrix (gate (f source 0) (sub (f source 2) (f destination 2)))
  pure [elements,destinations++sources]

def reference (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) : Eval (List Fields) := do
  let p := s.program
  let count := f (rowAt s.auxiliary 0) 0
  let _ ← range matrix p count 32
  for entry in (bank tables s 0).entries do
    raw matrix (gate entry.active (sub entry.value o))
    let gap ← mul matrix p entry.active (sub (sub count entry.address) o)
    let _ ← range matrix p gap 32
  let mut queries := []
  for i in List.range s.rows.length do
    let row := eventAt s i
    let primary := f (rowAt s.inputs i) 0
    let begin := f (flagsAt s i) 1
    let _ ← range matrix p (f row 8) 16
    let _ ← range matrix p primary 32
    raw matrix (gate (sub o begin) primary)
    let function ← zero matrix p (sub (f row 8) (n 210))
    let active ← mul matrix p begin function
    let address ← mul matrix p active primary
    queries := queries++[[active,address,active]]
  pure queries
end ZkBuild.RuntimeContextMatrix
