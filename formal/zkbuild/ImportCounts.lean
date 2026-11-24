import ImportRules
set_option autoImplicit false

namespace ZkBuild.ImportCounts
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ImportMatrix ImportRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def count : List Decoded → Nat → Nat | [],_ => 0 | d::ds,i => increment d i+count ds i
def activeCount : List Decoded → Nat | [] => 0 | d::ds => d.active.toNat+activeCount ds
def Prefix : Bool → List Decoded → Prop | _,[] => True | previous,d::ds => (d.active = true → previous = true) ∧ Prefix d.active ds

theorem count_bound (ds : List Decoded) (i : Nat) : count ds i ≤ ds.length := by
  induction ds with
  | nil => exact Nat.le_refl 0
  | cons d ds ih =>
    have bit : increment d i ≤ 1 := by unfold increment; split <;> decide
    simp only [count,List.length_cons]; omega

theorem active_bound (ds : List Decoded) : activeCount ds ≤ ds.length := by
  induction ds with
  | nil => exact Nat.le_refl 0
  | cons d ds ih =>
    have bit : d.active.toNat ≤ 1 := by cases d.active <;> decide
    simp only [activeCount,List.length_cons]; omega

theorem count_sum (ds : List Decoded) (bounds : ∀ d ∈ ds, d.kind < 4) :
    count ds 0+count ds 1+count ds 2+count ds 3 = activeCount ds := by
  induction ds with
  | nil => rfl
  | cons d ds ih =>
    have kb := bounds d (by simp)
    have tail := ih (by intro x xm; exact bounds x (by simp [xm]))
    have kinds : d.kind = 0 ∨ d.kind = 1 ∨ d.kind = 2 ∨ d.kind = 3 := by omega
    cases active : d.active <;> rcases kinds with k | k | k | k <;> simp [count,increment,activeCount,active,k] <;> omega

theorem total_cons {F : Type} [CommRing F] (values : Nat → F) (row : Row) (rest : List Row) :
    E values (ImportMatrix.total (row::rest)) = E values row.active+E values (ImportMatrix.total rest) := by
  simp only [ImportMatrix.total,List.flatMap_cons]
  have a := eval_append values z (row.active++rest.flatMap Row.active)
  have b := eval_append values row.active (rest.flatMap Row.active)
  have c := eval_append values z (rest.flatMap Row.active)
  change E values (z++(row.active++rest.flatMap Row.active)) = E values z+E values (row.active++rest.flatMap Row.active) at a
  change E values (row.active++rest.flatMap Row.active) = E values row.active+E values (rest.flatMap Row.active) at b
  change E values (z++rest.flatMap Row.active) = E values z+E values (rest.flatMap Row.active) at c
  rw [a,b,c]
  grind

theorem rows {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (exports : Linear) (items : List Row)
    (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear)
    (checked : checkRows matrix tokens splits exports items index cursor counts previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (flag : Bool) (pi : E values previous = (flag.toNat : F)) :
    ∃ ds : List Decoded, Related (ImportRules.Represents values) items ds ∧ (∀ d ∈ ds, d.kind < 4) ∧ Prefix flag ds ∧
      (∀ i, i < 4 → E values (DeclarationMatrix.get (final items cursor counts).2 i) = E values (DeclarationMatrix.get counts i)+(count ds i : F)) ∧
      E values (ImportMatrix.total items) = (activeCount ds : F) := by
  induction items generalizing index cursor counts previous flag with
  | nil =>
    refine ⟨[],.nil,by simp,True.intro,?_,?_⟩
    · intro i ib; simp only [final,count,Semiring.natCast_zero]; grind
    · simp [ImportMatrix.total,activeCount,z,eval_constant values oneValue]
  | cons row rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    obtain ⟨d,image,kb,prior,indicators,step⟩ := ImportRules.decode matrix tokens splits exports row index cursor counts previous parts.1 values oneValue satisfied
    have prefixStep : d.active = true → flag = true := by
      intro da
      have eq : (flag.toNat : F) = 1 := pi.symm.trans (prior da)
      cases flag with
      | true => rfl
      | false => simp only [Bool.toNat_false,Semiring.natCast_zero] at eq; exact False.elim (Field.zero_ne_one eq)
    obtain ⟨ds,images,bounds,ordered,finish,active⟩ := ih (index+1) (readAt row 6).cursor row.counts row.active parts.2 d.active image.1
    refine ⟨d::ds,.cons image images,?_,⟨prefixStep,ordered⟩,?_,?_⟩
    · intro x xm; rcases List.mem_cons.mp xm with rfl | later; exact kb; exact bounds x later
    · intro i ib
      simp only [final,count,Semiring.natCast_add]
      rw [finish i ib,step i ib]
      grind
    · rw [total_cons, image.1, active]
      simp only [activeCount,Semiring.natCast_add]

theorem checked_counts {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ ds : List Decoded, Related (ImportRules.Represents values) imports.rows ds ∧ (∀ d ∈ ds, d.kind < 4) ∧ Prefix true ds ∧
      activeCount ds < 2^32 ∧
      E values imports.importedFunctions = (count ds 0 : F) ∧ E values imports.importedTables = (count ds 1 : F) ∧
      E values imports.importedMemories = (count ds 2 : F) ∧ E values imports.importedGlobals = (count ds 3 : F) ∧
      E values (DeclarationMatrix.get body.envelope.outputs 9) = (activeCount ds : F) ∧
      count ds 0+count ds 1+count ds 2+count ds 3 = activeCount ds := by
  have imp := (Bool.and_eq_true_iff.mp checked).2
  simp only [ImportMatrix.check,ImportMatrix.closeGates,Bool.and_eq_true_iff] at imp
  have shape : imports.rows.length < 2^32 ∧ imports.importedFunctions = space.importedFunctions ∧ links tables signature imports := _root_.of_decide_eq_true (by grind only)
  have rc : checkRows matrix body.tokens splits imports.exportCount imports.rows 0 (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z] o = true := by grind only
  have one : E values o = ((true.toNat : Nat) : F) := by simp [o,eval_constant values oneValue]
  obtain ⟨ds,images,bounds,ordered,counts,active⟩ := rows matrix body.tokens splits imports.exportCount imports.rows 0 (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z] o rc values oneValue satisfied true one
  have close : MemoryEvidence.checkSpan matrix imports.closeStart imports.closeEnd
      [eqGate (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).1 (DeclarationMatrix.get body.envelope.outputs 11),
       eqGate (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 0) imports.importedFunctions,
       eqGate (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 1) imports.importedTables,
       eqGate (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 2) imports.importedMemories,
       eqGate (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 3) imports.importedGlobals,
       eqGate (ImportMatrix.total imports.rows) (DeclarationMatrix.get body.envelope.outputs 9)] = true := by grind only
  have all := MemoryEvidence.span_sound matrix _ _ _ close values satisfied
  have imagesCount (i : Nat) (ib : i < 4) : E values (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 i) = (count ds i : F) := by
    have ci := counts i ib
    have zi : E values (DeclarationMatrix.get [z,z,z,z] i) = 0 := by
      have which : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 := by omega
      rcases which with rfl | rfl | rfl | rfl <;> simp [DeclarationMatrix.get,z,eval_constant values oneValue]
    rw [zi] at ci
    have zeroAdd : (0 : F)+(count ds i : F) = (count ds i : F) := by grind
    exact ci.trans zeroAdd
  have last := equality_sound values oneValue (ImportMatrix.total imports.rows) (DeclarationMatrix.get body.envelope.outputs 9) (all _ (by simp))
  have f := equality_sound values oneValue (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 0) imports.importedFunctions (all _ (by simp))
  have t := equality_sound values oneValue (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 1) imports.importedTables (all _ (by simp))
  have m := equality_sound values oneValue (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 2) imports.importedMemories (all _ (by simp))
  have g := equality_sound values oneValue (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 3) imports.importedGlobals (all _ (by simp))
  have length := related_length _ _ _ images
  have size := active_bound ds
  exact ⟨ds,images,bounds,ordered,by omega,f.symm.trans (imagesCount 0 (by decide)),t.symm.trans (imagesCount 1 (by decide)),m.symm.trans (imagesCount 2 (by decide)),g.symm.trans (imagesCount 3 (by decide)),last.symm.trans active,count_sum ds bounds⟩

#print axioms rows
#print axioms checked_counts
end ZkBuild.ImportCounts
