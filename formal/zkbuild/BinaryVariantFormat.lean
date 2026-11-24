import BinaryVariantBits

namespace ZkBuild.BinaryVariantFormat
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix BinaryVariantFields
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

private theorem prologue_holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (prologue r) := by
  intro g member
  exact checked_holds matrix r accepted values satisfied g (List.mem_append_left _ member)

theorem upper_bits {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true) (variant : r.kind = 7)
    (kind : Nat) (small : kind < 7) (values : Nat → F) (oneValue : values 0 = 1)
    (satisfied : Satisfied matrix values) (mode : E values r.activeMode = ((kind+1 : Nat) : F)) :
    ∀ i, i < 64 → width kind ≤ i → E values (atBit (RangeUse.bits r.valueRange) i) = 0 := by
  have selected := checked_selected matrix r accepted variant kind small values oneValue satisfied mode
  have pro := prologue_holds matrix r accepted values satisfied
  intro i bound outside
  have mem : gate (sub one (outputAvailable r i)) (atBit (RangeUse.bits r.valueRange) i) ∈ prologue r := by
    simp only [prologue,variant,↓reduceIte,List.mem_append]
    right
    exact List.mem_map.mpr ⟨i,List.mem_range.mpr bound,rfl⟩
  have product := BinaryTokenBits.product_zero values oneValue _ _ (pro _ mem)
  have unavailable := output_available values oneValue r variant kind i small bound selected
  have notIn : ¬i < width kind := by omega
  rw [ite_eq_right notIn] at unavailable
  rw [eval_sub,unavailable] at product
  have oneImage : E values one = 1 := by simp [one,eval_constant values oneValue]
  rw [oneImage] at product
  grind

private theorem fixed_length {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (oneValue : values 0 = 1) (r : Record) (length target selected : Nat)
    (lengthSmall : length < 16) (targetSmall : target < 16)
    (lengthImage : E values r.length = (length : F)) (selectedImage : E values (selector r selected) = 1)
    (holds : Holds values (gate (selector r selected) (sub r.length (nat target)))) : length = target := by
  have product := BinaryTokenBits.product_zero values oneValue _ _ holds
  have targetImage : E values (nat target) = (target : F) := by
    rw [nat,eval_constant values oneValue]; exact Ring.intCast_natCast _
  rw [selectedImage,eval_sub,lengthImage,targetImage] at product
  have equal : (length : F) = (target : F) := by grind
  have big : 16 < scalarModulus := by decide
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp equal

private theorem long_sum {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (variant : r.kind = 7) (length : Nat) (low : 5 < length) (high : length ≤ 10)
    (choicesImage : ∀ i, i < 10 → E values (choice r i) = if length = i+1 then 1 else 0) :
    E values (sum ((choices r).drop 5)) = 1 := by
  have enumerated : (choices r).drop 5 = [choice r 5,choice r 6,choice r 7,choice r 8,choice r 9] := by
    simp only [choices,variant,capacity]
    rfl
  rw [enumerated,BinaryTokenSchedule.eval_sum values oneValue]
  have c5 := choicesImage 5 (by decide)
  have c6 := choicesImage 6 (by decide)
  have c7 := choicesImage 7 (by decide)
  have c8 := choicesImage 8 (by decide)
  have c9 := choicesImage 9 (by decide)
  have cases : length = 6 ∨ length = 7 ∨ length = 8 ∨ length = 9 ∨ length = 10 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl <;>
    simp only [List.map_cons,List.map_nil,List.sum_cons,List.sum_nil,c5,c6,c7,c8,c9] <;> simp <;> grind

theorem checked_length {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true) (variant : r.kind = 7)
    (kind : Nat) (small : kind < 7) (values : Nat → F) (oneValue : values 0 = 1)
    (satisfied : Satisfied matrix values) (mode : E values r.activeMode = ((kind+1 : Nat) : F)) :
    ∃ length : Nat, 0 < length ∧ length ≤ capacity kind ∧ E values r.length = (length : F) ∧
      (leb kind = false → length = capacity kind) := by
  have selected := checked_selected matrix r accepted variant kind small values oneValue satisfied mode
  have pro := prologue_holds matrix r accepted values satisfied
  obtain ⟨length,bound,lenImage,activity,choicesImage⟩ := BinaryTokenSchedule.checked_length matrix r accepted values oneValue satisfied
  have cap : capacity r.kind = 10 := by simp [variant,capacity]
  have nonzero : 0 < length := by
    have activeImage := active_image values oneValue r variant kind small selected
    by_cases zeroLength : length = 0
    · rw [zeroLength] at activity
      simp only [ite_true] at activity
      have impossible : (0 : F) = 1 := activity.symm.trans activeImage
      exact False.elim (Field.zero_ne_one impossible)
    · omega
  have short : kind = 1 ∨ kind = 2 ∨ kind = 3 → length ≤ 5 := by
    intro shortKind
    by_cases enough : length ≤ 5
    · exact enough
    have sumImage := long_sum values oneValue r variant length (by omega) (by omega)
      (by simpa [cap] using choicesImage)
    have mem : gate (selector r 1 ++ selector r 2 ++ selector r 3) (sum ((choices r).drop 5)) ∈ prologue r := by
      simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton]; grind
    have product := BinaryTokenBits.product_zero values oneValue _ _ (pro _ mem)
    have s1 := selected 1 (by decide)
    have s2 := selected 2 (by decide)
    have s3 := selected 3 (by decide)
    have selectImage : E values (selector r 1 ++ selector r 2 ++ selector r 3) = 1 := by
      rcases shortKind with rfl | rfl | rfl <;> simp only [eval_cat,s1,s2,s3] <;> simp <;> grind
    rw [selectImage,sumImage] at product
    have impossible : (0 : F) = 1 := by grind
    exact False.elim (Field.zero_ne_one impossible)
  have exactRaw (which target : Nat) (whichKind : kind = which) (targetSmall : target < 16)
      (mem : gate (selector r which) (sub r.length (nat target)) ∈ prologue r) : length = target := by
    have sel : E values (selector r which) = 1 := by simpa [whichKind] using selected which (by omega)
    exact fixed_length values oneValue r length target which (by omega) targetSmall lenImage sel (pro _ mem)
  have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 ∨ kind = 4 ∨ kind = 5 ∨ kind = 6 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl
  · have fixed := exactRaw 0 1 rfl (by decide) (by
      simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton]; grind)
    refine ⟨length,nonzero,?_,lenImage,?_⟩ <;> simp [capacity,leb,fixed]
  · refine ⟨length,nonzero,?_,lenImage,by simp [leb]⟩
    simpa [capacity] using short (Or.inl rfl)
  · refine ⟨length,nonzero,?_,lenImage,by simp [leb]⟩
    simpa [capacity] using short (Or.inr (Or.inl rfl))
  · refine ⟨length,nonzero,?_,lenImage,by simp [leb]⟩
    simpa [capacity] using short (Or.inr (Or.inr rfl))
  · refine ⟨length,nonzero,?_,lenImage,by simp [leb]⟩
    simpa [capacity,variant] using bound
  · have fixed := exactRaw 5 4 rfl (by decide) (by
      simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton]; grind)
    refine ⟨length,nonzero,?_,lenImage,?_⟩ <;> simp [capacity,leb,fixed]
  · have fixed := exactRaw 6 8 rfl (by decide) (by
      simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton]; grind)
    refine ⟨length,nonzero,?_,lenImage,?_⟩ <;> simp [capacity,leb,fixed]

#print axioms upper_bits
#print axioms checked_length
end ZkBuild.BinaryVariantFormat
