import DeclarationSourceVectors

namespace ZkBuild.DeclarationFraming
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram DeclarationLocations
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem u32_value {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BinaryTokenMatrix.Record) (checked : BinaryTokenMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : r.kind = 1) (active : E values r.activeMode = 1)
    (message : List Sha256.Byte) (position value : Nat) (pb : position < 2^64) (vb : value < 2^32)
    (pi : E values r.position = (position : F)) (vi : E values r.value = (value : F))
    (decoded : ∃ p length, BinaryTokenSound.Result values r message p length) :
    ∃ length, 0 < length ∧ length ≤ 5 ∧ position+length ≤ message.length ∧ E values r.length = (length : F) ∧
      TokenInteger.decode 1 length (fun i => (message.getD (position+i) 0).toNat) = value := by
  obtain ⟨p,len,bound,positive,cap,inside,pos,lenImage,val⟩ := TokenApplications.active_value matrix r checked values oneValue satisfied 1 (by decide) kind active message decoded
  have samePosition := natural_equal (F := F) p position (by omega) pb (pos.symm.trans pi)
  subst p
  have decodeBound : TokenInteger.decode 1 len (fun i => (message.getD (position+i) 0).toNat) < 2^32 := by
    simpa [TokenInteger.decode,BinaryTokenMatrix.width] using BitPacking.packed_bits_bounded ((List.range (BinaryTokenMatrix.width 1)).map (TokenInteger.decodedBit 1 len (fun i => (message.getD (position+i) 0).toNat)))
  have sameValue := natural_equal (F := F) _ value (by omega) (by omega) (val.symm.trans vi)
  exact ⟨len,positive,by simpa [BinaryTokenMatrix.capacity] using cap,inside,lenImage,sameValue⟩

def Framed (message : List Sha256.Byte) (d : DeclarationType.Decoded) : Prop :=
  d.start < message.length ∧ (message.getD d.start 0).toNat = 96 ∧
  ∃ paramLength resultLength : Nat,
    0 < paramLength ∧ paramLength ≤ 5 ∧ 0 < resultLength ∧ resultLength ≤ 5 ∧
    d.paramsStart = d.start+1+paramLength ∧ d.resultsStart = d.paramsStart+d.params+resultLength ∧
    d.finish = d.resultsStart+d.results ∧ d.paramsStart ≤ message.length ∧ d.resultsStart ≤ message.length ∧
    TokenInteger.decode 1 paramLength (fun i => (message.getD (d.start+1+i) 0).toNat) = d.params ∧
    TokenInteger.decode 1 resultLength (fun i => (message.getD (d.paramsStart+d.params+i) 0).toNat) = d.results

theorem type_framing {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : TypeRow) (i : Nat) (prior : List Linear) (previous endPos : Linear)
    (accepted : checkType matrix tokens splits r i prior previous endPos = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : DeclarationType.Decoded) (image : DeclarationType.Represents values r d) (bound : DeclarationType.Bounded d)
    (active : d.active = true) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ p length, BinaryTokenSound.Result values t message p length) : Framed message d := by
  have shape := DeclarationType.type_metadata matrix tokens splits r i prior previous endPos accepted
  have pm := shape.2.2.2.2.2.2.2.2.1
  have rm := shape.2.2.2.2.2.2.2.2.2.1
  have pMember : token tokens r.paramToken ∈ tokens := by rw [token,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.2.2.2.1
  have rMember : token tokens r.resultToken ∈ tokens := by rw [token,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.2.2.2.2.1
  have holds := DeclarationType.type_holds matrix tokens splits r i prior previous endPos accepted values satisfied
  have enabled : E values (get r.fields 0) = 1 := by simpa [active] using image.1
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have addition (a b : Linear) : E values (a++b) = E values a+E values b := eval_append values a b
  have pb : d.params < 2^32 := bound _ (by simp [DeclarationType.numbers])
  have rb : d.results < 2^32 := bound _ (by simp [DeclarationType.numbers])
  have sb : d.start < 2^32 := bound _ (by simp [DeclarationType.numbers])
  have psb : d.paramsStart < 2^32 := bound _ (by simp [DeclarationType.numbers])
  have rsb : d.resultsStart < 2^32 := bound _ (by simp [DeclarationType.numbers])
  have fb : d.finish < 2^32 := bound _ (by simp [DeclarationType.numbers])
  have paramPosGates := DeclarationType.part_holds values tokens splits r i prior previous endPos holds 4 (by decide)
  have paramPosition := multiply_sound values (get r.fields 0) (get r.fields 1++o) r.paramPosition (paramPosGates _ (by simp [typeParts]))
  have ppos : E values (token tokens r.paramToken).position = ((d.start+1 : Nat) : F) := by
    rw [pm.2.2.1,paramPosition,enabled,addition,image.2.1,one,Semiring.one_mul,Semiring.natCast_add,Semiring.natCast_one]
  obtain ⟨pl,plp,plb,pinside,pli,pvalue⟩ := u32_value matrix _ (List.all_eq_true.mp checks _ pMember) values oneValue satisfied pm.1
    (by rw [pm.2.1]; exact enabled) message (d.start+1) d.params (by omega) pb ppos (by rw [pm.2.2.2]; exact image.2.2.2.2.2.1) (decoded _ pMember)
  have resultGates := DeclarationType.part_holds values tokens splits r i prior previous endPos holds 6 (by decide)
  have resultPosition := multiply_sound values (get r.fields 0) (get r.fields 2++get r.fields 5) r.resultPosition (resultGates _ (by simp [typeParts]))
  have rpos : E values (token tokens r.resultToken).position = ((d.paramsStart+d.params : Nat) : F) := by
    rw [rm.2.2.1,resultPosition,enabled,addition,image.2.2.1,image.2.2.2.2.2.1,Semiring.one_mul,Semiring.natCast_add]
  obtain ⟨rl,rlp,rlb,rinside,rli,rvalue⟩ := u32_value matrix _ (List.all_eq_true.mp checks _ rMember) values oneValue satisfied rm.1
    (by rw [rm.2.1]; exact enabled) message (d.paramsStart+d.params) d.results (by omega) rb rpos (by rw [rm.2.2.2]; exact image.2.2.2.2.2.2) (decoded _ rMember)
  have pg := resultGates (gate (get r.fields 0) (sub (sub (sub (get r.fields 2) (get r.fields 1)) o) (token tokens r.paramToken).length)) (by simp [typeParts])
  change E values (get r.fields 0)*E values (sub (sub (sub (get r.fields 2) (get r.fields 1)) o) (token tokens r.paramToken).length) = E values z at pg
  rw [enabled,eval_sub,eval_sub,eval_sub,image.2.2.1,image.2.1,one,pli,zero] at pg
  have paramStart : d.paramsStart = d.start+1+pl := natural_equal (F := F) _ _ (by omega) (by omega) (by simp only [Semiring.natCast_add,Semiring.natCast_one]; grind)
  have finishGates := DeclarationType.part_holds values tokens splits r i prior previous endPos holds 8 (by decide)
  have rg := finishGates (gate (get r.fields 0) (sub (sub (sub (get r.fields 3) (get r.fields 2)) (get r.fields 5)) (token tokens r.resultToken).length)) (by simp [typeParts])
  change E values (get r.fields 0)*E values (sub (sub (sub (get r.fields 3) (get r.fields 2)) (get r.fields 5)) (token tokens r.resultToken).length) = E values z at rg
  rw [enabled,eval_sub,eval_sub,eval_sub,image.2.2.2.1,image.2.2.1,image.2.2.2.2.2.1,rli,zero] at rg
  have resultStart : d.resultsStart = d.paramsStart+d.params+rl := natural_equal (F := F) _ _ (by omega) (by omega) (by simp only [Semiring.natCast_add]; grind)
  have fg := finishGates (gate (get r.fields 0) (sub (sub (get r.fields 4) (get r.fields 3)) (get r.fields 6))) (by simp [typeParts])
  change E values (get r.fields 0)*E values (sub (sub (get r.fields 4) (get r.fields 3)) (get r.fields 6)) = E values z at fg
  rw [enabled,eval_sub,eval_sub,image.2.2.2.2.1,image.2.2.2.1,image.2.2.2.2.2.2,zero] at fg
  have finish : d.finish = d.resultsStart+d.results := natural_equal (F := F) _ _ (by omega) (by omega) (by simp only [Semiring.natCast_add]; grind)
  obtain ⟨headerBound,headerByte⟩ := DeclarationHeader.type_header matrix tokens splits checks r i prior previous endPos accepted values oneValue satisfied d image bound active message decoded
  exact ⟨headerBound,headerByte,pl,rl,plp,plb,rlp,rlb,paramStart,resultStart,finish,by omega,by omega,pvalue,rvalue⟩

/-- Complete source type declarations: headers, exact decoded arities and
    byte framing, with every parameter/result position accounted for. -/
theorem checked_type_declarations {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      Related (DeclarationType.Represents values) r.types types ∧ (∀ d ∈ types, DeclarationType.Bounded d) ∧
      (∀ i, i < types.length → (types.getD i default).active = true →
        Framed message (types.getD i default) ∧ (types.getD i default).finish ≤ message.length) ∧
      DeclarationSourceVectors.CompleteBytes values message types r.params true ∧
      DeclarationSourceVectors.CompleteBytes values message types r.results false := by
  obtain ⟨message,types,meaning,d0,d1,images,bounds,params,results⟩ := DeclarationSourceVectors.checked_source_vectors matrix body tables splits r accepted values oneValue satisfied
  have parts := Bool.and_eq_true_iff.mp accepted
  have envelope := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelope).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  obtain ⟨other,otherMeaning,_,_,unique,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have same := unique message meaning
  subst other
  have typeChecks : checkTypes matrix body.tokens splits r.typeEnd r.types 0 (typeSeed r.typeStart) o = true := by
    have checked := parts.2
    simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checked
    grind only
  refine ⟨message,types,meaning,d0,d1,images,bounds,?_,params,results⟩
  intro i ib enabled
  have size := related_length _ _ _ images
  have rowBound : i < r.types.length := by omega
  have rm : r.types.getD i default ∈ r.types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem rowBound
  have tm : types.getD i default ∈ types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem ib
  obtain ⟨index,prior,previous,checked⟩ := DeclarationSound.type_member matrix body.tokens splits r.typeEnd r.types 0 (typeSeed r.typeStart) o typeChecks _ rm
  have represented := related_at (DeclarationType.Represents values) r.types types images i rowBound
  have framing := type_framing matrix body.tokens splits tokenChecks _ index prior previous r.typeEnd checked values oneValue satisfied _ represented (bounds _ tm) enabled message decoded
  refine ⟨framing,?_⟩
  obtain ⟨_,_,pl,rl,_,_,_,_,_,rs,finish,_,resultBound,_,_⟩ := framing
  by_cases empty : (types.getD i default).results = 0
  · omega
  · have ob : (types.getD i default).results-1 < arity false (types.getD i default) := by
      change (types.getD i default).results-1 < (types.getD i default).results
      omega
    obtain ⟨_,tag,row,_,_,_,_,inside,_⟩ := results i ((types.getD i default).results-1) ib ob
    change (types.getD i default).resultsStart+((types.getD i default).results-1) < message.length at inside
    omega

#print axioms u32_value
#print axioms type_framing
#print axioms checked_type_declarations
end ZkBuild.DeclarationFraming
