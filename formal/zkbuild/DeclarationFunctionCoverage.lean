import DeclarationBinding
import DeclarationLocations

namespace ZkBuild.DeclarationFunctionCoverage
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram DeclarationLocations
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def count : List Bool → Nat | [] => 0 | a::rest => a.toNat+count rest
def Prefix : Bool → List Bool → Prop
  | _,[] => True
  | previous,a::rest => (a = true → previous = true) ∧ Prefix a rest

def Represents {F : Type} [Field F] (values : Nat → F) (row : FunctionRow) (active : Bool) : Prop :=
  E values row.active = (active.toNat : F)

theorem rows {F : Type} [Field F] [IsCharP F scalarModulus] (matrix : Shape) (tokens : Tokens)
    (first : Linear) (items : List FunctionRow) (index : Nat) (cursor previous currentCount : Linear)
    (checked : checkFunctions matrix tokens first items index cursor previous currentCount = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (previousFlag : Bool) (previousImage : E values previous = (previousFlag.toNat : F)) :
    ∃ flags : List Bool, Related (Represents values) items flags ∧ Prefix previousFlag flags ∧
      E values (functionFinal items cursor currentCount).2 = E values currentCount+(count flags : F) := by
  induction items generalizing index cursor previous currentCount previousFlag with
  | nil => exact ⟨[],.nil,True.intro,by simp only [functionFinal,count,Semiring.natCast_zero]; grind⟩
  | cons row rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    have holds := MemoryEvidence.span_sound matrix row.firstGate row.lastGate _ (Bool.and_eq_true_iff.mp parts.1).2 values satisfied
    have bit := boolean_sound values oneValue row.active (holds _ (by simp [functionGates]))
    obtain ⟨flag,image⟩ : ∃ flag : Bool, E values row.active = (flag.toNat : F) := by
      rcases bit with zero | one
      · exact ⟨false,by simpa using zero⟩
      · exact ⟨true,by simpa using one⟩
    have ordering := holds (gate row.active (sub o previous)) (by simp [functionGates])
    change E values row.active*E values (sub o previous) = E values z at ordering
    have one : E values o = 1 := by simp [o,eval_constant values oneValue]
    have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
    rw [image,eval_sub,one,previousImage,zero] at ordering
    have prior : flag = true → previousFlag = true := by
      intro active
      cases previousFlag with
      | true => rfl
      | false =>
        simp only [active,Bool.toNat_true,Bool.toNat_false,Semiring.natCast_one,Semiring.natCast_zero] at ordering
        have impossible : (0 : F) = 1 := by grind
        exact False.elim (Field.zero_ne_one impossible)
    have step := equality_sound values oneValue row.count (currentCount++row.active) (holds _ (by simp [functionGates]))
    have add := eval_append values currentCount row.active
    change E values (currentCount++row.active) = E values currentCount+E values row.active at add
    rw [add,image] at step
    obtain ⟨flags,images,ordered,total⟩ := ih (index+1) row.cursor row.active row.count parts.2 flag image
    refine ⟨flag::flags,.cons image images,⟨prior,ordered⟩,?_⟩
    simpa [functionFinal,count,Semiring.natCast_add,step,Semiring.add_assoc] using total

theorem count_bound (flags : List Bool) : count flags ≤ flags.length := by
  induction flags with
  | nil => exact Nat.le_refl 0
  | cons flag rest ih =>
    have b : flag.toNat ≤ 1 := by cases flag <;> decide
    simp only [count,List.length_cons]
    omega

theorem inactive_count (flags : List Bool) (ordered : Prefix false flags) : count flags = 0 := by
  induction flags with
  | nil => rfl
  | cons flag rest ih =>
    have inactive : flag = false := by
      cases flag with
      | false => rfl
      | true => have impossible := ordered.1 rfl; contradiction
    have tail : Prefix false rest := by simpa [inactive] using ordered.2
    simpa [count,inactive] using ih tail

theorem active_at (flags : List Bool) (ordered : Prefix true flags) (index : Nat)
    (inside : index < count flags) : flags.getD index false = true := by
  induction flags generalizing index with
  | nil => simp [count] at inside
  | cons flag rest ih =>
    cases active : flag with
    | false =>
      have tail : Prefix false rest := by simpa [active] using ordered.2
      simp [count,active,inactive_count rest tail] at inside
    | true =>
      cases index with
      | zero => simp
      | succ index =>
        exact ih (by simpa [active] using ordered.2) index (by simp only [count,active,Bool.toNat_true] at inside; omega)

/-- The function section's declared count covers exactly an active prefix of
    the source rows. In particular, padding cannot create holes in that prefix. -/
theorem checked_functions {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ total : Nat, total < 2^32 ∧ E values r.functionCount = (total : F) ∧ total ≤ r.functions.length ∧
      ∀ index, index < total → (r.functions.getD index default) ∈ r.functions ∧ E values (r.functions.getD index default).active = 1 := by
  have parts := (Bool.and_eq_true_iff.mp accepted).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at parts
  have shape : Metadata body.envelope r := _root_.of_decide_eq_true (by grind only)
  have fc : checkFunctions matrix body.tokens r.firstFunction r.functions 0 r.functionStart o z = true := by grind only
  have one : E values o = ((true.toNat : Nat) : F) := by simp [o,eval_constant values oneValue]
  obtain ⟨flags,images,ordered,totalImage⟩ := rows matrix body.tokens r.firstFunction r.functions 0 r.functionStart o z fc values oneValue satisfied true one
  have close : MemoryEvidence.checkSpan matrix r.functionCloseStart r.functionCloseEnd
      [eqGate (functionFinal r.functions r.functionStart z).2 r.functionCount,eqGate (functionFinal r.functions r.functionStart z).1 r.functionEnd] = true := by grind only
  have finalImage := equality_sound values oneValue (functionFinal r.functions r.functionStart z).2 r.functionCount
    (MemoryEvidence.span_sound matrix _ _ _ close values satisfied _ (by simp))
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have resultImage : E values r.functionCount = (count flags : F) := by rw [← finalImage,totalImage,zero]; grind
  have len := related_length _ _ _ images
  have cb := count_bound flags
  refine ⟨count flags,by have rb := shape.2.2.2.1; omega,resultImage,by omega,?_⟩
  intro index ib
  have ri : index < r.functions.length := by omega
  have rowImage := related_at (Represents values) r.functions flags images index ri
  change E values (r.functions.getD index default).active = ((flags.getD index false).toNat : F) at rowImage
  refine ⟨?_,?_⟩
  · rw [← List.getElem_eq_getD default]; exact List.getElem_mem ri
  · rw [active_at flags ordered index ib,Bool.toNat_true,Semiring.natCast_one] at rowImage
    exact rowImage

#print axioms rows
#print axioms checked_functions
end ZkBuild.DeclarationFunctionCoverage
