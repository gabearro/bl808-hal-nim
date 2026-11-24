import ParametricRowSound
set_option autoImplicit false
namespace ZkBuild.ParametricMode
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def active (code : Nat) := decide (code = 27 ∨ code = 28 ∨ code = 208)
def selecting (code : Nat) := decide (code = 27 ∨ code = 28)

theorem indicator {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : ParametricRowCheck.Record)
    (meaning : ParametricRowSound.Meaning values r) (input : Linear) (value literal i : Nat)
    (vb : value < 2^64) (lb : literal < 2^64) (image : E values input = (value : F))
    (member : (sub input (n literal),i) ∈ ParametricRowCheck.zeros r) :
    E values (f r.after i) = flag (decide (value = literal)) := by
  have selected := meaning.zero _ _ member
  have same : (value : F) = (literal : F) ↔ value = literal :=
    IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans vb (by decide)) (Nat.lt_trans lb (by decide))
  have diff : (value : F)-(literal : F) = 0 ↔ value = literal := by constructor <;> intro h <;> grind only
  simpa only [eval_sub,n,eval_constant values one,show ((Int.ofNat literal : Int) : F) = (literal : F) from Ring.intCast_natCast literal,image,diff,flag,decide_eq_true_eq] using selected

theorem images {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : ParametricRowCheck.Record)
    (meaning : ParametricRowSound.Meaning values r) (code : Nat) (cb : code < 2^16)
    (ci : E values (f r.row 8) = (code : F)) :
    E values (f r.after 0) = flag (decide (code = 27)) ∧
    E values (f r.after 1) = flag (decide (code = 28)) ∧
    E values (f r.after 2) = flag (decide (code = 208)) ∧
    E values (ParametricRowCheck.selectOp r) = flag (selecting code) ∧
    E values (ParametricRowCheck.present r) = flag (active code) := by
  have a := indicator values one r meaning _ code 27 0 (by omega) (by decide) ci (by simp [ParametricRowCheck.zeros])
  have b := indicator values one r meaning _ code 28 1 (by omega) (by decide) ci (by simp [ParametricRowCheck.zeros])
  have c := indicator values one r meaning _ code 208 2 (by omega) (by decide) ci (by simp [ParametricRowCheck.zeros])
  refine ⟨a,b,c,?_,?_⟩
  all_goals
    simp only [ParametricRowCheck.selectOp,ParametricRowCheck.present,eval_append,a,b,c]
    by_cases x : code = 27
    · simp [x,flag,active,selecting,AddCommMonoid.add_zero]
    by_cases y : code = 28
    · simp [y,flag,active,selecting,AddCommMonoid.zero_add,AddCommMonoid.add_zero]
    by_cases z : code = 208
    · simp [z,flag,active,selecting,AddCommMonoid.zero_add,AddCommMonoid.add_zero]
    simp [x,y,z,flag,active,selecting,AddCommMonoid.zero_add]

theorem type_indicators {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : ParametricRowCheck.Record)
    (meaning : ParametricRowSound.Meaning values r) (primary : Fin (2^32))
    (image : E values r.primary = (primary.val : F)) :
    ∀ i, i < 7 → E values (f r.after (4+i)) = flag (decide (primary.val = ParametricRowCheck.codes.getD i 0)) := by
  intro i ib
  have lb : ParametricRowCheck.codes.getD i 0 < 2^64 := by
    have choices : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6 := by omega
    rcases choices with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
  apply indicator values one r meaning r.primary primary.val (ParametricRowCheck.codes.getD i 0) (4+i)
    (by have := primary.isLt; omega) lb image
  simp only [ParametricRowCheck.zeros,List.mem_append,List.mem_map]
  exact Or.inl (Or.inr ⟨i,List.mem_range.mpr ib,rfl⟩)

theorem type_images {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : ParametricRowCheck.Record)
    (meaning : ParametricRowSound.Meaning values r) (primary : Fin (2^32))
    (image : E values r.primary = (primary.val : F)) :
    E values (ParametricRowCheck.tag r) = ((ParametricEvents.typeForCode primary.val).getD 0 : F) ∧
    E values (ParametricRowCheck.validType r) = flag (ParametricEvents.typeForCode primary.val).isSome ∧
    E values (f r.after 9++f r.after 10) = flag (ParametricEvents.referenceForCode primary.val).isSome := by
  have indicators := type_indicators values one r meaning primary image
  have a := indicators 0 (by decide)
  have b := indicators 1 (by decide)
  have c := indicators 2 (by decide)
  have d := indicators 3 (by decide)
  have e := indicators 4 (by decide)
  have f5 := indicators 5 (by decide)
  have g := indicators 6 (by decide)
  simp only [ParametricRowCheck.codes,List.getD_cons_zero,List.getD_cons_succ,Nat.reduceAdd] at a b c d e f5 g
  simp only [ParametricRowCheck.tag,ParametricRowCheck.validType,List.range_succ,List.range_zero,
    List.flatMap_append,List.flatMap_cons,List.flatMap_nil,List.nil_append,List.append_nil,
    eval_append,eval_scale,Nat.reduceAdd,a,b,c,d,e,f5,g]
  by_cases c127 : primary.val = 127
  · simp [c127,ParametricEvents.typeForCode,ParametricEvents.referenceForCode,flag]; grind only
  by_cases c126 : primary.val = 126
  · simp [c126,ParametricEvents.typeForCode,ParametricEvents.referenceForCode,flag]; grind only
  by_cases c125 : primary.val = 125
  · simp [c125,ParametricEvents.typeForCode,ParametricEvents.referenceForCode,flag]; grind only
  by_cases c124 : primary.val = 124
  · simp [c124,ParametricEvents.typeForCode,ParametricEvents.referenceForCode,flag]; grind only
  by_cases c123 : primary.val = 123
  · simp [c123,ParametricEvents.typeForCode,ParametricEvents.referenceForCode,flag]; grind only
  by_cases c112 : primary.val = 112
  · simp [c112,ParametricEvents.typeForCode,ParametricEvents.referenceForCode,flag]; grind only
  by_cases c111 : primary.val = 111
  · simp [c111,ParametricEvents.typeForCode,ParametricEvents.referenceForCode,flag]; grind only
  simp [c127,c126,c125,c124,c123,c112,c111,ParametricEvents.typeForCode,ParametricEvents.referenceForCode,flag]; grind only

#print axioms indicator
#print axioms images
#print axioms type_indicators
#print axioms type_images
end ZkBuild.ParametricMode
