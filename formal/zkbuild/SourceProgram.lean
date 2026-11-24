import ModuleProgramSound
import ModuleContextAuditIO
set_option autoImplicit false
namespace ZkBuild.SourceProgram
open CircuitShape GadgetShape DeclarationMatrix
structure Block where
  kind : Nat
  index : Nat
  firstOperation : Nat
  lastOperation : Nat
  firstGate : Nat
  lastGate : Nat
  deriving Inhabited
structure Program where
  base : ModuleProgram.Program
  blocks : List Block
  deriving Inhabited
structure Contract where
  block : Block
  kind : Nat
  first : Nat
  second : Nat
  inputs : List Linear
  deriving Inhabited
structure State where
  base : ModuleProgram.State
  usedBlocks : Nat := 0
  contracts : List Contract := []
  deriving Inhabited
abbrev Eval := StateT State (Except String)

def primitive {α : Type} (action : ModuleProgram.Eval α) : Eval α := do
  let state ← get
  let (result,next) ← match action.run state.base with
    | .error error => throw error
    | .ok value => pure value
  set {state with base := next}
  pure result

def eq (m : Shape) (p : Program) (a b : Linear) := primitive (ModuleProgram.eq m p.base a b)
def mul (m : Shape) (p : Program) (a b : Linear) := primitive (ModuleProgram.mul m p.base a b)
def materialize (m : Shape) (p : Program) (a : Linear) := primitive (ModuleProgram.materialize m p.base a)
def boolean (m : Shape) (p : Program) (a : Linear) := primitive (ModuleProgram.boolean m p.base a)
def select (m : Shape) (p : Program) (s a b : Linear) := primitive (ModuleProgram.select m p.base s a b)
def zero (m : Shape) (p : Program) (a : Linear) := primitive (ModuleProgram.zero m p.base a)
def range (m : Shape) (p : Program) (a : Linear) (width : Nat) := primitive (ModuleProgram.range m p.base a width)
def raw (m : Shape) (gate : Gate) := primitive (ModuleProgram.raw m gate)
def require (condition : Bool) (message : String) : Eval Unit := if condition then pure () else throw message

def checkContract (matrix : Shape) (tokens : Tokens) (splits : Splits) (c : Contract) : Bool :=
  c.block.kind == c.kind && match c.kind with
  | 0 =>
    let token := tokens.getD c.block.index default
    decide (c.block.index < tokens.length ∧ token.kind = c.first ∧ c.second = 0 ∧
      token.firstGate = c.block.firstGate ∧ token.lastGate = c.block.lastGate ∧
      ModuleProgram.sameInputs c.inputs [token.activeMode,token.position,token.value]) && BinaryTokenMatrix.check matrix token
  | 1 =>
    let split := splits.getD c.block.index default
    decide (c.block.index < splits.length ∧ split.lowWidth = c.first ∧ split.highWidth = c.second ∧
      split.range.call.firstGate = c.block.firstGate ∧ split.lastGate = c.block.lastGate ∧
      ModuleProgram.sameInputs c.inputs [split.value]) && PackedFields.check matrix split
  | _ => false

def external (matrix : Shape) (tokens : Tokens) (splits : Splits) (p : Program)
    (kind first second : Nat) (inputs : List Linear) : Eval (List Linear) := do
  let state ← get
  require (decide (state.usedBlocks < p.blocks.length)) "missing certified source helper"
  let block := p.blocks.getD state.usedBlocks default
  let contract : Contract := ⟨block,kind,first,second,inputs⟩
  require (decide (block.firstGate = state.base.gate ∧ block.firstOperation = state.base.used ∧
    block.firstOperation = block.lastOperation ∧ block.lastOperation ≤ p.base.operations.length ∧ block.firstGate ≤ block.lastGate))
    "source helper extent rejected"
  require (checkContract matrix tokens splits contract) s!"source helper {state.usedBlocks} rejected (kind {kind}, index {block.index})"
  let base := {state.base with gate := block.lastGate,used := block.lastOperation}
  set {state with base := base,usedBlocks := state.usedBlocks+1,contracts := state.contracts++[contract]}
  if kind == 0 then pure [(tokens.getD block.index default).length]
  else let s := splits.getD block.index default; pure [s.low,s.high]

def read (m : Shape) (ts : Tokens) (ss : Splits) (p : Program) (kind : Nat) (active position value : Linear) : Eval Linear := do
  let output ← external m ts ss p 0 kind 0 [active,position,value]
  pure (output.getD 0 z)
def split (m : Shape) (ts : Tokens) (ss : Splits) (p : Program) (value : Linear) (low : Nat := 32) (high : Nat := 32) : Eval (Linear × Linear) := do
  let output ← external m ts ss p 1 low high [value]
  pure (output.getD 0 z,output.getD 1 z)
def init (p : Program) : State := {base := ModuleProgram.init p.base}
def finished (p : Program) (s : State) := ModuleProgram.finished p.base s.base ∧ s.usedBlocks = p.blocks.length
instance (p : Program) (s : State) : Decidable (finished p s) := by unfold finished; infer_instance

def auditState (matrix : Shape) (tokens : Tokens) (splits : Splits) (s : State) :=
  ModuleProgram.auditState matrix s.base && s.contracts.all (checkContract matrix tokens splits)
end ZkBuild.SourceProgram
