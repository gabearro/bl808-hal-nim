import ControlSignatureSemanticSound
set_option autoImplicit false
namespace ZkBuild.ControlHeadTrace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

structure Heads (F : Type) where
  params : F
  results : F
  paramLength : F
  resultLength : F
def before {F : Type} [Field F] (values : Nat → F) (row : ControlTypeRowCheck.Record) : Heads F :=
  ⟨E values (f row.before 0),E values (f row.before 1),E values (f row.before 2),E values (f row.before 3)⟩
def after {F : Type} [Field F] (values : Nat → F) (row : ControlTypeRowCheck.Record) : Heads F :=
  ⟨E values (f row.after 7),E values (f row.after 8),E values (f row.after 11),E values (f row.after 12)⟩
def empty {F : Type} [Field F] : Heads F := ⟨0,0,0,0⟩
def held {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record) (i : Nat) :=
  after values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)

theorem unchanged {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (row : ControlTypeRowCheck.Record) (m : ControlTypeRowSound.Meaning values row)
    (reset : E values (ControlTypeRowCheck.reset row)=0) : after values row=before values row := by
  have p := m.select (ControlTypeRowCheck.reset row) (f row.after 6) (f row.before 0) 7 (by simp [ControlTypeRowCheck.selects])
  have r := m.select (ControlTypeRowCheck.reset row) (row.heads.high++row.singleton.value) (f row.before 1) 8 (by simp [ControlTypeRowCheck.selects])
  have pl := m.select (ControlTypeRowCheck.reset row) row.params.value (f row.before 2) 11 (by simp [ControlTypeRowCheck.selects])
  have rl := m.select (ControlTypeRowCheck.reset row) row.results.value (f row.before 3) 12 (by simp [ControlTypeRowCheck.selects])
  simp only [reset,Semiring.zero_mul,AddCommMonoid.add_zero] at p r pl rl
  simp only [after,before,Heads.mk.injEq]
  exact ⟨p,r,pl,rl⟩

theorem initial {F : Type} [Field F] (values : Nat → F) (one : values 0=1)
    (splits : Splits) (r : StructuredMatrix.Record) :
    before values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) 0)=empty := by
  simp [before,empty,ControlTypeRowCheck.record,f,DeclarationMatrix.get,z,eval_constant values one,Ring.intCast_zero]

theorem carry {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record) (i : Nat) :
    before values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) (i+1))=held values splits r i := by
  simp [before,held,after,ControlTypeRowCheck.record,f,DeclarationMatrix.get]

theorem reset_empty {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record) (splits : Splits)
    (r : StructuredMatrix.Record) (lookups : ControlLookupCheck.check matrix tables indexed r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length)
    (checked : ControlTypeRowCheck.check matrix (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (reset : E values (ControlTypeRowCheck.reset (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1)
    (lookup : E values (ControlTypeRowCheck.lookup (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=0) :
    held values splits r i=empty := by
  let row := ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i
  have m := ControlTypeRowSound.meaning matrix row checked values one satisfied
  have face := ControlTypeRowImages.interface matrix row checked values
  have ma := m.multiply (ControlTypeRowCheck.lookup row) (f row.frame 4++f row.frame 5) 1 (by simp [ControlTypeRowCheck.multiplies])
  have sa := m.multiply (ControlTypeRowCheck.lookup row) (f row.frame 7) 3 (by simp [ControlTypeRowCheck.multiplies])
  have metadataZero : E values (ControlLookupCheck.control r i 0).active=0 := by
    change E values row.metadata.active=0
    rw [face.metadataActive,ma,lookup]; exact Semiring.zero_mul _
  have singletonZero : E values (ControlLookupCheck.control r i 3).active=0 := by
    change E values row.singleton.active=0
    rw [face.singletonActive,sa,lookup]; exact Semiring.zero_mul _
  have mz := (ControlLookupSound.inactive matrix tables indexed r lookups values one satisfied i 0 ib (by decide) metadataZero).2
  have sz := (ControlLookupSound.inactive matrix tables indexed r lookups values one satisfied i 3 ib (by decide) singletonZero).2
  have pz := (ControlLookupSound.inactive matrix tables indexed r lookups values one satisfied i 1 ib (by decide) (face.paramsActive.trans lookup)).2
  have rz := (ControlLookupSound.inactive_direct matrix tables indexed r lookups values one satisfied i 4 ib (by simp) (face.resultsActive.trans lookup)).2
  have hz := ControlFrameMetadata.zero_heads matrix row checked values one satisfied mz
  change E values row.singleton.value=0 at sz
  change E values row.params.value=0 at pz
  change E values row.results.value=0 at rz
  have p := m.multiply (f row.frame 4) row.heads.low 6 (by simp [ControlTypeRowCheck.multiplies])
  have ph := m.select (ControlTypeRowCheck.reset row) (f row.after 6) (f row.before 0) 7 (by simp [ControlTypeRowCheck.selects])
  have rh := m.select (ControlTypeRowCheck.reset row) (row.heads.high++row.singleton.value) (f row.before 1) 8 (by simp [ControlTypeRowCheck.selects])
  have pl := m.select (ControlTypeRowCheck.reset row) row.params.value (f row.before 2) 11 (by simp [ControlTypeRowCheck.selects])
  have rl := m.select (ControlTypeRowCheck.reset row) row.results.value (f row.before 3) 12 (by simp [ControlTypeRowCheck.selects])
  simp only [reset,p,hz.1,hz.2,sz,pz,rz,eval_append] at ph rh pl rl
  change after values row=empty
  simp only [after,empty,Heads.mk.injEq]
  exact ⟨by grind only,by grind only,by grind only,by grind only⟩

def Origin {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) (i : Nat) : Prop :=
  held values splits r i=empty ∨ ∃ j, j≤i ∧
    ControlLookupMask.active (rows.getD j default).kind (ops.getD j 0)=true ∧
    held values splits r i=held values splits r j ∧
    ∀ k, j<k → k≤i → ControlTypeMasks.reset (rows.getD k default).kind=false

theorem origins {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record) (splits : Splits)
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (lookups : ControlLookupCheck.check matrix tables indexed r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : ∀ i, i<rows.length → Origin values splits r rows ops i := by
  have parts := checked
  simp only [ControlTypeCertificate.check,ControlTypeCertificate.linked,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have size : rows.length=(StructuredMatrix.stage r 4).rows.length := images.1.trans parts.2.1.1
  intro i
  induction i with
  | zero =>
    intro ib
    have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule 0 ib
    have masks := ControlTypeTrace.row_masks matrix splits events r checked values one satisfied rows ops images schedule 0 ib
    have m := ControlTypeRowSound.meaning matrix _ rc.1 values one satisfied
    have lm := ControlLookupMask.images values _ _ _ m masks.1 masks.2.2
    by_cases reset : ControlTypeMasks.reset (rows.getD 0 default).kind=true
    · by_cases active : ControlLookupMask.active (rows.getD 0 default).kind (ops.getD 0 0)=true
      · exact Or.inr ⟨0,by omega,active,rfl,by intro k h b; omega⟩
      · apply Or.inl
        exact reset_empty matrix tables indexed splits r lookups 0 (by omega) rc.1 values one satisfied
          (by simpa only [reset,flag,ite_true] using masks.2.1.reset)
          (by simpa only [active,flag,Bool.false_eq_true,ite_false] using lm.1)
    · apply Or.inl
      have same := unchanged values _ m (by simpa only [reset,flag,Bool.false_eq_true,ite_false] using masks.2.1.reset)
      exact same.trans (initial values one splits r)
  | succ i ih =>
    intro ib
    have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule (i+1) ib
    have masks := ControlTypeTrace.row_masks matrix splits events r checked values one satisfied rows ops images schedule (i+1) ib
    have m := ControlTypeRowSound.meaning matrix _ rc.1 values one satisfied
    have lm := ControlLookupMask.images values _ _ _ m masks.1 masks.2.2
    by_cases reset : ControlTypeMasks.reset (rows.getD (i+1) default).kind=true
    · by_cases active : ControlLookupMask.active (rows.getD (i+1) default).kind (ops.getD (i+1) 0)=true
      · exact Or.inr ⟨i+1,by omega,active,rfl,by intro k h b; omega⟩
      · apply Or.inl
        exact reset_empty matrix tables indexed splits r lookups (i+1) (by omega) rc.1 values one satisfied
          (by simpa only [reset,flag,ite_true] using masks.2.1.reset)
          (by simpa only [active,flag,Bool.false_eq_true,ite_false] using lm.1)
    · have same := (unchanged values _ m (by simpa only [reset,flag,Bool.false_eq_true,ite_false] using masks.2.1.reset)).trans (carry values splits r i)
      rcases ih (by omega) with zero | ⟨j,ji,active,previous,between⟩
      · exact Or.inl (same.trans zero)
      · refine Or.inr ⟨j,by omega,active,same.trans previous,?_⟩
        intro k jk ki
        by_cases last : k=i+1
        · subst k; exact Bool.eq_false_iff.mpr reset
        · exact between k jk (by omega)

#print axioms unchanged
#print axioms initial
#print axioms carry
#print axioms reset_empty
#print axioms origins
end ZkBuild.ControlHeadTrace
