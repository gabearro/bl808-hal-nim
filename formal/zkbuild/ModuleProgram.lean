import SegmentPayloadSoundness
set_option autoImplicit false
namespace ZkBuild.ModuleProgram
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix
attribute [local instance] Semiring.natCast Ring.intCast

structure Program where
  firstGate : Nat
  lastGate : Nat
  operations : List RangeUse.Record
  deriving Inhabited
structure Contract where
  kind : Nat
  width : Nat
  inputs : List Linear
  operation : RangeUse.Record
  deriving Inhabited
structure Raw where
  index : Nat
  value : Gate
  deriving Inhabited
structure State where
  gate : Nat
  used : Nat := 0
  contracts : List Contract := []
  raw : List Raw := []
  deriving Inhabited
abbrev Eval := StateT State (Except String)

def sameInputs (xs ys : List Linear) := xs.map normalizeLinear = ys.map normalizeLinear
instance (xs ys : List Linear) : Decidable (sameInputs xs ys) := by unfold sameInputs; infer_instance

def checkContract (matrix : Shape) (c : Contract) : Bool :=
  decide (sameInputs c.inputs c.operation.call.inputs) &&
  (if c.kind = 8 then
    RangeUse.check matrix c.operation (c.operation.call.inputs.getD 0 []) c.width
   else decide (c.operation.call.kind = c.kind ∧ c.operation.source.isNone = true) &&
    GadgetAudit.check matrix c.operation.call c.operation.source)

def call (matrix : Shape) (p : Program) (kind : Nat) (inputs : List Linear) (width : Nat := 0) : Eval (List Linear) := do
  let s ← get
  if s.used ≥ p.operations.length then throw "missing module primitive"
  let operation := p.operations.getD s.used default
  let contract : Contract := ⟨kind,width,inputs,operation⟩
  if operation.call.firstGate != s.gate || !checkContract matrix contract then throw s!"module primitive {s.used} rejected: expected kind={kind} gate={s.gate} inputs={reprStr (inputs.map normalizeLinear)} actual kind={operation.call.kind} gate={operation.call.firstGate} inputs={reprStr (operation.call.inputs.map normalizeLinear)}"
  set {s with gate := operation.call.lastGate,used := s.used+1,contracts := s.contracts++[contract]}
  pure operation.call.outputs

def raw (matrix : Shape) (g : Gate) : Eval Unit := do
  let s ← get
  if !MemoryEvidence.checkSpan matrix s.gate (s.gate+1) [g] then throw s!"module raw gate {s.gate} rejected: expected={reprStr (normalizeGate g)} actual={reprStr (matrix.gates[s.gate]?.map normalizeGate)}"
  set {s with gate := s.gate+1,raw := s.raw++[({index := s.gate,value := g} : Raw)]}

def eq (matrix : Shape) (p : Program) (a b : Linear) : Eval Unit := do
  let _ ← call matrix p 0 [a,b]
  pure ()
def mul (matrix : Shape) (p : Program) (a b : Linear) : Eval Linear := do
  let outputs ← call matrix p 1 [a,b]
  pure (outputs.getD 0 z)
def materialize (matrix : Shape) (p : Program) (a : Linear) : Eval Linear := do
  let outputs ← call matrix p 2 [a]
  pure (outputs.getD 0 z)
def boolean (matrix : Shape) (p : Program) (a : Linear) : Eval Unit := do
  let _ ← call matrix p 4 [a]
  pure ()
def select (matrix : Shape) (p : Program) (s yes no : Linear) : Eval Linear := do
  let outputs ← call matrix p 6 [s,yes,no]
  pure (outputs.getD 0 z)
def zero (matrix : Shape) (p : Program) (a : Linear) : Eval Linear := do
  let outputs ← call matrix p 7 [a]
  pure (outputs.getD 0 z)
def range (matrix : Shape) (p : Program) (a : Linear) (width : Nat) : Eval (List Linear) := call matrix p 8 [a] width

def init (p : Program) : State := {gate := p.firstGate}
def finished (p : Program) (s : State) := s.gate = p.lastGate ∧ s.used = p.operations.length
instance (p : Program) (s : State) : Decidable (finished p s) := by unfold finished; infer_instance

def auditState (matrix : Shape) (s : State) :=
  s.contracts.all (checkContract matrix) && s.raw.all (fun r => MemoryEvidence.checkSpan matrix r.index (r.index+1) [r.value])

theorem contract_inputs {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (c : Contract) (checked : checkContract matrix c = true) (values : Nat → F) :
    c.inputs.map (E values) = c.operation.call.inputs.map (E values) := by
  have same := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1
  have h := congrArg (List.map (fun l => R1CS.eval values (interpretLinear (F := F) l))) same
  change c.inputs.map (fun l => R1CS.eval values (interpretLinear l)) = c.operation.call.inputs.map (fun l => R1CS.eval values (interpretLinear l))
  simpa only [List.map_map,Function.comp_def,normalized_linear_same_field] using h

theorem range_certificate {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (c : Contract) (kind : c.kind = 8) (checked : checkContract matrix c = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    RangeReuse.Certificate c.width (E values (c.inputs.getD 0 [])) (c.operation.call.outputs.map (E values)) := by
  have input := contract_inputs matrix c checked values
  have checkRange : RangeUse.check matrix c.operation (c.operation.call.inputs.getD 0 []) c.width = true := by
    simpa only [checkContract,kind,ite_true,Bool.and_eq_true_iff] using (Bool.and_eq_true_iff.mp checked).2
  have certificate := RangeUse.checked_certificate matrix _ _ _ checkRange values oneValue satisfied
  have fields : c.operation.call.width = c.width ∧ c.operation.call.inputs = [c.operation.call.inputs.getD 0 []] ∧
      (c.operation.call.kind = 8 ∨ c.operation.call.kind = 9 ∨ c.operation.call.kind = 10) := by
    have h := checkRange
    simp only [RangeUse.check,Bool.and_eq_true_iff,decide_eq_true_eq] at h
    exact h.1.1
  have arity : c.inputs.length = 1 := by
    have sizes := congrArg List.length input
    have actualLen := congrArg List.length fields.2.1
    simp only [List.length_singleton] at actualLen
    simpa only [List.length_map,actualLen] using sizes
  obtain ⟨value,form⟩ := List.length_eq_one_iff.mp arity
  have sameFirst : E values (c.inputs.getD 0 []) = E values (c.operation.call.inputs.getD 0 []) := by
    have left : [E values value] = c.operation.call.inputs.map (E values) := by
      simpa only [form,List.map_cons,List.map_nil] using input
    have right := congrArg (List.map (E values)) fields.2.1
    have first := (List.cons.inj (left.trans right)).1
    change E values value = E values (c.operation.call.inputs.getD 0 []) at first
    simpa only [form,List.getD_cons_zero] using first
  rw [sameFirst]
  exact certificate

theorem range_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (c : Contract) (kind : c.kind = 8) (checked : checkContract matrix c = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ n : Nat, n < 2^c.width ∧ E values (c.inputs.getD 0 []) = (n : F) :=
  RangeReuse.certificate_sound _ _ _ (range_certificate matrix c kind checked values oneValue satisfied)

theorem raw_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : State) (checked : auditState matrix s = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : ∀ r ∈ s.raw, Holds values r.value := by
  intro r member
  have h := List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 r member
  have all := MemoryEvidence.span_sound matrix r.index (r.index+1) [r.value] h values satisfied
  exact all _ (by simp)

#print axioms contract_inputs
#print axioms range_certificate
#print axioms range_sound
#print axioms raw_sound
end ZkBuild.ModuleProgram
