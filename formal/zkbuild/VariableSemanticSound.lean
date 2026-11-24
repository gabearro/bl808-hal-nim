import EnvironmentTraceSound
import VariableEventSpec
import EnvironmentAccessSound
set_option autoImplicit false
namespace ZkBuild.VariableSemanticSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Schedule {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record)
    (typing : DynamicTypingMatrix.Record) (rows : List OperandEvents.Row) (ops : List Nat) (tags : Nat → Fin 7) : Prop where
  environment : ∀ i, i < rows.length → ∃ mutable : Bool,
    E values (EnvironmentRowCheck.tag (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i)) = ((tags i).val : F) ∧
    E values (f (RangeUse.bits (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).packedRange) 3) = OperandEvents.flag mutable ∧
    E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).localQuery.value +
      E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).objectQuery.value =
        (VariableTyping.globalValue (tags i).val mutable : F)
  declared : ∀ i, i < rows.length → E values (VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i).declared =
    ((EnvironmentTraceSound.state rows tags (i+1)).val : F)
  selectors : ∀ i, i < rows.length → VariableSelectorFields.Images values
    (VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i) (ops.getD i 0)
  access : ∀ i, i < rows.length → (rows.getD i default).kind = .instructionBegin → ∃ mutable : Bool,
    EnvironmentAccessSound.Spec values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i)
      (ops.getD i 0) (tags i) mutable ∧
    E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).localQuery.value +
      E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).objectQuery.value =
        (VariableTyping.globalValue (tags i).val mutable : F)
  typing : ∀ i, i < rows.length → ∀ rule : StaticTyping.Rule,
    VariableTyping.signature (ops.getD i 0) (EnvironmentTraceSound.state rows tags (i+1)).val = some rule →
    VariableEventSpec.Spec rule (rows.getD i default).kind (rows.getD i default).valueType
      (InstructionCounts.before (InstructionTraceSound.state rows ops i).counts (rows.getD i default).kind)

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (statics : StaticCatalog) (events : ValidationEventMatrix.Record)
    (typing : DynamicTypingMatrix.Record) (accepted : VariableSemanticCheck.check matrix tables statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List OperandEvents.Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∃ tags : Nat → Fin 7, Schedule values tables typing rows ops tags := by
  have parts := accepted
  simp only [VariableSemanticCheck.check,Bool.and_eq_true_iff] at parts
  have links := parts.2
  simp only [VariableSemanticCheck.linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  obtain ⟨other,otherImages,size,rowFacts⟩ := VariableCertificate.rows matrix statics events typing parts.1.1.1 values one satisfied
  have same := OperandRepresentationUnique.trace values _ other rows otherImages images
  subst other
  have rowLinks (i : Nat) (ib : i < rows.length) := List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega))
  have envFacts (i : Nat) (ib : i < rows.length) :
      EnvironmentRowCheck.check matrix (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i) = true ∧
      EnvironmentRowSound.Tags values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i) (rows.getD i default).kind := by
    refine ⟨List.all_eq_true.mp (Bool.and_eq_true_iff.mp parts.1.2).2 i (List.mem_range.mpr (by omega)),?_⟩
    have linked := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (rowLinks i ib)).2
    intro j
    have eq := VariableSelectorCheck.point values _ _ linked.2.2.1 j
    exact eq.trans ((rowFacts i ib).2.1 j)
  obtain ⟨tags,packed,_,declared⟩ := EnvironmentTraceSound.trace matrix tables (DynamicTypingCheck.stage typing 1) rows values one satisfied envFacts
  have declaredImages (i : Nat) (ib : i < rows.length) :
      E values (VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i).declared = ((EnvironmentTraceSound.state rows tags (i+1)).val : F) := by
    have linked := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (rowLinks i ib)).2
    have eq := VariableSelectorCheck.point values _ _ linked.2.2.2.2 0
    change E values (f (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).after 11) =
      E values (VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i).declared at eq
    exact eq.symm.trans (declared i ib)
  have selectors (i : Nat) (ib : i < rows.length) : VariableSelectorFields.Images values
      (VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i) (ops.getD i 0) := by
    have linked := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (rowLinks i ib)).2
    have eq := VariableSelectorCheck.point values _ _ linked.1 8
    have opImage : E values (f (VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i).row 8) = (ops.getD i 0 : F) := by
      have field : E values (f (VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i).row 8) = E values (f (rowAt events.rows i) 8) := by
        simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take] using eq
      exact field.trans (schedule.opcode i ib).2.1
    exact VariableSelectorCheck.images matrix _ _ i parts.1.1.2 (Bool.and_eq_true_iff.mp (rowLinks i ib)).1
      (by omega) values one satisfied _ (schedule.opcode i ib).1 opImage
  have access (i : Nat) (ib : i < rows.length) (kind : (rows.getD i default).kind = .instructionBegin) : ∃ mutable : Bool,
      EnvironmentAccessSound.Spec values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i)
        (ops.getD i 0) (tags i) mutable ∧
      E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).localQuery.value +
        E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).objectQuery.value =
          (VariableTyping.globalValue (tags i).val mutable : F) := by
    have linked := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (rowLinks i ib)).2
    have equal (j : Nat) := VariableSelectorCheck.point values _ _ linked.2.2.2.1 j
    have cats := VariableSelectorCheck.categories values _ _ i _ (Bool.and_eq_true_iff.mp (rowLinks i ib)).1 (selectors i ib)
    have envCats : VariableSelectorCheck.Categories values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).selectors (ops.getD i 0) :=
      ⟨(equal 10).trans cats.1,(equal 11).trans cats.2.1,(equal 12).trans cats.2.2.1,(equal 13).trans cats.2.2.2⟩
    have setter := (equal 4).trans (selectors i ib 4 (by decide))
    simp only [DynamicSelectors.codes,List.getD_cons_zero,List.getD_cons_succ] at setter
    obtain ⟨mutable,tagImage,mutableImage,packedImage⟩ := packed i ib
    exact ⟨mutable,EnvironmentAccessSound.begin matrix _ (envFacts i ib).1 values one satisfied
      (by simpa only [kind] using (envFacts i ib).2) _ envCats setter _ mutable tagImage mutableImage,packedImage⟩
  refine ⟨tags,packed,declaredImages,selectors,access,?_⟩
  intro i ib rule signature
  let record := VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i
  have rc := rowFacts i ib
  have prior := VariableCountTrace.invariant matrix _ rows ops values one satisfied
    (fun j jb => ⟨(rowFacts j jb).1,(rowFacts j jb).2.1⟩) i (by omega)
  have countImages := VariableRowSound.counts matrix record rc.1 values one satisfied _ rc.2.1
    (InstructionTraceSound.state rows ops i).counts prior.1 prior.2
  have counts := schedule.counts i (by omega)
  have limit : (DynamicTypingCheck.stage typing 2).rows.length < 2^64 := by
    have ck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1.1.1).1).2
    simp only [VariableRowCheck.checkStage,Bool.and_eq_true_iff,decide_eq_true_eq] at ck
    exact ck.1.1.2
  have bounded : (InstructionCounts.before (InstructionTraceSound.state rows ops i).counts (rows.getD i default).kind).pops < NumericEvents.countBound ∧
      (InstructionCounts.before (InstructionTraceSound.state rows ops i).counts (rows.getD i default).kind).pushes < NumericEvents.countBound := by
    unfold InstructionCounts.before
    split <;> simp only [NumericEvents.countBound] <;> omega
  have categories := VariableSelectorCheck.categories values _ record i _ (Bool.and_eq_true_iff.mp (rowLinks i ib)).1 (selectors i ib)
  have supported := VariableEventSpec.supported _ _ rule signature
  have present : E values (f record.selectors 13) = 1 := by
    have yes : decide (VariableTyping.environment (ops.getD i 0) ≠ 0) = true := decide_eq_true supported
    exact categories.2.2.2.trans (by rw [yes]; rfl)
  have ruleImage := VariableRuleImageSound.rule_image matrix record rc.1 values one satisfied _ _ _ bounded.1
    rule signature (selectors i ib) present (declaredImages i ib) countImages.1
  have gates := VariableRowSound.gates matrix record rc.1 values one satisfied _ rc.2.1 rule _ _ _ ruleImage rc.2.2 countImages.1 countImages.2.1
  exact VariableEventSpec.sound (F := F) _ _ rule signature _ _ _ bounded gates

#print axioms trace
end ZkBuild.VariableSemanticSound
