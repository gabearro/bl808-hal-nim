import ConstantSourceModes
set_option autoImplicit false
namespace ZkBuild.ConstantSourceRead
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ConstantSourceMatrix ConstantSourceRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def Decoded {F : Type} [Field F] (values : Nat → F) (r : ConstantSourceMatrix.Record) (i : Nat)
    (message : List Sha256.Byte) (kind position length : Nat) : Prop :=
  position < 2^32 ∧ 0 < length ∧ length ≤ BinaryTokenMatrix.capacity kind ∧ position+length ≤ message.length ∧
    E values (cursor r i) = (position : F) ∧ E values (readAt r i).cursor = ((position+length : Nat) : F) ∧
    E values (layout r i).2.2 = (TokenInteger.decode kind length (fun j => (message.getD (position+j) 0).toNat) : F)

theorem active_fixed {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (r : ConstantSourceMatrix.Record) (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p l, BinaryTokenSound.Result values t message p l)
    (i kind : Nat) (ib : i < 6) (kb : kind < 7) (format : (layout r i).1 = kind)
    (active : E values (layout r i).2.1 = 1) : ∃ p l, Decoded values r i message kind p l := by
  have sh := read_shape tokens splits r (metadata matrix tokens splits r checked) i ib
  let t := EnvelopeMatrix.token tokens (readAt r i).token
  have tm : t ∈ tokens := by unfold t; rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem sh.1
  have ti := NameGraphRoots.normalized_eval values _ _ sh.2.2.1
  have pi := NameGraphRoots.normalized_eval values _ _ sh.2.2.2.1
  have vi := NameGraphRoots.normalized_eval values _ _ sh.2.2.2.2
  obtain ⟨p,l,pb,positive,short,within,position,length,value⟩ := TokenApplications.active_value matrix t
    (List.all_eq_true.mp tokenChecks t tm) values oneValue satisfied kind kb (sh.2.1.trans format) (ti.trans active) message (decoded t tm)
  have old : E values (cursor r i) = (p : F) := pi.symm.trans position
  have reads := reader_holds values tokens splits r (holds matrix tokens splits r checked values satisfied) i ib
  have finish := equality_sound values oneValue (readAt r i).cursor (cursor r i ++ t.length) (reads _ (by simp [readGates,t]))
  have add : E values (cursor r i ++ t.length) = E values (cursor r i)+E values t.length := eval_append values _ _
  exact ⟨p,l,pb,positive,short,within,old,by rw [finish,add,old,length,Semiring.natCast_add],vi.symm.trans value⟩

theorem active_variant {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (r : ConstantSourceMatrix.Record) (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p l, BinaryTokenSound.Result values t message p l)
    (i kind : Nat) (ib : i < 6) (kb : kind < 7) (format : (layout r i).1 = 7)
    (active : E values (layout r i).2.1 = ((kind+1 : Nat) : F)) : ∃ p l, Decoded values r i message kind p l := by
  have sh := read_shape tokens splits r (metadata matrix tokens splits r checked) i ib
  let t := EnvelopeMatrix.token tokens (readAt r i).token
  have tm : t ∈ tokens := by unfold t; rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem sh.1
  have tc := List.all_eq_true.mp tokenChecks t tm
  have tk : t.kind = 7 := sh.2.1.trans format
  have ti := (NameGraphRoots.normalized_eval values _ _ sh.2.2.1).trans active
  obtain ⟨length,positive,short,lengthImage,_⟩ := BinaryVariantFormat.checked_length matrix t tc tk kind kb values oneValue satisfied ti
  obtain ⟨p,l,pb,lb,pi,li,body⟩ := decoded t tm
  have capacity : BinaryTokenMatrix.capacity kind ≤ 10 := by unfold BinaryTokenMatrix.capacity; grind
  have same : length = l := BinaryTokenDecoded.small_nat_unique length l (by omega) (by omega) (lengthImage.symm.trans li)
  subst l
  rcases body with absent | ⟨actual,ab,_,_,within,value,selected⟩
  · omega
  · have actualEq : actual = kind := by
      rcases selected with variant | normal
      · have n := DeclarationLocations.natural_equal (F := F) (actual+1) (kind+1) (by omega) (by omega) (variant.2.symm.trans ti)
        omega
      · omega
    subst actual
    have position := NameGraphRoots.normalized_eval values _ _ sh.2.2.2.1
    have val := NameGraphRoots.normalized_eval values _ _ sh.2.2.2.2
    have old : E values (cursor r i) = (p : F) := position.symm.trans pi
    have reads := reader_holds values tokens splits r (holds matrix tokens splits r checked values satisfied) i ib
    have finish := equality_sound values oneValue (readAt r i).cursor (cursor r i ++ t.length) (reads _ (by simp [readGates,t]))
    have add : E values (cursor r i ++ t.length) = E values (cursor r i)+E values t.length := eval_append values _ _
    exact ⟨p,length,pb,positive,short,within,old,by rw [finish,add,old,lengthImage,Semiring.natCast_add],val.symm.trans value⟩

theorem inactive {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (r : ConstantSourceMatrix.Record) (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i < 6) (disabled : E values (layout r i).2.1 = 0) :
    E values (readAt r i).cursor = E values (cursor r i) ∧ E values (layout r i).2.2 = 0 := by
  have sh := read_shape tokens splits r (metadata matrix tokens splits r checked) i ib
  let t := EnvelopeMatrix.token tokens (readAt r i).token
  have tm : t ∈ tokens := by unfold t; rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem sh.1
  have tc := List.all_eq_true.mp tokenChecks t tm
  have ti : E values t.activeMode = 0 := (NameGraphRoots.normalized_eval values _ _ sh.2.2.1).trans disabled
  have lengthZero : E values t.length = 0 := by
    by_cases variant : t.kind = 7
    · obtain ⟨mode,bound,mi,ai,_⟩ := BinaryTokenSchedule.checked_variant_mode matrix t tc variant values oneValue satisfied
      have eq : mode = 0 := DeclarationLocations.natural_equal (F := F) _ 0 (by omega) (by decide) (by simpa using mi.symm.trans ti)
      have absent : E values (BinaryTokenMatrix.absent t) = 1 := by simpa [eq] using ai
      have all := BinaryTokenMatrix.checked_holds matrix t tc values satisfied
      have nil := all (BinaryTokenMatrix.gate (BinaryTokenMatrix.absent t) t.length) (by
        simp [BinaryTokenMatrix.gates,BinaryTokenMatrix.prologue,variant])
      change E values (BinaryTokenMatrix.absent t)*E values t.length = E values BinaryTokenMatrix.zero at nil
      rw [absent,Semiring.one_mul] at nil
      simpa [BinaryTokenMatrix.zero,eval_constant values oneValue] using nil
    · obtain ⟨length,_,li,activity,_⟩ := BinaryTokenSchedule.checked_length matrix t tc values oneValue satisfied
      have az : E values (BinaryTokenMatrix.active t) = 0 := by simpa [BinaryTokenMatrix.active,variant] using ti
      have eq : length = 0 := by
        by_cases zero : length = 0
        · exact zero
        · rw [az,ite_eq_right zero] at activity
          exact False.elim (Field.zero_ne_one activity)
      simpa [eq] using li
  have valueZero := BinaryTokenDecoded.zero_length_value matrix t tc values oneValue satisfied lengthZero
  have reads := reader_holds values tokens splits r (holds matrix tokens splits r checked values satisfied) i ib
  have finish := equality_sound values oneValue (readAt r i).cursor (cursor r i ++ t.length) (reads _ (by simp [readGates,t]))
  have add : E values (cursor r i ++ t.length) = E values (cursor r i)+E values t.length := eval_append values _ _
  have val := NameGraphRoots.normalized_eval values _ _ sh.2.2.2.2
  exact ⟨by rw [finish,add,lengthZero,Semiring.add_zero],val.symm.trans valueZero⟩

theorem active_byte {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (r : ConstantSourceMatrix.Record) (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p l, BinaryTokenSound.Result values t message p l)
    (i expected : Nat) (ib : i < 6) (eb : expected < 256) (format : (layout r i).1 = 0)
    (active : E values (layout r i).2.1 = 1) (image : E values (layout r i).2.2 = (expected : F)) :
    ∃ p, p < 2^32 ∧ p < message.length ∧ (message.getD p 0).toNat = expected ∧
      E values (cursor r i) = (p : F) ∧ E values (readAt r i).cursor = ((p+1 : Nat) : F) := by
  obtain ⟨p,l,pb,positive,short,within,pi,fi,value⟩ := active_fixed matrix tokens tokenChecks splits r checked values oneValue satisfied message decoded i 0 ib (by decide) format active
  have one : l = 1 := by simp [BinaryTokenMatrix.capacity] at short; omega
  subst l
  have bb := (message.getD p 0).isLt
  rw [EnvelopeSound.decode_byte _ bb] at value
  have byte := DeclarationLocations.natural_equal (F := F) _ expected (by omega) (by omega) (value.symm.trans image)
  exact ⟨p,pb,by omega,byte,pi,fi⟩

#print axioms active_fixed
#print axioms active_variant
#print axioms inactive
#print axioms active_byte
end ZkBuild.ConstantSourceRead
