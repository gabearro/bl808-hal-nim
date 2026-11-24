import SignatureOrigins

namespace ZkBuild.DeclarationPrefix
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def Prefix : Bool → List DeclarationType.Decoded → Prop
  | _,[] => True
  | previous,d::rest => (d.active = true → previous = true) ∧ Prefix d.active rest

theorem checked_prefix {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (endPos : Linear)
    (rows : List TypeRow) (index : Nat) (counts : List Linear) (previous : Linear)
    (checked : checkTypes matrix tokens splits endPos rows index counts previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (types : List DeclarationType.Decoded) (images : Related (DeclarationType.Represents values) rows types)
    (flag : Bool) (pi : E values previous = (flag.toNat : F)) : Prefix flag types := by
  induction images generalizing index counts previous flag with
  | nil => trivial
  | @cons row d rows ds image images ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    have all := DeclarationType.type_holds matrix tokens splits row index counts previous endPos parts.1 values satisfied
    have first := DeclarationType.part_holds values tokens splits row index counts previous endPos all 0 (by decide)
    have gate := first (DeclarationMatrix.gate (get row.fields 0) (sub o previous)) (by simp [typeParts])
    change E values (get row.fields 0)*E values (sub o previous) = E values z at gate
    have one : E values o = 1 := by simp [o,eval_constant values oneValue]
    have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
    rw [image.1,eval_sub,one,pi,zero] at gate
    refine ⟨?_,ih (index+1) row.counts (get row.fields 0) parts.2 d.active image.1⟩
    intro active
    cases flag with
    | true => rfl
    | false =>
      simp only [active,Bool.toNat_true,Bool.toNat_false,Semiring.natCast_one,Semiring.natCast_zero] at gate
      have bad : (0 : F) = 1 := by grind
      exact False.elim (Field.zero_ne_one bad)

theorem inactive_count (types : List DeclarationType.Decoded) (ordered : Prefix false types) : DeclarationCounts.typeActive types = 0 := by
  induction types with
  | nil => rfl
  | cons d ds ih =>
    have inactive : d.active = false := by
      cases flag : d.active with
      | false => rfl
      | true => have bad := ordered.1 flag; contradiction
    have tail : Prefix false ds := by simpa [inactive] using ordered.2
    simpa [DeclarationCounts.typeActive,inactive] using ih tail

theorem active_at (types : List DeclarationType.Decoded) (ordered : Prefix true types)
    (i : Nat) (bound : i < DeclarationCounts.typeActive types) : (types.getD i default).active = true := by
  induction types generalizing i with
  | nil => simp [DeclarationCounts.typeActive] at bound
  | cons d ds ih =>
    cases active : d.active with
    | false =>
      have tail : Prefix false ds := by simpa [active] using ordered.2
      simp [DeclarationCounts.typeActive,active,inactive_count ds tail] at bound
    | true =>
      cases i with
      | zero => simpa using active
      | succ i =>
        exact ih (by simpa [active] using ordered.2) i (by simp only [DeclarationCounts.typeActive,active,Bool.toNat_true] at bound; omega)

theorem count_bound (types : List DeclarationType.Decoded) : DeclarationCounts.typeActive types ≤ types.length := by
  induction types with
  | nil => exact Nat.le_refl 0
  | cons d ds ih =>
    have b : d.active.toNat ≤ 1 := by cases d.active <;> decide
    simp only [DeclarationCounts.typeActive,List.length_cons]
    omega

theorem count_unique {F : Type} [Field F] (values : Nat → F) (rows : List TypeRow)
    (a b : List DeclarationType.Decoded) (ai : Related (DeclarationType.Represents values) rows a)
    (bi : Related (DeclarationType.Represents values) rows b) : DeclarationCounts.typeActive a = DeclarationCounts.typeActive b := by
  induction ai generalizing b with
  | nil => cases bi; rfl
  | @cons row x rows xs image images ih =>
    cases bi with
    | @cons _ y _ ys other others =>
      have same : x.active = y.active := by
        have eq := image.1.symm.trans other.1
        cases xa : x.active <;> cases ya : y.active <;> simp_all
        · exact False.elim (Field.zero_ne_one eq)
        · exact False.elim (Field.zero_ne_one eq.symm)
      simp [DeclarationCounts.typeActive,same,ih ys others]

#print axioms checked_prefix
#print axioms active_at
#print axioms count_unique
end ZkBuild.DeclarationPrefix
