import BinaryTokenEmbedded

namespace ZkBuild.BinaryTokenSchedule
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

private theorem in_prologue (r : Record) (g : Gate) (member : g ∈ choiceGates r) : g ∈ prologue r := by
  by_cases variant : r.kind = 7 <;> simp only [prologue,variant,↓reduceIte,List.mem_append] <;> grind

private theorem total_in_prologue (r : Record) : eqGate (sum (choices r)) (active r) ∈ prologue r := by
  by_cases variant : r.kind = 7
  · simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton]
    grind
  · have same : active r = r.activeMode := by simp [active,variant]
    simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton]
    grind

theorem eval_sum {F : Type} [CommRing F] (values : Nat → F) (oneValue : values 0 = 1)
    (xs : List Linear) : E values (sum xs) = (xs.map (E values)).sum := by
  have fold (xs : List Linear) (seed : Linear) :
      E values (xs.foldl (·++·) seed) = E values seed+(xs.map (E values)).sum := by
    induction xs generalizing seed with
    | nil => simp only [List.foldl_nil,List.map_nil,List.sum_nil,Semiring.add_zero]
    | cons x xs ih =>
      simp only [List.foldl_cons,List.map_cons,List.sum_cons,ih,E,FullMatrix.eval_append]
      grind
  simpa [sum,zero,eval_constant values oneValue,AddCommMonoid.zero_add] using fold xs zero

theorem delta_sum {F : Type} [CommRing F] (n count : Nat) :
    ((List.range count).map (fun i => if n = i+1 then (1 : F) else 0)).sum =
      if 0 < n ∧ n ≤ count then 1 else 0 := by
  have append (a b : List F) : (a++b).sum = a.sum+b.sum := by
    induction a with
    | nil => simp [AddCommMonoid.zero_add]
    | cons x xs ih => simp only [List.cons_append,List.sum_cons,ih]; grind
  induction count with
  | zero =>
    have outside : ¬(0 < n ∧ n ≤ 0) := by omega
    simp only [List.range_zero,List.map_nil,List.sum_nil,ite_eq_right outside]
  | succ count ih =>
    rw [List.range_succ,List.map_append,append,ih]
    by_cases same : n = count+1
    · subst n
      have outside : ¬ (0 < count+1 ∧ count+1 ≤ count) := by omega
      have inside : 0 < count+1 ∧ count+1 ≤ count+1 := by omega
      simp only [ite_eq_right outside,ite_eq_left inside,List.map_cons,List.map_nil,List.sum_cons,List.sum_nil]
      simp [AddCommMonoid.zero_add,Semiring.add_zero]
    · have equal : (0 < n ∧ n ≤ count+1) ↔ (0 < n ∧ n ≤ count) := by omega
      simp [same,equal,Semiring.add_zero]

theorem choice_images {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (oneValue : values 0 = 1) (r : Record) (n : Nat)
    (length : E values r.length = (n : F)) (small : n < 16)
    (kind : r.kind ≤ 7) (holds : AllHold values (prologue r)) :
    (∀ i, i < capacity r.kind → E values (choice r i) = if n = i+1 then 1 else 0) ∧
    E values (active r) = if 0 < n ∧ n ≤ capacity r.kind then 1 else 0 := by
  have cap : capacity r.kind ≤ 10 := by unfold capacity; grind
  have each (i : Nat) (inside : i < capacity r.kind) :
      E values (choice r i) = if n = i+1 then 1 else 0 := by
    have localHolds : AllHold values (zeroGates (sub r.length (nat (i+1))) (choice r i) (wire (r.choiceStart+2*i+1))) := by
      intro g member
      apply holds g (in_prologue r g _)
      exact List.mem_flatMap.mpr ⟨i,List.mem_range.mpr inside,member⟩
    have zero := zero_sound values oneValue _ _ _ localHolds
    have smallI : i+1 < scalarModulus := by
      have large : 32 < scalarModulus := by decide
      omega
    have smallN : n < scalarModulus := by
      have large : 32 < scalarModulus := by decide
      omega
    have castEq : ((n : F) = ((i+1 : Nat) : F)) ↔ n = i+1 :=
      IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus smallN smallI
    have subEq : (n : F)-((i+1 : Nat) : F) = 0 ↔ n = i+1 := by
      constructor
      · intro h; apply castEq.mp; grind
      · intro h; subst n; grind
    have evalI : E values (nat (i+1)) = ((i+1 : Nat) : F) := by
      rw [nat,eval_constant values oneValue]
      exact Ring.intCast_natCast _
    rw [eval_sub,length,evalI] at zero
    simpa only [subEq] using zero
  refine ⟨each,?_⟩
  have total := equality_sound values oneValue _ _ (holds _ (total_in_prologue r))
  rw [eval_sum values oneValue] at total
  have sums : ((choices r).map (E values)).sum =
      ((List.range (capacity r.kind)).map (fun i => if n = i+1 then (1 : F) else 0)).sum := by
    apply congrArg List.sum
    simp only [choices,List.map_map,Function.comp_def]
    apply List.map_congr_left
    intro i member
    exact each i (List.mem_range.mp member)
  rw [sums,delta_sum] at total
  exact total.symm

private theorem inactive_length {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (holds : AllHold values (prologue r)) :
    (1-E values (active r))*E values r.length = 0 := by
  by_cases variant : r.kind = 7
  · have first : eqGate (absent r ++ active r) one ∈ prologue r := by
      simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton]; grind
    have second : gate (absent r) r.length ∈ prologue r := by
      simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton]; grind
    have equation := equality_sound values oneValue _ _ (holds _ first)
    have product := holds _ second
    change E values (absent r)*E values r.length = E values zero at product
    have append : E values (absent r ++ active r) = E values (absent r)+E values (active r) := FullMatrix.eval_append ..
    rw [append] at equation
    have out : E values one = 1 := by simp [one,eval_constant values oneValue]
    have z : E values zero = 0 := by simp [zero,eval_constant values oneValue]
    rw [out] at equation
    rw [z] at product
    grind
  · have member : gate (sub one r.activeMode) r.length ∈ prologue r := by
      simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons,List.mem_singleton]; grind
    have product := holds _ member
    change E values (sub one r.activeMode)*E values r.length = E values zero at product
    simpa [active,variant,eval_sub,one,zero,eval_constant values oneValue] using product

theorem checked_length {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : BinaryTokenMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ n, n ≤ capacity r.kind ∧ E values r.length = (n : F) ∧
      E values (active r) = (if n = 0 then 0 else 1) ∧
      ∀ i, i < capacity r.kind → E values (choice r i) = if n = i+1 then 1 else 0 := by
  have all := BinaryTokenMatrix.checked_holds matrix r accepted values satisfied
  have pro : AllHold values (prologue r) := by
    intro g mem; exact all g (List.mem_append_left _ mem)
  have ranges := BinaryTokenMatrix.checked_ranges matrix r accepted values oneValue satisfied
  obtain ⟨n,small,length⟩ := RangeReuse.certificate_sound _ _ _ ranges.2.2.1
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1).1).1
  have kind : r.kind ≤ 7 := shape.1
  have images := choice_images values oneValue r n length small kind pro
  have zeroProduct := inactive_length values oneValue r pro
  by_cases inside : 0 < n ∧ n ≤ capacity r.kind
  · exact ⟨n,inside.2,length,by simp [images.2,inside]; omega,images.1⟩
  · have az : E values (active r) = 0 := by simpa [inside] using images.2
    have nz : (n : F) = 0 := by rw [az,length] at zeroProduct; grind
    have nSmall : n < scalarModulus := by
      have big : 16 < scalarModulus := by decide
      omega
    have zeroSmall : 0 < scalarModulus := by decide
    have nZero : n = 0 := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus nSmall zeroSmall).mp (by simpa using nz)
    exact ⟨n,by omega,length,by simp [nZero,az],images.1⟩

theorem row_facts {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (row : Row) (i : Nat) (present : Linear)
    (holds : AllHold values (rowGates r row i present)) :
    E values row.address = E values present*(E values r.position+(i : F)) ∧
    E values row.next = E values present-E values (choice r i) := by
  have addressMem : mulGate present (r.position++nat i) row.address ∈ rowGates r row i present := by
    simp only [rowGates,List.mem_append,List.mem_cons,List.mem_singleton]; grind
  have nextMem : eqGate row.next (sub present (choice r i)) ∈ rowGates r row i present := by
    simp only [rowGates,List.mem_append,List.mem_cons,List.mem_singleton]; grind
  have address := multiply_sound values _ _ _ (holds _ addressMem)
  have next := equality_sound values oneValue _ _ (holds _ nextMem)
  have offset : E values (nat i) = (i : F) := by
    rw [nat,eval_constant values oneValue]; exact Ring.intCast_natCast _
  have addition : E values (r.position++nat i) = E values r.position+(i : F) := by
    change evalLinear values (r.position++nat i) = _
    rw [FullMatrix.eval_append]
    exact congrArg (E values r.position+·) offset
  exact ⟨by simpa [addition] using address,by simpa [eval_sub] using next⟩

theorem indicator_step {F : Type} [Field F] (i n : Nat) :
    (if i < n then (1 : F) else 0) - (if n = i+1 then 1 else 0) =
      (if i+1 < n then 1 else 0) := by
  by_cases inside : i < n
  · by_cases last : n = i+1
    · have outside : ¬i+1 < n := by omega
      simp only [ite_eq_left inside,ite_eq_left last,ite_eq_right outside]; grind
    · have more : i+1 < n := by omega
      simp only [ite_eq_left inside,ite_eq_right last,ite_eq_left more]; grind
  · have last : n ≠ i+1 := by omega
    have outside : ¬i+1 < n := by omega
    simp only [ite_eq_right inside,ite_eq_right last,ite_eq_right outside]; grind

theorem rows_schedule {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : Record) (n i : Nat) (present : Linear) (rows : List Row)
    (bound : i+rows.length ≤ capacity r.kind)
    (start : E values present = if i < n then 1 else 0)
    (choices : ∀ j, j < capacity r.kind → E values (choice r j) = if n = j+1 then 1 else 0)
    (holds : AllHold values (rowsGates r i present rows)) :
    ∀ item ∈ rowInputs i present rows,
      E values item.2.1 = (if item.1 < n then 1 else 0) ∧
      E values item.2.2.address = E values item.2.1*(E values r.position+(item.1 : F)) := by
  induction rows generalizing i present with
  | nil => simp [rowInputs]
  | cons row rest ih =>
    have head : AllHold values (rowGates r row i present) := by
      intro g member; exact holds g (List.mem_append_left _ member)
    have tail : AllHold values (rowsGates r (i+1) row.next rest) := by
      intro g member; exact holds g (List.mem_append_right _ member)
    have facts := row_facts values oneValue r row i present head
    have next : E values row.next = (if i+1 < n then 1 else 0) := by
      rw [facts.2,start,choices i (by simp only [List.length_cons] at bound; omega)]
      exact indicator_step i n
    intro item member
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨start,facts.1⟩
    · exact ih (i+1) row.next (by simp only [List.length_cons] at bound; omega) next tail item later

theorem checked_schedule {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : BinaryTokenMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ n, n ≤ capacity r.kind ∧ E values r.length = (n : F) ∧
      E values (active r) = (if n = 0 then 0 else 1) ∧
      ∀ item ∈ rowInputs 0 (active r) r.rows,
        E values item.2.1 = (if item.1 < n then 1 else 0) ∧
        E values item.2.2.address = E values item.2.1*(E values r.position+(item.1 : F)) := by
  obtain ⟨n,bound,length,activity,choices⟩ := checked_length matrix r accepted values oneValue satisfied
  have checked := BinaryTokenMatrix.checked_holds matrix r accepted values satisfied
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1).1).1
  have tail : AllHold values (rowsGates r 0 (active r) r.rows) := by
    intro g member; exact checked g (List.mem_append_right _ member)
  refine ⟨n,bound,length,activity,rows_schedule values oneValue r n 0 (active r) r.rows (by omega) ?_ choices tail⟩
  by_cases z : n = 0
  · simp [activity,z]
  · have pos : 0 < n := by omega
    simp [activity,z,pos]

/-- The dynamic reader cannot select an unrecognized field value as its mode. -/
theorem variant_mode {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (oneValue : values 0 = 1) (r : Record) (variant : r.kind = 7)
    (holds : AllHold values (prologue r)) :
    ∃ mode : Nat, mode ≤ 7 ∧ E values r.activeMode = (mode : F) ∧
      E values (absent r) = (if mode = 0 then 1 else 0) ∧
      ∀ i, i < 7 → E values (selector r i) = (if mode = i+1 then 1 else 0) := by
  have absentHolds : AllHold values (zeroGates r.activeMode (absent r) (wire (r.selectorStart+1))) := by
    intro g member
    apply holds
    simp only [prologue,variant,↓reduceIte,selectorGates,List.mem_append]
    grind
  have absentImage := zero_sound values oneValue _ _ _ absentHolds
  have selected (i : Nat) (inside : i < 7) : E values (selector r i) =
      (if E values r.activeMode = ((i+1 : Nat) : F) then 1 else 0) := by
    have zeroHolds : AllHold values (zeroGates (sub r.activeMode (nat (i+1)))
        (selector r i) (wire (r.selectorStart+3+2*i))) := by
      intro g gm
      apply holds
      have member : g ∈ selectorGates r := by
        apply List.mem_append_right
        exact List.mem_flatMap.mpr ⟨i,List.mem_range.mpr inside,gm⟩
      simp only [prologue,variant,↓reduceIte,List.mem_append]
      grind
    have point := zero_sound values oneValue _ _ _ zeroHolds
    have literal : E values (nat (i+1)) = ((i+1 : Nat) : F) := by
      rw [nat,eval_constant values oneValue]; exact Ring.intCast_natCast _
    rw [eval_sub,literal] at point
    have zeroIff : E values r.activeMode-((i+1 : Nat) : F) = 0 ↔ E values r.activeMode = ((i+1 : Nat) : F) := by
      constructor <;> intro h <;> grind
    simpa only [zeroIff] using point
  have member : eqGate (absent r ++ active r) one ∈ prologue r := by
    simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons]; grind
  have total := equality_sound values oneValue _ _ (holds _ member)
  have addition : E values (absent r ++ active r) = E values (absent r)+E values (active r) := FullMatrix.eval_append ..
  have oneImage : E values one = 1 := by simp [one,eval_constant values oneValue]
  rw [addition,oneImage] at total
  have existsMode : ∃ mode : Nat, mode ≤ 7 ∧ E values r.activeMode = (mode : F) := by
    by_cases isZero : E values r.activeMode = 0
    · exact ⟨0,by decide,by simpa using isZero⟩
    by_cases found : ∃ i, i < 7 ∧ E values r.activeMode = ((i+1 : Nat) : F)
    · obtain ⟨i,inside,equal⟩ := found
      exact ⟨i+1,by omega,equal⟩
    have selZero : ∀ i, i < 7 → E values (selector r i) = 0 := by
      intro i inside
      have different : E values r.activeMode ≠ ((i+1 : Nat) : F) := by
        intro equal; exact found ⟨i,inside,equal⟩
      simp [selected i inside,different]
    have az : E values (absent r) = 0 := by simpa [isZero] using absentImage
    have activeZero : E values (active r) = 0 := by
      rw [active,ite_eq_left variant,eval_sum values oneValue]
      have zeros : ((List.range 7).map (selector r)).map (E values) = List.replicate 7 (0 : F) := by
        rw [List.map_map]
        calc
          (List.range 7).map (E values ∘ selector r) = (List.range 7).map (fun _ => (0 : F)) := by
            apply List.map_congr_left
            intro i member
            exact selZero i (List.mem_range.mp member)
          _ = List.replicate 7 (0 : F) := by simp only [List.map_const',List.length_range]
      rw [zeros]
      simp [List.replicate_succ,List.sum_cons,List.sum_nil,AddCommMonoid.zero_add]
    rw [az,activeZero] at total
    have impossible : (0 : F) = 1 := by simpa [AddCommMonoid.zero_add] using total
    exact False.elim (Field.zero_ne_one impossible)
  obtain ⟨mode,bound,modeImage⟩ := existsMode
  have small : mode < scalarModulus := by
    have big : 8 < scalarModulus := by decide
    omega
  have zeroSmall : 0 < scalarModulus := by decide
  have modeZero : ((mode : F) = 0) ↔ mode = 0 := by
    simpa using (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus small zeroSmall)
  refine ⟨mode,bound,modeImage,?_,?_⟩
  · simpa only [modeImage,modeZero] using absentImage
  · intro i inside
    have indexSmall : i+1 < scalarModulus := by
      have big : 8 < scalarModulus := by decide
      omega
    have equalIff : ((mode : F) = ((i+1 : Nat) : F)) ↔ mode = i+1 :=
      IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus small indexSmall
    simpa only [modeImage,equalIff] using selected i inside

theorem checked_variant_mode {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : BinaryTokenMatrix.check matrix r = true)
    (variant : r.kind = 7) (values : Nat → F) (oneValue : values 0 = 1)
    (satisfied : Satisfied matrix values) :
    ∃ mode : Nat, mode ≤ 7 ∧ E values r.activeMode = (mode : F) ∧
      E values (absent r) = (if mode = 0 then 1 else 0) ∧
      ∀ i, i < 7 → E values (selector r i) = (if mode = i+1 then 1 else 0) := by
  apply variant_mode values oneValue r variant
  intro g member
  exact BinaryTokenMatrix.checked_holds matrix r accepted values satisfied g (List.mem_append_left _ member)

#print axioms choice_images
#print axioms checked_length
#print axioms checked_schedule
#print axioms variant_mode
#print axioms checked_variant_mode
end ZkBuild.BinaryTokenSchedule
