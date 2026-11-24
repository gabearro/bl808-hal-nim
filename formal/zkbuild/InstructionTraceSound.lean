import InstructionCertificate
set_option autoImplicit false
namespace ZkBuild.InstructionTraceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure State where
  opened : Bool := false
  pc : Nat := 0
  opcode : Nat := 2
  counts : InstructionCounts.Counts := {}

def state (rows : List OperandEvents.Row) (opcodes : List Nat) : Nat → State
  | 0 => {}
  | i+1 => let prior := state rows opcodes i
    let kind := (rows.getD i default).kind
    ⟨InstructionSchedule.afterOpen prior.opened kind,InstructionSchedule.nextPc prior.pc kind,
      InstructionSchedule.chosenOpcode prior.opcode (opcodes.getD i 0) kind,InstructionCounts.next prior.counts kind⟩

def pending (rows : List OperandEvents.Row) (i : Nat) : Bool :=
  if i = 0 then false else decide ((rows.getD (i-1) default).kind = .functionBegin)

def StateImage {F : Type} [Field F] (values : Nat → F) (statics : StaticCatalog) (s : Stage) (st : State) (i : Nat) : Prop :=
  let before := (InstructionCertificate.record statics s i).before
  E values (f before 0) = OperandEvents.flag st.opened ∧
  E values (f before 2) = (st.pc : F) ∧ E values (f before 3) = (st.opcode : F) ∧
  E values (f before 4) = (st.counts.pops : F) ∧ E values (f before 5) = (st.counts.pushes : F) ∧
  E values (f before 6) = (st.counts.clears : F)

noncomputable def opcode {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (s : Stage) (checked : InstructionRowCheck.checkStage matrix statics s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) (i : Nat) (ib : i < s.rows.length) : Nat :=
  Classical.choose (InstructionRowSound.facts matrix (InstructionCertificate.record statics s i)
    (InstructionCertificate.row_checked matrix statics s checked i ib) values one satisfied).2.2.2.1

noncomputable def opcodes {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (s : Stage) (checked : InstructionRowCheck.checkStage matrix statics s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : List Nat :=
  List.ofFn (fun i : Fin s.rows.length => opcode matrix statics s checked values one satisfied i i.isLt)

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (r : ValidationEventMatrix.Record)
    (accepted : InstructionCertificate.check matrix statics r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (rows : List OperandEvents.Row) (ops : List Nat),
      OperandTraceSound.Represents values (ValidationEventCheck.stage r 1) rows ∧
      rows.length = (ValidationEventCheck.stage r 3).rows.length ∧ ops.length = rows.length ∧
      (∀ i, i < rows.length → ops.getD i 0 < 2^16 ∧ E values (f (rowAt (ValidationEventCheck.stage r 3).rows i) 8) = (ops.getD i 0 : F)) ∧
      (∀ i, i ≤ rows.length → StateImage values statics (ValidationEventCheck.stage r 3) (state rows ops i) i ∧
        (state rows ops i).pc ≤ 2^32 ∧ (state rows ops i).opcode < 2^16 ∧
        (state rows ops i).counts.pops ≤ i ∧ (state rows ops i).counts.pushes ≤ i ∧ (state rows ops i).counts.clears ≤ i) ∧
      (∀ i, i < rows.length →
        InstructionSchedule.allowed (state rows ops i).opened (pending rows i) (rows.getD i default).kind = true ∧
        ∃ pc : Nat, pc < 2^32 ∧ E values (f (rowAt (ValidationEventCheck.stage r 3).rows i) 9) = (pc : F) ∧
          InstructionSchedule.BindingSpec (state rows ops i).pc (state rows ops i).opcode pc (ops.getD i 0) (rows.getD i default).kind) := by
  let s := ValidationEventCheck.stage r 3
  have ck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).2
  obtain ⟨rows,images,size,rowFacts⟩ := InstructionCertificate.rows matrix statics r accepted values one satisfied
  let ops := opcodes matrix statics s ck values one satisfied
  have opSize : ops.length = rows.length := by simp [ops,opcodes,s,size]
  have opFacts (i : Nat) (ib : i < rows.length) : ops.getD i 0 < 2^16 ∧
      E values (f (rowAt s.rows i) 8) = (ops.getD i 0 : F) := by
    have si : i < s.rows.length := by change i < (ValidationEventCheck.stage r 3).rows.length; omega
    have choice := Classical.choose_spec (InstructionRowSound.facts matrix (InstructionCertificate.record statics s i)
      (InstructionCertificate.row_checked matrix statics s ck i si) values one satisfied).2.2.2.1
    simpa [ops,opcodes,List.getD,si,opcode,InstructionCertificate.record,InstructionRowCheck.record] using choice
  have pendingImage (i : Nat) (ib : i < rows.length) :
      E values (f (InstructionCertificate.record statics s i).before 1) = OperandEvents.flag (pending rows i) := by
    by_cases first : i = 0
    · subst i
      change E values z = OperandEvents.flag false
      simp [z,eval_constant values one,OperandEvents.flag,Ring.intCast_zero]
    · have prior := rowFacts (i-1) (by omega)
      have tag := (InstructionRowSound.selectors values _ _ prior.2.1).1
      simpa only [pending,first,ite_false,InstructionCertificate.record,InstructionRowCheck.record,
        ControlEvents.selected,List.getD_cons_succ,List.getD_cons_zero,f,DeclarationMatrix.get] using tag
  have invariant (i : Nat) (ib : i ≤ rows.length) : StateImage values statics s (state rows ops i) i ∧
      (state rows ops i).pc ≤ 2^32 ∧ (state rows ops i).opcode < 2^16 ∧
      (state rows ops i).counts.pops ≤ i ∧ (state rows ops i).counts.pushes ≤ i ∧ (state rows ops i).counts.clears ≤ i := by
    induction i with
    | zero =>
      refine ⟨?_,by simp [state],by simp [state],by simp [state],by simp [state],by simp [state]⟩
      simp [StateImage,state,InstructionCertificate.record,InstructionRowCheck.record,f,DeclarationMatrix.get,z,n,
        eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero,OperandEvents.flag,Semiring.natCast_eq_ofNat 2,Ring.intCast_ofNat 2]
    | succ i ih =>
      have rb : i < rows.length := by omega
      obtain ⟨prior,pcBound,opBound,countP,countQ,countC⟩ := ih (by omega)
      have current := rowFacts i rb
      have mode := InstructionRowSound.mode matrix _ current.1 values one satisfied _ current.2.1 _ _ prior.1 (pendingImage i rb)
      obtain ⟨pc,op,pb,ob,pi,oi,spec,nextBound,pcField,opField⟩ := InstructionRowSound.binding matrix _ current.1 values one satisfied
        _ current.2.1 _ _ pcBound opBound prior.2.1 prior.2.2.1
      have same : op = ops.getD i 0 := OperandEvents.natural_eq op _
        (by unfold OperandEvents.bound; omega) (by have := (opFacts i rb).1; unfold OperandEvents.bound; omega)
        (oi.symm.trans (opFacts i rb).2)
      subst op
      have counts := InstructionCounts.sound matrix _ current.1 values one satisfied _ current.2.1
        (state rows ops i).counts prior.2.2.2.1 prior.2.2.2.2.1 prior.2.2.2.2.2
      have nextCounts := InstructionCounts.bounded (state rows ops i).counts (rows.getD i default).kind i ⟨countP,countQ,countC⟩
      refine ⟨?_,nextBound,?_,nextCounts⟩
      · exact ⟨by simpa [StateImage,state,InstructionCertificate.record,InstructionRowCheck.record,f,DeclarationMatrix.get,s] using mode.2,
          by simpa [StateImage,state,InstructionCertificate.record,InstructionRowCheck.record,f,DeclarationMatrix.get,s] using pcField,
          by simpa [StateImage,state,InstructionCertificate.record,InstructionRowCheck.record,f,DeclarationMatrix.get,s] using opField,
          by simpa [StateImage,state,InstructionCertificate.record,InstructionRowCheck.record,f,DeclarationMatrix.get,s] using counts.2.2.2.1,
          by simpa [StateImage,state,InstructionCertificate.record,InstructionRowCheck.record,f,DeclarationMatrix.get,s] using counts.2.2.2.2.1,
          by simpa [StateImage,state,InstructionCertificate.record,InstructionRowCheck.record,f,DeclarationMatrix.get,s] using counts.2.2.2.2.2⟩
      · change InstructionSchedule.chosenOpcode _ _ _ < 2^16
        unfold InstructionSchedule.chosenOpcode
        split
        · exact (opFacts i rb).1
        · exact opBound
  refine ⟨rows,ops,images,size,opSize,opFacts,invariant,?_⟩
  intro i ib
  have prior := invariant i (by omega)
  have current := rowFacts i ib
  have mode := InstructionRowSound.mode matrix _ current.1 values one satisfied _ current.2.1 _ _ prior.1.1 (pendingImage i ib)
  obtain ⟨pc,op,pb,ob,pi,oi,spec,_⟩ := InstructionRowSound.binding matrix _ current.1 values one satisfied
    _ current.2.1 _ _ prior.2.1 prior.2.2.1 prior.1.2.1 prior.1.2.2.1
  have same : op = ops.getD i 0 := OperandEvents.natural_eq op _
    (by unfold OperandEvents.bound; omega) (by have := (opFacts i ib).1; unfold OperandEvents.bound; omega)
    (oi.symm.trans (opFacts i ib).2)
  exact ⟨mode.1,pc,pb,pi,by simpa only [same] using spec⟩

theorem closed {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (s : Stage)
    (checked : InstructionRowCheck.checkStage matrix statics s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (st : State) (image : StateImage values statics s st s.rows.length) : st.opened = false := by
  have closing := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  have holds := OperandRowSound.includes_sound matrix _ _ _ closing values satisfied
  have equation := equality_sound values one
    (if s.rows.isEmpty then z else (InstructionRowCheck.op s (s.rows.length-1) 16).call.outputs.getD 0 []) z
    (holds _ (by simp))
  have lhs : (if s.rows.isEmpty then z else (InstructionRowCheck.op s (s.rows.length-1) 16).call.outputs.getD 0 []) =
      f (InstructionCertificate.record statics s s.rows.length).before 0 := by
    cases h : s.rows with
    | nil => simp [h,InstructionCertificate.record,InstructionRowCheck.record,f,DeclarationMatrix.get]
    | cons row rest => simp [h,InstructionCertificate.record,InstructionRowCheck.record,f,DeclarationMatrix.get]
  rw [lhs,image.1] at equation
  have zero : OperandEvents.flag (F := F) st.opened = 0 := by
    simpa [z,eval_constant values one,Ring.intCast_zero] using equation
  cases h : st.opened
  · rfl
  · have bad : (1 : F) = 0 := by simpa [h,OperandEvents.flag] using zero
    exact False.elim (Field.zero_ne_one bad.symm)

#print axioms closed

#print axioms trace
end ZkBuild.InstructionTraceSound
