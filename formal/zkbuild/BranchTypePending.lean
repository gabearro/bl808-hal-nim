import BranchTypeScalar
set_option autoImplicit false
namespace ZkBuild.BranchTypePending
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents BranchTypeRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

def reset (kind : Kind) : Bool := decide (kind = .functionBegin ∨ kind = .instructionBegin)
def selected (kind target : Kind) (code : Nat) : Bool := decide (kind = target ∧ code = 14)
def prepare (kind : Kind) (code : Nat) (before : Bool) : Bool :=
  if reset kind then selected kind .instructionBegin code else before
def advance (kind : Kind) (code : Nat) (ready : Bool) : Bool := ready && !(selected kind .pop code)

structure Masks {F : Type} [Field F] (values : Nat → F) (r : BranchTypeRowCheck.Record)
    (kind : Kind) (code : Nat) (ready : Bool) : Prop where
  table : E values (f r.after 0) = flag (decide (code = 14))
  begin : E values (f r.after 6) = flag (selected kind .instructionBegin code)
  pop : E values (f r.after 32) = flag (selected kind .pop code)
  push : E values (f r.after 34) = flag (selected kind .push code)
  clear : E values (f r.after 35) = flag (selected kind .clear code)
  finish : E values (f r.after 52) = flag (selected kind .instructionEnd code)
  pending : E values (f r.after 7) = flag ready
  condition : E values (f r.after 33) = flag (selected kind .pop code && ready)
  argument : E values (BranchTypeRowCheck.argument r) = flag (selected kind .pop code && !ready)
  next : E values (f r.after 50) = flag (advance kind code ready)

theorem step {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : BranchTypeRowCheck.Record)
    (m : BranchTypeRowSound.Meaning values r) (kind : Kind) (code : Nat)
    (cb : code < 2^16) (ci : E values (f r.row 8) = (code : F))
    (tags : BranchTypeCertificate.Tags values r kind code) (before : Bool)
    (bi : E values (f r.before 5) = flag before) :
    Masks values r kind code (prepare kind code before) := by
  have table := BranchTypeScalar.indicator values one r m (f r.row 8) code 14 0
    (by omega) (by decide) ci (by simp [zeros])
  have beginEq := m.multiply (f r.flags 1) (f r.after 0) 6 (by simp [multiplies])
  have beginImage : E values (f r.after 6) = flag (selected kind .instructionBegin code) := by
    rw [beginEq,tags.instructionBegin,table]
    by_cases k : kind = .instructionBegin <;> by_cases c : code = 14 <;> simp [selected,flag,k,c] <;> grind only
  have masked (target : Kind) (flagIndex output : Nat)
      (tag : E values (f r.flags flagIndex) = flag (decide (kind = target)))
      (mul : (f r.after 0,f r.flags flagIndex,output) ∈ multiplies r) :
      E values (f r.after output) = flag (selected kind target code) := by
    rw [m.multiply _ _ _ mul,table,tag]
    by_cases k : kind = target <;> by_cases c : code = 14 <;> simp [selected,flag,k,c] <;> grind only
  have pop := masked .pop 3 32 tags.pop (by simp [multiplies])
  have push := masked .push 2 34 tags.push (by simp [multiplies])
  have clear := masked .clear 6 35 tags.clear (by simp [multiplies])
  have finish := masked .instructionEnd 7 52 tags.instructionEnd (by simp [multiplies])
  have readyEq := m.select (f r.flags 0++f r.flags 1) (f r.after 6) (f r.before 5) 7 (by simp [selects])
  have sum : E values (f r.flags 0++f r.flags 1) = E values (f r.flags 0)+E values (f r.flags 1) := eval_append values _ _
  have readyImage : E values (f r.after 7) = flag (prepare kind code before) := by
    rw [readyEq,sum,tags.functionBegin,tags.instructionBegin,beginImage,bi]
    cases kind <;> simp [prepare,reset,selected,flag] <;> grind only
  have conditionEq := m.multiply (f r.after 32) (f r.after 7) 33 (by simp [multiplies])
  have condition : E values (f r.after 33) = flag (selected kind .pop code && prepare kind code before) := by
    rw [conditionEq,pop,readyImage]
    cases selected kind .pop code <;> cases prepare kind code before <;> simp [flag] <;> grind only
  have argument : E values (BranchTypeRowCheck.argument r) = flag (selected kind .pop code && !(prepare kind code before)) := by
    rw [BranchTypeRowCheck.argument,eval_sub,pop,condition]
    cases selected kind .pop code <;> cases prepare kind code before <;> simp [flag] <;> grind only
  have nextEq := m.equality (sub (f r.after 7) (f r.after 33)) 50 (by simp [equalities])
  have next : E values (f r.after 50) = flag (advance kind code (prepare kind code before)) := by
    rw [nextEq,eval_sub,readyImage,condition]
    unfold advance
    cases selected kind .pop code <;> cases prepare kind code before <;> simp [flag] <;> grind only
  exact ⟨table,beginImage,pop,push,clear,finish,readyImage,condition,argument,next⟩

def state (rows : List Row) (ops : List Nat) : Nat → Bool
  | 0 => false
  | i+1 => advance (rows.getD i default).kind (ops.getD i 0)
      (prepare (rows.getD i default).kind (ops.getD i 0) (state rows ops i))

theorem invariant {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∀ i, i ≤ rows.length →
      E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).before 5) = flag (state rows ops i) := by
  intro i ib
  induction i with
  | zero => simp [BranchTypeRowCheck.record,f,DeclarationMatrix.get,state,z,eval_constant values one,Ring.intCast_zero,flag]
  | succ i ih =>
    have rb : i < rows.length := by omega
    have row := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i rb
    have masks := step values one _ (BranchTypeRowSound.meaning matrix _ row.1 values one satisfied)
      _ _ (schedule.opcode i rb).1 row.2.2.2 row.2.1 (state rows ops i) (ih (by omega))
    simpa [BranchTypeRowCheck.record,f,DeclarationMatrix.get,state] using masks.next

def Trace {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i < rows.length → Masks values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i)
    (rows.getD i default).kind (ops.getD i 0) (prepare (rows.getD i default).kind (ops.getD i 0) (state rows ops i))

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Trace values splits r rows ops := by
  intro i ib
  have row := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i ib
  exact step values one _ (BranchTypeRowSound.meaning matrix _ row.1 values one satisfied)
    _ _ (schedule.opcode i ib).1 row.2.2.2 row.2.1 (state rows ops i)
    (invariant matrix splits tables statics events r checked values one satisfied rows ops images schedule i (by omega))

#print axioms step
#print axioms invariant
#print axioms sound
end ZkBuild.BranchTypePending
