import NameSourceSoundness
import ImportRead
set_option autoImplicit false

namespace ZkBuild.NameSourceConsumers
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ImportMatrix NameSourceShared ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- Name length, UTF-8 value and complete source-span interpretation. Concrete
    U32 header syntax is certified separately in NameSourceSyntax. -/
def Encoded (message : List Sha256.Byte) (start finish : Nat) (bytes : List Nat) : Prop :=
  ∃ length, 0 < length ∧ length ≤ 5 ∧ finish = start+length+bytes.length ∧
    finish ≤ message.length ∧
    TokenInteger.decode 1 length (fun i => (message.getD (start+i) 0).toNat) = bytes.length ∧
    Utf8Suffix.Valid bytes ∧ Matches message (start+length) bytes

theorem complete_span (message : List Sha256.Byte) (start length : Nat) (bytes : List Nat)
    (header : start+length ≤ message.length) (matched : Matches message (start+length) bytes) :
    start+length+bytes.length ≤ message.length := by
  by_cases empty : bytes.length = 0
  · omega
  · have last := (matched (bytes.length-1) (by omega)).1
    omega

/-- The actual split and selection gates advance a name consumer over the
    complete UTF-8 string, including its U32 header. -/
theorem consume_name {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (source : NameSourceMatrix.Record) (graph : NameGraphMatrix.Record)
    (frameCheck : NameFrameMatrix.check matrix tokens tables imports owned frame = true)
    (tableCheck : ReadOnlyMatrix.check matrix (ImportMatrix.table tables imports 0) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte)
    (names : ∀ i, i < frame.headers.length → E values (NameFrameMatrix.hget (frame.headers.getD i default) 0) = 1 →
      BoundName values (NameGraphMatrix.table tables graph 0) (frame.headers.getD i default) (source.headers.getD i default) message)
    (use : NameUse) (enabled index cursor : Linear)
    (shape : nameMatches splits use enabled)
    (member : use.query ∈ (ImportMatrix.table tables imports 0).queries)
    (active : E values enabled = 1)
    (holds : AllHold values (nameGates splits use enabled index cursor)) :
    ∃ start finish bytes, start < 2^32 ∧ finish < 2^32 ∧ Encoded message start finish bytes ∧
      E values cursor = (start : F) ∧ E values use.cursor = (finish : F) := by
  have qa : E values use.query.active = 1 := by rw [shape.2.2]; exact active
  obtain ⟨i,_,bound,_,queryValue⟩ := NameSourceSoundness.query_bound_name matrix tokens tables imports owned frame source
    frameCheck tableCheck values oneValue satisfied message graph names use.query member qa
  obtain ⟨p,l,bytes,pb,positive,short,headerInside,endBound,pi,_,_,fi,decode,_,valid,matching⟩ := bound
  let f := frame.headers.getD i default
  have span : E values use.query.value = ((p+2^32*(p+l+bytes.length) : Nat) : F) := by
    rw [queryValue]
    change E values (NameFrameMatrix.hget f 2 ++ scale (NameFrameMatrix.hget f 4) (2^32)) = _
    have add : E values (NameFrameMatrix.hget f 2 ++ scale (NameFrameMatrix.hget f 4) (2^32)) =
        E values (NameFrameMatrix.hget f 2)+E values (scale (NameFrameMatrix.hget f 4) (2^32)) := eval_append values _ _
    have scaled := eval_scale values (NameFrameMatrix.hget f 4) (2^32)
    change E values (scale (NameFrameMatrix.hget f 4) (2^32)) = ((2^32 : Int) : F)*E values (NameFrameMatrix.hget f 4) at scaled
    rw [add,scaled,pi,fi]
    have radix : ((2^32 : Int) : F) = ((2^32 : Nat) : F) := Ring.intCast_natCast _
    rw [radix,← Semiring.natCast_mul,← Semiring.natCast_add]
  have sm : split splits use.heads ∈ splits := by
    rw [split,← List.getElem_eq_getD default]
    exact List.getElem_mem shape.1
  obtain ⟨n,lo,hi,nb,lb,hb,ni,li,hiI,packed,_,_⟩ := PackedFields.checked_split matrix _
    (List.all_eq_true.mp splitChecks _ sm) values oneValue satisfied
  have fields := shape.2.1
  unfold splitMatches at fields
  simp only [fields.2.1,fields.2.2] at nb lb hb packed
  have exactSpan : n = p+2^32*(p+l+bytes.length) := DeclarationLocations.natural_equal (F := F) _ _
    (by omega) (by omega) (ni.symm.trans (by rw [fields.1]; exact span))
  have same : lo = p ∧ hi = p+l+bytes.length :=
    DeclarationLocations.packed_unique _ _ _ _ lb pb (packed.symm.trans exactSpan)
  have low : E values (split splits use.heads).low = (p : F) := by simpa [same.1] using li
  have high : E values (split splits use.heads).high = ((p+l+bytes.length : Nat) : F) := by simpa [same.2] using hiI
  have startGate := holds (gate enabled (sub cursor (split splits use.heads).low)) (by simp [nameGates])
  change E values enabled*E values (sub cursor (split splits use.heads).low) = E values z at startGate
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  rw [active,eval_sub,low,zero] at startGate
  have finishGate := select_sound values enabled (split splits use.heads).high cursor use.cursor
    (holds _ (by simp [nameGates]))
  rw [active,high] at finishGate
  refine ⟨p,p+l+bytes.length,bytes,pb,endBound,⟨l,positive,short,rfl,complete_span message p l bytes headerInside matching,decode,valid,matching⟩,?_,?_⟩
  · grind
  · grind

/-- Both names of an import occupy consecutive complete encodings; the kind
    reader starts immediately after them. This applies to all four kinds. -/
theorem import_pair {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (source : NameSourceMatrix.Record) (graph : NameGraphMatrix.Record)
    (frameCheck : NameFrameMatrix.check matrix tokens tables imports owned frame = true)
    (tableCheck : ReadOnlyMatrix.check matrix (ImportMatrix.table tables imports 0) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte)
    (names : ∀ i, i < frame.headers.length → E values (NameFrameMatrix.hget (frame.headers.getD i default) 0) = 1 →
      BoundName values (NameGraphMatrix.table tables graph 0) (frame.headers.getD i default) (source.headers.getD i default) message)
    (row : Row) (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear)
    (checked : checkRow matrix tokens splits imports.exportCount row index cursor counts previous = true)
    (queries : ∀ name ∈ row.names, name.query ∈ (ImportMatrix.table tables imports 0).queries)
    (active : E values row.active = 1) :
    ∃ start middle finish first second, Encoded message start middle first ∧ Encoded message middle finish second ∧
      E values cursor = (start : F) ∧ E values (EnvelopeMatrix.token tokens (readAt row 0).token).position = (finish : F) := by
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).1
  have nameCount : row.names.length = 2 := by unfold ImportMatrix.shape at shape; grind only
  have firstShape : nameMatches splits (nameAt row 0) row.active := by unfold ImportMatrix.shape at shape; grind only
  have secondShape : nameMatches splits (nameAt row 1) row.active := by unfold ImportMatrix.shape at shape; grind only
  have kindShape : readMatches tokens (readAt row 0) 0 row.active (nameAt row 1).cursor := by unfold ImportMatrix.shape at shape; grind only
  have query (i : Nat) (inside : i < 2) : (nameAt row i).query ∈ (ImportMatrix.table tables imports 0).queries := by
    apply queries
    unfold nameAt
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (by omega)
  have all := ImportRules.row_holds matrix tokens splits imports.exportCount row index cursor counts previous checked values satisfied
  have firstHolds : AllHold values (nameGates splits (nameAt row 0) row.active (imports.exportCount++n (2*index)) cursor) := by
    simpa only [rowParts,List.getD_cons_zero,List.getD_cons_succ] using ImportRules.part_holds values tokens splits imports.exportCount row index cursor counts previous all 1 (by decide)
  have secondHolds : AllHold values (nameGates splits (nameAt row 1) row.active (imports.exportCount++n (2*index+1)) (nameAt row 0).cursor) := by
    simpa only [rowParts,List.getD_cons_zero,List.getD_cons_succ] using ImportRules.part_holds values tokens splits imports.exportCount row index cursor counts previous all 2 (by decide)
  obtain ⟨start,middle,first,_,middleBound,firstName,firstStart,firstEnd⟩ := consume_name matrix tokens tables splits splitChecks imports owned frame source graph frameCheck tableCheck values oneValue satisfied message names (nameAt row 0) row.active _ cursor firstShape (query 0 (by decide)) active firstHolds
  obtain ⟨next,finish,second,nextBound,_,secondName,secondStart,secondEnd⟩ := consume_name matrix tokens tables splits splitChecks imports owned frame source graph frameCheck tableCheck values oneValue satisfied message names (nameAt row 1) row.active _ (nameAt row 0).cursor secondShape (query 1 (by decide)) active secondHolds
  have same : middle = next := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega) (firstEnd.symm.trans secondStart)
  subst next
  exact ⟨start,middle,finish,first,second,firstName,secondName,firstStart,by rw [kindShape.2.2.2]; exact secondEnd⟩

/-- Public-digest composition for the actual import-name consumers. -/
theorem module_imports {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (checked : NameSourceSound.check matrix body tables splits declaration indexed signature space imports owned frame graph source = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      ∀ row ∈ imports.rows, E values row.active = 1 →
        ∃ start middle finish first second, Encoded message start middle first ∧ Encoded message middle finish second ∧
          E values (EnvelopeMatrix.token body.tokens (readAt row 0).token).position = (finish : F) := by
  obtain ⟨message,meaning,d0,d1,_,_,names⟩ := NameSourceSoundness.module_verified matrix body tables splits declaration indexed signature space imports owned frame graph source checked values oneValue satisfied
  have checks := Bool.and_eq_true_iff.mp checked
  have gp := Bool.and_eq_true_iff.mp checks.1
  have fp := Bool.and_eq_true_iff.mp gp.1
  have op := Bool.and_eq_true_iff.mp fp.1
  have ip := Bool.and_eq_true_iff.mp op.1
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp ip.1).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).2
  have splitChecks := (Bool.and_eq_true_iff.mp moduleCheck).2
  have ic := ip.2
  simp only [ImportMatrix.check,Bool.and_eq_true_iff] at ic
  have facts : imports.rows.length < 2^32 ∧ imports.importedFunctions = space.importedFunctions ∧ ImportMatrix.links tables signature imports := _root_.of_decide_eq_true (by grind only)
  have rowsCheck : checkRows matrix body.tokens splits imports.exportCount imports.rows 0 (get body.envelope.outputs 10) [z,z,z,z] o = true := by grind only
  have links := facts.2.2
  have bank : ImportMatrix.table tables imports 0 ∈ tables := by
    have b : 0 < imports.tables.length := by rw [links.1]; decide
    have m : imports.tables.getD 0 0 ∈ imports.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold ImportMatrix.table
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (links.2.1 _ m)
  have bankCheck := List.all_eq_true.mp tableChecks _ bank
  refine ⟨message,meaning,d0,d1,?_⟩
  intro row member active
  obtain ⟨index,cursor,counts,previous,rowCheck⟩ := ImportMembers.member_check matrix body.tokens splits imports.exportCount imports.rows 0 (get body.envelope.outputs 10) [z,z,z,z] o rowsCheck row member
  obtain ⟨start,middle,finish,first,second,a,b,_,position⟩ := import_pair matrix body.tokens tables splits splitChecks imports owned frame source graph fp.2 bankCheck values oneValue satisfied message names row index cursor counts previous rowCheck (links.2.2.2.1 row member).1 active
  exact ⟨start,middle,finish,first,second,a,b,position⟩

#print axioms complete_span
#print axioms consume_name
#print axioms import_pair
#print axioms module_imports
end ZkBuild.NameSourceConsumers
