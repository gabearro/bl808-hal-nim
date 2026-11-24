import BinaryTokenSound
set_option autoImplicit false

namespace ZkBuild.BinaryTokenSyntax
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- U32 LEB syntax allows nonminimal encodings, but requires termination and
    zero overflow bits in the fifth byte. -/
def U32 (length : Nat) (bytes : Nat → Nat) : Prop :=
  0 < length ∧ length ≤ 5 ∧ ∀ i, i < length → bytes i < 256 ∧
    (bytes i).testBit 7 = decide (i+1 < length) ∧
    ∀ j, j < 7 → 32 ≤ 7*i+j → (bytes i).testBit j = false

theorem normal_u32 {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (checked : BinaryTokenMatrix.check matrix r = true) (kind : r.kind = 1)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (length : Nat) (positive : 0 < length) (bound : length ≤ 5) (lengthImage : E values r.length = (length : F))
    (bytes : Nat → Nat)
    (source : ∀ item ∈ rowInputs 0 (active r) r.rows, item.1 < length →
      bytes item.1 < 256 ∧ E values item.2.2.value = (bytes item.1 : F)) : U32 length bytes := by
  have normal : r.kind ≠ 7 := by omega
  obtain ⟨other,ob,oi,rules⟩ := BinaryTokenBits.checked_rules matrix r normal checked values oneValue satisfied
  have ob' : other ≤ 5 := by simpa [kind,capacity] using ob
  have same : other = length := BinaryTokenDecoded.small_nat_unique other length (by omega) (by omega) (oi.symm.trans lengthImage)
  subst other
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).1).1).1
  have rowCount : r.rows.length = 5 := by simpa [kind,capacity] using shape.2.1
  have ranges := BinaryTokenMatrix.checked_ranges matrix r checked values oneValue satisfied
  refine ⟨positive,bound,?_⟩
  intro i ib
  obtain ⟨present,row,member⟩ := TokenInteger.row_exists r i (by omega)
  have actual := source (i,present,row) member ib
  have bits := TokenInteger.known_byte_bits values oneValue row.value (RangeUse.bits row.byteRange) (bytes i) actual.1 actual.2
    ((ranges.2.2.2 row (TokenInteger.row_member 0 (active r) r.rows _ member)).1)
  have rule := rules (i,present,row) member
  simp only [BinaryTokenBits.Rules,kind,leb] at rule
  refine ⟨actual.1,?_,?_⟩
  · have equal := (bits 7).symm.trans rule.1
    apply TokenInteger.bool_image_injective (F := F)
    by_cases more : i+1 < length <;> simpa [R1CS.boolValue,more] using equal
  · intro j jb beyond
    have overflow := rule.2.2.1 j jb (by simpa [kind,width] using beyond) ib
    have zero : E values (sign r) = 0 := by simp [sign,kind,signed,zero,eval_constant values oneValue]
    rw [bits,zero] at overflow
    apply TokenInteger.bool_image_injective (F := F)
    simpa [R1CS.boolValue] using overflow

/-- Every active U32 reader has valid terminating LEB syntax in the uniquely
    committed source message, in addition to its integer decoding theorem. -/
theorem checked_u32 {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (source : BinarySourceEmbedded.Record) (hash : ShaEmbedded.Record)
    (memory : MemoryEmbedded.Record) (queries : List BinarySourceMatrix.Entry) (tokens : List Record)
    (accepted : BinaryTokenEmbedded.check matrix source hash memory queries tokens = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values source.firstWire source.capacity source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      ∀ r ∈ tokens, r.kind = 1 → E values r.activeMode = 1 →
        ∃ position length, position < 2^32 ∧ position+length ≤ message.length ∧
          E values r.position = (position : F) ∧ E values r.length = (length : F) ∧
          U32 length (fun i => (message.getD (position+i) 0).toNat) := by
  obtain ⟨message,meaning,d0,d1,_,spans⟩ := BinaryTokenSource.checked_spans matrix source hash memory queries tokens accepted values oneValue satisfied
  have parts : BinaryReadMemory.check matrix source hash memory queries = true ∧
      tokens.all (BinaryTokenMatrix.check matrix) = true ∧ tokens.flatMap BinaryTokenMatrix.queries = queries ∧
      ∀ r ∈ tokens, r.sourceLength = source.length := by
    simpa only [BinaryTokenEmbedded.check,Bool.and_eq_true_iff,List.all_eq_true,decide_eq_true_eq,and_assoc] using accepted
  refine ⟨message,meaning,d0,d1,?_⟩
  intro r member kind enabled
  obtain ⟨position,length,pb,lb,pi,li,activity,within,bytes⟩ := spans r member
  have positive : 0 < length := by
    by_cases yes : 0 < length
    · exact yes
    · have eq : length = 0 := by omega
      have active : E values (BinaryTokenMatrix.active r) = 1 := by simpa [BinaryTokenMatrix.active,kind] using enabled
      have bad : (1 : F) = 0 := by simpa [active,eq] using activity
      exact False.elim (Field.zero_ne_one bad.symm)
  refine ⟨position,length,pb,within positive,pi,li,?_⟩
  apply normal_u32 matrix r (List.all_eq_true.mp parts.2.1 r member) kind values oneValue satisfied length positive (by simpa [kind,capacity] using lb) li
  intro item im used
  exact ⟨(message.getD (position+item.1) 0).isLt,(bytes item im used).2⟩

#print axioms normal_u32
#print axioms checked_u32
end ZkBuild.BinaryTokenSyntax
