import BranchListCheck
import BranchLists
import BranchRowImages
set_option autoImplicit false
namespace ZkBuild.BranchListSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix BranchListCheck
attribute [local instance] Ring.intCast Semiring.natCast

/-- The immutable bank's active head is a nonempty, bounded linked list. -/
theorem bank {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Bank) (checked : checkBank matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values r.entry.active = 1) :
    ∃ head : Fin (2^32), 0 < head.val ∧ E values r.entry.value = (head.val : F) ∧
      E values r.query.active = 1 ∧ E values r.query.address = (head.val : F) := by
  have parts := checked
  simp only [checkBank,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  obtain ⟨head,hb,hi,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix r.range r.entry.value 32 parts.1.2 values one satisfied)
  have all := OperandRowSound.includes_sound matrix _ _ _ parts.2 values satisfied
  have nil := zero_sound values one r.entry.value r.selected r.reciprocal
    (fun g gm => all g (List.mem_append_left _ gm))
  have guard := all _ (by simp [bankGates] : gate r.entry.active r.selected ∈ bankGates r)
  change E values r.entry.active*E values r.selected = E values z at guard
  have zero : E values z = 0 := by simpa [z,Ring.intCast_zero] using eval_constant values one 0
  have positive : 0 < head := by
    by_cases positive : 0 < head
    · exact positive
    have h : head = 0 := by omega
    rw [active,nil,hi,h,Semiring.natCast_zero,ite_eq_left rfl,Semiring.one_mul,zero] at guard
    exact False.elim (Field.zero_ne_one guard.symm)
  have query := VariableSelectorCheck.point values _ _ parts.1.1 0
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero] at query
  have address := all _ (by simp [bankGates] : mulGate r.entry.active r.entry.value r.query.address ∈ bankGates r)
  change E values r.entry.active*E values r.entry.value = E values r.query.address at address
  rw [active,hi,Semiring.one_mul] at address
  exact ⟨⟨head,hb⟩,positive,hi,query.trans active,address.symm⟩

/-- Every active list node points strictly backwards and authenticates its tail. -/
theorem node {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Node) (checked : checkNode matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (id : Fin (2^32)) (address : E values r.entry.address = (id.val : F)) (active : E values r.entry.active = 1) :
    ∃ depth next : Fin (2^32), next.val < id.val ∧ E values r.entry.value = ((depth.val+2^32*next.val : Nat) : F) ∧
      (next.val ≠ 0 → E values r.query.active = 1 ∧ E values r.query.address = (next.val : F)) := by
  have parts := checked
  simp only [checkNode,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have shape := parts.1.1.1
  obtain ⟨value,depth,next,_,db,nb,vi,di,ni,eq,_,_⟩ := PackedFields.checked_split matrix r.payload parts.1.1.2 values one satisfied
  rw [shape.2.1] at db eq
  rw [shape.2.2.1] at nb
  have interface := SourceProgramSound.normalized_inputs values _ _ shape.2.2.2
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at interface
  have packed : E values r.entry.value = ((depth+2^32*next : Nat) : F) := interface.1.symm.trans (by simpa only [eq] using vi)
  obtain ⟨delta,bound,image,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix r.delta (f r.after 0) 32 parts.1.2 values one satisfied)
  have all := OperandRowSound.includes_sound matrix _ _ _ parts.2 values satisfied
  have selected := select_sound values r.entry.active (sub (sub r.entry.address r.payload.high) o) z (f r.after 0)
    (all _ (by simp [nodeGates]))
  simp only [image,active,eval_sub,address,ni,o,z,eval_constant values one,Ring.intCast_zero,Ring.intCast_one] at selected
  have less := BranchLists.next_decreases (F := F) id.val next delta id.isLt nb bound (by grind only)
  have nil := zero_sound values one r.payload.high (f r.after 2) r.reciprocal
    (fun g gm => all g (by simp only [nodeGates,List.mem_append]; exact Or.inl (Or.inr gm)))
  refine ⟨⟨depth,db⟩,⟨next,nb⟩,less,packed,?_⟩
  intro nonzero
  have nf : (next : F) ≠ 0 := by
    intro equal
    exact nonzero (NumericEvents.nat_eq (F := F) next 0 (by simp [NumericEvents.countBound]; omega) (by decide) (by simpa only [Semiring.natCast_zero] using equal))
  have enabled := all _ (by simp [nodeGates] : mulGate r.entry.active (sub o (f r.after 2)) (f r.after 3) ∈ nodeGates r)
  change E values r.entry.active*E values (sub o (f r.after 2)) = E values (f r.after 3) at enabled
  simp only [active,eval_sub,o,eval_constant values one,Ring.intCast_one,nil,ni,ite_eq_right nf] at enabled
  have ai : E values r.query.active = 1 := interface.2.1.trans (by grind only)
  have addr := all _ (by simp [nodeGates] : mulGate (f r.after 3) r.payload.high (f r.after 4) ∈ nodeGates r)
  change E values (f r.after 3)*E values r.payload.high = E values (f r.after 4) at addr
  have addressImage : E values r.query.address = (next : F) := by rw [interface.2.2]; rw [← addr,← interface.2.1,ai,ni,Semiring.one_mul]
  exact ⟨ai,addressImage⟩

#print axioms bank
#print axioms node
end ZkBuild.BranchListSound
