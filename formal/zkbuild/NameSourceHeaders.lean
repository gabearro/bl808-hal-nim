import NameSourceLegacy
set_option autoImplicit false
namespace ZkBuild.NameSourceHeaders
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules NameSourceShared ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem frame_member (matrix : Shape) (tokens : Tokens) (bytes : List NameFrameMatrix.ByteRow)
    (headers : List NameFrameMatrix.Header) (index offset : Nat)
    (checked : NameFrameMatrix.legacyHeaders matrix tokens bytes headers index offset = true)
    (target : NameFrameMatrix.Header) (member : target ∈ headers) :
    NameFrameMatrix.checkHeader matrix tokens false target = true ∧ target.byteStart+target.byteCount ≤ bytes.length ∧
      ∃ i, NameFrameMatrix.legacyLink ((bytes.drop target.byteStart).take target.byteCount) i 0 (NameFrameMatrix.hget target 3) = true := by
  induction headers generalizing index offset with
  | nil => simp at member
  | cons f fs ih =>
    have c := checked
    simp only [NameFrameMatrix.legacyHeaders,Bool.and_eq_true_iff,decide_eq_true_eq] at c
    have fc : NameFrameMatrix.checkHeader matrix tokens false f = true := by grind only
    have bounds : f.byteStart = offset ∧ offset+f.byteCount ≤ bytes.length := by grind only
    have link : NameFrameMatrix.legacyLink ((bytes.drop offset).take f.byteCount) index 0 (NameFrameMatrix.hget f 3) = true := by grind only
    have tail : NameFrameMatrix.legacyHeaders matrix tokens bytes fs (index+1) (offset+f.byteCount) = true := by grind only
    rcases List.mem_cons.mp member with same | later
    · subst target
      exact ⟨fc,by omega,index,by rw [bounds.1]; exact link⟩
    · exact ih (index+1) (offset+f.byteCount) tail later

theorem source_member (matrix : Shape) (bytes : List ByteRow) (fs : List NameFrameMatrix.Header) (hs : List Header)
    (checked : checkLegacy matrix bytes fs hs = true) (f : NameFrameMatrix.Header) (h : Header)
    (member : (f,h) ∈ fs.zip hs) :
    f ∈ fs ∧ h ∈ hs ∧ legacyLink ((bytes.drop f.byteStart).take f.byteCount) h.head h.finalHead = true ∧
      MemoryEvidence.checkSpan matrix h.nilGate (h.nilGate+1) [eqGate h.finalHead z] = true := by
  induction fs generalizing hs with
  | nil => simp at member
  | cons first rest ih => cases hs with
    | nil => simp at member
    | cons head tail =>
      have c := checked
      simp only [checkLegacy,Bool.and_eq_true_iff] at c
      have link : legacyLink ((bytes.drop first.byteStart).take first.byteCount) head.head head.finalHead = true := by grind only
      have nilCheck : MemoryEvidence.checkSpan matrix head.nilGate (head.nilGate+1) [eqGate head.finalHead z] = true := by grind only
      have restCheck : checkLegacy matrix bytes rest tail = true := by grind only
      simp only [List.zip_cons_cons,List.mem_cons] at member
      rcases member with same | later
      · cases same
        exact ⟨by simp,by simp,link,nilCheck⟩
      · obtain ⟨fm,hm,link,nilCheck⟩ := ih tail restCheck later
        exact ⟨by simp [fm],by simp [hm],link,nilCheck⟩

/-- Legacy source names are precisely the valid graph strings, in byte order. -/
theorem legacy_names {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = false)
    (frameCheck : NameFrameMatrix.check matrix tokens tables imports owned frame = true)
    (graph : NameGraphMatrix.Record) (graphCheck : NameGraphMatrix.check matrix tables graph = true)
    (source : NameSourceMatrix.Record) (sourceCheck : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p length, BinaryTokenSound.Result values t message p length) :
    ∀ f h, (f,h) ∈ frame.headers.zip source.headers → BoundName values (NameGraphMatrix.table tables graph 0) f h message := by
  have fc := frameCheck
  have sc := sourceCheck
  simp only [NameFrameMatrix.check,flat,Bool.false_eq_true,↓reduceIte,Bool.and_eq_true_iff,decide_eq_true_eq] at fc
  simp only [NameSourceMatrix.check,flat,Bool.false_eq_true,↓reduceIte,Bool.and_eq_true_iff] at sc
  have frameByteChecks : frame.bytes.all (NameFrameMatrix.checkByte matrix tokens false) = true := by grind only
  have frameHeaderChecks : NameFrameMatrix.legacyHeaders matrix tokens frame.bytes frame.headers 0 0 = true := by grind only
  have sourceByteChecks : checkBytes matrix tokens false frame.bytes source.bytes 0 z z = true := by grind only
  have sourceHeaderChecks : checkLegacy matrix source.bytes frame.headers source.headers = true := by grind only
  have linked := legacy_bytes matrix tokens frame.bytes source.bytes sourceByteChecks frameByteChecks
  have facts := metadata matrix tokens tables frame graph source sourceCheck
  have bytesBound : frame.bytes.length < 2^32 := by
    unfold NameSourceMatrix.links at facts
    grind only
  intro f h member
  obtain ⟨fm,hm,sourceLink,nilCheck⟩ := source_member matrix source.bytes frame.headers source.headers sourceHeaderChecks f h member
  obtain ⟨headerCheck,inside,owner,frameLink⟩ := frame_member matrix tokens frame.bytes frame.headers 0 0 frameHeaderChecks f fm
  obtain ⟨bytes,rep,valid⟩ := root_rep matrix tokens tables tableChecks frame graph source sourceCheck graphCheck values oneValue satisfied h hm
  obtain ⟨p,l,count,finish,pb,cb,fb,positive,lb,headerInside,pi,bi,ci,fi,endEq,decode⟩ := NameFrameSource.legacy_headers matrix tokens tokenChecks tables imports owned frame frameCheck flat values oneValue satisfied message decoded f fm
  have shape := NameFrameRules.header_shape matrix tokens false f headerCheck
  have countField : NameFrameMatrix.hget f 1 = n f.byteCount := by simpa using shape.2.2.2.2.2.2.2.2
  have countImage : E values (NameFrameMatrix.hget f 1) = (f.byteCount : F) := by
    rw [countField,n,eval_constant values oneValue]
    exact Ring.intCast_natCast _
  have countEq : count = f.byteCount := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega) (ci.symm.trans countImage)
  have sliceChecks := related_take _ _ _ (related_drop _ _ _ linked f.byteStart) f.byteCount
  have sliceSize : ((frame.bytes.drop f.byteStart).take f.byteCount).length = f.byteCount := by simp; omega
  have nilEq := equality_sound values oneValue h.finalHead z (MemoryEvidence.span_sound matrix _ _ _ nilCheck values satisfied _ (by simp))
  have nilEnd : E values h.finalHead = 0 := by rw [nilEq,z,eval_constant values oneValue]; simp
  have outcome := NameSourceLegacy.chain matrix tokens tokenChecks tables tableChecks frame flat graph source sourceCheck graphCheck values oneValue satisfied message decoded
    _ _ sliceChecks (by intro b bm; exact List.mem_of_mem_drop (List.mem_of_mem_take bm)) owner 0 (NameFrameMatrix.hget f 3) h.head h.finalHead frameLink sourceLink nilEnd bytes rep (p+l) bi
    (by rw [sliceSize]; omega)
  have sourceSize := related_length _ _ _ sliceChecks
  have size : bytes.length = count := by omega
  refine ⟨p,l,bytes,pb,positive,lb,headerInside,by omega,pi,bi,?_,?_,?_,rep,valid,outcome.2⟩
  · simpa only [size] using ci
  · rw [fi,endEq,size]
  · simpa only [size] using decode

#print axioms legacy_names
end ZkBuild.NameSourceHeaders
