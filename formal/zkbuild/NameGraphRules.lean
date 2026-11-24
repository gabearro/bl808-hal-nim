import NameBits
import ReadOnlyInactive
set_option autoImplicit false
namespace ZkBuild.NameGraphRules
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameGraphMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def byteOf (word : Nat) := word%256
def tailOf (word : Nat) := word/256%2^32
def stateOf (word : Nat) := word/2^40%4
def highOf (word : Nat) := word/16%16

theorem shape (matrix : Shape) (r : Node) (i : Nat) (checked : checkNode matrix r i = true) : nodeShape r := by
  simp only [checkNode,Bool.and_eq_true_iff,decide_eq_true_eq] at checked
  grind only

theorem holds {F : Type} [Field F] [IsCharP F scalarModulus] (matrix : Shape) (r : Node) (i : Nat)
    (checked : checkNode matrix r i = true) (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (nodeGates r i) :=
  MemoryEvidence.span_sound matrix r.firstGate r.lastGate (nodeGates r i) (Bool.and_eq_true_iff.mp checked).2 values satisfied

theorem part {F : Type} [Field F] (values : Nat → F) (r : Node) (i : Nat)
    (all : AllHold values (nodeGates r i)) (j : Nat) (bound : j < 6) : AllHold values ((nodeParts r i).getD j []) := by
  have inside : j < (nodeParts r i).length := by simpa [nodeParts] using bound
  have member : (nodeParts r i).getD j [] ∈ nodeParts r i := by rw [← List.getElem_eq_getD []]; exact List.getElem_mem inside
  intro gate gm
  exact all gate (List.mem_flatten.mpr ⟨_,member,gm⟩)

theorem words {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Node) (i : Nat) (checked : checkNode matrix r i = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ current following : Nat, current < 2^42 ∧ following < 2^42 ∧
      E values r.entry.value = (current : F) ∧ E values r.query.value = (following : F) ∧
      E values (field r 0) = (byteOf current : F) ∧ E values (field r 1) = (tailOf current : F) ∧
      E values (field r 2) = (stateOf current : F) ∧ E values (field r 4) = (stateOf following : F) ∧
      E values (field r 5) = (highOf following : F) := by
  have checks := checked
  simp only [checkNode,Bool.and_eq_true_iff] at checks
  have first : RangeUse.check matrix (nodeRange r 0) r.entry.value 42 = true := by grind only
  have second : RangeUse.check matrix (nodeRange r 1) r.query.value 42 = true := by grind only
  obtain ⟨a,ab,ai,partsA⟩ := NameBits.slices values (nodeRange r 0) r.entry.value 42
    (RangeUse.checked_certificate matrix _ _ _ first values oneValue satisfied)
  obtain ⟨b,bb,bi,partsB⟩ := NameBits.slices values (nodeRange r 1) r.query.value 42
    (RangeUse.checked_certificate matrix _ _ _ second values oneValue satisfied)
  have all := holds matrix r i checked values satisfied
  have pa := part values r i all 1 (by decide)
  have pb := part values r i all 3 (by decide)
  have eq0 := equality_sound values oneValue (field r 0) (slice (nodeRange r 0) 0 8) (pa _ (by simp [nodeParts]))
  have eq1 := equality_sound values oneValue (field r 1) (slice (nodeRange r 0) 8 32) (pa _ (by simp [nodeParts]))
  have eq2 := equality_sound values oneValue (field r 2) (slice (nodeRange r 0) 40 2) (pa _ (by simp [nodeParts]))
  have eq4 := equality_sound values oneValue (field r 4) (slice (nodeRange r 1) 40 2) (pb _ (by simp [nodeParts]))
  have eq5 := equality_sound values oneValue (field r 5) (slice (nodeRange r 1) 4 4) (pb _ (by simp [nodeParts]))
  exact ⟨a,b,ab,bb,ai,bi,by simpa [byteOf] using eq0.trans (partsA 0 8 (by decide)),
    by simpa [tailOf] using eq1.trans (partsA 8 32 (by decide)),
    by simpa [stateOf] using eq2.trans (partsA 40 2 (by decide)),
    by simpa [stateOf] using eq4.trans (partsB 40 2 (by decide)),
    by simpa [highOf] using eq5.trans (partsB 4 4 (by decide))⟩

theorem node_index {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Node) (i : Nat) (checked : checkNode matrix r i = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values r.entry.active = 1) : E values r.entry.address = ((i+1 : Nat) : F) := by
  have all := part values r i (holds matrix r i checked values satisfied) 0 (by decide)
  have eqn := all (gate r.entry.active (sub r.entry.address (n (i+1)))) (by simp [nodeParts])
  change E values r.entry.active*E values (sub r.entry.address (n (i+1))) = E values z at eqn
  rw [active,eval_sub,n,z,eval_constant values oneValue,eval_constant values oneValue] at eqn
  have cast : ((Int.ofNat (i+1) : Int) : F) = ((i+1 : Nat) : F) := Ring.intCast_natCast (i+1)
  grind

theorem tail_query {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Node) (i : Nat) (checked : checkNode matrix r i = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values r.entry.active = 1) (next : Nat) (bound : next < 2^32)
    (image : E values (field r 1) = (next : F)) :
    E values r.query.active = (if next = 0 then 0 else 1) ∧ E values r.query.address = (next : F) := by
  have sh := shape matrix r i checked
  have all := part values r i (holds matrix r i checked values satisfied) 2 (by decide)
  have zs := zero_sound values oneValue (field r 1) (wire r.zeroStart) (wire (r.zeroStart+1))
    (by intro gate gm; exact all gate (List.mem_append_left _ gm))
  have isZero : E values (field r 1) = 0 ↔ next = 0 := by
    rw [image]
    have small : next < scalarModulus := by
      have p : 2^32 < scalarModulus := by decide
      omega
    simpa only [Semiring.natCast_zero] using (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus small (by decide : 0 < scalarModulus))
  have on := multiply_sound values r.entry.active (sub o (wire r.zeroStart)) (field r 3) (all _ (by simp [nodeParts]))
  have addr := multiply_sound values (field r 3) (field r 1) r.query.address (all _ (by simp [nodeParts]))
  have a : E values (field r 3) = (if next = 0 then 0 else 1) := by
    simp only [isZero] at zs
    rw [active,eval_sub,o,eval_constant values oneValue,zs] at on
    by_cases same : next = 0 <;> simp [same] at on ⊢ <;> grind
  have link : r.query.active = field r 3 := sh.2.2.2.2.2.1
  refine ⟨by rw [link,a],?_⟩
  rw [a,image] at addr
  by_cases same : next = 0 <;> simp [same] at addr ⊢ <;> grind

#print axioms words
#print axioms node_index
#print axioms tail_query
end ZkBuild.NameGraphRules
