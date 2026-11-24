import SignatureRules

namespace ZkBuild.SignatureDense
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram SignatureNamespace
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

structure Decoded where
  active : Bool
  isType : Bool
  address : Nat

def fInc (d : Decoded) : Nat := if d.active && !d.isType then 1 else 0
def tInc (d : Decoded) : Nat := if d.active && d.isType then 1 else 0
def fCount : List Decoded → Nat | [] => 0 | d::ds => fInc d+fCount ds
def tCount : List Decoded → Nat | [] => 0 | d::ds => tInc d+tCount ds
def Dense : Nat → Nat → List Decoded → Prop
  | _,_,[] => True
  | f,t,d::ds => (d.active = true → d.address = 2*(if d.isType then t else f)+d.isType.toNat) ∧ Dense (f+fInc d) (t+tInc d) ds
def Represents {F : Type} [CommRing F] (values : Nat → F) (r : SignatureNamespace.Row) (d : Decoded) : Prop :=
  E values r.entry.active = (d.active.toNat : F) ∧ E values r.entry.address = (d.address : F)

theorem row_step {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : SignatureNamespace.Row) (f t : Linear) (checked : checkRow matrix r f t = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (functions types : Nat) (fb : functions < 2^32) (tb : types < 2^32)
    (fi : E values f = (functions : F)) (ti : E values t = (types : F))
    (active : Bool) (ai : E values r.entry.active = (active.toNat : F)) :
    ∃ d : Decoded, Represents values r d ∧ d.active = active ∧ d.address < 2^33 ∧
      (d.active = true → d.address = 2*(if d.isType then types else functions)+d.isType.toNat) ∧
      E values r.functions = ((functions+fInc d : Nat) : F) ∧ E values r.types = ((types+tInc d : Nat) : F) := by
  have range := (Bool.and_eq_true_iff.mp checked).1
  obtain ⟨address,ab,addressImage,bits⟩ := TokenInteger.certificate_nat values oneValue r.entry.address (RangeUse.bits r.range) 33
    (RangeUse.checked_certificate matrix r.range r.entry.address 33 range values oneValue satisfied)
  let kind := address.testBit 0
  have bitImage : E values (SignatureNamespace.parity r) = (kind.toNat : F) := by
    have b := bits 0
    change E values (SignatureNamespace.parity r) = (if kind then 1 else 0) at b
    cases k : kind <;> simpa only [k,Bool.false_eq_true,↓reduceIte,Bool.toNat_false,Bool.toNat_true,Semiring.natCast_zero,Semiring.natCast_one] using b
  let d : Decoded := ⟨active,kind,address⟩
  have all := MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have typeGate := multiply_sound values r.entry.active (SignatureNamespace.parity r) r.typeEntry (all _ (by simp [SignatureNamespace.rowGates]))
  have indexGate := select_sound values (SignatureNamespace.parity r) t f r.index (all _ (by simp [SignatureNamespace.rowGates]))
  have fGate := equality_sound values oneValue r.functions (f++sub r.entry.active r.typeEntry) (all _ (by simp [SignatureNamespace.rowGates]))
  have tGate := equality_sound values oneValue r.types (t++r.typeEntry) (all _ (by simp [SignatureNamespace.rowGates]))
  have aGate := all (gate r.entry.active (sub (sub r.entry.address (scale r.index 2)) (SignatureNamespace.parity r))) (by simp [SignatureNamespace.rowGates])
  change E values r.entry.active*E values (sub (sub r.entry.address (scale r.index 2)) (SignatureNamespace.parity r)) = E values z at aGate
  have idxImage : E values r.index = ((if kind then types else functions : Nat) : F) := by
    rw [bitImage,ti,fi] at indexGate
    cases k : kind <;> simp only [k,Bool.toNat_false,Bool.toNat_true,Semiring.natCast_zero,Semiring.natCast_one,↓reduceIte] at indexGate ⊢ <;> grind
  have typeImage : E values r.typeEntry = (tInc d : F) := by
    rw [typeGate,ai,bitImage]
    cases a : active <;> cases k : kind <;> simp [d,tInc,a,k] <;> grind
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have two : ((2 : Int) : F) = ((2 : Nat) : F) := Ring.intCast_natCast 2
  have scaled := eval_scale values r.index 2
  change E values (scale r.index 2) = ((2 : Int) : F)*E values r.index at scaled
  have natural : d.active = true → d.address = 2*(if d.isType then types else functions)+d.isType.toNat := by
    intro enabled
    have a : active = true := enabled
    rw [ai,eval_sub,eval_sub,addressImage,scaled,two,idxImage,bitImage,zero] at aGate
    have ib : (if kind then types else functions) < 2^32 := by cases kind <;> assumption
    have kb : kind.toNat ≤ 1 := by cases kind <;> decide
    apply DeclarationLocations.natural_equal (F := F) address (2*(if kind then types else functions)+kind.toNat) (by omega) (by omega)
    simp only [a,Bool.toNat_true,Semiring.natCast_one] at aGate
    simp only [Semiring.natCast_add,Semiring.natCast_mul]
    grind
  have add (x y : Linear) : E values (x++y) = E values x+E values y := eval_append values x y
  refine ⟨d,⟨ai,addressImage⟩,rfl,ab,natural,?_,?_⟩
  · rw [fGate,add,eval_sub,fi,ai,typeImage]
    cases a : active <;> cases k : kind <;> simp [d,fInc,tInc,a,k,Semiring.natCast_add] <;> grind
  · rw [tGate,add,ti,typeImage,Semiring.natCast_add]

theorem decode_rows {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (rows : List SignatureNamespace.Row) (f t : Linear) (checked : checkRows matrix rows f t = true)
    (consumer : ReadOnlyMatrix.Record) (consumerChecked : ReadOnlyMatrix.check matrix consumer = true)
    (members : ∀ r ∈ rows, r.entry ∈ consumer.entries)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (functions types : Nat) (bound : functions+types+rows.length < 2^32)
    (fi : E values f = (functions : F)) (ti : E values t = (types : F)) :
    ∃ decoded : List Decoded, Related (Represents values) rows decoded ∧ (∀ d ∈ decoded, d.address < 2^33) ∧ Dense functions types decoded ∧
      E values (SignatureNamespace.final rows f t).1 = ((functions+fCount decoded : Nat) : F) ∧
      E values (SignatureNamespace.final rows f t).2 = ((types+tCount decoded : Nat) : F) := by
  induction rows generalizing f t functions types with
  | nil => exact ⟨[],.nil,by simp,True.intro,by simpa [SignatureNamespace.final,fCount] using fi,by simpa [SignatureNamespace.final,tCount] using ti⟩
  | cons r rows ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    obtain ⟨active,_,_,_,_,ai,_,_⟩ := ReadOnlyFacts.entry_fields matrix consumer consumerChecked values oneValue satisfied r.entry (members r (by simp))
    obtain ⟨d,image,da,db,dense,fc,tc⟩ := row_step matrix r f t parts.1 values oneValue satisfied functions types (by omega) (by omega) fi ti active ai
    have incBound : fInc d+tInc d ≤ 1 := by cases a : d.active <;> cases k : d.isType <;> simp [fInc,tInc,a,k]
    obtain ⟨ds,images,dsb,rest,ff,tt⟩ := ih r.functions r.types parts.2 (by intro x xm; exact members x (by simp [xm]))
      (functions+fInc d) (types+tInc d) (by simp only [List.length_cons] at bound; omega) fc tc
    refine ⟨d::ds,.cons image images,?_,⟨dense,rest⟩,?_,?_⟩
    · intro x xm; rcases List.mem_cons.mp xm with rfl | later; exact db; exact dsb x later
    · simpa [SignatureNamespace.final,fCount,Nat.add_assoc] using ff
    · simpa [SignatureNamespace.final,tCount,Nat.add_assoc] using tt

theorem type_bound (decoded : List Decoded) (functions types : Nat) (dense : Dense functions types decoded)
    (d : Decoded) (member : d ∈ decoded) (active : d.active = true) (index : Nat) (address : d.address = 2*index+1) :
    index < types+tCount decoded := by
  induction decoded generalizing functions types with
  | nil => simp at member
  | cons first rest ih =>
    rcases List.mem_cons.mp member with rfl | later
    · have head := dense.1 active
      cases k : d.isType <;> simp only [k,Bool.toNat_false,Bool.toNat_true,↓reduceIte] at head
      · omega
      · simp [tCount,tInc,active,k]; omega
    · have bound := ih (functions+fInc first) (types+tInc first) dense.2 later
      simpa [tCount,Nat.add_assoc] using bound

theorem function_count_bound (ds : List Decoded) : fCount ds ≤ ds.length := by
  induction ds with
  | nil => exact Nat.le_refl 0
  | cons d ds ih =>
    have bit : fInc d ≤ 1 := by unfold fInc; split <;> decide
    simp only [fCount,List.length_cons]
    omega

theorem function_bound (decoded : List Decoded) (functions types : Nat) (dense : Dense functions types decoded)
    (d : Decoded) (member : d ∈ decoded) (active : d.active = true) (index : Nat) (address : d.address = 2*index) :
    index < functions+fCount decoded := by
  induction decoded generalizing functions types with
  | nil => simp at member
  | cons first rest ih =>
    rcases List.mem_cons.mp member with rfl | later
    · have head := dense.1 active
      cases k : d.isType <;> simp only [k,Bool.toNat_false,Bool.toNat_true,↓reduceIte] at head
      · simp at head
        simp [fCount,fInc,active,k]; omega
      · omega
    · have bound := ih (functions+fInc first) (types+tInc first) dense.2 later
      simpa [fCount,Nat.add_assoc] using bound

#print axioms row_step
#print axioms decode_rows
#print axioms type_bound
#print axioms function_bound
end ZkBuild.SignatureDense
