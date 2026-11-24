import FrameSound
set_option autoImplicit false
namespace ZkBuild.ControlDepthTrace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def next (kind : Kind) (before : Nat) : Nat :=
  match kind with
  | .controlPush => before+1
  | .controlPop => before-1
  | _ => before

def depth (rows : List Row) : Nat → Nat
  | 0 => 0
  | i+1 => next (rows.getD i default).kind (depth rows i)

theorem determined (before after : Nat) (row : Row) (spec : ControlEvents.Spec before after row) :
    after = next row.kind before := by
  have step := spec.2.2.1
  cases k : row.kind <;> simp only [k,next] at step ⊢ <;> omega

structure Facts {F : Type} [Field F] (values : Nat → F) (s : Stage) (rows : List Row) : Prop where
  length : rows.length = s.rows.length
  bounded : ∀ i, i ≤ rows.length → depth rows i < 2^32
  before : ∀ i, i ≤ rows.length → E values (ControlRowCheck.record s i).beforeDepth = (depth rows i : F)
  after : ∀ i, i < rows.length → E values (f (ControlRowCheck.record s i).row 7) = (depth rows (i+1) : F)
  step : ∀ i, i < rows.length → ControlEvents.Spec (depth rows i) (depth rows (i+1)) (rows.getD i default)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (checked : ControlCertificate.check matrix events = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows) :
    Facts values (ValidationEventCheck.stage events 2) rows := by
  obtain ⟨other,oi,size,rowFacts⟩ := ControlCertificate.rows matrix events checked values one satisfied
  have same := OperandRepresentationUnique.trace values _ other rows oi images
  subst other
  let s := ValidationEventCheck.stage events 2
  have inv (i : Nat) (ib : i ≤ rows.length) : depth rows i < 2^32 ∧
      E values (ControlRowCheck.record s i).beforeDepth = (depth rows i : F) := by
    induction i with
    | zero =>
      refine ⟨by simp [depth],?_⟩
      simp only [ControlRowCheck.record,depth,ite_true,z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
    | succ i ih =>
      have bound : i < rows.length := by omega
      have previous := ih (by omega)
      have current := rowFacts i bound
      obtain ⟨d,db,di,sp,_⟩ := ControlRowSound.step matrix _ current.2 values one satisfied
        (depth rows i) previous.1 previous.2 _ current.1 (images.2 i bound).2.2.1 (images.2 i bound).2.2.2
      have eq : d = depth rows (i+1) := determined _ _ _ sp
      refine ⟨by simpa only [eq] using db,?_⟩
      simpa only [ControlRowCheck.record,Nat.add_eq_zero_iff,Nat.one_ne_zero,and_false,ite_false,Nat.add_sub_cancel,eq] using di
  refine ⟨size,fun i ib => (inv i ib).1,fun i ib => (inv i ib).2,?_,?_⟩
  · intro i ib
    have h := (inv (i+1) (by omega)).2
    simpa only [ControlRowCheck.record,Nat.add_eq_zero_iff,Nat.one_ne_zero,and_false,ite_false,Nat.add_sub_cancel] using h
  · intro i ib
    have current := rowFacts i ib
    obtain ⟨d,_,_,sp,_⟩ := ControlRowSound.step matrix _ current.2 values one satisfied
      (depth rows i) (inv i (by omega)).1 (inv i (by omega)).2 _ current.1 (images.2 i ib).2.2.1 (images.2 i ib).2.2.2
    have eq : d = depth rows (i+1) := determined _ _ _ sp
    simpa only [eq] using sp

theorem frame_before {F : Type} [Field F] [IsCharP F scalarModulus]
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (linked : FrameCertificate.linked events r = true) (values : Nat → F) (one : values 0 = 1)
    (rows : List Row) (facts : Facts values (ValidationEventCheck.stage events 2) rows)
    (i : Nat) (ib : i ≤ rows.length) :
    E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).before 0) = (depth rows i : F) := by
  have size := facts.length
  have links := linked
  simp only [FrameCertificate.linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  by_cases first : i=0
  · subst i
    change E values z = ((0:Nat):F)
    simp only [z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
  · have prior : i-1 < rows.length := by omega
    have matched := _root_.of_decide_eq_true (List.all_eq_true.mp links.2 (i-1) (List.mem_range.mpr (by omega)))
    have point := VariableSelectorCheck.point values _ _ matched.2.2.2 0
    simp only [f,DeclarationMatrix.get,List.getD_cons_zero] at point
    have current := facts.after (i-1) prior
    have index : i-1+1=i := by omega
    rw [index] at current
    simpa only [FrameRowCheck.record,first,ite_false,f,DeclarationMatrix.get,List.getD_cons_zero] using point.trans current

#print axioms determined
#print axioms sound
#print axioms frame_before
end ZkBuild.ControlDepthTrace
