import SourceProgram
import OpcodeCatalog
import LookupReferenceFast
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.InstructionDecodeMatrix
open CircuitShape GadgetShape DeclarationMatrix SourceProgram
abbrev Catalog := List (Nat × LookupEmbedded.Record)
structure Record where
  inputs : List Linear
  auxiliary : List Linear
  outputs : List Linear
  program : Program
  deriving Inhabited

def f (r : Record) (i : Nat) := get r.inputs i
def lookupRecord (catalog : Catalog) (id : Nat) : LookupEmbedded.Record := ((catalog.find? (fun p => p.1 == id)).getD (id,default)).2

-- Share the reference execution across all eight output columns.
def canonicalTable (r : LookupEmbedded.Record) : Bool :=
  decide (16 ≤ 16) && (List.range (2^16)).all (fun input =>
    let evaluated := LookupReferenceFast.evaluate r.columns r.root r.nodes input
    (List.range r.columns).all (fun field => decide (LookupReferenceFast.read evaluated.sums field = OpcodeCatalog.payload input field)))

theorem canonicalTable_exact (r : LookupEmbedded.Record) :
    canonicalTable r = LookupEmbedded.checkTable r 16 OpcodeCatalog.payload := by
  simp only [canonicalTable,LookupEmbedded.checkTable,LookupReferenceFast.evaluate_eq]

structure TableView where
  id : Nat
  columns : Nat
  root : Nat
  nodes : List LookupMatrix.Node
  deriving Inhabited, DecidableEq

def tableView (entry : Nat × LookupEmbedded.Record) : TableView :=
  ⟨entry.1,entry.2.columns,entry.2.root,entry.2.nodes⟩
def viewRecord (v : TableView) : LookupEmbedded.Record :=
  {(default : LookupEmbedded.Record) with columns := v.columns,root := v.root,nodes := v.nodes}
def catalogViewCheck (views : List TableView) : Bool :=
  decide ((views.map (·.id)).Nodup) && match views.head? with
  | none => true
  | some first => first.columns == 8 && canonicalTable (viewRecord first) &&
    views.all (fun r => decide (r.columns = first.columns ∧ r.root = first.root ∧ r.nodes = first.nodes))
def catalogCheck (catalog : Catalog) : Bool := catalogViewCheck (catalog.map tableView)
def sameTables (a b : Catalog) : Bool := decide (a.map tableView = b.map tableView)
theorem sameTables_checked (a b : Catalog) (checked : catalogCheck a = true) (same : sameTables a b = true) : catalogCheck b = true := by
  have equal := _root_.of_decide_eq_true same
  unfold catalogCheck
  rw [← equal]
  exact checked

def lookup (matrix : Shape) (catalog : Catalog) (p : Program) (opcode : Linear) : Eval (List Linear) := do
  let state ← get
  require (decide (state.usedBlocks < p.blocks.length)) "missing opcode lookup"
  let b := p.blocks.getD state.usedBlocks default
  let r := lookupRecord catalog b.index
  require (decide (b.kind = 2 ∧ b.firstOperation = state.base.used ∧ b.lastOperation = state.base.used ∧
    b.firstGate = state.base.gate ∧ b.firstGate = r.range.call.firstGate ∧ b.lastGate = r.lastGate ∧
    r.columns = 8 ∧ (catalog.map Prod.fst).contains b.index = true ∧ ModuleProgram.sameInputs [opcode] [r.input])) "opcode lookup interface rejected"
  require (LookupEmbedded.check matrix r) "opcode lookup matrix rejected"
  let base := {state.base with gate := b.lastGate}
  set {state with base := base,usedBlocks := state.usedBlocks+1}
  pure r.outputs

def replay (matrix : Shape) (tokens : Tokens) (splits : Splits) (catalog : Catalog) (r : Record) : Eval (List Linear) := do
  let p := r.program
  let active := f r 0
  let branchIndex := f r 1
  let catchIndex := f r 2
  let vectorIndex := f r 3
  let opcode := f r 4
  let primary := f r 5
  let secondary := f r 6
  let pad := f r 7
  let start := f r 8
  let finish := f r 9
  let first := get r.auxiliary 0
  let second := get r.auxiliary 1
  let encoding ← lookup matrix catalog p opcode
  boolean matrix p active
  eq matrix p (get encoding 0) o
  for (value,width) in [(primary,32),(secondary,32),(pad,33),(start,32),(finish,32)] do
    let _ ← range matrix p value width
  let prefixValue ← mul matrix p active (get encoding 1)
  let _ ← read matrix tokens splits p 0 active start prefixValue
  let prefixed ← mul matrix p active (get encoding 2)
  let subPosition ← mul matrix p prefixed (start++o)
  let subValue ← mul matrix p prefixed (get encoding 3)
  let subSize ← read matrix tokens splits p 1 prefixed subPosition subValue
  let mut cursor ← materialize matrix p (start++active++subSize)
  let firstMode ← mul matrix p active (get encoding 6)
  let firstSize ← read matrix tokens splits p 7 firstMode cursor first
  cursor ← materialize matrix p (cursor++firstSize)
  let secondMode ← mul matrix p active (get encoding 7)
  let secondSize ← read matrix tokens splits p 7 secondMode cursor second
  cursor ← materialize matrix p (cursor++secondSize)
  let mut forms := []
  for i in List.range 14 do
    let matching ← zero matrix p (sub (get encoding 4) (n i))
    let selected ← mul matrix p active matching
    forms := forms++[selected]
  let branch := get forms 4
  let catching := get forms 5
  let vector := get forms 13
  let blockLike := get forms 3++catching
  let isIf ← zero matrix p (sub opcode (n 4))
  let conditional ← mul matrix p active isIf
  let count ← select matrix p branch first second
  let words ← split matrix tokens splits p first
  let ordinary := get forms 1++get forms 7++get forms 9++get forms 11++get forms 12
  let wide := get forms 8++get forms 10
  let pairFirst ← select matrix p (get encoding 5) second first
  let pairSecond ← select matrix p (get encoding 5) first second
  let a ← mul matrix p ordinary first
  let b ← mul matrix p wide words.1
  let c ← mul matrix p (get forms 2) pairFirst
  let d ← mul matrix p (get forms 6) second
  let e ← mul matrix p branch branchIndex
  let g ← mul matrix p vector vectorIndex
  let h ← mul matrix p blockLike primary
  eq matrix p primary (a++b++c++d++e++g++h)
  let a ← mul matrix p wide words.2
  let b ← mul matrix p (get forms 2) pairSecond
  let c ← mul matrix p catching catchIndex
  let d ← mul matrix p conditional secondary
  eq matrix p secondary (a++b++c++d)
  raw matrix (gate (get forms 6) (sub first o))
  let bits ← range matrix p first 64
  let positive := sub o (get bits 32)
  let mut allowed := positive
  let mut blockPad ← mul matrix p positive (first++n 256)
  for (value,padValue) in [(64,0),(1,1),(2,2),(3,3),(4,4),(5,5),(16,6),(17,7)] do
    let matching ← zero matrix p (sub first (n (2^33-value)))
    allowed := allowed++matching
    blockPad := blockPad++scale matching (Int.ofNat padValue)
  raw matrix (gate blockLike (sub allowed o))
  let negativeBlock ← mul matrix p blockLike (get bits 32)
  raw matrix (gate negativeBlock (sub firstSize o))
  let actualPad ← mul matrix p blockLike blockPad
  eq matrix p pad actualPad
  pure [cursor,branch,catching,vector,blockLike,conditional,count]

def check (matrix : Shape) (tokens : Tokens) (splits : Splits) (catalog : Catalog) (r : Record) : Bool :=
  decide (r.inputs.length = 10 ∧ r.auxiliary.length = 2 ∧ r.outputs.length = 7) &&
  match (replay matrix tokens splits catalog r).run (init r.program) with
  | .error _ => false
  | .ok (outputs,state) => decide (finished r.program state ∧ ModuleProgram.sameInputs outputs r.outputs) &&
      auditState matrix tokens splits state
end ZkBuild.InstructionDecodeMatrix
