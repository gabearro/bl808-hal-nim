import NameSourceFlat
set_option autoImplicit false
namespace ZkBuild.NameSourceSoundness
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules NameSourceShared NameSourceSelect ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- Every active source name is exactly the valid UTF-8 graph string bound to
    its actual U32 header and byte span in the unique public-digest message. -/
theorem module_verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (checked : NameSourceSound.check matrix body tables splits declaration indexed signature space imports owned frame graph source = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      NameLists.Canonical (NameGraphTable.table values (NameGraphMatrix.table tables graph 0)) ∧
      ∀ i, i < frame.headers.length → E values (NameFrameMatrix.hget (frame.headers.getD i default) 0) = 1 →
        BoundName values (NameGraphMatrix.table tables graph 0) (frame.headers.getD i default) (source.headers.getD i default) message := by
  have checks := Bool.and_eq_true_iff.mp checked
  have gp := Bool.and_eq_true_iff.mp checks.1
  have fp := Bool.and_eq_true_iff.mp gp.1
  have op := Bool.and_eq_true_iff.mp fp.1
  have signatureCheck := (Bool.and_eq_true_iff.mp op.1).1
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureCheck).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).2
  have splitChecks := (Bool.and_eq_true_iff.mp moduleCheck).2
  have envelopeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelopeCheck).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  obtain ⟨message,meaning,d0,d1,unique,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  refine ⟨message,meaning,d0,d1,unique,NameGraphStrings.canonical matrix tables tableChecks graph gp.2 values oneValue satisfied,?_⟩
  intro i ib active
  cases flat : frame.flat with
  | true => exact NameSourceFlat.bound_names matrix body.tokens tokenChecks tables tableChecks splits splitChecks imports owned op.2 frame flat fp.2 graph gp.2 source checks.2 values oneValue satisfied message decoded i ib active
  | false =>
    have facts := metadata matrix body.tokens tables frame graph source checks.2
    have pair := (indexed_pair frame.headers source.headers facts.1.symm i ib).1
    have member := List.mem_zipIdx pair
    have plain : (frame.headers.getD i default,source.headers.getD i default) ∈ frame.headers.zip source.headers := by
      rw [member.2.2]
      exact List.getElem_mem _
    exact NameSourceHeaders.legacy_names matrix body.tokens tokenChecks tables tableChecks imports owned frame flat fp.2 graph gp.2 source checks.2 values oneValue satisfied message decoded _ _ plain

theorem equal_heads_iff {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (bank : ReadOnlyMatrix.Record)
    (canonical : NameLists.Canonical (NameGraphTable.table values bank))
    (a b : Linear) (xs ys : List Nat)
    (first : RepWire values bank a xs) (second : RepWire values bank b ys) :
    E values a = E values b ↔ xs = ys := by
  constructor
  · intro same; exact rep_unique values bank a b xs ys same first second
  · intro same
    obtain ⟨i,_,ii,ir⟩ := first
    obtain ⟨j,_,ji,jr⟩ := second
    have ids := NameLists.canonical_heads _ canonical i j xs ys ir jr same
    rw [ii,ji,ids]

/-- A name-span query selects a complete, correctly encoded source name,
    not merely an arbitrary pair of internally consistent offsets. -/
theorem query_bound_name {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (imports : ImportMatrix.Record)
    (owned : List OwnedMatrix.Record) (frame : NameFrameMatrix.Record) (source : NameSourceMatrix.Record)
    (frameCheck : NameFrameMatrix.check matrix tokens tables imports owned frame = true)
    (tableCheck : ReadOnlyMatrix.check matrix (ImportMatrix.table tables imports 0) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (graph : NameGraphMatrix.Record)
    (names : ∀ i, i < frame.headers.length → E values (NameFrameMatrix.hget (frame.headers.getD i default) 0) = 1 →
      BoundName values (NameGraphMatrix.table tables graph 0) (frame.headers.getD i default) (source.headers.getD i default) message)
    (q : Entry) (member : q ∈ (ImportMatrix.table tables imports 0).queries) (active : E values q.active = 1) :
    ∃ i, i < frame.headers.length ∧ BoundName values (NameGraphMatrix.table tables graph 0)
      (frame.headers.getD i default) (source.headers.getD i default) message ∧
      E values q.address = (i : F) ∧ E values q.value = E values (NameFrameMatrix.entry (frame.headers.getD i default) i).value := by
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp frameCheck).1).1
  obtain ⟨_,_,_,_,_,_,_,_,lookup⟩ := ReadOnlySound.checked_membership matrix _ tableCheck values oneValue satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := lookup q member active
  rw [links.2.1] at em
  obtain ⟨pair,pm,same⟩ := List.mem_map.mp em
  have index := List.mem_zipIdx pm
  have ib : pair.2 < frame.headers.length := by simpa using index.2.1
  have fEq : pair.1 = frame.headers.getD pair.2 default := by
    have h : pair.1 = frame.headers[pair.2] := by simpa only [Nat.sub_zero] using index.2.2
    exact h.trans (List.getElem_eq_getD default)
  have sameEntry : NameFrameMatrix.entry pair.1 pair.2 = entry := by cases pair; exact same
  have enabled : E values (NameFrameMatrix.hget (frame.headers.getD pair.2 default) 0) = 1 := by
    simpa only [← same,NameFrameMatrix.entry,fEq] using ea
  have addr : E values (NameFrameMatrix.entry (frame.headers.getD pair.2 default) pair.2).address = (pair.2 : F) := by
    change E values (scale (NameFrameMatrix.hget (frame.headers.getD pair.2 default) 0) (Int.ofNat pair.2)) = _
    have scaled := eval_scale values (NameFrameMatrix.hget (frame.headers.getD pair.2 default) 0) (Int.ofNat pair.2)
    change E values (scale _ _) = ((Int.ofNat pair.2 : Int) : F)*E values _ at scaled
    rw [scaled,enabled,Semiring.mul_one]
    exact Ring.intCast_natCast _
  exact ⟨pair.2,ib,names pair.2 ib enabled,by rw [← ek,← sameEntry,fEq]; exact addr,by rw [← ev,← sameEntry,fEq]⟩

#print axioms module_verified
#print axioms equal_heads_iff
#print axioms query_bound_name
end ZkBuild.NameSourceSoundness
