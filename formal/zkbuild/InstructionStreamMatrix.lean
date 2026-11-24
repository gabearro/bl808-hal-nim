import InstructionDecodeMatrix
import BodySourceCommitted
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.InstructionStreamMatrix
open CircuitShape GadgetShape DeclarationMatrix SourceProgram
abbrev Fields := List Linear
abbrev Entry := ReadOnlyMatrix.Entry
structure Row where
  fields : Fields
  frame : Linear
  decoder : Nat
  labels : Nat
  catches : Nat
  deriving Inhabited
structure Record where
  flat : Bool
  firstFunction : Linear
  bodySizes : List Nat
  rows : List Row
  spans : List Entry
  functions : List Fields
  labels : List Fields
  catches : List Fields
  events : List Fields
  banks : List Nat
  program : Program
  memory : MemoryEmbedded.Record
  deriving Inhabited
structure Acc where
  queries : List (List Entry) := List.replicate 16 []
  entries : List (List Entry) := List.replicate 16 []
  frames : List Fields := []
  deriving Inhabited

def f (xs : Fields) (i : Nat) := get xs i
def bank (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) :=
  let actual := if r.flat then i else ([0,8,9,10,0,5,0,2,1,3,4,6,7,0,0,0] : List Nat).getD i 0
  tables.getD (r.banks.getD actual 0) default
def put (lists : List (List Entry)) (i : Nat) (entry : Entry) := lists.take i ++ [lists.getD i [] ++ [entry]] ++ lists.drop (i+1)
def addEntry (a : Acc) (i : Nat) (entry : Entry) := {a with entries := put a.entries i entry}
def addFrame (a : Acc) (active write address value : Linear) := {a with frames := a.frames++[[active,write,address,value]]}
def query (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : Record) (a : Acc)
    (i : Nat) (active key : Linear) : Eval (Linear × Acc) := do
  let rows := (bank tables r i).queries
  let index := (a.queries.getD i []).length
  require (decide (index < rows.length)) s!"missing instruction query {i}:{index}"
  let row := rows.getD index default
  let address ← mul matrix r.program active key
  require (decide (ModuleContextMatrix.normalizedEntries [row] = ModuleContextMatrix.normalizedEntries [⟨active,address,row.value⟩])) s!"instruction query {i}:{index} rejected"
  pure (row.value,{a with queries := put a.queries i row})
def packedBits (matrix : Shape) (p : Program) (bits : Fields) : Eval Linear := do
  let value := ((List.range bits.length).map (fun i => scale (f bits i) (Int.ofNat (2^i)))).foldl (·++·) z
  materialize matrix p value

def decode (matrix : Shape) (tokens : Tokens) (splits : Splits) (catalog : InstructionDecodeMatrix.Catalog)
    (decoders : List InstructionDecodeMatrix.Record) (r : Record) (row : Row) (b c v : Linear) : Eval Fields := do
  let state ← get
  require (decide (state.usedBlocks < r.program.blocks.length ∧ row.decoder < decoders.length)) "missing instruction decoder"
  let helper := r.program.blocks.getD state.usedBlocks default
  let d := decoders.getD row.decoder default
  require (decide (helper.kind = 3 ∧ helper.index = row.decoder ∧ helper.firstOperation = state.base.used ∧ helper.lastOperation = state.base.used ∧
    helper.firstGate = state.base.gate ∧ helper.firstGate = d.program.base.firstGate ∧ helper.lastGate = d.program.base.lastGate ∧
    ModuleProgram.sameInputs d.inputs ([f row.fields 0,b,c,v]++row.fields.drop 3))) "instruction decoder interface rejected"
  require (InstructionDecodeMatrix.check matrix tokens splits catalog d) "instruction decoder rejected"
  let base := {state.base with gate := helper.lastGate}
  set {state with base := base,usedBlocks := state.usedBlocks+1}
  pure d.outputs

def events (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : Record) (a : Acc) : Eval Acc := do
  let p := r.program
  let mut a := a
  for row in r.events do
    let kind := f row 0
    let fn := f row 1
    let pc := f row 2
    let opcode := f row 3
    let primary := f row 4
    let secondary := f row 5
    let pad := f row 6
    for (value,width) in [(fn,32),(pc,32),(opcode,16),(primary,32),(secondary,32),(pad,33)] do
      let _ ← range matrix p value width
    let begin ← zero matrix p (sub kind (n 1))
    let ending ← zero matrix p (sub kind (n 8))
    let key := scale fn (Int.ofNat (2^32))++pc
    let (info,next) ← query matrix tables r a 11 begin key
    a := next
    let (immediate,next) ← query matrix tables r a 12 begin key
    a := next
    raw matrix (gate begin (sub (sub info opcode) (scale pad 65536)))
    raw matrix (gate begin (sub (sub immediate primary) (scale secondary (Int.ofNat (2^32)))))
    let (last,next) ← query matrix tables r a 1 ending fn
    a := next
    raw matrix (gate ending (sub last pc))
  pure a

def bankBounds (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (r : Record) (a : Acc) : Eval Acc := do
  let mut a := a
  for i in [6,7] do
    for row in (bank tables r i).entries do
      let key ← split matrix tokens splits r.program row.address
      let (count,next) ← query matrix tables r a (if i == 6 then 2 else 3) row.active key.2
      a := next
      let distance ← mul matrix r.program row.active (sub (sub count key.1) o)
      let _ ← range matrix r.program distance 32
  pure a

def frameCheck (matrix : Shape) (r : Record) (a : Acc) : Bool :=
  decide (r.memory.addressBits = 64 ∧ r.memory.valueBits = 34 ∧ a.frames.length ≤ r.memory.inputs.length ∧
    r.memory.inputs.map (fun x => BinaryReadMemory.normalizedPayload x.fields) =
      ((List.range r.memory.inputs.length).map (fun i =>
        let row := a.frames.getD i [z,z,z,z]
        BinaryReadMemory.normalizedPayload ⟨f row 0,f row 1,f row 2,f row 3,n i⟩))) && MemoryEmbedded.check matrix r.memory
end ZkBuild.InstructionStreamMatrix
