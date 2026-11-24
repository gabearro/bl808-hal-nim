import SegmentPayloadRules
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.SegmentPayloadSoundness
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix SegmentPayloadMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def ConstantMeaning {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (c : ConstantSourceMatrix.Record) (message : List Sha256.Byte) : Prop :=
  ConstantSourceTrace.Trace values tokens c message ∧ (E values (ConstantSourceMatrix.field c 0) = 1 →
    ConstantSourceSoundness.Modern values c message ∨ ConstantSourceSoundness.Legacy values c message)
def RowMeaning {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (cs : List ConstantSourceMatrix.Record)
    (kind : Nat) (r : Row) (start finish : Linear) (message : List Sha256.Byte) : Prop :=
  (E values (f r 0) = 0 ∨ E values (f r 0) = 1) ∧
  (∃ flags : Nat, flags < (if kind = 0 then 8 else 3) ∧ E values (f r 1) = (flags : F)) ∧
  (∀ i, i < SegmentPayloadRead.count kind → E values (SegmentPayloadRead.layout cs kind r start i).2.1 = 1 →
    ∃ p len, SegmentPayloadRead.Decoded values cs kind r start message i p len) ∧
  (∀ i, i < r.constants.length → ConstantMeaning values tokens (constAt cs r i) message) ∧
  (kind ≠ 0 → E values (f r 7) = E values (readAt r 2).cursor + E values (f r 6) ∧
    ∃ gap : Nat, gap < 2^32 ∧ E values finish = E values (f r 7)+(gap : F))
def Trace {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (cs : List ConstantSourceMatrix.Record)
    (flat : Bool) (kind : Nat) (finish : Linear) (message : List Sha256.Byte) : List Row → Linear → Prop
  | [],_ => True
  | r::rest,start => RowMeaning values tokens cs kind r start finish message ∧
      Trace values tokens cs flat kind finish message rest (if kind = 0 then elementEnd cs flat r else f r 7)
def CustomMeaning {F : Type} [Field F] [DecidableEq F] (values : Nat → F) (splits : Splits) (r : Row) (s : EnvelopeMatrix.Row) (message : List Sha256.Byte) : Prop :=
  E values (f r 0) = (if E values s.entry.id = 0 then E values s.entry.active else 0) ∧
  (E values (f r 0) = 1 → ∃ p q bytes, p < 2^32 ∧ q < 2^32 ∧ NameSourceConsumers.Encoded message p q bytes ∧
    E values s.entry.body = (p : F) ∧ E values (split splits r.heads).high = (q : F) ∧
    ∃ gap : Nat, gap < 2^32 ∧ E values s.entry.finish = ((q+gap : Nat) : F))

theorem trace_bits {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (cs : List ConstantSourceMatrix.Record)
    (flat : Bool) (kind : Nat) (finish : Linear) (message : List Sha256.Byte) (rows : List Row) (start : Linear)
    (trace : Trace values tokens cs flat kind finish message rows start) : ∀ r ∈ rows, E values (f r 0) = 0 ∨ E values (f r 0) = 1 := by
  induction rows generalizing start with
  | nil => simp
  | cons r rest ih =>
    intro x xm
    rcases List.mem_cons.mp xm with same | later
    · subst x; exact trace.1.1
    · exact ih _ trace.2 x later

/-- Source, reader, section-closure and owned-child composition. Type/index
    validity and instruction semantics remain separate certification layers. -/
theorem module_verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (cs : List ConstantSourceMatrix.Record) (scalar : ScalarPayloadMatrix.Record) (r : SegmentPayloadMatrix.Record)
    (checked : SegmentPayloadSound.check matrix body tables splits declaration indexed signature space imports owned frame graph source cs scalar r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ t ∈ body.tokens, t.kind = 1 → E values t.activeMode = 1 →
        ∃ p len, p < 2^32 ∧ p+len ≤ message.length ∧ E values t.position = (p : F) ∧ E values t.length = (len : F) ∧
          BinaryTokenSyntax.U32 len (fun j => (message.getD (p+j) 0).toNat)) ∧
      (∀ kind, kind < 4 → ScalarPayloadSoundness.Trace values body.tokens splits cs kind message (ScalarPayloadMatrix.getRows scalar kind) (ScalarPayloadMatrix.start body kind) ∧
        E values (ScalarPayloadMatrix.final cs kind (ScalarPayloadMatrix.getRows scalar kind) (ScalarPayloadMatrix.start body kind)) = E values (ScalarPayloadMatrix.finish body kind) ∧
        ∃ count : Nat, count ≤ (ScalarPayloadMatrix.getRows scalar kind).length ∧ count < 2^32 ∧ E values (ScalarPayloadMatrix.size body kind) = (count : F)) ∧
      Trace values body.tokens cs r.flat 0 (atEnd body 9) message r.elements (atStart body 9) ∧
      Trace values body.tokens cs r.flat 1 (atEnd body 11) message r.datas (atStart body 11) ∧
      Related (CustomMeaning values splits · · message) r.customs body.envelope.rows ∧
      E values (elementsEnd cs r.flat r.elements (atStart body 9)) = E values (atEnd body 9) ∧
      E values (datasEnd r.datas (atStart body 11)) = E values (atEnd body 11) ∧
      E values (atStart body 8) = E values (atEnd body 8) ∧ E values (atStart body 12) = E values (atEnd body 12) ∧
      (∃ ne nd : Nat, ne < 2^32 ∧ nd < 2^32 ∧ ne ≤ r.elements.length ∧ nd ≤ r.datas.length ∧
        E values (atCount body 9) = (ne : F) ∧ E values (atCount body 11) = (nd : F)) ∧
      (∀ item ∈ r.items, ConstantMeaning values body.tokens (constAt cs item 0) message) ∧
      (r.flat = true → OwnedSoundness.Coverage values (stream owned r) ∧
        (stream owned r).parents.map (fun p => p.fields.map (E values)) =
          r.elements.map (fun row => [f row 0,f row 10,f row 11,f row 12].map (E values)) ∧
        (stream owned r).children.map (fun c => c.fields.map (E values)) =
          r.items.map (fun row => (row.fields.take 5).map (E values))) := by
  have cp := Bool.and_eq_true_iff.mp checked
  have scp := Bool.and_eq_true_iff.mp cp.1
  have constants := Bool.and_eq_true_iff.mp scp.1
  have nameCheck := constants.1
  have gp := Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp nameCheck).1
  have fp := Bool.and_eq_true_iff.mp gp.1
  have op := Bool.and_eq_true_iff.mp fp.1
  have ip := Bool.and_eq_true_iff.mp op.1
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp ip.1).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).2
  have splitChecks := (Bool.and_eq_true_iff.mp moduleCheck).2
  have envelopeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelopeCheck).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  have checks : links body tables owned imports frame r ∧
      checkElements matrix body.tokens splits cs r.flat r.elements (atStart body 9) = true ∧
      r.items.all (checkItem matrix body.tokens splits cs) = true ∧
      checkDatas matrix body.tokens splits cs (atEnd body 11) r.datas (atStart body 11) = true ∧
      checkCustoms matrix splits (imports.exportCount ++ scale (ImportMatrix.total imports.rows) 2) r.customs body.envelope.rows z = true ∧
      (List.range 3).all (fun i => MemoryEvidence.checkSpan matrix (r.closeStarts.getD i 0) (r.closeEnds.getD i 0) (closeGates body cs r i)) = true ∧
      (if r.flat then checkRange matrix (rangeAt r.tail 0) (sub (f r.tail 0) (customTotal r.customs)) 32 else true) = true ∧
      MemoryEvidence.checkSpan matrix r.tail.firstGate r.tail.lastGate (tailGates imports frame scalar r) = true := by
    simpa only [SegmentPayloadMatrix.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using cp.2
  obtain ⟨_,elementBound,dataBound,_,_,_,_,queryLinks,flatLinks⟩ := checks.1
  obtain ⟨message,meaning,d0,d1,unique,_,names⟩ := NameSourceSoundness.module_verified matrix body tables splits declaration indexed signature space imports owned frame graph source nameCheck values oneValue satisfied
  obtain ⟨other,otherMeaning,_,_,_,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have equal := unique other otherMeaning
  subst other
  obtain ⟨scalarMessage,scalarMeaning,_,_,grammar,scalars⟩ := ScalarPayloadSoundness.module_verified matrix body tables splits declaration indexed signature space imports owned frame graph source cs scalar cp.1 values oneValue satisfied
  have scalarSame := unique scalarMessage scalarMeaning
  subst scalarMessage
  have constantMeaning (c : ConstantSourceMatrix.Record) (member : c ∈ cs) : ConstantMeaning values body.tokens c message := by
    have cc := List.all_eq_true.mp constants.2 c member
    exact ⟨ConstantSourceTrace.checked_trace matrix body.tokens splits c cc values oneValue satisfied message decoded,
      fun active => (ConstantSourceSoundness.active_constant matrix body.tokens tokenChecks splits splitChecks c cc values oneValue satisfied message decoded active).2.2⟩
  have rowMeaning (kind : Nat) (row : Row) (start finish : Linear)
      (rc : SegmentPayloadRead.rowCheck matrix body.tokens splits cs r.flat kind row start finish = true) :
      RowMeaning values body.tokens cs kind row start finish message := by
    refine ⟨SegmentPayloadRead.active_boolean matrix body.tokens tokenChecks splits cs r.flat kind row start finish rc values oneValue satisfied,
      SegmentPayloadRead.flags matrix body.tokens splits cs r.flat kind row start finish rc values oneValue satisfied,
      fun i ib enabled => SegmentPayloadRead.active_read matrix body.tokens tokenChecks splits cs r.flat kind row start finish rc values oneValue satisfied message decoded i ib enabled,
      fun i ib => constantMeaning _ (SegmentPayloadConstants.row_constant matrix body.tokens splits cs r.flat kind row start finish rc i ib),?_⟩
    intro k
    exact SegmentPayloadSpans.data_span matrix body.tokens splits cs row start finish (by simpa only [SegmentPayloadRead.rowCheck,k,ite_false] using rc) values oneValue satisfied
  have elementWalk (rows : List Row) (start : Linear)
      (rc : checkElements matrix body.tokens splits cs r.flat rows start = true) : Trace values body.tokens cs r.flat 0 (atEnd body 9) message rows start := by
    induction rows generalizing start with
    | nil => trivial
    | cons row rest ih =>
      have p := Bool.and_eq_true_iff.mp rc
      exact ⟨rowMeaning 0 row start _ p.1,ih _ p.2⟩
  have dataWalk (rows : List Row) (start : Linear)
      (rc : checkDatas matrix body.tokens splits cs (atEnd body 11) rows start = true) : Trace values body.tokens cs r.flat 1 (atEnd body 11) message rows start := by
    induction rows generalizing start with
    | nil => trivial
    | cons row rest ih =>
      have p := Bool.and_eq_true_iff.mp rc
      exact ⟨rowMeaning 1 row start _ p.1,ih _ p.2⟩
  have et := elementWalk _ _ checks.2.1
  have dt := dataWalk _ _ checks.2.2.2.1
  have closed (i : Nat) (ib : i < 3) : AllHold values (closeGates body cs r i) :=
    MemoryEvidence.span_sound matrix _ _ _ (List.all_eq_true.mp checks.2.2.2.2.2.1 i (List.mem_range.mpr ib)) values satisfied
  have ec := equality_sound values oneValue (elementsEnd cs r.flat r.elements (atStart body 9)) (atEnd body 9) (closed 0 (by decide) _ (by simp [closeGates]))
  have dc := equality_sound values oneValue (datasEnd r.datas (atStart body 11)) (atEnd body 11) (closed 1 (by decide) _ (by simp [closeGates]))
  have en := equality_sound values oneValue (sumActive r.elements) (atCount body 9) (closed 0 (by decide) _ (by simp [closeGates]))
  have dn := equality_sound values oneValue (sumActive r.datas) (atCount body 11) (closed 1 (by decide) _ (by simp [closeGates]))
  obtain ⟨ne,neb,nei⟩ := SegmentPayloadRules.bounded_count values oneValue r.elements (trace_bits values body.tokens cs r.flat 0 _ message _ _ et)
  obtain ⟨nd,ndb,ndi⟩ := SegmentPayloadRules.bounded_count values oneValue r.datas (trace_bits values body.tokens cs r.flat 1 _ message _ _ dt)
  have il : ImportMatrix.links tables signature imports := by
    have h := ip.2
    simp only [ImportMatrix.check,Bool.and_eq_true_iff] at h
    have facts : imports.rows.length < 2^32 ∧ imports.importedFunctions = space.importedFunctions ∧ ImportMatrix.links tables signature imports := _root_.of_decide_eq_true (by grind only)
    exact facts.2.2
  have bank : ImportMatrix.table tables imports 0 ∈ tables := by
    have b : 0 < imports.tables.length := by rw [il.1]; decide
    have m : imports.tables.getD 0 0 ∈ imports.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold ImportMatrix.table
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (il.2.1 _ m)
  have customWalk (rows : List Row) (ss : List EnvelopeMatrix.Row) (previous : Linear)
      (members : ∀ row ∈ rows, row ∈ r.customs)
      (rc : checkCustoms matrix splits (imports.exportCount ++ scale (ImportMatrix.total imports.rows) 2) rows ss previous = true) :
      Related (CustomMeaning values splits · · message) rows ss := by
    induction rows generalizing ss previous with
    | nil => cases ss with
      | nil => exact Related.nil
      | cons s ss => simp [checkCustoms] at rc
    | cons row rest ih => cases ss with
      | nil => simp [checkCustoms] at rc
      | cons sec secs =>
        have cc := Bool.and_eq_true_iff.mp rc
        have all := MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp cc.1).2 values satisfied
        have zs := zero_sound values oneValue sec.entry.id (zero row 0) (wire (row.zeros.getD 0 0+1)) (by intro g gm; exact all g (by simp only [customGates,zeroG,List.mem_append]; grind only))
        have prod := multiply_sound values sec.entry.active (zero row 0) (f row 0) (all _ (by simp [customGates]))
        have selected : E values (f row 0) = (if E values sec.entry.id = 0 then E values sec.entry.active else 0) := by rw [prod,zs]; split <;> grind
        refine Related.cons ⟨selected,?_⟩ (ih secs (f row 2) (by intro x xm; exact members x (by simp [xm])) cc.2)
        intro active
        exact SegmentPayloadSpans.custom_name matrix body.tokens tables splits splitChecks imports owned frame source graph fp.2
          (List.all_eq_true.mp tableChecks _ bank) row sec _ previous cc.1
          (_root_.of_decide_eq_true (List.all_eq_true.mp queryLinks row (members row (by simp)))) values oneValue satisfied message names active
  refine ⟨message,meaning,d0,d1,grammar,scalars,et,dt,customWalk _ _ z (by intro x xm; exact xm) checks.2.2.2.2.1,ec,dc,
    equality_sound values oneValue (atStart body 8) (atEnd body 8) (closed 2 (by decide) _ (by simp [closeGates])),
    equality_sound values oneValue (atStart body 12) (atEnd body 12) (closed 2 (by decide) _ (by simp [closeGates])),
    ⟨ne,nd,by omega,by omega,neb,ndb,en.symm.trans nei,dn.symm.trans ndi⟩,?_,?_⟩
  · intro item member
    exact constantMeaning _ (SegmentPayloadConstants.item_constant matrix body.tokens splits cs item (List.all_eq_true.mp checks.2.2.1 item member))
  · intro flat
    simp only [flat,ite_true] at flatLinks
    obtain ⟨positive,bound,_,_,parents,children,_⟩ := flatLinks
    have sm : stream owned r ∈ owned := by
      unfold stream
      rw [← List.getElem_eq_getD default]
      exact List.getElem_mem (by omega)
    refine ⟨OwnedComplete.checked_complete matrix tables tableChecks splits _ (List.all_eq_true.mp op.2 _ sm) values oneValue satisfied,?_,?_⟩
    · have same : ((stream owned r).parents.map OwnedMatrix.Parent.fields).map (List.map normalizeLinear) =
          (r.elements.map (fun row => [f row 0,f row 10,f row 11,f row 12])).map (List.map normalizeLinear) := by
        simpa only [List.map_map,Function.comp_def] using parents
      simpa only [List.map_map,Function.comp_def] using SegmentPayloadRules.normalized_fields values _ _ same
    · have same : ((stream owned r).children.map OwnedMatrix.Child.fields).map (List.map normalizeLinear) =
          (r.items.map (fun row => row.fields.take 5)).map (List.map normalizeLinear) := by
        simpa only [List.map_map,Function.comp_def] using children
      simpa only [List.map_map,Function.comp_def] using SegmentPayloadRules.normalized_fields values _ _ same

#print axioms module_verified
end ZkBuild.SegmentPayloadSoundness
