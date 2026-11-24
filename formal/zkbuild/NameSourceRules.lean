import NameSourceSound
set_option autoImplicit false
namespace ZkBuild.NameSourceRules
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem metadata (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (r : NameSourceMatrix.Record)
    (checked : NameSourceMatrix.check matrix tokens tables frame graph r = true) : NameSourceMatrix.links tables frame graph r := by
  simp only [NameSourceMatrix.check,Bool.and_eq_true_iff,decide_eq_true_eq] at checked
  grind only

theorem byte_shape (matrix : Shape) (tokens : Tokens) (flat : Bool) (f : NameFrameMatrix.ByteRow) (b : ByteRow)
    (i : Nat) (po pt : Linear) (checked : checkByte matrix tokens flat f b i po pt = true) : byteShape tokens flat f b i := by
  simp only [checkByte,Bool.and_eq_true_iff,decide_eq_true_eq] at checked
  grind only

theorem byte_holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (flat : Bool) (f : NameFrameMatrix.ByteRow) (b : ByteRow)
    (i : Nat) (po pt : Linear) (checked : checkByte matrix tokens flat f b i po pt = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (byteGates flat f b i po pt) := by
  have checks := checked
  simp only [checkByte,Bool.and_eq_true_iff] at checks
  exact MemoryEvidence.span_sound matrix b.firstGate b.lastGate _ (by grind only) values satisfied

theorem byte_word {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (flat : Bool) (f : NameFrameMatrix.ByteRow) (b : ByteRow)
    (i : Nat) (po pt : Linear) (checked : checkByte matrix tokens flat f b i po pt = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ word : Nat, word < 2^42 ∧ E values b.nodeQuery.value = (word : F) ∧
      E values (field b 0) = (NameGraphRules.byteOf word : F) ∧ E values (field b 1) = (NameGraphRules.tailOf word : F) := by
  have checks := checked
  simp only [checkByte,Bool.and_eq_true_iff] at checks
  have rangeCheck : RangeUse.check matrix b.range b.nodeQuery.value 42 = true := by grind only
  obtain ⟨word,wb,wi,slices⟩ := NameBits.slices values b.range b.nodeQuery.value 42
    (RangeUse.checked_certificate matrix _ _ _ rangeCheck values oneValue satisfied)
  have all := byte_holds matrix tokens flat f b i po pt checked values satisfied
  have byteEq := equality_sound values oneValue (field b 0) (packed b.range 0 8) (all _ (by simp [byteGates]))
  have tailEq : E values (field b 1) = E values (packed b.range 8 32) := by
    cases flat with
    | true => exact equality_sound values oneValue _ _ (all _ (by simp [byteGates]))
    | false =>
      have endCheck : MemoryEvidence.checkSpan matrix b.tailGate (b.tailGate+1) [eqGate (field b 1) (packed b.range 8 32)] = true := by
        simpa using (Bool.and_eq_true_iff.mp checked).2
      exact equality_sound values oneValue _ _ (MemoryEvidence.span_sound matrix _ _ _ endCheck values satisfied _ (by simp))
  have evaluated (offset count : Nat) (bound : offset+count ≤ 42) :
      E values (packed b.range offset count) = ((word/2^offset%2^count : Nat) : F) := by
    have add : E values (z ++ NameGraphMatrix.slice b.range offset count) = E values z+E values (NameGraphMatrix.slice b.range offset count) := eval_append values _ _
    rw [packed,add]
    rw [z,eval_constant values oneValue,slices offset count bound]
    simp only [Ring.intCast_zero]; grind
  exact ⟨word,wb,wi,by simpa [NameGraphRules.byteOf] using byteEq.trans (evaluated 0 8 (by decide)),
    by simpa [NameGraphRules.tailOf] using tailEq.trans (evaluated 8 32 (by decide))⟩

theorem byte_member (matrix : Shape) (tokens : Tokens) (flat : Bool)
    (fs : List NameFrameMatrix.ByteRow) (bs : List ByteRow) (i : Nat) (po pt : Linear)
    (checked : checkBytes matrix tokens flat fs bs i po pt = true) (b : ByteRow) (member : b ∈ bs) :
    ∃ f j previousOwner previousTail, checkByte matrix tokens flat f b j previousOwner previousTail = true := by
  induction fs generalizing bs i po pt with
  | nil => cases bs <;> simp_all [checkBytes]
  | cons f fs ih =>
    cases bs with
    | nil => simp at member
    | cons current rest =>
      have checks := Bool.and_eq_true_iff.mp checked
      rcases List.mem_cons.mp member with same | later
      · subst b; exact ⟨f,i,po,pt,checks.1⟩
      · exact ih rest (i+1) (NameFrameMatrix.bget f 1) (field current 1) checks.2 later

def RepWire {F : Type} [Field F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) (head : Linear) (bytes : List Nat) : Prop :=
  ∃ id : Nat, id < 2^32 ∧ E values head = (id : F) ∧ NameLists.Represents (NameGraphTable.table values bank) id bytes

theorem rep_transfer {F : Type} [Field F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) (a b : Linear) (bytes : List Nat)
    (same : E values a = E values b) (represented : RepWire values bank a bytes) : RepWire values bank b bytes := by
  obtain ⟨id,ib,ai,rep⟩ := represented
  exact ⟨id,ib,same.symm.trans ai,rep⟩

theorem rep_zero {F : Type} [Field F] [IsCharP F scalarModulus] (values : Nat → F) (bank : ReadOnlyMatrix.Record)
    (head : Linear) (bytes : List Nat) (zero : E values head = 0) (represented : RepWire values bank head bytes) : bytes = [] := by
  obtain ⟨id,ib,image,rep⟩ := represented
  have idZero : id = 0 := DeclarationLocations.natural_equal (F := F) _ 0 (by omega) (by decide) (by simpa using image.symm.trans zero)
  subst id
  cases rep with
  | nil => rfl
  | cons nonzero _ _ => exact False.elim (nonzero rfl)
end ZkBuild.NameSourceRules
