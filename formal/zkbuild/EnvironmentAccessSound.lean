import EnvironmentRowSound
import VariableSelectorCheck
set_option autoImplicit false
namespace ZkBuild.EnvironmentAccessSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Spec {F : Type} [Field F] (values : Nat → F) (r : EnvironmentRowCheck.Record)
    (code : Nat) (declared : Fin 7) (mutable : Bool) : Prop where
  immediate : ∃ index : Nat, index < 2^32 ∧ E values r.immediate = (index : F)
  localActive : E values r.localQuery.active = OperandEvents.flag (decide (VariableTyping.environment code = 1))
  objectActive : E values r.objectQuery.active = OperandEvents.flag (decide (VariableTyping.environment code = 2)) +
    OperandEvents.flag (decide (VariableTyping.environment code = 3))
  localAddress : E values r.localQuery.address = E values r.localQuery.active *
    (E values (f r.row 1)*(2^32 : Nat)+E values r.immediate)
  objectAddress : E values r.objectQuery.address = E values r.objectQuery.active *
    (E values r.immediate*2+OperandEvents.flag (decide (VariableTyping.environment code = 3)))
  localImmutable : VariableTyping.environment code = 1 → mutable = false
  setterMutable : code = 36 → mutable = true
  tableType : VariableTyping.environment code = 3 → (declared.val = 5 ∨ declared.val = 6) ∧ mutable = false

theorem begin {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : EnvironmentRowCheck.Record) (checked : EnvironmentRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (tags : EnvironmentRowSound.Tags values r .instructionBegin) (code : Nat)
    (categories : VariableSelectorCheck.Categories values r.selectors code)
    (setterImage : E values (f r.selectors 4) = OperandEvents.flag (decide (code = 36)))
    (declared : Fin 7) (mutable : Bool)
    (typeImage : E values (EnvironmentRowCheck.tag r) = (declared.val : F))
    (mutableImage : E values (f (RangeUse.bits r.packedRange) 3) = OperandEvents.flag mutable) :
    Spec values r code declared mutable := by
  have all := EnvironmentRowSound.facts matrix r checked values satisfied
  have raw (a b : Linear) (member : gate a b ∈ EnvironmentRowCheck.gates r) : E values a*E values b = 0 := by
    have h := all _ member
    change E values a*E values b = E values z at h
    simpa only [z,eval_constant values one,Ring.intCast_zero] using h
  have multiplied (a b c : Linear) (member : mulGate a b c ∈ EnvironmentRowCheck.gates r) : E values c = E values a*E values b := (all _ member).symm
  have t1 := (InstructionRowSound.selectors values _ _ tags).2.1
  change E values (f r.flags 1) = _ at t1
  have started : E values (f r.flags 1) = 1 := by simpa [ControlEvents.selected,OperandEvents.flag] using t1
  have l := multiplied (f r.flags 1) (f r.selectors 10) (f r.after 1) (by simp [EnvironmentRowCheck.gates])
  have o := multiplied (f r.flags 1) (f r.selectors 11++f r.selectors 12) (f r.after 2) (by simp [EnvironmentRowCheck.gates])
  have t := multiplied (f r.flags 1) (f r.selectors 12) (f r.after 3) (by simp [EnvironmentRowCheck.gates])
  have la := multiplied (f r.after 1) (scale (f r.row 1) (Int.ofNat (2^32))++r.immediate) (f r.after 4) (by simp [EnvironmentRowCheck.gates])
  have oa := multiplied (f r.after 2) (scale r.immediate 2++f r.selectors 12) (f r.after 5) (by simp [EnvironmentRowCheck.gates])
  have setter := multiplied (f r.flags 1) (f r.selectors 4) (f r.after 9) (by simp [EnvironmentRowCheck.gates])
  have refType := multiplied (sub (EnvironmentRowCheck.tag r) (n 5)) (sub (EnvironmentRowCheck.tag r) (n 6)) (f r.after 10) (by simp [EnvironmentRowCheck.gates])
  simp only [started,eval_append,categories.1,categories.2.1,categories.2.2.1,Semiring.one_mul] at l o t
  simp only [started,setterImage,Semiring.one_mul] at setter
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).1
  have links := SourceProgramSound.normalized_inputs values _ _ shape.2.2.2.2
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at links
  have range := RangeUse.checked_certificate matrix _ _ _ (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2 values one satisfied
  have index := RangeReuse.certificate_sound _ _ _ range
  have packedImmutable := raw (f r.after 1++f r.after 3) (f (RangeUse.bits r.packedRange) 3) (by simp [EnvironmentRowCheck.gates])
  have setterMutable := raw (f r.after 9) (sub DeclarationMatrix.o (f (RangeUse.bits r.packedRange) 3)) (by simp [EnvironmentRowCheck.gates])
  have table := raw (f r.after 3) (f r.after 10) (by simp [EnvironmentRowCheck.gates])
  simp only [eval_append,l,t,mutableImage] at packedImmutable
  simp only [eval_sub,setter,mutableImage,DeclarationMatrix.o,eval_constant values one,Ring.intCast_one] at setterMutable
  simp only [eval_sub,n,eval_constant values one,typeImage,
    show ((Int.ofNat 5 : Int) : F) = 5 from Ring.intCast_ofNat 5,
    show ((Int.ofNat 6 : Int) : F) = 6 from Ring.intCast_ofNat 6] at refType
  rw [t,refType] at table
  refine ⟨index,links.1.trans l,links.2.2.1.trans o,?_,?_,?_,?_,?_⟩
  · rw [links.2.1,la,links.1]
    simp only [eval_append,eval_scale,Int.ofNat_eq_natCast,Ring.intCast_natCast]
    grind only
  · rw [links.2.2.2,oa,links.2.2.1]
    simp only [eval_append,eval_scale,categories.2.2.1,Ring.intCast_ofNat 2]
    grind only
  · intro localKind
    have h := packedImmutable
    simp only [localKind,reduceCtorEq,decide_true,decide_false,OperandEvents.flag,ite_true,ite_false,AddCommMonoid.add_zero,Semiring.one_mul] at h
    cases mutable with
    | false => rfl
    | true => exact False.elim (Field.zero_ne_one h.symm)
  · intro same
    have h := setterMutable
    simp only [same,decide_true,OperandEvents.flag,ite_true,Semiring.one_mul] at h
    exact VariableTyping.mutation_gate mutable h
  · intro tableKind
    have h := packedImmutable
    have typed := table
    simp only [tableKind,reduceCtorEq,decide_true,decide_false,OperandEvents.flag,ite_true,ite_false,AddCommMonoid.zero_add,Semiring.one_mul] at h typed
    exact VariableTyping.table_type_gate declared mutable typed h

#print axioms begin
end ZkBuild.EnvironmentAccessSound
