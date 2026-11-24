import InstructionStreamCheck
import StaticLookupEmbedded
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.ValidationEventMatrix
open CircuitShape GadgetShape DeclarationMatrix SourceProgram
abbrev Fields := List Linear
abbrev LookupCatalog := List (Nat × LookupEmbedded.Record)
abbrev StaticCatalog := List (Nat × StaticLookupEmbedded.Record)
structure Stage where
  kind : Nat
  firstFunction : Linear
  rows : List Fields
  flags : List Fields
  inputs : List Fields
  outputs : List Fields
  program : Program
  deriving Inhabited
structure Record where
  firstFunction : Linear
  rows : List Fields
  stages : List Stage
  operand : MemoryEmbedded.Record
  control : MemoryEmbedded.Record
  deriving Inhabited

def f (row : Fields) (i : Nat) := DeclarationMatrix.get row i
def rowAt (rows : List Fields) (i : Nat) := rows.getD i []
def normalized (rows : List Fields) := rows.map (List.map normalizeLinear)
def e : Linear := []
def bit (m : Shape) (p : Program) : Eval Linear := do
  let outputs ← primitive (ModuleProgram.call m p.base 3 [])
  pure (outputs.getD 0 [])

def admission (matrix : Shape) (catalog : LookupCatalog) (s : Stage) (opcode : Linear) : Eval Linear := do
  let state ← get
  require (decide (state.usedBlocks < s.program.blocks.length)) "missing admission lookup"
  let helper := s.program.blocks.getD state.usedBlocks default
  let found := catalog.find? (fun pair => pair.1 == helper.index)
  require found.isSome "admission lookup ID rejected"
  let r := (found.getD (0,default)).2
  require (decide (helper.kind = 2 ∧ helper.firstOperation = state.base.used ∧ helper.lastOperation = state.base.used ∧
    helper.firstGate = state.base.gate ∧ helper.firstGate = r.range.call.firstGate ∧ helper.lastGate = r.lastGate ∧
    r.columns = 1 ∧ ModuleProgram.sameInputs [opcode] [r.input])) "admission lookup interface rejected"
  require (LookupEmbedded.check matrix r) "admission lookup matrix rejected"
  set {state with base := {state.base with gate := helper.lastGate},usedBlocks := state.usedBlocks+1}
  pure (r.outputs.getD 0 [])

def staticRule (matrix : Shape) (catalog : StaticCatalog) (s : Stage) (opcode index actual : Linear) : Eval Fields := do
  let state ← get
  require (decide (state.usedBlocks < s.program.blocks.length)) "missing static lookup"
  let helper := s.program.blocks.getD state.usedBlocks default
  let found := catalog.find? (fun pair => pair.1 == helper.index)
  require found.isSome "static lookup ID rejected"
  let r := (found.getD (0,default)).2
  require (decide (helper.kind = 4 ∧ helper.firstOperation = state.base.used ∧ helper.lastOperation = state.base.used ∧
    helper.firstGate = state.base.gate ∧ helper.firstGate = r.firstGate ∧ helper.lastGate = r.lastGate ∧
    ModuleProgram.sameInputs [opcode,index,actual] r.inputs)) "static lookup interface rejected"
  require (StaticLookupEmbedded.check matrix r) "static lookup matrix rejected"
  set {state with base := {state.base with gate := helper.lastGate},usedBlocks := state.usedBlocks+1}
  pure r.outputs

def replayAdmission (matrix : Shape) (catalog : LookupCatalog) (s : Stage) : Eval (List Fields) := do
  for row in s.rows do
    let value ← admission matrix catalog s (f row 8)
    eq matrix s.program value o
  pure []

def replayOperands (matrix : Shape) (s : Stage) : Eval (List Fields × List Fields) := do
  let p := s.program
  let mut previousHeight := z
  let mut previousPadding := z
  let mut flags := []
  let mut accesses := []
  for row in s.rows do
    let mut tags := []
    let mut total := e
    let mut packed := e
    for code in ([0,1,2,3,4,5,6,7,8,9,15] : List Nat) do
      let selected ← bit matrix p
      tags := tags++[selected]
      total := total++selected
      if code != 0 then packed := packed++scale selected (Int.ofNat code)
    eq matrix p total o
    eq matrix p (f row 0) packed
    let push := f tags 2
    let pop := f tags 3
    let clear := f tags 6
    let padding := f tags 10
    for (value,width) in [(f row 1,32),(f row 2,32),(f row 3,32),(f row 4,3)] do
      let _ ← range matrix p value width
    boolean matrix p (f row 5)
    boolean matrix p (f row 6)
    raw matrix (gate (f row 5) (sub o pop))
    raw matrix (gate (f row 5) (sub (f row 4) (n 7)))
    raw matrix (gate (sub (sub o push) pop) (sub (f row 4) (n 7)))
    raw matrix (gate (f row 5) (sub previousHeight (f row 3)))
    raw matrix (gate (f row 5) (sub o (f row 6)))
    let realPop := sub pop (f row 5)
    let available ← mul matrix p (pop++clear) (sub previousHeight (f row 3))
    let _ ← range matrix p (sub available realPop) 32
    let discarded ← mul matrix p clear (sub previousHeight (f row 3))
    eq matrix p (f row 2) (sub (sub (previousHeight++push) realPop) discarded)
    raw matrix (gate (f tags 0++f tags 8) (f row 2))
    raw matrix (gate previousPadding (sub o padding))
    for value in [f row 1,f row 3,f row 6] do raw matrix (gate padding value)
    let active := push++realPop
    let address ← mul matrix p active (sub (scale (f row 1) (Int.ofNat (2^32))++f row 2) push)
    let value ← mul matrix p active (f row 4)
    accesses := accesses++[[active,push,address,value]]
    flags := flags++[tags]
    previousHeight := f row 2
    previousPadding := padding
  eq matrix p previousHeight z
  pure (flags,accesses)

def replayControl (matrix : Shape) (s : Stage) : Eval (List Fields) := do
  let p := s.program
  let _ ← range matrix p s.firstFunction 32
  let mut beforeDepth := z
  let mut beforeHeight := z
  let mut functionOpen := z
  let mut functionIndex := s.firstFunction
  let mut accesses := []
  for i in List.range s.rows.length do
    let row := rowAt s.rows i
    let flags := rowAt s.flags i
    let _ ← range matrix p (f row 7) 32
    let empty ← zero matrix p beforeDepth
    let nonempty := sub o empty
    raw matrix (gate empty (scale (f row 3) 2++f row 6))
    raw matrix (gate (f flags 5++f flags 6) empty)
    raw matrix (gate (f (rowAt s.inputs i) 0++f row 5) empty)
    eq matrix p (f row 7) (sub (beforeDepth++f flags 4) (f flags 5))
    raw matrix (gate (f flags 5) (sub (f row 2) (f row 3)))
    raw matrix (gate (f flags 0++f flags 8++f flags 10) (f row 7))
    raw matrix (gate (f flags 0++f flags 10) functionOpen)
    raw matrix (gate (sub (sub o (f flags 0)) (f flags 10)) (sub o functionOpen))
    raw matrix (gate (sub o (f flags 10)) (sub (f row 1) functionIndex))
    functionOpen ← materialize matrix p (sub (functionOpen++f flags 0) (f flags 8))
    functionIndex ← materialize matrix p (functionIndex++f flags 8)
    let space := scale (f row 1) (Int.ofNat (2^32))
    let address ← mul matrix p nonempty (sub (space++beforeDepth) o)
    let value ← mul matrix p nonempty (scale (f row 3) 2++f row 6)
    accesses := accesses++[[nonempty,z,address,value]]
    let active := f flags 4++f flags 6
    let address ← mul matrix p active (sub (space++beforeDepth) (f flags 6))
    let pushed ← mul matrix p (f flags 4) beforeHeight
    let cleared ← mul matrix p (f flags 6) (f row 3)
    accesses := accesses++[[active,active,address,scale (pushed++cleared) 2++f flags 6]]
    beforeDepth := f row 7
    beforeHeight := f row 2
  eq matrix p beforeDepth z
  eq matrix p functionOpen z
  pure accesses

def replayInstructions (matrix : Shape) (catalog : StaticCatalog) (s : Stage) : Eval Unit := do
  let p := s.program
  let mut opened := z
  let mut rootPending := z
  let mut nextPc := z
  let mut opcode := n 2
  let mut pops := z
  let mut pushes := z
  let mut clears := z
  for i in List.range s.rows.length do
    let row := rowAt s.rows i
    let flags := rowAt s.flags i
    let begin := f flags 1
    let finish := f flags 7
    let newInstruction := f flags 0++begin
    let _ ← range matrix p (f row 9) 32
    raw matrix (gate rootPending (sub o (f flags 4)))
    raw matrix (gate rootPending opened)
    raw matrix (gate begin opened)
    raw matrix (gate finish (sub o opened))
    raw matrix (gate (f flags 0++f flags 8++f flags 10) opened)
    let middle := f flags 2++f flags 3++f flags 4++f flags 5++f flags 6++f flags 9
    let branch ← zero matrix p (sub (f row 8) (n 14))
    let catching ← zero matrix p (sub (f row 8) (n 31))
    raw matrix (gate (f flags 9) (sub (sub o branch) catching))
    raw matrix (gate (sub middle rootPending) (sub o opened))
    let pc ← select matrix p (f flags 0) z nextPc
    raw matrix (gate (sub o (f flags 10)) (sub (f row 9) pc++f flags 8))
    raw matrix (gate (f flags 10) (f row 9))
    nextPc ← materialize matrix p (pc++finish)
    opcode ← select matrix p newInstruction (f row 8) opcode
    raw matrix (gate (sub o (f flags 10)) (sub (f row 8) opcode))
    raw matrix (gate (f flags 0) (sub (f row 8) (n 2)))
    raw matrix (gate (f flags 8) (sub (f row 8) (n 11)))
    raw matrix (gate (f flags 10) (f row 8))
    let beforePops ← select matrix p newInstruction z pops
    let beforePushes ← select matrix p newInstruction z pushes
    let beforeClears ← select matrix p newInstruction z clears
    let rule ← staticRule matrix catalog s (f row 8) beforePops (f row 4)
    let typedPop ← mul matrix p (f rule 0) (f flags 3)
    let typedPush ← mul matrix p (f rule 0) (f flags 2)
    raw matrix (gate typedPop (sub beforePops (f rule 6)))
    raw matrix (gate typedPop (sub o (f rule 5)))
    raw matrix (gate typedPop beforePushes)
    raw matrix (gate typedPush (sub (f row 4) (f rule 3)))
    raw matrix (gate typedPush (sub o (f rule 2)))
    raw matrix (gate typedPush (sub beforePops (f rule 1)))
    raw matrix (gate typedPush beforePushes)
    raw matrix (gate (f rule 0) (f flags 4++f flags 5))
    let typedClear ← mul matrix p (f rule 0) (f flags 6)
    raw matrix (gate typedClear (sub o (f rule 4)))
    raw matrix (gate typedClear beforeClears)
    let typedEnd ← mul matrix p (f rule 0) finish
    raw matrix (gate typedEnd (sub beforePops (f rule 1)))
    raw matrix (gate typedEnd (sub beforePushes (f rule 2)))
    raw matrix (gate typedEnd (sub beforeClears (f rule 4)))
    pops ← materialize matrix p (beforePops++f flags 3)
    pushes ← materialize matrix p (beforePushes++f flags 2)
    clears ← materialize matrix p (beforeClears++f flags 6)
    opened ← materialize matrix p (sub (opened++begin) finish)
    rootPending := f flags 0
  eq matrix p opened z
  eq matrix p rootPending z
end ZkBuild.ValidationEventMatrix
