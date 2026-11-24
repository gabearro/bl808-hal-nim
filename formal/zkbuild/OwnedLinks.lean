import OwnedComplete
set_option autoImplicit false
namespace ZkBuild.OwnedLinks
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix OwnedMatrix OwnedRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem same_owner {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (r prior : Child) (next : Option Child)
    (checked : checkChild matrix splits r (some prior) next = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d p : ChildValue) (image : ChildImage values r d) (pi : ChildImage values prior p)
    (db : ChildBound d) (pb : ChildBound p) (active : d.active = true) :
    E values r.same = if d.owner = p.owner then 1 else 0 := by
  have all := child_holds matrix splits r (some prior) next checked values satisfied
  have third := child_part values splits r (some prior) next all 3 (by decide)
  have zeros := zero_sound values oneValue (sub (cget r 1) (cget prior 1)) (wire r.priorZero) (wire (r.priorZero+1)) (by
    intro g gm; exact third g (List.mem_append_left _ (List.mem_append_left _ (List.mem_append_left _ gm))))
  have multiply := multiply_sound values (cget r 0) (wire r.priorZero) r.same (third _ (by simp [childParts,priorGates]))
  have equal : E values (sub (cget r 1) (cget prior 1)) = 0 ↔ d.owner = p.owner := by
    rw [eval_sub,image.2.1,pi.2.1]
    constructor
    · intro h
      apply DeclarationLocations.natural_equal (F := F) d.owner p.owner (by have b := db.1; omega) (by have b := pb.1; omega)
      grind
    · intro h; rw [h]; grind
  have on : E values (cget r 0) = 1 := by simpa [active] using image.1
  rw [multiply,on,zeros]
  simp only [equal,Semiring.one_mul]

theorem adjacent {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (r prior : Child) (next : Option Child)
    (checked : checkChild matrix splits r (some prior) next = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d p : ChildValue) (image : ChildImage values r d) (pi : ChildImage values prior p)
    (db : ChildBound d) (pb : ChildBound p) (active : d.active = true) (same : d.owner = p.owner) :
    d.ordinal = p.ordinal+1 ∧ d.start = p.finish := by
  have isSame : E values r.same = 1 := by simpa [same] using same_owner matrix splits r prior next checked values oneValue satisfied d p image pi db pb active
  have all := child_holds matrix splits r (some prior) next checked values satisfied
  have third := child_part values splits r (some prior) next all 3 (by decide)
  have ordinalGate := third (gate r.same (sub (sub (cget r 2) (cget prior 2)) o)) (by simp [childParts,priorGates])
  have positionGate := third (gate r.same (sub (cget r 3) (cget prior 4))) (by simp [childParts,priorGates])
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  change E values r.same*E values (sub (sub (cget r 2) (cget prior 2)) o) = E values z at ordinalGate
  change E values r.same*E values (sub (cget r 3) (cget prior 4)) = E values z at positionGate
  rw [isSame,eval_sub,eval_sub,image.2.2.1,pi.2.2.1,one,zero] at ordinalGate
  rw [isSame,eval_sub,image.2.2.2.1,pi.2.2.2.2,zero] at positionGate
  constructor
  · apply DeclarationLocations.natural_equal (F := F) d.ordinal (p.ordinal+1) (by have b := db.2.1; omega) (by have b := pb.2.1; omega)
    simp only [Semiring.natCast_add,Semiring.natCast_one]
    grind
  · apply DeclarationLocations.natural_equal (F := F) d.start p.finish (by have b := db.2.2.1; omega) (by have b := pb.2.2.2; omega)
    grind

theorem first_child {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : Child) (prior next : Option Child)
    (checked : checkChild matrix splits r prior next = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : ChildValue) (image : ChildImage values r d) (bound : ChildBound d) (active : d.active = true)
    (first : E values r.same = 0) (start : Nat) (startBound : start < 2^32) (startImage : E values (split splits r.heads).low = (start : F)) :
    d.ordinal = 0 ∧ d.start = start := by
  have all := child_holds matrix splits r prior next checked values satisfied
  have fourth := child_part values splits r prior next all 4 (by decide)
  have ordinalGate := fourth (gate (sub (cget r 0) r.same) (cget r 2)) (by simp [childParts])
  have startGate := fourth (gate (sub (cget r 0) r.same) (sub (cget r 3) (split splits r.heads).low)) (by simp [childParts])
  have on : E values (cget r 0) = 1 := by simpa [active] using image.1
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  change E values (sub (cget r 0) r.same)*E values (cget r 2) = E values z at ordinalGate
  change E values (sub (cget r 0) r.same)*E values (sub (cget r 3) (split splits r.heads).low) = E values z at startGate
  rw [eval_sub,on,first,image.2.2.1,zero] at ordinalGate
  rw [eval_sub,on,first,eval_sub,image.2.2.2.1,startImage,zero] at startGate
  constructor
  · apply DeclarationLocations.natural_equal (F := F) d.ordinal 0 (by have b := bound.2.1; omega) (by decide)
    simp only [Semiring.natCast_zero]
    grind
  · apply DeclarationLocations.natural_equal (F := F) d.start start (by have b := bound.2.2.1; omega) (by omega)
    grind

theorem last_child {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : Child) (prior next : Option Child)
    (checked : checkChild matrix splits r prior next = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : ChildValue) (image : ChildImage values r d) (bound : ChildBound d) (active : d.active = true)
    (last : E values r.continues = 0) (count finish : Nat) (countBound : count < 2^32) (finishBound : finish < 2^32)
    (countImage : E values r.countQuery.value = (count : F)) (finishImage : E values (split splits r.heads).high = (finish : F)) :
    d.ordinal+1 = count ∧ d.finish = finish := by
  have all := child_holds matrix splits r prior next checked values satisfied
  have sixth := child_part values splits r prior next all 6 (by decide)
  have ordinalGate := sixth (gate (sub (cget r 0) r.continues) (sub (cget r 2++o) r.countQuery.value)) (by simp [childParts])
  have finishGate := sixth (gate (sub (cget r 0) r.continues) (sub (cget r 4) (split splits r.heads).high)) (by simp [childParts])
  have on : E values (cget r 0) = 1 := by simpa [active] using image.1
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have add := eval_append values (cget r 2) o
  change E values (cget r 2++o) = E values (cget r 2)+E values o at add
  change E values (sub (cget r 0) r.continues)*E values (sub (cget r 2++o) r.countQuery.value) = E values z at ordinalGate
  change E values (sub (cget r 0) r.continues)*E values (sub (cget r 4) (split splits r.heads).high) = E values z at finishGate
  rw [eval_sub,on,last,eval_sub,add,image.2.2.1,one,countImage,zero] at ordinalGate
  rw [eval_sub,on,last,eval_sub,image.2.2.2.2,finishImage,zero] at finishGate
  constructor
  · apply DeclarationLocations.natural_equal (F := F) (d.ordinal+1) count (by have b := bound.2.1; omega) (by omega)
    simp only [Semiring.natCast_add,Semiring.natCast_one]
    grind
  · apply DeclarationLocations.natural_equal (F := F) d.finish finish (by have b := bound.2.2.2; omega) (by omega)
    grind

theorem next_owner {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (r next : Child) (prior : Option Child)
    (checked : checkChild matrix splits r prior (some next) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d n : ChildValue) (image : ChildImage values r d) (ni : ChildImage values next n)
    (db : ChildBound d) (nb : ChildBound n) :
    E values r.continues = if n.active && n.owner == d.owner then 1 else 0 := by
  have all := child_holds matrix splits r prior (some next) checked values satisfied
  have fifth := child_part values splits r prior (some next) all 5 (by decide)
  have zeros := zero_sound values oneValue (sub (cget next 1) (cget r 1)) (wire r.nextZero) (wire (r.nextZero+1)) (by
    intro g gm; exact fifth g (List.mem_append_left _ gm))
  have multiply := multiply_sound values (cget next 0) (wire r.nextZero) r.continues (fifth _ (by simp [childParts,nextGates]))
  have equal : E values (sub (cget next 1) (cget r 1)) = 0 ↔ n.owner = d.owner := by
    rw [eval_sub,ni.2.1,image.2.1]
    constructor
    · intro h
      apply DeclarationLocations.natural_equal (F := F) n.owner d.owner (by have b := nb.1; omega) (by have b := db.1; omega)
      grind
    · intro h; rw [h]; grind
  rw [multiply,ni.1,zeros]
  simp only [equal]
  cases active : n.active <;> by_cases same : n.owner = d.owner <;> simp [active,same] <;> grind

theorem absent_flags {F : Type} [Field F]
    (matrix : Shape) (splits : Splits) (r : Child) (prior next : Option Child)
    (checked : checkChild matrix splits r prior next = true)
    (values : Nat → F) (oneValue : values 0 = 1) :
    (prior = none → E values r.same = 0) ∧ (next = none → E values r.continues = 0) := by
  have ck := checked
  simp only [checkChild,Bool.and_eq_true_iff] at ck
  have shape : childShape splits r prior next := _root_.of_decide_eq_true (by grind only)
  have first : prior.isNone = true → r.same = z := by unfold childShape at shape; grind only
  have last : next.isNone = true → r.continues = z := by unfold childShape at shape; grind only
  constructor
  · intro same
    subst prior
    rw [first rfl]
    simp [z,eval_constant values oneValue]
  · intro same
    subst next
    rw [last rfl]
    simp [z,eval_constant values oneValue]

#print axioms same_owner
#print axioms adjacent
#print axioms first_child
#print axioms last_child
#print axioms next_owner
#print axioms absent_flags
end ZkBuild.OwnedLinks
