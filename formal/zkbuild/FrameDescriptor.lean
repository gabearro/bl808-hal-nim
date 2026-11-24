import FrameRowImages
import SignatureFrames
set_option autoImplicit false
namespace ZkBuild.FrameDescriptor
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix FrameRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem field_zero (x : Linear) (xs : Fields) : f (x::xs) 0 = x := rfl
theorem field_succ (x : Linear) (xs : Fields) (i : Nat) : f (x::xs) (i+1) = f xs i := rfl

structure Image {F : Type} [Field F] (values : Nat → F) (r : FrameRowCheck.Record) (token : Nat) : Prop where
  value : E values (f r.after 36) = (token : F)
  kind : E values (f (descriptor r) 1) = ((token%4 : Nat) : F)
  key : E values (f r.after 38) = ((token/4 : Nat) : F)
  index : E values (f r.after 39) = ((token/16 : Nat) : F)
  typed : E values (f (descriptor r) 4) = OperandEvents.flag (decide (token/4%4 = 0))
  function : E values (f (descriptor r) 5) = OperandEvents.flag (decide (token/4%4 = 1))
  empty : E values (f (descriptor r) 6) = OperandEvents.flag (decide (token/4%4 = 2))
  singleton : E values (f (descriptor r) 7) = OperandEvents.flag (decide (token/4%4 = 3))

theorem bit_value {F : Type} [Field F] (n i : Nat) :
    (if n.testBit i then (1:F) else 0) = ((n/2^i%2 : Nat) : F) := by
  rw [Nat.testBit_eq_decide_div_mod_eq]
  rcases Nat.mod_two_eq_zero_or_one (n/2^i) with h | h
  · simp [h,Semiring.natCast_zero]
  · simp [h,Semiring.natCast_one]

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ token : Fin (2^36), Image values r token.val := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have cert := FrameRowImages.range matrix r checked values one satisfied 4 (by decide)
  change RangeReuse.Certificate 36 (E values (f r.after 36)) ((RangeUse.bits (r.ranges.getD 4 default)).map (E values)) at cert
  obtain ⟨n,nb,ni,bits⟩ := TokenInteger.certificate_nat values one _ _ _ cert
  have bi (i : Nat) : E values (bit r i) = ((n/2^i%2 : Nat) : F) := by
    exact (bits i).trans (bit_value n i)
  obtain ⟨m,mb,mi,slices⟩ := NameBits.slices values _ _ _ cert
  have same : m = n := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (by exact Nat.lt_trans mb (by decide))
    (by exact Nat.lt_trans nb (by decide))).mp (mi.symm.trans ni)
  subst m
  have size : (RangeUse.bits (r.ranges.getD 4 default)).length = 36 := by simpa using cert.1
  have tail (offset count : Nat) (total : offset+count=36) :
      E values (GadgetShape.pack (BitPacking.bitWeights count) ((RangeUse.bits (r.ranges.getD 4 default)).drop offset)) =
      ((n/2^offset%2^count : Nat) : F) := by
    have h := slices offset count (by omega)
    have short : ((RangeUse.bits (r.ranges.getD 4 default)).drop offset).length ≤ count := by
      rw [List.length_drop,size]
      omega
    simpa only [NameGraphMatrix.slice,List.take_of_length_le short] using h
  have key := facts.equality (GadgetShape.pack (BitPacking.bitWeights 34) ((RangeUse.bits (r.ranges.getD 4 default)).drop 2)) 38 (by simp [equalities])
  have idx := facts.equality (GadgetShape.pack (BitPacking.bitWeights 32) ((RangeUse.bits (r.ranges.getD 4 default)).drop 4)) 39 (by simp [equalities])
  rw [tail 2 34 (by decide)] at key
  rw [tail 4 32 (by decide)] at idx
  have kb : n/4 < 2^34 := by omega
  have ib : n/16 < 2^32 := by omega
  simp only [show 2^2=4 from rfl,show 2^4=16 from rfl] at key idx
  rw [Nat.mod_eq_of_lt kb] at key
  rw [Nat.mod_eq_of_lt ib] at idx
  have product := facts.multiply (bit r 2) (bit r 3) 40 (by simp [multiplies])
  rw [bi,bi] at product
  have low : n%4 = n%2+2*(n/2%2) := by omega
  simp only [E] at bi product
  have kind : E values (f (descriptor r) 1) = ((n%4 : Nat) : F) := by
    change E values (bit r 0++scale (bit r 1) 2) = _
    simp only [E,eval_append,eval_scale,bi]
    rw [low]
    simp only [Nat.pow_zero,Nat.pow_one,Nat.div_one,Semiring.natCast_add,Semiring.natCast_mul,Ring.intCast_ofNat 2,Semiring.natCast_eq_ofNat 2]
  refine ⟨⟨n,nb⟩,⟨ni,kind,key,idx,?_,?_,?_,?_⟩⟩
  all_goals
    simp only [descriptor,field_zero,field_succ]
    simp only [E]
    simp only [eval_append,eval_sub,eval_constant values one,o,Ring.intCast_one,bi,product]
    have possibilities : n/4%4=0 ∨ n/4%4=1 ∨ n/4%4=2 ∨ n/4%4=3 := by omega
    rcases possibilities with h | h | h | h
    all_goals
      have b2 : n/4%2 = (n/4%4)%2 := by omega
      have b3 : n/8%2 = (n/4%4)/2 := by omega
      simp only [show 2^2=4 from rfl,show 2^3=8 from rfl]
      simp only [b2,b3,h]
      simp [OperandEvents.flag,Semiring.natCast_zero,Semiring.natCast_one]
      try grind only

#print axioms bit_value
#print axioms sound
end ZkBuild.FrameDescriptor
