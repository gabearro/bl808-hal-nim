import FrameMemorySound
set_option autoImplicit false
namespace ZkBuild.FrameSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

structure Facts {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop where
  length : rows.length = (StructuredMatrix.stage r 3).rows.length
  row : ∀ i, i < rows.length →
    let frame := FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i
    FrameRowSound.Meaning values frame ∧
    FrameCertificate.Images values frame (rows.getD i default) (ops.getD i 0) ∧
    FrameOpcodes.Categories values frame (ops.getD i 0) ∧
    (∀ k, k<9 → E values (f frame.after k) = flag (decide (ops.getD i 0 = FrameRowCheck.codes.getD k 0))) ∧
    ∃ token : Fin (2^36), ∃ depth : Fin (2^32),
      FrameDescriptor.Image values frame token.val ∧ E values (f frame.before 0) = (depth.val : F)
  readOrigin : ∀ i, i < rows.length →
    E values (FrameRowCheck.readActive (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i)) = 1 →
    ∃ j, j<i ∧ (rows.getD j default).kind = .controlPush ∧
      E values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).read.address =
        E values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) j).write.address ∧
      E values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).read.value =
        E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) j).after 43)

theorem control_push {F : Type} [Field F]
    (values : Nat → F) (one : values 0=1) (r : FrameRowCheck.Record) (row : Row) (op : Nat)
    (image : FrameCertificate.Images values r row op) (active : E values (f r.flags 4)=1) :
    row.kind = .controlPush := by
  have h := congrArg (fun xs : List F => xs.getD 4 0) image.tags
  have zero : E values z = 0 := by simpa only [z,Ring.intCast_zero] using eval_constant values one 0
  rw [← zero,TokenInteger.map_getD] at h
  change E values (f r.flags 4) = _ at h
  rw [active] at h
  cases k : row.kind <;> try rfl
  all_goals
    simp [EventSelectors.codes,kindCode,flag,k,zero] at h
    exact False.elim (Field.zero_ne_one h.symm)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r = true)
    (controls : ControlRowCheck.checkStage matrix (ValidationEventCheck.stage events 2) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Facts values r rows ops := by
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).2).1
  have size : rows.length = (StructuredMatrix.stage r 3).rows.length := images.1.trans shape.1
  have row := FrameCertificate.row matrix events r checked values rows ops images schedule
  refine ⟨size,?_,?_⟩
  · intro i ib
    have rc := row i ib
    obtain ⟨token,ti⟩ := FrameDescriptor.sound matrix _ rc.1 values one satisfied
    obtain ⟨depth,di⟩ := FrameCertificate.control_depth matrix events r checked controls values one satisfied i (by omega)
    exact ⟨FrameRowSound.meaning matrix _ rc.1 values one satisfied,rc.2,
      FrameOpcodes.categories matrix _ rc.1 values one satisfied _ (schedule.opcode i ib).1 rc.2.opcode,
      FrameOpcodes.selectors matrix _ rc.1 values one satisfied _ (schedule.opcode i ib).1 rc.2.opcode,
      token,depth,ti,di⟩
  · intro i ib active
    obtain ⟨j,ji,push,addr,val⟩ := FrameMemorySound.origin matrix r.frames (StructuredMatrix.stage r 3)
      (Bool.and_eq_true_iff.mp checked).1 values one satisfied i (by omega) active
    exact ⟨j,ji,control_push values one _ _ _ (row j (by omega)).2 push,addr,val⟩

#print axioms control_push
#print axioms sound
end ZkBuild.FrameSound
