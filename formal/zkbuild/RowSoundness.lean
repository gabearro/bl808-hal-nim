import CircuitShape
import BitPacking

/- Algebraic row semantics after eliminating the multiplication-result wires.
   Residual expressions are interpreted in both integers and an arbitrary
   scalar field. This separates finite parser cases from field soundness. -/
namespace ZkBuild.RowSoundness

open Lean.Grind
attribute [local instance] Ring.intCast Semiring.natCast

inductive Expr where
  | literal : Int → Expr
  | input : Nat → Expr
  | add : Expr → Expr → Expr
  | sub : Expr → Expr → Expr
  | mul : Expr → Expr → Expr
  deriving Repr, Inhabited, DecidableEq

instance : Add Expr := ⟨Expr.add⟩
instance : Sub Expr := ⟨Expr.sub⟩
instance : Mul Expr := ⟨Expr.mul⟩
instance (n : Nat) : OfNat Expr n := ⟨.literal (Int.ofNat n)⟩

def evalInt (values : Nat → Int) : Expr → Int
  | .literal n => n
  | .input i => values i
  | .add a b => evalInt values a + evalInt values b
  | .sub a b => evalInt values a - evalInt values b
  | .mul a b => evalInt values a * evalInt values b

def evalField {F : Type} [CommRing F] (values : Nat → F) : Expr → F
  | .literal n => (n : F)
  | .input i => values i
  | .add a b => evalField values a + evalField values b
  | .sub a b => evalField values a - evalField values b
  | .mul a b => evalField values a * evalField values b

theorem integer_interpretation_commutes {F : Type} [CommRing F]
    (values : Nat → Int) (e : Expr) :
    evalField (fun i => (values i : F)) e = (evalInt values e : F) := by
  induction e <;> simp_all [evalField, evalInt, Ring.intCast_add, Ring.intCast_sub, Ring.intCast_mul]

def sumExpr : List Expr → Expr
  | [] => 0
  | value :: rest => value + sumExpr rest

structure Row where
  residuals : List Expr
  nextPhases : List Expr
  nextDepths : List Expr

-- Input positions: phases 0..7, depths 8..16, byte bits 17..24,
-- opcode selectors 25..34. They are constrained separately by Boolean,
-- byte-binding and selector-binding equations.
def phase (i : Nat) : Expr := .input i
def depth (i : Nat) : Expr := .input (8+i)
def bit (i : Nat) : Expr := .input (17+i)
def selected (i : Nat) : Expr := .input (25+i)

def row : Row := Id.run do
  let ready := phase 0
  let index := phase 1
  let done := phase 7
  let leb := sumExpr ((List.range 5).map fun i => phase (i+2))
  let value := sumExpr ((List.range 8).map fun i => bit i * .literal (Int.ofNat (2^i)))
  let cont := bit 7
  let finish := leb * (1 - cont)
  let push := index + finish
  let binary := sumExpr ((List.range 6).map fun i => selected (i+3))
  let keep := 1 - push - binary
  let nextDepths := (List.range 9).map fun i =>
    depth i * keep + (if i > 0 then depth (i-1) * push else 0) +
      (if i < 8 then depth (i+1) * binary else 0)
  let nextLeb := selected 2 :: ((List.range 4).map fun i => phase (i+2) * cont)
  let nextReady := selected 0 + binary + index + finish
  let nextIndex := selected 1
  let nextDone := 1 - nextReady - nextIndex - sumExpr nextLeb
  let residuals := [
    done * value,
    sumExpr ((List.range 10).map selected) - ready,
    ready * value - sumExpr ((List.range 10).map fun i => selected i * .literal (Int.ofNat (ByteStream.opcode i)))] ++
    ((List.range 7).map fun i => index * bit (i+1)) ++
    [phase 6 * cont] ++
    ((List.range 3).map fun i => phase 6 * (bit (i+4) - bit 3)) ++
    [binary * (depth 0 + depth 1), sumExpr nextDepths - 1, selected 9 * (depth 1 - 1)]
  return ⟨residuals, nextReady :: nextIndex :: nextLeb ++ [nextDone], nextDepths⟩

def flag (p : Prop) [Decidable p] : Int := if p then 1 else 0

def canonicalInputs (p : Fin 8) (h : Fin 9) (b : Fin 256) (i : Nat) : Int :=
  if i < 8 then flag (i = p.val)
  else if i < 17 then flag (i-8 = h.val)
  else if i < 25 then flag ((b.val / 2^(i-17)) % 2 = 1)
  else if i < 35 then flag (p.val = 0 ∧ b.val = ByteStream.opcode (i-25))
  else 0

def oneHot (size index : Nat) : List Int := (List.range size).map fun i => flag (i = index)

def intResiduals (p : Fin 8) (h : Fin 9) (b : Fin 256) : List Int :=
  row.residuals.map (evalInt (canonicalInputs p h b))

def integerHolds (p : Fin 8) (h : Fin 9) (b : Fin 256) : Bool :=
  (intResiduals p h b).all (fun r => r == 0)

def finiteCertificate (p : Fin 8) (h : Fin 9) (b : Fin 256) : Bool :=
  match ByteStream.referenceRow p.val h.val b.val with
  | none => !integerHolds p h b
  | some (nextPhase, nextDepth) =>
    integerHolds p h b &&
    decide (row.nextPhases.map (evalInt (canonicalInputs p h b)) = oneHot 8 nextPhase) &&
    decide (row.nextDepths.map (evalInt (canonicalInputs p h b)) = oneHot 9 nextDepth)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem finite_row_certificate : ∀ p h b, finiteCertificate p h b = true := by
  native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem finite_residual_bounds : ∀ p h b,
    (intResiduals p h b).all (fun r => decide ((-65536 : Int) < r ∧ r < 65536)) = true := by
  native_decide

theorem small_integer_zero {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (r : Int) (bound : (-65536 : Int) < r ∧ r < 65536)
    (zero : (r : F) = 0) : r = 0 := by
  have modular := (IsCharP.intCast_eq_zero_iff (α := F) scalarModulus r).mp zero
  unfold scalarModulus at modular
  omega

def FieldHolds {F : Type} [CommRing F] (values : Nat → F) : Prop :=
  ∀ e ∈ row.residuals, evalField values e = 0

theorem field_constraints_imply_integer_constraints {F : Type} [CommRing F]
    [IsCharP F scalarModulus] (p : Fin 8) (h : Fin 9) (b : Fin 256)
    (holds : FieldHolds (fun i => (canonicalInputs p h b i : F))) :
    integerHolds p h b = true := by
  unfold integerHolds
  apply List.all_eq_true.mpr
  intro r member
  obtain ⟨e, eMember, rfl⟩ := List.mem_map.mp member
  have bounds := List.all_eq_true.mp (finite_residual_bounds p h b) _ (List.mem_map.mpr ⟨e, eMember, rfl⟩)
  have bounds' : (-65536 : Int) < evalInt (canonicalInputs p h b) e ∧
      evalInt (canonicalInputs p h b) e < 65536 := by simpa using bounds
  have zero := holds e eMember
  rw [integer_interpretation_commutes] at zero
  have exactZero := small_integer_zero (evalInt (canonicalInputs p h b) e) bounds' zero
  simp [exactZero]

theorem canonical_field_row_sound {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (p : Fin 8) (h : Fin 9) (b : Fin 256)
    (holds : FieldHolds (fun i => (canonicalInputs p h b i : F))) :
    ∃ nextPhase nextDepth,
      ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth) ∧
      row.nextPhases.map (evalField (fun i => (canonicalInputs p h b i : F))) =
        (oneHot 8 nextPhase).map (fun n : Int => (n : F)) ∧
      row.nextDepths.map (evalField (fun i => (canonicalInputs p h b i : F))) =
        (oneHot 9 nextDepth).map (fun n : Int => (n : F)) := by
  have intHolds := field_constraints_imply_integer_constraints p h b holds
  have certified := finite_row_certificate p h b
  cases ref : ByteStream.referenceRow p.val h.val b.val with
  | none => simp [finiteCertificate, ref, intHolds] at certified
  | some next =>
    rcases next with ⟨nextPhase, nextDepth⟩
    have outputs := certified
    simp [finiteCertificate, ref, intHolds] at outputs
    refine ⟨nextPhase, nextDepth, rfl, ?_, ?_⟩
    · have mapped := congrArg (List.map (fun n : Int => (n : F))) outputs.1
      simpa only [List.map_map, Function.comp_def, ← integer_interpretation_commutes] using mapped
    · have mapped := congrArg (List.map (fun n : Int => (n : F))) outputs.2
      simpa only [List.map_map, Function.comp_def, ← integer_interpretation_commutes] using mapped

#print axioms canonical_field_row_sound

end ZkBuild.RowSoundness
