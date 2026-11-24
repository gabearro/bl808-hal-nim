import FrameTraceMemory
set_option autoImplicit false
namespace ZkBuild.FrameReadSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix FrameRowCheck OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (kind : Kind) (code : Nat) (tags : FrameSelectors.Tags values r kind)
    (cats : FrameOpcodes.Categories values r code) (active : FrameSelectors.reads kind code=true) :
    E values (f r.after 36)=E values r.read.value := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have choose := facts.select (f r.flags 9) r.read.value (f r.after 35) 36 (by simp [selects])
  rw [tags.label] at choose
  have enabled := active
  simp only [FrameSelectors.reads,Bool.or_eq_true,Bool.and_eq_true,decide_eq_true_eq] at enabled
  rcases enabled with ⟨begin,mode⟩ | label
  · have codes : code=12 ∨ code=13 ∨ code=15 ∨ code=5 ∨ code=11 := by
      simpa only [FrameOpcodes.branches,FrameOpcodes.closes,Bool.or_eq_true,decide_eq_true_eq,_root_.or_assoc] using mode
    have opZero : E values (opening r)=0 := by
      rw [cats.isOpening]
      rcases codes with rfl | rfl | rfl | rfl | rfl <;> simp [FrameOpcodes.opens,flag]
    have opOne : E values (branching r++closing r)=1 := by
      simp only [eval_append,cats.isBranching,cats.isClosing]
      rcases codes with rfl | rfl | rfl | rfl | rfl <;>
        simp [FrameOpcodes.branches,FrameOpcodes.closes,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
    have left := facts.multiply (opening r) (f r.after 31) 32 (by simp [multiplies])
    have right := facts.multiply (branching r++closing r) r.read.value 33 (by simp [multiplies])
    rw [opZero,Semiring.zero_mul] at left
    rw [opOne,Semiring.one_mul] at right
    have initial := facts.select (f r.flags 0) (rootToken r) (f r.after 32++f r.after 33) 34 (by simp [selects])
    have source := facts.select (reset r) (f r.after 34) (f r.before 3) 35 (by simp [selects])
    simp only [eval_append,left,right,tags.functionBegin,begin,reduceCtorEq,decide_false,flag,ite_false,
      Semiring.zero_mul,AddCommMonoid.zero_add,AddCommMonoid.add_zero] at initial
    have resetOne : E values (reset r)=1 := by
      simp only [reset,eval_append,tags.functionBegin,tags.instructionBegin,begin,reduceCtorEq,decide_false,decide_true,flag,ite_true,ite_false,AddCommMonoid.zero_add]
    rw [resetOne,initial] at source
    simp only [begin,reduceCtorEq,decide_false,flag,ite_false,Semiring.zero_mul,AddCommMonoid.add_zero] at choose
    grind only
  · simp only [label,decide_true,flag,ite_true] at choose
    grind only

#print axioms selected
end ZkBuild.FrameReadSource
