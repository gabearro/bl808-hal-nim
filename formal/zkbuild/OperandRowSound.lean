import OperandRowCheck
import EventSelectors
set_option autoImplicit false
namespace ZkBuild.OperandRowSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem includes_sound {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (first last : Nat) (gates : List Gate)
    (checked : includes matrix first last gates = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values gates := by
  intro g member
  have found := List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 g member
  obtain ⟨actual,inside,same⟩ := List.mem_map.mp (List.contains_iff_mem.mp found)
  have inMatrix : actual ∈ matrix.gates.toList := by
    simp only [Array.toList_extract,List.extract_eq_take_drop] at inside
    exact List.mem_of_mem_drop (List.mem_of_mem_take inside)
  have equal := congrArg (interpretGate (F := F)) same
  simp only [normalized_gate_same_field] at equal
  change R1CS.Holds values (interpretGate g)
  rw [← equal]
  exact satisfied actual inMatrix

def Facts {F : Type} [Field F] (_matrix : Shape) (r : OperandRowCheck.Record) (values : Nat → F) : Prop :=
  r.tags.length = 11 ∧
  AllHold values (selectorGates r) ∧ AllHold values (stepGates r) ∧ AllHold values (accessGates r) ∧
  (∀ i, i < 5 → ∃ n : Nat, n < 2^(if i = 3 then 3 else 32) ∧
    E values ([f r.row 1,f r.row 2,f r.row 3,f r.row 4,r.available].getD i []) = (n : F)) ∧
  E values r.available = E values (sub r.product (sub (f r.tags 3) (f r.row 5))) ∧
  E values (f r.access 0) = E values (f r.tags 2++sub (f r.tags 3) (f r.row 5)) ∧
  E values (f r.access 1) = E values (f r.tags 2)

theorem facts {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : OperandRowCheck.Record) (checked : OperandRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : Facts matrix r values := by
  have parts := checked
  simp only [OperandRowCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] at parts
  rcases parts with ⟨rowLength,tagLength,accessLength,rangeLength,selector,step,access,inputs,boundary,ranges⟩
  have same := SourceProgramSound.normalized_inputs values _ _ inputs
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at same
  refine ⟨tagLength,includes_sound matrix _ _ _ selector values satisfied,
    includes_sound matrix _ _ _ step values satisfied,
    includes_sound matrix _ _ _ access values satisfied,?_,same⟩
  intro i bound
  have rc := List.all_eq_true.mp ranges i (List.mem_range.mpr bound)
  have cert := RangeUse.checked_certificate matrix _ _ _ rc values one satisfied
  obtain ⟨n,nb,ni,_⟩ := TokenInteger.certificate_nat values one _ _ _ cert
  exact ⟨n,by simpa only [beq_iff_eq] using nb,ni⟩

theorem fold_append {F : Type} [CommRing F] (values : Nat → F) (xs : Fields) (a : Linear) :
    E values (xs.foldl (·++·) a) = E values a + R1CS.sum (xs.map (E values)) := by
  induction xs generalizing a with
  | nil => simp [R1CS.sum,AddCommMonoid.add_zero]
  | cons x xs ih =>
    simp only [List.foldl_cons,ih,eval_append,List.map_cons,R1CS.sum]
    grind

theorem fold_weighted {F : Type} [CommRing F] (values : Nat → F) (pairs : List (Nat × Linear)) (a : Linear) :
    E values (pairs.foldl (fun a pair => a++scale pair.2 (Int.ofNat pair.1)) a) =
      E values a + R1CS.sum (pairs.map (fun pair => E values pair.2 * (pair.1 : F))) := by
  induction pairs generalizing a with
  | nil => simp [R1CS.sum,AddCommMonoid.add_zero]
  | cons pair pairs ih =>
    simp only [List.foldl_cons,ih,eval_append,eval_scale,List.map_cons,R1CS.sum]
    simp only [Int.ofNat_eq_natCast,Ring.intCast_natCast]
    grind only

theorem weighted_zip {F : Type} [CommRing F] (values : Nat → F) (codes : List Nat) (xs : Fields) :
    R1CS.sum ((codes.zip xs).map (fun pair => E values pair.2 * (pair.1 : F))) =
      R1CS.weightedValues codes (xs.map (E values)) := by
  induction codes generalizing xs with
  | nil => simp [R1CS.sum,R1CS.weightedValues]
  | cons code codes ih => cases xs <;> simp [R1CS.sum,R1CS.weightedValues,ih]

theorem selectors {F : Type} [Field F] [IsCharP F scalarModulus]
    (r : OperandRowCheck.Record) (length : r.tags.length = 11) (values : Nat → F) (one : values 0 = 1)
    (holds : AllHold values (selectorGates r)) :
    ∃ kind : OperandEvents.Kind, E values (f r.row 0) = (OperandEvents.kindCode kind : F) ∧
      r.tags.map (E values) = EventSelectors.codes.map (fun code => OperandEvents.flag (decide (code = OperandEvents.kindCode kind))) := by
  have boolean : ∀ v ∈ r.tags.map (E values), v*(v-1) = 0 := by
    intro value member
    obtain ⟨x,xm,rfl⟩ := List.mem_map.mp member
    have h := holds (boolGate x) (by simp [selectorGates,List.mem_map_of_mem,xm])
    change E values x * E values (sub x (constant 1)) = E values (constant 0) at h
    simpa [eval_sub,eval_constant values one,Ring.intCast_zero,Ring.intCast_one] using h
  have total := equality_sound values one (r.tags.foldl (·++·) []) o (holds _ (by simp [selectorGates]))
  have totalValue : R1CS.sum (r.tags.map (E values)) = 1 := by
    rw [fold_append] at total
    have origin : E values ([] : Linear) = 0 := by rfl
    rw [origin,show o = constant 1 from rfl,eval_constant values one] at total
    simpa only [AddCommMonoid.zero_add,Ring.intCast_one] using total
  have binding := equality_sound values one (f r.row 0) (((codes.zip r.tags).drop 1).foldl (fun a pair => a++scale pair.2 (Int.ofNat pair.1)) []) (holds _ (by simp [selectorGates]))
  have bindValue : R1CS.weightedValues EventSelectors.codes (r.tags.map (E values)) = E values (f r.row 0) := by
    cases tags : r.tags with
    | nil => simp [tags] at length
    | cons x xs =>
      rw [tags] at binding
      change E values (f r.row 0) = E values
        (([1,2,3,4,5,6,7,8,9,15].zip xs).foldl (fun a pair => a++scale pair.2 (Int.ofNat pair.1)) []) at binding
      rw [fold_weighted,weighted_zip] at binding
      simpa only [EventSelectors.codes,tags,List.map_cons,R1CS.weightedValues,
        Semiring.natCast_zero,Semiring.mul_zero,AddCommMonoid.zero_add,
        E,evalLinear,interpretLinear,R1CS.eval,List.map_nil] using binding.symm

  exact EventSelectors.selection _ _ (by simpa using length) boolean totalValue bindValue

structure Represents {F : Type} [Field F] (values : Nat → F) (r : OperandRowCheck.Record)
    (row : OperandEvents.Row) : Prop where
  kind : E values (f r.row 0) = (OperandEvents.kindCode row.kind : F)
  functionIndex : E values (f r.row 1) = (row.functionIndex : F)
  height : E values (f r.row 2) = (row.height : F)
  floor : E values (f r.row 3) = (row.floor : F)
  valueType : E values (f r.row 4) = (row.valueType.val : F)
  polymorphic : E values (f r.row 5) = OperandEvents.flag row.polymorphic
  unreachable : E values (f r.row 6) = OperandEvents.flag row.unreachable
  selectors : r.tags.map (E values) = EventSelectors.codes.map
    (fun code => OperandEvents.flag (decide (code = OperandEvents.kindCode row.kind)))

theorem decoded {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : OperandRowCheck.Record) (checked : OperandRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ row : OperandEvents.Row, Represents values r row ∧ row.functionIndex < 2^32 ∧
      row.height < 2^32 ∧ row.floor < 2^32 ∧
      ∃ available : Nat, available < 2^32 ∧ E values r.available = (available : F) := by
  have fs := facts matrix r checked values one satisfied
  obtain ⟨kind,kindImage,tags⟩ := selectors r fs.1 values one fs.2.1
  obtain ⟨fn,fnb,fni⟩ := fs.2.2.2.2.1 0 (by decide)
  obtain ⟨height,hb,hi⟩ := fs.2.2.2.2.1 1 (by decide)
  obtain ⟨floor,fb,fi⟩ := fs.2.2.2.2.1 2 (by decide)
  obtain ⟨ty,tb,ti⟩ := fs.2.2.2.2.1 3 (by decide)
  obtain ⟨av,ab,ai⟩ := fs.2.2.2.2.1 4 (by decide)
  have boolRep (x : Linear) (h : Holds values (boolGate x)) :
      ∃ b : Bool, E values x = OperandEvents.flag b := by
    rcases boolean_sound values one x h with off | on
    · exact ⟨false,off⟩
    · exact ⟨true,on⟩
  obtain ⟨poly,pi⟩ := boolRep (f r.row 5) (fs.2.2.1 _ (by simp [stepGates]))
  obtain ⟨unreach,ui⟩ := boolRep (f r.row 6) (fs.2.2.1 _ (by simp [stepGates]))
  exact ⟨⟨kind,fn,height,floor,⟨ty,by simpa using tb⟩,poly,unreach⟩,
    ⟨kindImage,fni,hi,fi,ti,pi,ui,tags⟩,fnb,hb,fb,av,ab,ai⟩

theorem selected {F : Type} [Field F] (values : Nat → F) (r : OperandRowCheck.Record)
    (row : OperandEvents.Row) (images : Represents values r row) :
    E values (f r.tags 2) = OperandEvents.flag (OperandEvents.isPush row) ∧
    E values (f r.tags 3) = OperandEvents.flag (OperandEvents.isPop row) ∧
    E values (f r.tags 6) = OperandEvents.flag (OperandEvents.isClear row) := by
  have getImage (i : Nat) := congrArg (fun xs : List F => xs.getD i 0) images.selectors
  have zero : E values z = 0 := by simp [z,E,evalLinear,constant,interpretLinear,R1CS.eval,Ring.intCast_zero,Semiring.zero_mul,AddCommMonoid.zero_add]
  have get (i : Nat) : E values (f r.tags i) =
      (EventSelectors.codes.map (fun code => OperandEvents.flag (decide (code = OperandEvents.kindCode row.kind)))).getD i 0 := by
    have h := getImage i
    have left : (r.tags.map (E values)).getD i 0 = E values (f r.tags i) := by
      rw [← zero]
      exact TokenInteger.map_getD (E values) r.tags z i
    rw [left] at h
    exact h
  have a := get 2
  have b := get 3
  have c := get 6
  cases k : row.kind <;> simpa [EventSelectors.codes,OperandEvents.kindCode,OperandEvents.isPush,
    OperandEvents.isPop,OperandEvents.isClear,k] using And.intro a (And.intro b c)

theorem transition_of_represents {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : OperandRowCheck.Record) (checked : OperandRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (before : Nat) (beforeBound : before < 2^32) (beforeImage : E values r.before = (before : F))
    (row : OperandEvents.Row) (images : Represents values r row)
    (heightBound : row.height < 2^32) (floorBound : row.floor < 2^32) :
    OperandEvents.StepSpec before row ∧
      E values (f r.access 0) = OperandEvents.flag (OperandEvents.project row).active ∧
      E values (f r.access 1) = OperandEvents.flag (OperandEvents.project row).write ∧
      E values (f r.access 2) = ((OperandEvents.project row).address : F) ∧
      E values (f r.access 3) = ((OperandEvents.project row).value : F) := by
  have fs := facts matrix r checked values one satisfied
  obtain ⟨av,ab,ai⟩ := fs.2.2.2.2.1 4 (by decide)
  change av < 2^32 at ab
  change E values r.available = (av : F) at ai
  obtain ⟨push,pop,clear⟩ := selected values r row images
  have raw (a b : Linear) (h : Holds values (gate a b)) : E values a * E values b = 0 := by
    change E values a * E values b = E values z at h
    simpa [z,eval_constant values one,Ring.intCast_zero] using h
  have a := raw (f r.row 5) (sub o (f r.tags 3)) (fs.2.2.1 _ (by simp [stepGates]))
  have b := raw (f r.row 5) (sub (f r.row 4) (n 7)) (fs.2.2.1 _ (by simp [stepGates]))
  have c := raw (sub (sub o (f r.tags 2)) (f r.tags 3)) (sub (f r.row 4) (n 7)) (fs.2.2.1 _ (by simp [stepGates]))
  have d := raw (f r.row 5) (sub r.before (f r.row 3)) (fs.2.2.1 _ (by simp [stepGates]))
  have e := raw (f r.row 5) (sub o (f r.row 6)) (fs.2.2.1 _ (by simp [stepGates]))
  have product := multiply_sound values (f r.tags 3++f r.tags 6) (sub r.before (f r.row 3)) r.product (fs.2.2.1 _ (by simp [stepGates]))
  have discarded := multiply_sound values (f r.tags 6) (sub r.before (f r.row 3)) r.discarded (fs.2.2.1 _ (by simp [stepGates]))
  have height := equality_sound values one (f r.row 2) (sub (sub (r.before++f r.tags 2) (sub (f r.tags 3) (f r.row 5))) r.discarded) (fs.2.2.1 _ (by simp [stepGates]))
  have available := fs.2.2.2.2.2.1
  have steps : OperandEvents.StepGates (F := F) before row av := by
    simp only [eval_sub,eval_append,eval_constant values one,o,n,Ring.intCast_one,
      show ((Int.ofNat 7 : Int) : F) = 7 from Ring.intCast_ofNat 7,push,pop,clear,images.height,images.floor,images.valueType,
      images.polymorphic,images.unreachable,beforeImage,ai] at a b c d e product discarded height available
    exact ⟨a,b,c,d,e,by rw [available,product],by rw [height,discarded]⟩
  have step := OperandEvents.step_sound before row av beforeBound floorBound heightBound ab steps
  have address := multiply_sound values (f r.tags 2++sub (f r.tags 3) (f r.row 5)) (sub (scale (f r.row 1) (Int.ofNat (2^32))++f r.row 2) (f r.tags 2)) (f r.access 2) (fs.2.2.2.1 _ (by simp [accessGates]))
  have value := multiply_sound values (f r.tags 2++sub (f r.tags 3) (f r.row 5)) (f r.row 4) (f r.access 3) (fs.2.2.2.1 _ (by simp [accessGates]))
  have active := fs.2.2.2.2.2.2.1
  have write := fs.2.2.2.2.2.2.2
  have accesses : OperandEvents.AccessGates row (E values (f r.access 0)) (E values (f r.access 1))
      (E values (f r.access 2)) (E values (f r.access 3)) := by
    simp only [eval_sub,eval_append,eval_scale,push,pop,images.polymorphic,images.functionIndex,
      images.height,images.valueType,Int.ofNat_eq_natCast,Ring.intCast_natCast] at address value active write
    change _ = _ ∧ _ = _ ∧ _ = _ ∧ _ = _
    refine ⟨by grind only,write,?_,?_⟩
    · unfold OperandEvents.bound
      grind only
    · grind only
  exact ⟨step,OperandEvents.access_sound before row _ _ _ _ step accesses⟩

theorem transition {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : OperandRowCheck.Record) (checked : OperandRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (before : Nat) (beforeBound : before < 2^32) (beforeImage : E values r.before = (before : F)) :
    ∃ row : OperandEvents.Row, Represents values r row ∧ row.functionIndex < 2^32 ∧
      row.height < 2^32 ∧ row.floor < 2^32 ∧ OperandEvents.StepSpec before row ∧
      E values (f r.access 0) = OperandEvents.flag (OperandEvents.project row).active ∧
      E values (f r.access 1) = OperandEvents.flag (OperandEvents.project row).write ∧
      E values (f r.access 2) = ((OperandEvents.project row).address : F) ∧
      E values (f r.access 3) = ((OperandEvents.project row).value : F) := by
  obtain ⟨row,images,fb,hb,flb,_⟩ := decoded matrix r checked values one satisfied
  exact ⟨row,images,fb,hb,flb,transition_of_represents matrix r checked values one satisfied
    before beforeBound beforeImage row images hb flb⟩

theorem boundaries {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : OperandRowCheck.Record) (checked : OperandRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : OperandEvents.Row) (images : Represents values r row) (heightBound : row.height < 2^32) (functionBound : row.functionIndex < 2^32) (floorBound : row.floor < 2^32) :
    (row.kind = .functionBegin ∨ row.kind = .functionEnd → row.height = 0) ∧
    (row.kind = .padding → row.functionIndex = 0 ∧ row.floor = 0 ∧ row.unreachable = false) ∧
    (E values r.previousPadding = 1 → row.kind = .padding) := by
  have parts := checked
  simp only [OperandRowCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] at parts
  rcases parts with ⟨_,_,_,_,_,_,_,_,boundary,_⟩
  have holds := includes_sound matrix _ _ _ boundary values satisfied
  have selector (i : Nat) := congrArg (fun xs : List F => xs.getD i 0) images.selectors
  have zeros : E values z = 0 := by simpa [z,Ring.intCast_zero] using eval_constant values one 0
  have tags (i : Nat) : E values (f r.tags i) =
      (EventSelectors.codes.map (fun code => OperandEvents.flag (decide (code = OperandEvents.kindCode row.kind)))).getD i 0 := by
    have h := selector i
    have left : (r.tags.map (E values)).getD i 0 = E values (f r.tags i) := by
      rw [← zeros]; exact TokenInteger.map_getD _ _ z i
    rw [left] at h
    exact h
  have raw (a b : Linear) (h : Holds values (gate a b)) : E values a * E values b = 0 := by
    change E values a * E values b = E values z at h
    rwa [zeros] at h
  have closed := raw (f r.tags 0++f r.tags 8) (f r.row 2) (holds _ (by simp [boundaryGates]))
  have fn := raw (f r.tags 10) (f r.row 1) (holds _ (by simp [boundaryGates]))
  have floor := raw (f r.tags 10) (f r.row 3) (holds _ (by simp [boundaryGates]))
  have unreach := raw (f r.tags 10) (f r.row 6) (holds _ (by simp [boundaryGates]))
  have pad := raw r.previousPadding (sub o (f r.tags 10)) (holds _ (by simp [boundaryGates]))
  have range := facts matrix r checked values one satisfied
  have naturalZero (n : Nat) (nb : n < 2^32) (nz : (n : F) = 0) : n = 0 :=
    OperandEvents.natural_eq n 0 (by unfold OperandEvents.bound; omega) (by decide) (by simpa [Semiring.natCast_zero] using nz)
  constructor
  · intro h
    rcases h with k | k
    all_goals
      have zero : (row.height : F) = 0 := by
        simpa [eval_append,tags,images.height,EventSelectors.codes,OperandEvents.kindCode,
          OperandEvents.flag,k,Semiring.one_mul,Semiring.add_zero,AddCommMonoid.zero_add] using closed
      exact naturalZero row.height heightBound zero
  constructor
  · intro k
    have nz : (row.functionIndex : F) = 0 := by
      simpa [tags,images.functionIndex,EventSelectors.codes,OperandEvents.kindCode,OperandEvents.flag,k,Semiring.one_mul] using fn
    have fz : (row.floor : F) = 0 := by
      simpa [tags,images.floor,EventSelectors.codes,OperandEvents.kindCode,OperandEvents.flag,k,Semiring.one_mul] using floor
    have uz : OperandEvents.flag (F := F) row.unreachable = 0 := by
      simpa [tags,images.unreachable,EventSelectors.codes,OperandEvents.kindCode,OperandEvents.flag,k,Semiring.one_mul] using unreach
    exact ⟨naturalZero _ functionBound nz,naturalZero _ floorBound fz,by
      cases h : row.unreachable
      · rfl
      · have bad : (1 : F) = 0 := by simpa [h,OperandEvents.flag] using uz
        exact False.elim (Field.zero_ne_one bad.symm)⟩
  · intro previous
    rw [previous,eval_sub,show o = constant 1 from rfl,eval_constant values one] at pad
    cases k : row.kind <;> try rfl
    all_goals simp [tags,EventSelectors.codes,OperandEvents.kindCode,OperandEvents.flag,k,Ring.intCast_one] at pad
    all_goals exact False.elim (Field.zero_ne_one (α := F) (by grind))

#print axioms boundaries
#print axioms transition_of_represents
#print axioms decoded
#print axioms selected
#print axioms transition

#print axioms includes_sound
#print axioms facts
#print axioms selectors
end ZkBuild.OperandRowSound
