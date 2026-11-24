import FrameLifoSound
set_option autoImplicit false
namespace ZkBuild.FrameBlockEncoding
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix FrameRowCheck OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def kind (code : Nat) : Nat := if code=3 then 1 else if code=4 then 2 else 0
def key (pad : Nat) : Nat := if pad=0 then 2 else if pad≤7 then 4*(pad-1)+3 else 4*(pad-256)
def token (code pad : Nat) := 4*key pad+kind code
def Valid (pad : Nat) : Prop := pad≤7 ∨ (256≤pad ∧ pad-256<2^32)

theorem kind_bound (code : Nat) : kind code<4 := by
  unfold kind
  split
  · decide
  · split <;> decide

theorem bounded (code pad : Nat) (valid : Valid pad) : token code pad<2^36 := by
  have kb := kind_bound code
  unfold token key
  split
  · omega
  · split
    · omega
    · rcases valid with h | ⟨_,h⟩ <;> omega

theorem indicator {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0=1) (r : FrameRowCheck.Record)
    (facts : FrameRowSound.Meaning values r) (pad : Fin (2^33))
    (image : E values (f r.after 20)=(pad.val:F)) (tag : Nat) (tb : tag<7) :
    E values (f r.after (22+tag))=flag (decide (pad.val=tag+1)) := by
  have member : (sub (f r.after 20) (n (tag+1)),22+tag) ∈ zeros r := by
    unfold zeros
    exact List.mem_append_right _ (List.mem_map.mpr ⟨tag,List.mem_range.mpr tb,rfl⟩)
  have z := facts.zero _ _ member
  have same : (pad.val:F)=(tag+1:F) ↔ pad.val=tag+1 := by
    simpa only [Semiring.natCast_add,Semiring.natCast_one] using
      IsCharP.natCast_eq_iff_of_lt (α:=F) scalarModulus (Nat.lt_trans pad.isLt (by decide)) (show tag+1<scalarModulus by unfold scalarModulus; omega)
  have diff : (pad.val:F)-(tag+1:F)=0 ↔ pad.val=tag+1 := by constructor <;> intro h <;> grind only
  have constant : E values (n (tag+1))=(tag+1:F) := by
    rw [show E values (n (tag+1)) = (((tag+1:Nat):Int):F) from
      eval_constant values one (Int.ofNat (tag+1))]
    rw [Ring.intCast_natCast,Semiring.natCast_add,Semiring.natCast_one]
  simpa only [eval_sub,constant,image,diff,flag,decide_eq_true_eq] using z

theorem scalar {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (pad : Fin (2^33)) (pi : E values (f r.after 20)=(pad.val:F))
    (code : Nat) (cb : code<2^16) (ci : E values (f r.row 8)=(code:F)) :
    Valid pad.val ∧ E values (f r.after 31)=(token code pad.val:F) := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have s0 := indicator values one r facts pad pi 0 (by decide)
  have s1 := indicator values one r facts pad pi 1 (by decide)
  have s2 := indicator values one r facts pad pi 2 (by decide)
  have s3 := indicator values one r facts pad pi 3 (by decide)
  have s4 := indicator values one r facts pad pi 4 (by decide)
  have s5 := indicator values one r facts pad pi 5 (by decide)
  have s6 := indicator values one r facts pad pi 6 (by decide)
  have empty : E values (f r.after 21)=flag (decide (pad.val=0)) := by
    have e := facts.zero (f r.after 20) 21 (by simp [zeros])
    have same : (pad.val:F)=0 ↔ pad.val=0 := by
      simpa only [Semiring.natCast_zero] using IsCharP.natCast_eq_iff_of_lt (α:=F) scalarModulus
        (Nat.lt_trans pad.isLt (by decide)) (by decide : 0<scalarModulus)
    simpa only [pi,same,flag,decide_eq_true_eq] using e
  have single : E values (FrameRowCheck.singleton r) =
      flag (decide (pad.val=1))+flag (decide (pad.val=2))+flag (decide (pad.val=3))+
      flag (decide (pad.val=4))+flag (decide (pad.val=5))+flag (decide (pad.val=6))+flag (decide (pad.val=7)) := by
    simp [FrameRowCheck.singleton,List.range_succ,eval_append,s0,s1,s2,s3,s4,s5,s6]
    grind only
  have singleKey : E values (singletonKey r) =
      flag (decide (pad.val=1))*3+flag (decide (pad.val=2))*7+flag (decide (pad.val=3))*11+
      flag (decide (pad.val=4))*15+flag (decide (pad.val=5))*19+flag (decide (pad.val=6))*23+flag (decide (pad.val=7))*27 := by
    simp [singletonKey,List.range_succ,eval_append,eval_scale,s0,s1,s2,s3,s4,s5,s6,
      Ring.intCast_ofNat 3,Ring.intCast_ofNat 7,Ring.intCast_ofNat 11,Ring.intCast_ofNat 15,Ring.intCast_ofNat 19,Ring.intCast_ofNat 23,Ring.intCast_ofNat 27]
    grind only
  obtain ⟨idx,ib,ii⟩ := FrameRowImages.bounded matrix r checked values one satisfied 3 (by decide)
  change idx<2^32 at ib
  change E values (f r.after 29)=(idx:F) at ii
  have m := facts.multiply (sub (sub o (f r.after 21)) (FrameRowCheck.singleton r)) (sub (f r.after 20) (n 256)) 29 (by simp [multiplies])
  simp only [eval_sub,o,n,eval_constant values one,Ring.intCast_one,Int.ofNat_eq_natCast,Ring.intCast_natCast,empty,single,pi,ii] at m
  have eq := facts.equality (scale (blockKey r) 4++f r.after 1++scale (f r.after 2) 2) 31 (by simp [equalities])
  have loop := FrameOpcodes.selectors matrix r checked values one satisfied code cb ci 1 (by decide)
  have conditional := FrameOpcodes.selectors matrix r checked values one satisfied code cb ci 2 (by decide)
  simp only [FrameRowCheck.codes,List.getD_cons_zero,List.getD_cons_succ] at loop conditional
  simp only [eval_append,eval_scale,blockKey,empty,singleKey,ii,loop,conditional,Ring.intCast_ofNat 2,Ring.intCast_ofNat 4] at eq
  have kindImage : flag (F:=F) (decide (code=3))+flag (decide (code=4))*2 = (kind code:F) := by
    by_cases a : code=3
    · subst code; simp [kind,flag,AddCommMonoid.add_zero,Semiring.zero_mul,Semiring.natCast_one]
    · by_cases b : code=4
      · subst code; simp [kind,flag,AddCommMonoid.zero_add,Semiring.one_mul,Semiring.natCast_eq_ofNat 2]
      · simp [kind,flag,a,b,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.natCast_zero]
  by_cases small : pad.val≤7
  · have choices : pad.val=0 ∨ pad.val=1 ∨ pad.val=2 ∨ pad.val=3 ∨ pad.val=4 ∨ pad.val=5 ∨ pad.val=6 ∨ pad.val=7 := by omega
    refine ⟨Or.inl small,?_⟩
    rcases choices with h | h | h | h | h | h | h | h
    all_goals
      simp [h,flag,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul] at m eq
      simp only [token,key,h] at ⊢
      simp only [ite_true,ite_false,Nat.reduceLeDiff,Nat.reduceEqDiff] at ⊢
      simp only [Semiring.natCast_add,Semiring.natCast_mul,Semiring.natCast_zero,Semiring.natCast_one] at ⊢
      simp only [E] at m eq kindImage ⊢
      simp only [flag,decide_eq_true_eq] at kindImage
      grind only
  · have nonzero : pad.val≠0 := by omega
    have not1 : pad.val≠1 := by omega
    have not2 : pad.val≠2 := by omega
    have not3 : pad.val≠3 := by omega
    have not4 : pad.val≠4 := by omega
    have not5 : pad.val≠5 := by omega
    have not6 : pad.val≠6 := by omega
    have not7 : pad.val≠7 := by omega
    simp [flag,nonzero,not1,not2,not3,not4,not5,not6,not7,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul] at m eq
    have addition : pad.val=idx+256 := by
      apply DeclarationLocations.natural_equal (F:=F) _ _ (by have := pad.isLt; omega) (by omega)
      simp only [Semiring.natCast_add]
      grind only
    have index : idx=pad.val-256 := by omega
    refine ⟨Or.inr ⟨by omega,by omega⟩,?_⟩
    simp only [token,key,nonzero,small,ite_false,Semiring.natCast_add,Semiring.natCast_mul]
    rw [← index]
    simp only [E] at m eq kindImage ⊢
    simp only [flag,decide_eq_true_eq] at kindImage
    grind only

#print axioms bounded
#print axioms indicator
#print axioms scalar
end ZkBuild.FrameBlockEncoding
