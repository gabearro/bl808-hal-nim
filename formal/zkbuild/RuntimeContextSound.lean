import RuntimeContextAuditIO
set_option autoImplicit false
namespace ZkBuild.RuntimeContextSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix DynamicTypingMatrix RuntimeContextMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def StageFacts {F : Type} [Field F] (matrix : Shape) (tables : List ReadOnlyMatrix.Record)
    (r : RuntimeContextMatrix.Record) (values : Nat → F) (s : DynamicTypingMatrix.Stage) : Prop :=
  ∃ state, (RuntimeContextCheck.replay matrix tables r s).run (SourceProgram.init s.program) = .ok ((),state) ∧
    SourceProgram.finished s.program state ∧ BodySourceTheorems.StateMeaning matrix [] [] values state

theorem stage {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : RuntimeContextMatrix.Record) (s : DynamicTypingMatrix.Stage)
    (accepted : RuntimeContextCheck.checkStage matrix tables r s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    StageFacts matrix tables r values s := by
  unfold RuntimeContextCheck.checkStage at accepted
  cases h : (RuntimeContextCheck.replay matrix tables r s).run (SourceProgram.init s.program) with
  | error e => simp [h] at accepted
  | ok pair =>
    rcases pair with ⟨result,state⟩
    cases result
    rw [h] at accepted
    exact ⟨state,h,_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp accepted).1,
      SourceProgramSound.state matrix [] [] state (Bool.and_eq_true_iff.mp accepted).2 values one satisfied⟩

theorem checked {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : RuntimeContextMatrix.Record)
    (accepted : RuntimeContextCheck.check matrix body tables context instructions events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    (∀ s ∈ r.stages, StageFacts matrix tables r values s) ∧
    (∀ s ∈ r.stages, ∀ i ∈ s.banks, DynamicTypingSound.TableFacts values (tables.getD i default)) ∧
    (∀ item ∈ r.catalog, LookupEmbedded.check matrix item.2 = true) := by
  have parts := accepted
  simp only [RuntimeContextCheck.check,Bool.and_eq_true_iff] at parts
  refine ⟨?_,?_,List.all_eq_true.mp parts.2⟩
  · intro s member
    exact stage matrix tables r s (List.all_eq_true.mp parts.1.1.2 s member) values one satisfied
  · intro s member i bank
    exact DynamicTypingSound.table matrix _ (List.all_eq_true.mp (List.all_eq_true.mp parts.1.2 s member) i bank) values one satisfied

theorem catalog (records : InstructionDecodeMatrix.Catalog)
    (accepted : RuntimeContextMatrix.catalogCheck records = true)
    (id : Nat) (r : LookupEmbedded.Record) (member : (id,r) ∈ records) :
    r.columns = 7 ∧ LookupEmbedded.checkTable r 16 (fun code field => Int.ofNat ((InstructionMetadata.payload code).getD field 0)) = true := by
  cases shape : records with
  | nil => simp [shape] at member
  | cons first rest =>
    rcases first with ⟨firstId,first⟩
    have parts := accepted
    simp only [RuntimeContextMatrix.catalogCheck,shape,List.map_cons,List.head?_cons,Bool.and_eq_true_iff] at parts
    have rm : InstructionDecodeMatrix.tableView (id,r) ∈ (InstructionDecodeMatrix.tableView (firstId,first))::rest.map InstructionDecodeMatrix.tableView := by
      simpa [shape] using List.mem_map.mpr ⟨(id,r),member,rfl⟩
    have same : r.columns = first.columns ∧ r.root = first.root ∧ r.nodes = first.nodes :=
      _root_.of_decide_eq_true (List.all_eq_true.mp parts.2.2 (InstructionDecodeMatrix.tableView (id,r)) rm)
    have firstColumns : first.columns = 7 := by simpa [InstructionDecodeMatrix.tableView] using parts.2.1.1
    refine ⟨same.1.trans firstColumns,?_⟩
    have table := parts.2.1.2
    rw [RuntimeContextMatrix.canonicalTable_exact] at table
    unfold LookupEmbedded.checkTable
    rw [same.1,same.2.1,same.2.2]
    exact table

#print axioms stage
#print axioms checked
#print axioms catalog
end ZkBuild.RuntimeContextSound
