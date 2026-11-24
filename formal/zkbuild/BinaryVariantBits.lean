import BinaryVariantFields

namespace ZkBuild.BinaryVariantBits
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix BinaryVariantFields
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem plan_locate (r : Record) (row : Row) (i cursor : Nat) (js : List Nat) (j : Nat) (member : j ∈ js) :
    ∃ start, (j,payloadStep r row i j start) ∈ (payloadPlan r row i cursor js).steps := by
  induction js generalizing cursor with
  | nil => simp at member
  | cons head tail ih =>
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨cursor,by simp [payloadPlan]⟩
    · obtain ⟨start,found⟩ := ih (payloadStep r row i head cursor).nextWire later
      exact ⟨start,by simp [payloadPlan,found]⟩

theorem step_holds {F : Type} [CommRing F] (values : Nat → F) (r : Record) (row : Row)
    (i : Nat) (present : Linear) (holds : AllHold values (variantBits r row i present))
    (j : Nat) (inside : j < 7) :
    ∃ start, AllHold values (payloadStep r row i j start).gates := by
  obtain ⟨start,member⟩ := plan_locate r row i (row.extrasStart+2) (List.range 7) j (List.mem_range.mpr inside)
  refine ⟨start,?_⟩
  intro g gm
  have placed : g ∈ ((payloadPlan r row i (row.extrasStart+2) (List.range 7)).steps.flatMap (fun pair => pair.2.gates)) :=
    List.mem_flatMap.mpr ⟨(j,payloadStep r row i j start),member,gm⟩
  apply holds
  simp only [variantBits,List.mem_append]
  grind

theorem target_image {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (row : Row) (i j start kind : Nat) (small : kind < 7)
    (le : E values (lebActive r) = 1)
    (available : E values (bitAvailable r (7*i+j)) = (if 7*i+j < width kind then 1 else 0))
    (holds : AllHold values (payloadStep r row i j start).gates) :
    E values (payloadStep r row i j start).target =
      if 7*i+j < width kind then E values (atBit (RangeUse.bits r.valueRange) (7*i+j)) else E values (sign r) := by
  let step := payloadStep r row i j start
  have extensionMem : mulGate (sub (lebActive r) (bitAvailable r (7*i+j))) (sign r) step.extension ∈ step.gates := by
    simp [step,payloadStep]
  have extension := multiply_sound values _ _ _ (holds _ extensionMem)
  have packed : E values step.target = E values step.data+E values step.extension := by
    exact eval_cat values _ _
  have data : E values step.data = if 7*i+j < 64 then
      E values (bitAvailable r (7*i+j))*E values (atBit (RangeUse.bits r.valueRange) (7*i+j)) else 0 := by
    by_cases fits : 7*i+j < 64
    · have m : mulGate (bitAvailable r (7*i+j)) (atBit (RangeUse.bits r.valueRange) (7*i+j)) step.data ∈ step.gates := by
        simp [step,payloadStep,fits]
      simpa only [ite_eq_left fits] using multiply_sound values _ _ _ (holds _ m)
    · simp [step,payloadStep,fits,zero,eval_constant values oneValue]
  have bound : width kind ≤ 64 := by unfold width; grind
  change E values step.target = _
  rw [packed,data,extension,eval_sub,le,available]
  by_cases inside : 7*i+j < width kind
  · have fits : 7*i+j < 64 := by omega
    simp only [ite_eq_left inside,ite_eq_left fits]
    grind
  · simp only [ite_eq_right inside]
    split <;> grind

private theorem step_products {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (row : Row) (i j start : Nat)
    (holds : AllHold values (payloadStep r row i j start).gates) :
    E values (wire row.extrasStart)*(E values (atBit (RangeUse.bits row.byteRange) j)-E values (payloadStep r row i j start).target) = 0 ∧
    (E values (lebActive r)-E values (wire row.extrasStart))*(E values (payloadStep r row i j start).target-E values (sign r)) = 0 := by
  have a : gate (wire row.extrasStart) (sub (atBit (RangeUse.bits row.byteRange) j) (payloadStep r row i j start).target) ∈
      (payloadStep r row i j start).gates := by simp [payloadStep]
  have b : gate (sub (lebActive r) (wire row.extrasStart)) (sub (payloadStep r row i j start).target (sign r)) ∈
      (payloadStep r row i j start).gates := by simp [payloadStep]
  constructor
  · simpa [eval_sub] using BinaryTokenBits.product_zero values oneValue _ _ (holds _ a)
  · simpa [eval_sub] using BinaryTokenBits.product_zero values oneValue _ _ (holds _ b)

def Rules {F : Type} [Field F] (values : Nat → F) (r : Record) (kind length : Nat) (item : Nat × Linear × Row) : Prop :=
  let i := item.1
  let bytes := RangeUse.bits item.2.2.byteRange
  let bits := RangeUse.bits r.valueRange
  if leb kind then
    E values (atBit bytes 7) = (if i+1 < length then 1 else 0) ∧
    (∀ j, j < 7 → 7*i+j < width kind → E values (atBit bits (7*i+j)) =
      if i < length then E values (atBit bytes j) else E values (kindSign r kind)) ∧
    (∀ j, j < 7 → width kind ≤ 7*i+j → i < length → E values (atBit bytes j) = E values (kindSign r kind)) ∧
    (signed kind = true → length = i+1 → E values (atBit bytes 6) = E values (kindSign r kind))
  else i < 8 → ∀ j, j < 8 → E values (atBit bits (8*i+j)) = if i < length then E values (atBit bytes j) else 0

/-- The shared reader enforces the selected kind's payload and terminal rules. -/
theorem checked_rules {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true) (variant : r.kind = 7)
    (kind : Nat) (small : kind < 7) (values : Nat → F) (oneValue : values 0 = 1)
    (satisfied : Satisfied matrix values) (mode : E values r.activeMode = ((kind+1 : Nat) : F)) :
    ∃ length : Nat, length ≤ 10 ∧ E values r.length = (length : F) ∧
      ∀ item ∈ rowInputs 0 (active r) r.rows, Rules values r kind length item := by
  have selected := checked_selected matrix r accepted variant kind small values oneValue satisfied mode
  obtain ⟨length,bound,lenImage,_,schedule⟩ := BinaryTokenSchedule.checked_schedule matrix r accepted values oneValue satisfied
  have checked := BinaryTokenMatrix.checked_holds matrix r accepted values satisfied
  have pro : AllHold values (prologue r) := by intro g gm; exact checked g (List.mem_append_left _ gm)
  have tail : AllHold values (rowsGates r 0 (active r) r.rows) := by intro g gm; exact checked g (List.mem_append_right _ gm)
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1).1).1
  have cap : capacity r.kind = 10 := by simp [variant,capacity]
  have choices := (BinaryTokenSchedule.choice_images values oneValue r length lenImage (by omega) shape.1 pro).1
  have flag := flags values oneValue r variant kind small selected
  have signImage := sign_image values oneValue r variant kind small selected pro
  refine ⟨length,by omega,lenImage,?_⟩
  intro item member
  have found := BinaryTokenBits.row_member values r 0 (active r) r.rows tail item member
  have inside : item.1 < capacity r.kind := by have size := shape.2.1; omega
  have body : AllHold values (variantBits r item.2.2 item.1 item.2.1) := by
    intro g gm
    apply found.2
    simp only [rowGates,variant,↓reduceIte,List.mem_append]
    grind
  have present := (schedule item member).1
  have next := (BinaryTokenSchedule.row_facts values oneValue r item.2.2 item.1 item.2.1 found.2).2
  have nextImage : E values item.2.2.next = (if item.1+1 < length then 1 else 0) := by
    rw [next,present,choices item.1 inside]
    exact BinaryTokenSchedule.indicator_step item.1 length
  have lpMem : mulGate (lebActive r) item.2.1 (wire item.2.2.extrasStart) ∈ variantBits r item.2.2 item.1 item.2.1 := by
    simp only [variantBits,List.mem_append,List.mem_cons,List.mem_singleton]; grind
  have rpMem : mulGate (raw r) item.2.1 (wire (item.2.2.extrasStart+1)) ∈ variantBits r item.2.2 item.1 item.2.1 := by
    simp only [variantBits,List.mem_append,List.mem_cons,List.mem_singleton]; grind
  have lp := multiply_sound values _ _ _ (body _ lpMem)
  have rp := multiply_sound values _ _ _ (body _ rpMem)
  dsimp only [Rules]
  by_cases encoded : leb kind = true
  · simp only [encoded,↓reduceIte]
    have le : E values (lebActive r) = 1 := by simpa [encoded] using flag.2.1
    have lpImage : E values (wire item.2.2.extrasStart) = E values item.2.1 := by rw [lp,le]; grind
    have contMem : gate (lebActive r) (sub (atBit (RangeUse.bits item.2.2.byteRange) 7) item.2.2.next) ∈
        variantBits r item.2.2 item.1 item.2.1 := by simp only [variantBits,List.mem_append,List.mem_cons,List.mem_singleton]; grind
    have cont := BinaryTokenBits.product_zero values oneValue _ _ (body _ contMem)
    have contImage : E values (atBit (RangeUse.bits item.2.2.byteRange) 7) = E values item.2.2.next := by
      rw [le,eval_sub] at cont; grind
    refine ⟨contImage.trans nextImage,?_,?_,?_⟩
    · intro j jb inWidth
      obtain ⟨start,stepHolds⟩ := step_holds values r item.2.2 item.1 item.2.1 body j jb
      have target := target_image values oneValue r item.2.2 item.1 j start kind small le
        (bit_available values oneValue r variant kind (7*item.1+j) small encoded selected) stepHolds
      have products := step_products values oneValue r item.2.2 item.1 j start stepHolds
      rw [ite_eq_left inWidth] at target
      rw [lpImage,target] at products
      by_cases used : item.1 < length
      · simp only [present,ite_eq_left used] at products
        rw [ite_eq_left used]
        grind
      · simp only [present,ite_eq_right used,le] at products
        rw [ite_eq_right used]
        rw [← signImage]
        grind
    · intro j jb beyond used
      obtain ⟨start,stepHolds⟩ := step_holds values r item.2.2 item.1 item.2.1 body j jb
      have target := target_image values oneValue r item.2.2 item.1 j start kind small le
        (bit_available values oneValue r variant kind (7*item.1+j) small encoded selected) stepHolds
      have products := step_products values oneValue r item.2.2 item.1 j start stepHolds
      have outside : ¬7*item.1+j < width kind := by omega
      rw [ite_eq_right outside] at target
      rw [lpImage,target] at products
      simp only [present,ite_eq_left used] at products
      rw [← signImage]
      grind
    · intro isSigned last
      let plan := payloadPlan r item.2.2 item.1 (item.2.2.extrasStart+2) (List.range 7)
      have m : mulGate (signedActive r) (choice r item.1) (wire plan.nextWire) ∈ variantBits r item.2.2 item.1 item.2.1 := by
        simp only [variantBits,List.mem_append,List.mem_cons,List.mem_singleton]; grind
      have g : gate (wire plan.nextWire) (sub (atBit (RangeUse.bits item.2.2.byteRange) 6) (sign r)) ∈
          variantBits r item.2.2 item.1 item.2.1 := by
        simp only [variantBits,List.mem_append,List.mem_cons,List.mem_singleton]; grind
      have mult := multiply_sound values _ _ _ (body _ m)
      have signedImage : E values (signedActive r) = 1 := by simpa [isSigned] using flag.2.2
      rw [signedImage,choices item.1 inside,ite_eq_left last] at mult
      have product := BinaryTokenBits.product_zero values oneValue _ _ (body _ g)
      rw [mult,eval_sub] at product
      rw [← signImage]
      grind
  · have rawImage : E values (raw r) = 1 := by simpa [encoded] using flag.1
    simp only [encoded,↓reduceIte]
    intro fits j jb
    have a : gate (wire (item.2.2.extrasStart+1)) (sub (atBit (RangeUse.bits item.2.2.byteRange) j)
        (atBit (RangeUse.bits r.valueRange) (8*item.1+j))) ∈ variantBits r item.2.2 item.1 item.2.1 := by
      simp only [variantBits,ite_eq_left fits,List.mem_append]
      right
      exact List.mem_flatMap.mpr ⟨j,List.mem_range.mpr jb,by simp⟩
    have b : gate (sub (raw r) (wire (item.2.2.extrasStart+1))) (atBit (RangeUse.bits r.valueRange) (8*item.1+j)) ∈
        variantBits r item.2.2 item.1 item.2.1 := by
      simp only [variantBits,ite_eq_left fits,List.mem_append]
      right
      exact List.mem_flatMap.mpr ⟨j,List.mem_range.mpr jb,by simp⟩
    have pa := BinaryTokenBits.product_zero values oneValue _ _ (body _ a)
    have pb := BinaryTokenBits.product_zero values oneValue _ _ (body _ b)
    have rpImage : E values (wire (item.2.2.extrasStart+1)) = E values item.2.1 := by rw [rp,rawImage]; grind
    rw [rpImage,eval_sub] at pa
    rw [eval_sub,rawImage,rpImage] at pb
    by_cases used : item.1 < length
    · rw [ite_eq_left used]
      simp only [present,ite_eq_left used] at pa
      grind
    · rw [ite_eq_right used]
      simp only [present,ite_eq_right used] at pb
      grind

#print axioms target_image
#print axioms checked_rules
end ZkBuild.BinaryVariantBits
