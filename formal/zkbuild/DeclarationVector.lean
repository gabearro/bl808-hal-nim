import DeclarationHeader
import BinaryDeclarations
namespace ZkBuild.DeclarationVector
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem vector_metadata (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : VectorRow)
    (reverse : Bool) (index : Nat) (previous previousAddress count : Linear)
    (accepted : checkVector matrix tokens splits r reverse index previous previousAddress count = true) :
    r.fields.length = 3 ∧ r.byteToken < tokens.length ∧ r.keySplit < splits.length ∧
    r.spanSplit < splits.length ∧ r.heads < splits.length ∧ r.node < splits.length ∧
    r.hasOrder = (index != 0) ∧ tokenMatches (token tokens r.byteToken) 0 (get r.fields 0) r.position r.code ∧
    splitMatches (split splits r.keySplit) (get r.fields 1) 32 32 ∧
    splitMatches (split splits r.spanSplit) r.location.value 32 32 ∧
    splitMatches (split splits r.heads) r.metadata.value 32 32 ∧
    splitMatches (split splits r.node) r.memberQuery.value 3 32 ∧
    r.location.active = get r.fields 0 ∧ r.metadata.active = get r.fields 0 ∧ r.memberQuery.active = get r.fields 0 := by
  exact _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1).1).1

theorem vector_holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : VectorRow) (reverse : Bool)
    (index : Nat) (previous previousAddress count : Linear)
    (accepted : checkVector matrix tokens splits r reverse index previous previousAddress count = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (vectorGates tokens splits r reverse previous previousAddress count) :=
  MemoryEvidence.span_sound matrix r.firstGate r.lastGate _ (Bool.and_eq_true_iff.mp accepted).2 values satisfied

theorem part_holds {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (splits : Splits) (r : VectorRow)
    (reverse : Bool) (previous previousAddress count : Linear)
    (holds : AllHold values (vectorGates tokens splits r reverse previous previousAddress count)) (part : Nat) (inside : part < 19) :
    AllHold values ((vectorParts tokens splits r reverse previous previousAddress count).getD part []) := by
  have bound : part < (vectorParts tokens splits r reverse previous previousAddress count).length := by simpa [vectorParts] using inside
  have member : (vectorParts tokens splits r reverse previous previousAddress count).getD part [] ∈ vectorParts tokens splits r reverse previous previousAddress count := by
    rw [← List.getElem_eq_getD []]; exact List.getElem_mem bound
  intro g gm; exact holds g (List.mem_flatten.mpr ⟨_,member,gm⟩)

theorem tag_value {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : VectorRow) (reverse : Bool)
    (index : Nat) (previous previousAddress count : Linear)
    (accepted : checkVector matrix tokens splits r reverse index previous previousAddress count = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ tag : Fin 7, E values (get r.fields 2) = (tag.val : F) ∧
      (E values (get r.fields 0) = 1 → E values r.code = (BinaryDeclarations.encodedType tag : F)) := by
  have ranges := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1
  have valueCheck := (Bool.and_eq_true_iff.mp ranges).2
  obtain ⟨tag,tagBound,tagImage⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix r.valueRange (get r.fields 2) 3 valueCheck values oneValue satisfied)
  have holds := vector_holds matrix tokens splits r reverse index previous previousAddress count accepted values satisfied
  have zeros := part_holds values tokens splits r reverse previous previousAddress count holds 3 (by decide)
  change AllHold values (zeroGates (sub (get r.fields 2) (n 7)) (wire r.tagZero) (wire (r.tagZero+1))++[eqGate (wire r.tagZero) z]) at zeros
  have zi := zero_sound values oneValue (sub (get r.fields 2) (n 7)) (wire r.tagZero) (wire (r.tagZero+1))
    (by intro g gm; exact zeros g (List.mem_append_left _ gm))
  have ze := equality_sound values oneValue (wire r.tagZero) z (zeros _ (by simp))
  have constantImage (k : Nat) : E values (n k) = (k : F) := (eval_constant values oneValue (Int.ofNat k)).trans (Ring.intCast_natCast k)
  have eqNat (k : Nat) (bound : k < 8) : E values (sub (get r.fields 2) (n k)) = 0 ↔ tag = k := by
    rw [eval_sub,tagImage,constantImage]
    have cast := IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans tagBound (by decide)) (Nat.lt_trans bound (by decide))
    constructor
    · intro h; apply cast.mp; grind
    · intro h; rw [h]; grind
  have below : tag < 7 := by
    have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
    rw [zero] at ze
    by_cases equal : tag = 7
    · have inputZero := (eqNat 7 (by decide)).mpr equal
      have outOne : E values (wire r.tagZero) = 1 := by simpa only [inputZero,↓reduceIte] using zi
      exact False.elim (Field.zero_ne_one (ze.symm.trans outOne))
    · omega
  refine ⟨⟨tag,below⟩,tagImage,?_⟩
  intro active
  have extensions := part_holds values tokens splits r reverse previous previousAddress count holds 11 (by decide)
  change AllHold values (zeroGates (sub (get r.fields 2) (n 5)) (wire r.extendedZero) (wire (r.extendedZero+1))++
      zeroGates (sub (get r.fields 2) (n 6)) (wire (r.extendedZero+2)) (wire (r.extendedZero+3))) at extensions
  have first := zero_sound values oneValue _ _ _ (by intro g gm; exact extensions g (List.mem_append_left _ gm))
  have second := zero_sound values oneValue _ _ _ (by intro g gm; exact extensions g (List.mem_append_right _ gm))
  have lowImage : E values (wire r.extendedZero) = if tag = 5 then 1 else 0 := by simpa only [eqNat 5 (by decide)] using first
  have highImage : E values (wire (r.extendedZero+2)) = if tag = 6 then 1 else 0 := by simpa only [eqNat 6 (by decide)] using second
  have core := part_holds values tokens splits r reverse previous previousAddress count holds 12 (by decide)
  change AllHold values [mulGate (get r.fields 0) (sub (sub (n 127) (get r.fields 2)) (scale (wire r.extendedZero++wire (r.extendedZero+2)) 10)) r.code,
    mulGate (get r.fields 0) ((split splits r.spanSplit).low++(split splits r.keySplit).low) r.position] at core
  have code := multiply_sound values (get r.fields 0) (sub (sub (n 127) (get r.fields 2)) (scale (wire r.extendedZero++wire (r.extendedZero+2)) 10)) r.code (core _ (by simp))
  rw [active,eval_sub,eval_sub,constantImage,tagImage] at code
  have scaled := FullMatrix.eval_scale values (wire r.extendedZero++wire (r.extendedZero+2)) 10
  have cat := FullMatrix.eval_append values (wire r.extendedZero) (wire (r.extendedZero+2))
  change E values (scale (wire r.extendedZero++wire (r.extendedZero+2)) 10) = ((10 : Int) : F)*E values (wire r.extendedZero++wire (r.extendedZero+2)) at scaled
  change E values (wire r.extendedZero++wire (r.extendedZero+2)) = E values (wire r.extendedZero)+E values (wire (r.extendedZero+2)) at cat
  rw [scaled,cat,lowImage,highImage] at code
  have cases : tag = 0 ∨ tag = 1 ∨ tag = 2 ∨ tag = 3 ∨ tag = 4 ∨ tag = 5 ∨ tag = 6 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp only [BinaryDeclarations.encodedType,Fin.val_mk,ite_true,ite_false,Nat.reduceLT,Nat.reduceSub,Semiring.natCast_eq_ofNat,Ring.intCast_ofNat] at code ⊢ <;> grind

theorem source_type_byte {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : VectorRow) (reverse : Bool) (index : Nat) (previous previousAddress count : Linear)
    (accepted : checkVector matrix tokens splits r reverse index previous previousAddress count = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values (get r.fields 0) = 1) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ position length, BinaryTokenSound.Result values t message position length) :
    ∃ (tag : Fin 7) (position : Nat), position < message.length ∧
      E values (get r.fields 2) = (tag.val : F) ∧ E values r.position = (position : F) ∧
      (message.getD position 0).toNat = BinaryDeclarations.encodedType tag := by
  obtain ⟨tag,tagImage,code⟩ := tag_value matrix tokens splits r reverse index previous previousAddress count accepted values oneValue satisfied
  have shape := vector_metadata matrix tokens splits r reverse index previous previousAddress count accepted
  have matchToken := shape.2.2.2.2.2.2.2.1
  have member : token tokens r.byteToken ∈ tokens := by
    rw [token,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.1
  obtain ⟨position,length,result⟩ := decoded _ member
  have positionImage : E values (token tokens r.byteToken).position = (position : F) := result.2.2.1
  have bound : BinaryDeclarations.encodedType tag < 256 := by
    unfold BinaryDeclarations.encodedType
    split <;> omega
  have bytes := TokenApplications.byte_value matrix _ (EnvelopeChain.token_checked matrix tokens checks _ shape.2.1) values oneValue satisfied matchToken.1
    (by rw [matchToken.2.1]; exact active) message position (BinaryDeclarations.encodedType tag) result.1 bound positionImage
    (by rw [matchToken.2.2.2]; exact code active) ⟨position,length,result⟩
  exact ⟨tag,position,bytes.1,tagImage,by simpa only [matchToken.2.2.1] using positionImage,bytes.2⟩

#print axioms tag_value
#print axioms source_type_byte
end ZkBuild.DeclarationVector
