import ImportSound
set_option autoImplicit false

namespace ZkBuild.ImportRules
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ImportMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

structure Decoded where
  active : Bool
  kind : Nat
  deriving Inhabited

def Represents {F : Type} [Field F] (values : Nat → F) (r : Row) (d : Decoded) : Prop :=
  E values r.active = (d.active.toNat : F) ∧ E values r.kind = (d.kind : F)
def increment (d : Decoded) (i : Nat) : Nat := if d.active && d.kind == i then 1 else 0

theorem row_holds {F : Type} [Field F] [IsCharP F scalarModulus] (matrix : Shape) (tokens : Tokens) (splits : Splits)
    (exports : Linear) (r : Row) (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear)
    (checked : checkRow matrix tokens splits exports r index cursor counts previous = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) :
    AllHold values (ImportMatrix.rowGates tokens splits exports r index cursor counts previous) :=
  MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied

theorem part_holds {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (splits : Splits)
    (exports : Linear) (r : Row) (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear)
    (all : AllHold values (ImportMatrix.rowGates tokens splits exports r index cursor counts previous))
    (i : Nat) (bound : i < 9) : AllHold values ((rowParts tokens splits exports r index cursor counts previous).getD i []) := by
  have b : i < (rowParts tokens splits exports r index cursor counts previous).length := by simpa [rowParts] using bound
  have member : (rowParts tokens splits exports r index cursor counts previous).getD i [] ∈ rowParts tokens splits exports r index cursor counts previous := by
    rw [← List.getElem_eq_getD []]; exact List.getElem_mem b
  intro g gm
  exact all g (List.mem_flatten.mpr ⟨_,member,gm⟩)

theorem indicator {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (oneValue : values 0 = 1) (r : Row)
    (all : AllHold values ((List.range 4).flatMap (indicatorGates r)))
    (d : Decoded) (image : Represents values r d) (kindBound : d.kind < 4)
    (i : Nat) (inside : i < 4) : E values (get r.indicators i) = (increment d i : F) := by
  let start := r.zeroStarts.getD i 0
  have gates : AllHold values (indicatorGates r i) := by
    intro g gm
    exact all g (List.mem_flatMap.mpr ⟨i,List.mem_range.mpr inside,gm⟩)
  let input := if i = 0 then r.kind else sub r.kind (n i)
  have zeros := zero_sound values oneValue input (wire start) (wire (start+1)) (by
    intro g gm; exact gates g (List.mem_append_left _ gm))
  have product := multiply_sound values r.active (wire start) (get r.indicators i) (gates _ (List.mem_append_right _ (by simp [indicatorGates,start])))
  have number : E values (n i) = (i : F) := (eval_constant values oneValue (Int.ofNat i)).trans (Ring.intCast_natCast i)
  have inputImage : E values input = E values r.kind-E values (n i) := by
    by_cases zero : i = 0
    · subst i
      have z : E values (n 0) = 0 := by simp [n,eval_constant values oneValue]
      simp only [input,ite_true,z]
      grind
    · simp only [input,zero,ite_false]
      exact eval_sub values _ _
  have equal : E values input = 0 ↔ d.kind = i := by
    rw [inputImage,image.2,number]
    have inject := IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans kindBound (by decide)) (Nat.lt_trans inside (by decide))
    constructor
    · intro h; apply inject.mp; grind
    · intro h; rw [h]; grind
  rw [product,image.1,zeros]
  simp only [equal]
  cases flag : d.active <;> by_cases same : d.kind = i <;> simp [increment,flag,same] <;> grind

theorem decode {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (exports : Linear) (r : Row)
    (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear)
    (checked : checkRow matrix tokens splits exports r index cursor counts previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ d : Decoded, Represents values r d ∧ d.kind < 4 ∧
      (d.active = true → E values previous = 1) ∧
      (∀ i, i < 4 → E values (get r.indicators i) = (increment d i : F)) ∧
      (∀ i, i < 4 → E values (get r.counts i) = E values (get counts i)+(increment d i : F)) := by
  have kindRange := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).2
  obtain ⟨kind,kb,ki,_⟩ := TokenInteger.certificate_nat values oneValue r.kind (RangeUse.bits r.kindRange) 2
    (RangeUse.checked_certificate matrix r.kindRange r.kind 2 kindRange values oneValue satisfied)
  have all := row_holds matrix tokens splits exports r index cursor counts previous checked values satisfied
  have first := part_holds values tokens splits exports r index cursor counts previous all 0 (by decide)
  have boolean := boolean_sound values oneValue r.active (first _ (by simp [rowParts]))
  obtain ⟨flag,fi⟩ : ∃ flag : Bool, E values r.active = (flag.toNat : F) := by
    rcases boolean with no | yes
    · exact ⟨false,by simpa using no⟩
    · exact ⟨true,by simpa using yes⟩
  let d : Decoded := ⟨flag,kind⟩
  have indicators : ∀ i, i < 4 → E values (get r.indicators i) = (increment d i : F) := by
    intro i ib
    exact indicator values oneValue r (by simpa [rowParts] using part_holds values tokens splits exports r index cursor counts previous all 4 (by decide)) d ⟨fi,ki⟩ kb i ib
  refine ⟨d,⟨fi,ki⟩,kb,?_,indicators,?_⟩
  · intro active
    have gate := first (DeclarationMatrix.gate r.active (sub o previous)) (by simp [rowParts])
    change E values r.active*E values (sub o previous) = E values z at gate
    have one : E values o = 1 := by simp [o,eval_constant values oneValue]
    have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
    have fa : flag = true := active
    rw [fi,fa,Bool.toNat_true,Semiring.natCast_one,eval_sub,one,zero] at gate
    grind
  · intro i ib
    have last := part_holds values tokens splits exports r index cursor counts previous all 8 (by decide)
    have which : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 := by omega
    have eq := equality_sound values oneValue (get r.counts i) (get counts i++get r.indicators i) (last _ (by rcases which with rfl | rfl | rfl | rfl <;> simp [rowParts]))
    have cat := eval_append values (get counts i) (get r.indicators i)
    change E values (get counts i++get r.indicators i) = E values (get counts i)+E values (get r.indicators i) at cat
    rw [eq,cat,indicators i ib]

#print axioms indicator
#print axioms decode
end ZkBuild.ImportRules
