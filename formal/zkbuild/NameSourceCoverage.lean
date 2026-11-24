import NameSourceLineage
set_option autoImplicit false
namespace ZkBuild.NameSourceCoverage
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules NameSourceShared NameSourceFlatFacts NameSourceLineage ShaProgram OwnedRules
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem checked_rows {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (ownChecks : owned.all (OwnedMatrix.check matrix tables splits) = true)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = true) (frameCheck : NameFrameMatrix.check matrix tokens tables imports owned frame = true)
    (graph : NameGraphMatrix.Record) (graphCheck : NameGraphMatrix.check matrix tables graph = true)
    (source : NameSourceMatrix.Record) (sourceCheck : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ ps : List ParentValue, ∃ ds : List ChildValue,
      Related (ParentImage values) (NameFrameMatrix.stream owned frame).parents ps ∧ (∀ p ∈ ps, ParentBound p) ∧
      Related (Certified values (NameGraphMatrix.table tables graph 0) matrix tokens) (frame.bytes.zip source.bytes) ds ∧
      (∀ d ∈ ds, ChildBound d) ∧ (∀ d ∈ ds, OwnedUnit.Position ps d) ∧
      BinaryDeclarations.vectorKeys 0 (ps.map ParentValue.count) ⊆ OwnedComplete.keys ds := by
  have fp := NameFrameFlat.parts matrix tokens tables imports owned frame frameCheck flat
  have streamMember : NameFrameMatrix.stream owned frame ∈ owned := by
    unfold NameFrameMatrix.stream
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem fp.2.2.1
  have oc := List.all_eq_true.mp ownChecks _ streamMember
  obtain ⟨ps,ds,pi,di,pb,db,_,_,_,_,complete⟩ := OwnedComplete.checked_complete matrix tables tableChecks splits _ oc values oneValue satisfied
  have cc : OwnedMatrix.checkChildren matrix splits (NameFrameMatrix.stream owned frame).children none = true := by
    simp only [OwnedMatrix.check,Bool.and_eq_true_iff] at oc
    grind only
  have sc : checkBytes matrix tokens true frame.bytes source.bytes 0 z z = true := by
    have checked := sourceCheck
    simp only [NameSourceMatrix.check,Bool.and_eq_true_iff] at checked
    simpa only [flat] using checked.1.2
  have certified := rows matrix tokens tables tableChecks frame flat graph source sourceCheck graphCheck splits values oneValue satisfied
    _ ds di db frame.bytes source.bytes fp.2.2.2.2 (by simp) 0 z z none cc sc rfl
  have positions := OwnedUnit.checked_positions matrix tables tableChecks splits splitChecks _ oc values oneValue satisfied ps pi pb ds di db
    (NameFrameFlat.unit_width matrix tokens tokenChecks tables imports owned frame frameCheck flat values oneValue satisfied)
  exact ⟨ps,ds,pi,pb,certified,db,positions,complete⟩

theorem count_bank (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = true) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (checked : NameSourceMatrix.check matrix tokens tables frame graph source = true) :
    ReadOnlyMatrix.check matrix (NameSourceMatrix.table tables source 0) = true ∧
      (NameSourceMatrix.table tables source 0).entries = frame.headers.zipIdx.map (fun (f,i) => countEntry f i) ∧
      (NameSourceMatrix.table tables source 0).queries = source.ends.map Ending.countQuery := by
  have facts := metadata matrix tokens tables frame graph source checked
  have size : source.tables.length = 3 := by have t := facts.2.2.2.1; simpa [flat] using t
  have im : source.tables.getD 0 0 ∈ source.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem (by omega)
  have member : NameSourceMatrix.table tables source 0 ∈ tables := by
    unfold NameSourceMatrix.table
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (facts.2.2.2.2.1 _ im)
  have data := facts.2.2.2.2.2.2.2.2
  simp only [flat,↓reduceIte] at data
  exact ⟨List.all_eq_true.mp tableChecks _ member,data.1,data.2.1⟩

theorem root_query_at {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = true) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (checked : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (f : NameFrameMatrix.Header) (h : Header) (i : Nat) (entryMember : ((f,h),i) ∈ (frame.headers.zip source.headers).zipIdx)
    (enabled : E values (NameFrameMatrix.hget f 0) = 1) (b : ByteRow) (bm : b ∈ source.bytes)
    (qa : E values b.rootQuery.active = 1) (qi : E values b.rootQuery.address = (i : F)) :
    E values b.rootQuery.value = E values h.head := by
  obtain ⟨tc,entries,queries⟩ := root_bank matrix tokens tables tableChecks frame flat graph source checked
  have em : rootEntry f h i ∈ (NameSourceMatrix.table tables source 2).entries := by rw [entries]; exact List.mem_map.mpr ⟨((f,h),i),entryMember,rfl⟩
  have qm : b.rootQuery ∈ (NameSourceMatrix.table tables source 2).queries := by rw [queries]; exact List.mem_map.mpr ⟨b,bm,rfl⟩
  have ea : E values (rootEntry f h i).active = 1 := enabled
  have ek : E values (rootEntry f h i).address = E values b.rootQuery.address := by
    change E values (scale (NameFrameMatrix.hget f 0) (Int.ofNat i)) = _
    have scaled := eval_scale values (NameFrameMatrix.hget f 0) (Int.ofNat i)
    change E values (scale _ _) = ((Int.ofNat i : Int) : F)*E values (NameFrameMatrix.hget f 0) at scaled
    rw [scaled,enabled,qi,Semiring.mul_one]
    exact Ring.intCast_natCast _
  exact ReadOnlySound.checked_expected matrix _ tc values oneValue satisfied b.rootQuery (rootEntry f h i) qm em qa ea ek

theorem count_query_at {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = true) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (checked : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (f : NameFrameMatrix.Header) (i : Nat) (entryMember : (f,i) ∈ frame.headers.zipIdx)
    (enabled : E values (NameFrameMatrix.hget f 0) = 1) (e : Ending) (em : e ∈ source.ends)
    (qa : E values e.countQuery.active = 1) (qi : E values e.countQuery.address = (i : F)) :
    E values e.countQuery.value = E values (NameFrameMatrix.hget f 1) := by
  obtain ⟨tc,entries,queries⟩ := count_bank matrix tokens tables tableChecks frame flat graph source checked
  have entryMem : countEntry f i ∈ (NameSourceMatrix.table tables source 0).entries := by rw [entries]; exact List.mem_map.mpr ⟨(f,i),entryMember,rfl⟩
  have qm : e.countQuery ∈ (NameSourceMatrix.table tables source 0).queries := by rw [queries]; exact List.mem_map.mpr ⟨e,em,rfl⟩
  have ea : E values (countEntry f i).active = 1 := enabled
  have ek : E values (countEntry f i).address = E values e.countQuery.address := by
    change E values (scale (NameFrameMatrix.hget f 0) (Int.ofNat i)) = _
    have scaled := eval_scale values (NameFrameMatrix.hget f 0) (Int.ofNat i)
    change E values (scale _ _) = ((Int.ofNat i : Int) : F)*E values (NameFrameMatrix.hget f 0) at scaled
    rw [scaled,enabled,qi,Semiring.mul_one]
    exact Ring.intCast_natCast _
  exact ReadOnlySound.checked_expected matrix _ tc values oneValue satisfied e.countQuery (countEntry f i) qm entryMem qa ea ek

#print axioms checked_rows
#print axioms root_query_at
#print axioms count_query_at
end ZkBuild.NameSourceCoverage
