import BinaryTokenBits

namespace ZkBuild.BinaryVariantFields
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

@[simp] theorem eval_cat {F : Type} [CommRing F] (values : Nat → F) (a b : Linear) :
    E values (a++b) = E values a+E values b := FullMatrix.eval_append ..

def kindSign (r : Record) (kind : Nat) : Linear :=
  if signed kind then atBit (RangeUse.bits r.valueRange) (width kind-1) else zero

def Selected {F : Type} [Field F] (values : Nat → F) (r : Record) (kind : Nat) : Prop :=
  ∀ i, i < 7 → E values (selector r i) = if kind = i then 1 else 0

theorem checked_selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true) (variant : r.kind = 7)
    (kind : Nat) (small : kind < 7) (values : Nat → F) (oneValue : values 0 = 1)
    (satisfied : Satisfied matrix values) (modeImage : E values r.activeMode = ((kind+1 : Nat) : F)) :
    Selected values r kind := by
  obtain ⟨mode,bound,modeValue,_,selectors⟩ := BinaryTokenSchedule.checked_variant_mode matrix r accepted variant values oneValue satisfied
  have smallMode : mode < scalarModulus := by
    have big : 8 < scalarModulus := by decide
    omega
  have smallKind : kind+1 < scalarModulus := by
    have big : 8 < scalarModulus := by decide
    omega
  have equal : mode = kind+1 := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus smallMode smallKind).mp (modeValue.symm.trans modeImage)
  intro i inside
  simpa only [equal,Nat.add_right_cancel_iff] using selectors i inside

theorem active_image {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (variant : r.kind = 7) (kind : Nat) (small : kind < 7) (selected : Selected values r kind) :
    E values (active r) = 1 := by
  rw [active,ite_eq_left variant,BinaryTokenSchedule.eval_sum values oneValue]
  have same : (((List.range 7).map (selector r)).map (E values)) =
      (List.range 7).map (fun i => if kind+1 = i+1 then (1 : F) else 0) := by
    rw [List.map_map]
    apply List.map_congr_left
    intro i inside
    simpa only [Nat.add_right_cancel_iff,Function.comp_def] using selected i (List.mem_range.mp inside)
  rw [same,BinaryTokenSchedule.delta_sum]
  have inside : 0 < kind+1 ∧ kind+1 ≤ 7 := by omega
  simp [inside]

theorem flags {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (variant : r.kind = 7) (kind : Nat) (small : kind < 7) (selected : Selected values r kind) :
    E values (raw r) = (if leb kind then 0 else 1) ∧
    E values (lebActive r) = (if leb kind then 1 else 0) ∧
    E values (signedActive r) = (if signed kind then 1 else 0) := by
  have activity := active_image values oneValue r variant kind small selected
  have s0 := selected 0 (by decide)
  have s1 := selected 1 (by decide)
  have s2 := selected 2 (by decide)
  have s3 := selected 3 (by decide)
  have s4 := selected 4 (by decide)
  have s5 := selected 5 (by decide)
  have s6 := selected 6 (by decide)
  have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 ∨ kind = 4 ∨ kind = 5 ∨ kind = 6 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp only [raw,lebActive,signedActive,eval_sub,eval_cat,s0,s1,s2,s3,s4,s5,s6,activity,leb,signed] <;>
    simp <;> grind

theorem sign_image {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (variant : r.kind = 7) (kind : Nat) (small : kind < 7)
    (selected : Selected values r kind) (holds : AllHold values (prologue r)) :
    E values (sign r) = E values (kindSign r kind) := by
  have aMem : mulGate (selector r 2) (atBit (RangeUse.bits r.valueRange) 31) (wire r.signStart) ∈ prologue r := by
    simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton] <;> grind
  have bMem : mulGate (selector r 3) (atBit (RangeUse.bits r.valueRange) 32) (wire (r.signStart+1)) ∈ prologue r := by
    simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton] <;> grind
  have cMem : mulGate (selector r 4) (atBit (RangeUse.bits r.valueRange) 63) (wire (r.signStart+2)) ∈ prologue r := by
    simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton] <;> grind
  have a := multiply_sound values _ _ _ (holds _ aMem)
  have b := multiply_sound values _ _ _ (holds _ bMem)
  have c := multiply_sound values _ _ _ (holds _ cMem)
  have s2 := selected 2 (by decide)
  have s3 := selected 3 (by decide)
  have s4 := selected 4 (by decide)
  simp only [eval_wire] at a b c
  have z : E values zero = 0 := by simp [zero,eval_constant values oneValue]
  have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 ∨ kind = 4 ∨ kind = 5 ∨ kind = 6 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl
  all_goals
    simp only [sign,variant,↓reduceIte,eval_cat,kindSign,signed,width]
    simp at s2 s3 s4
    simp only [eval_wire]
    rw [a,b,c,s2,s3,s4]
    try simp only [z]
    grind

theorem bit_available {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (variant : r.kind = 7) (kind index : Nat) (small : kind < 7)
    (encoded : leb kind = true) (selected : Selected values r kind) :
    E values (bitAvailable r index) = (if index < width kind then 1 else 0) := by
  have le : E values (lebActive r) = 1 := by simpa [encoded] using (flags values oneValue r variant kind small selected).2.1
  have s3 := selected 3 (by decide)
  have s4 := selected 4 (by decide)
  have z : E values zero = 0 := by simp [zero,eval_constant values oneValue]
  have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 ∨ kind = 4 ∨ kind = 5 ∨ kind = 6 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> simp [leb] at encoded
  all_goals
    by_cases low : index < 32
    · simp [bitAvailable,low,le,width] <;> grind
    · by_cases middle : index = 32
      · subst index; simp [bitAvailable,width,le,eval_cat,s3,s4] <;> grind
      · by_cases high : index < 64
        · simp [bitAvailable,low,middle,high,width,le,s3,s4] <;> grind
        · simp [bitAvailable,low,middle,high,width,z] <;> grind

theorem output_available {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (variant : r.kind = 7) (kind index : Nat) (small : kind < 7) (indexBound : index < 64)
    (selected : Selected values r kind) :
    E values (outputAvailable r index) = (if index < width kind then 1 else 0) := by
  have activity := active_image values oneValue r variant kind small selected
  have s0 := selected 0 (by decide)
  have s3 := selected 3 (by decide)
  have s4 := selected 4 (by decide)
  have s6 := selected 6 (by decide)
  have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 ∨ kind = 4 ∨ kind = 5 ∨ kind = 6 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl
  all_goals
    by_cases byte : index < 8
    · simp [outputAvailable,byte,activity,width] <;> grind
    · by_cases word : index < 32
      · simp [outputAvailable,byte,word,activity,eval_sub,s0,width] <;> grind
      · by_cases extra : index = 32
        · subst index; simp [outputAvailable,byte,word,activity,eval_cat,s3,s4,s6,width] <;> grind
        · simp [outputAvailable,byte,word,extra,activity,eval_cat,s4,s6,width] <;> grind

#print axioms checked_selected
#print axioms sign_image
#print axioms bit_available
#print axioms output_available
end ZkBuild.BinaryVariantFields
