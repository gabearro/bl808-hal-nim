import EnvelopeSound
namespace ZkBuild.TokenApplications
open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem byte_value {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BinaryTokenMatrix.Record) (accepted : BinaryTokenMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : r.kind = 0) (active : E values r.activeMode = 1)
    (message : List Sha256.Byte) (index expected : Nat) (ib : index < 2^32) (eb : expected < 256)
    (positionImage : E values r.position = (index : F)) (valueImage : E values r.value = (expected : F))
    (decoded : ∃ position length, BinaryTokenSound.Result values r message position length) :
    index < message.length ∧ (message.getD index 0).toNat = expected := by
  obtain ⟨position,length,result⟩ := decoded
  obtain ⟨actual,bound,actualImage,activity,_⟩ := BinaryTokenSchedule.checked_length matrix r accepted values oneValue satisfied
  have a : E values (BinaryTokenMatrix.active r) = 1 := by simpa [BinaryTokenMatrix.active,kind] using active
  have positive : actual ≠ 0 := by
    intro zero
    have impossible : (1 : F) = 0 := by simpa [zero,a] using activity
    exact Field.zero_ne_one impossible.symm
  have short : actual ≤ 1 := by simpa [kind,BinaryTokenMatrix.capacity] using bound
  rcases result with ⟨pb,lb,pi,li,body⟩
  have sameLength : actual = length := BinaryTokenDecoded.small_nat_unique actual length (by omega) (by omega) (actualImage.symm.trans li)
  have lengthOne : length = 1 := by omega
  have prime : 2^32 < scalarModulus := by decide
  have samePosition : position = index := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp (pi.symm.trans positionImage)
  rcases body with absent | ⟨actualKind,_,_,_,inside,value,selected⟩
  · omega
  · have actualZero : actualKind = 0 := by rcases selected with variant | normal <;> omega
    have byteBound := (message.getD index 0).isLt
    rw [actualZero,lengthOne,samePosition,EnvelopeSound.decode_byte _ byteBound] at value
    have sameByte : (message.getD index 0).toNat = expected :=
      (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans byteBound (by decide)) (Nat.lt_trans eb (by decide))).mp (value.symm.trans valueImage)
    exact ⟨by omega,sameByte⟩

theorem active_value {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BinaryTokenMatrix.Record) (accepted : BinaryTokenMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : Nat) (kindBound : kind < 7) (format : r.kind = kind) (active : E values r.activeMode = 1)
    (message : List Sha256.Byte) (decoded : ∃ position length, BinaryTokenSound.Result values r message position length) :
    ∃ position length, position < 2^32 ∧ 0 < length ∧ length ≤ BinaryTokenMatrix.capacity kind ∧ position+length ≤ message.length ∧
      E values r.position = (position : F) ∧ E values r.length = (length : F) ∧
      E values r.value = (TokenInteger.decode kind length (fun i => (message.getD (position+i) 0).toNat) : F) := by
  obtain ⟨position,length,result⟩ := decoded
  obtain ⟨actual,bound,actualImage,activity,_⟩ := BinaryTokenSchedule.checked_length matrix r accepted values oneValue satisfied
  have normal : r.kind ≠ 7 := by omega
  have a : E values (BinaryTokenMatrix.active r) = 1 := by simpa [BinaryTokenMatrix.active,normal] using active
  have cap : BinaryTokenMatrix.capacity r.kind ≤ 10 := by unfold BinaryTokenMatrix.capacity; grind
  have positive : actual ≠ 0 := by
    intro zero
    have impossible : (1 : F) = 0 := by simpa [zero,a] using activity
    exact Field.zero_ne_one impossible.symm
  rcases result with ⟨pb,lb,pi,li,body⟩
  have sameLength : actual = length := BinaryTokenDecoded.small_nat_unique actual length (by omega) (by omega) (actualImage.symm.trans li)
  rcases body with absent | ⟨actualKind,_,positive,limit,inside,value,selected⟩
  · omega
  · have sameKind : actualKind = kind := by rcases selected with variant | normal <;> omega
    exact ⟨position,length,pb,positive,by simpa [sameKind] using limit,inside,pi,li,by simpa [sameKind] using value⟩

#print axioms byte_value
#print axioms active_value
end ZkBuild.TokenApplications
