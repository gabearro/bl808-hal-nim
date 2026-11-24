import InstructionTraceSound
import StaticEventSpec
import RuntimeContextSource
set_option autoImplicit false
namespace ZkBuild.InstructionSemanticSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def canonical (r : ValidationEventMatrix.Record) : Bool :=
  decide ((ValidationEventCheck.stage r 3).rows.length = r.rows.length) &&
  (List.range r.rows.length).all (fun i => decide (ModuleProgram.sameInputs
    (rowAt (ValidationEventCheck.stage r 3).rows i) ((rowAt r.rows i).take 10)))

def check (matrix : Shape) (statics : StaticCatalog) (r : ValidationEventMatrix.Record) : Bool :=
  InstructionCertificate.check matrix statics r && canonical r

theorem canonical_field {F : Type} [Field F] [IsCharP F scalarModulus]
    (r : ValidationEventMatrix.Record) (accepted : canonical r = true) (values : Nat → F)
    (i : Nat) (ib : i < r.rows.length) (field : Nat) (fb : field < 10) :
    E values (f (rowAt (ValidationEventCheck.stage r 3).rows i) field) = E values (f (rowAt r.rows i) field) := by
  have same := _root_.of_decide_eq_true (List.all_eq_true.mp (Bool.and_eq_true_iff.mp accepted).2 i (List.mem_range.mpr ib))
  have evaluated := SourceProgramSound.normalized_inputs values _ _ same
  have zero : E values z = 0 := by simp [z,E,evalLinear,constant,interpretLinear,R1CS.eval,Ring.intCast_zero,Semiring.zero_mul,AddCommMonoid.zero_add]
  have point := congrArg (fun xs : List F => xs.getD field 0) evaluated
  rw [← zero,TokenInteger.map_getD,TokenInteger.map_getD] at point
  simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take,fb] using point

theorem rule_member (matrix : Shape) (statics : StaticCatalog) (s : Stage)
    (accepted : InstructionRowCheck.checkStage matrix statics s = true) (i : Nat) (ib : i < s.rows.length) :
    ∃ id : Nat, (id,(InstructionCertificate.record statics s i).rule) ∈ statics := by
  have row := List.all_eq_true.mp (Bool.and_eq_true_iff.mp accepted).2 i (List.mem_range.mpr ib)
  cases found : statics.find? (fun pair => pair.1 == (s.program.blocks.getD i default).index) with
  | none =>
    simp only [List.getD] at found
    simp [InstructionRowCheck.rule,List.getD,found] at row
  | some pair =>
    rcases pair with ⟨id,rule⟩
    have member := List.mem_of_find?_eq_some found
    simp only [List.getD] at found
    refine ⟨id,?_⟩
    simpa [InstructionCertificate.record,InstructionRowCheck.record,InstructionRowCheck.rule,found] using member

structure Schedule {F : Type} [Field F] (values : Nat → F) (r : ValidationEventMatrix.Record)
    (rows : List OperandEvents.Row) (ops : List Nat) : Prop where
  length : rows.length = r.rows.length
  opLength : ops.length = rows.length
  closed : (InstructionTraceSound.state rows ops rows.length).opened = false
  opcode : ∀ i, i < rows.length → ops.getD i 0 < 2^16 ∧
    E values (f (rowAt r.rows i) 8) = (ops.getD i 0 : F) ∧ OpcodeCatalog.admitted (ops.getD i 0) = true
  modes : ∀ i, i < rows.length → InstructionSchedule.allowed (InstructionTraceSound.state rows ops i).opened
    (InstructionTraceSound.pending rows i) (rows.getD i default).kind = true
  binding : ∀ i, i < rows.length → ∃ pc : Nat, pc < 2^32 ∧ E values (f (rowAt r.rows i) 9) = (pc : F) ∧
    InstructionSchedule.BindingSpec (InstructionTraceSound.state rows ops i).pc (InstructionTraceSound.state rows ops i).opcode
      pc (ops.getD i 0) (rows.getD i default).kind
  labels : ∀ i, i < rows.length → (rows.getD i default).kind = .labelCheck → ops.getD i 0 = 14 ∨ ops.getD i 0 = 31
  counts : ∀ i, i ≤ rows.length →
    (InstructionTraceSound.state rows ops i).counts.pops ≤ i ∧
    (InstructionTraceSound.state rows ops i).counts.pushes ≤ i ∧
    (InstructionTraceSound.state rows ops i).counts.clears ≤ i
  typing : ∀ i, i < rows.length → ∀ rule : StaticTyping.Rule, StaticTyping.signature (ops.getD i 0) = some rule →
    StaticEventSpec.Spec rule (rows.getD i default).kind (rows.getD i default).valueType
      (InstructionCounts.before (InstructionTraceSound.state rows ops i).counts (rows.getD i default).kind)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (admission : LookupCatalog)
    (instructions : InstructionStreamMatrix.Record) (r : ValidationEventMatrix.Record)
    (catalogs : ValidationEventAuditIO.catalogs statics admission = true)
    (events : ValidationEventCheck.check matrix statics admission instructions r = true)
    (accepted : check matrix statics r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (rows : List OperandEvents.Row) (ds : List Nat) (first : Nat) (ops : List Nat),
      OperandTraceSound.Represents values (ValidationEventCheck.stage r 1) rows ∧
      EventSemanticLifo.Trace rows ds first ∧ Schedule values r rows ops := by
  have ck := (Bool.and_eq_true_iff.mp accepted).1
  have canon := (Bool.and_eq_true_iff.mp accepted).2
  have stageCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp ck).1).2
  obtain ⟨rows,ops,images,size,opSize,opFacts,invariant,steps⟩ := InstructionTraceSound.trace matrix statics r ck values one satisfied
  obtain ⟨lifoRows,ds,first,lifoImages,lifo⟩ := EventSemanticLifo.sound matrix r
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp ck).1).1 values one satisfied
  have same := OperandRepresentationUnique.trace values _ lifoRows rows lifoImages images
  subst lifoRows
  obtain ⟨typedRows,typedImages,_,rowFacts⟩ := InstructionCertificate.rows matrix statics r ck values one satisfied
  have same := OperandRepresentationUnique.trace values _ typedRows rows typedImages images
  subst typedRows
  have length : rows.length = r.rows.length := size.trans (_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp canon).1)
  have opValid (i : Nat) (ib : i < rows.length) : ops.getD i 0 < 2^16 ∧
      E values (f (rowAt r.rows i) 8) = (ops.getD i 0 : F) ∧ OpcodeCatalog.admitted (ops.getD i 0) = true := by
    have oi := (opFacts i ib).2
    have cf := canonical_field r canon values i (by omega) 8 (by decide)
    obtain ⟨op,ob,field,allowed⟩ := ValidationEventSound.admitted_rows matrix statics admission instructions r catalogs events values one satisfied i (by omega)
    have same : op = ops.getD i 0 := OperandEvents.natural_eq _ _ (by unfold OperandEvents.bound; omega)
      (by have := (opFacts i ib).1; unfold OperandEvents.bound; omega) (field.symm.trans (cf.symm.trans oi))
    exact ⟨(opFacts i ib).1,cf.symm.trans oi,by simpa only [same] using allowed⟩
  refine ⟨rows,ds,first,ops,images,lifo,?_⟩
  constructor
  · exact length
  · exact opSize
  · exact InstructionTraceSound.closed matrix statics _ stageCheck values one satisfied _
      (by rw [← size]; exact (invariant rows.length (by omega)).1)
  · exact opValid
  · intro i ib; exact (steps i ib).1
  · intro i ib
    obtain ⟨pc,pb,pi,spec⟩ := (steps i ib).2
    exact ⟨pc,pb,(canonical_field r canon values i (by omega) 9 (by decide)).symm.trans pi,spec⟩
  · intro i ib
    exact InstructionRowSound.label matrix _ (rowFacts i ib).1 values one satisfied _ (rowFacts i ib).2.1
      _ (opFacts i ib).1 (opFacts i ib).2
  · intro i ib; exact (invariant i ib).2.2.2
  · intro i ib rule signature
    let record := InstructionCertificate.record statics (ValidationEventCheck.stage r 3) i
    have rc := rowFacts i ib
    obtain ⟨id,member⟩ := rule_member matrix statics _ stageCheck i (by omega)
    have ruleChecked := (ValidationEventSound.checked matrix statics admission instructions r events values one satisfied).2.2.2.1 (id,record.rule) member
    have table := ValidationEventSound.static_table statics admission catalogs id record.rule member
    obtain ⟨index,actual,ruleImage,actualImage⟩ := InstructionStaticSound.lookup matrix record rc.1 ruleChecked table values one satisfied
      _ (opValid i ib).1 (opValid i ib).2.2 (opFacts i ib).2 rule signature
    have actualSame : actual = (rows.getD i default).valueType := by
      apply Fin.ext
      exact OperandEvents.natural_eq _ _ (by have := actual.isLt; unfold OperandEvents.bound; omega)
        (by have := (rows.getD i default).valueType.isLt; unfold OperandEvents.bound; omega) (actualImage.symm.trans rc.2.2)
    subst actual
    have prior := (invariant i (by omega)).1
    have countImages := InstructionCounts.sound matrix record rc.1 values one satisfied _ rc.2.1
      (InstructionTraceSound.state rows ops i).counts prior.2.2.2.1 prior.2.2.2.2.1 prior.2.2.2.2.2
    have gates := InstructionStaticSound.gates matrix record rc.1 values one satisfied _ rc.2.1 rule index _ ruleImage rc.2.2
      _ countImages.1 countImages.2.1 countImages.2.2.1
    have stageLength : (ValidationEventCheck.stage r 3).rows.length < 2^64 := by
      have shape := stageCheck
      simp only [InstructionRowCheck.checkStage,Bool.and_eq_true_iff,decide_eq_true_eq] at shape
      exact shape.1.1.1.1.2
    have counts := (invariant i (by omega)).2.2.2
    have bounded : (InstructionCounts.before (InstructionTraceSound.state rows ops i).counts (rows.getD i default).kind).pops < NumericEvents.countBound ∧
        (InstructionCounts.before (InstructionTraceSound.state rows ops i).counts (rows.getD i default).kind).pushes < NumericEvents.countBound ∧
        (InstructionCounts.before (InstructionTraceSound.state rows ops i).counts (rows.getD i default).kind).clears < NumericEvents.countBound := by
      unfold InstructionCounts.before
      split <;> simp only [NumericEvents.countBound] <;> omega
    exact StaticEventSpec.sound (F := F) _ rule signature _ _ index _ bounded gates

#print axioms canonical_field
#print axioms rule_member
#print axioms sound
end ZkBuild.InstructionSemanticSound
