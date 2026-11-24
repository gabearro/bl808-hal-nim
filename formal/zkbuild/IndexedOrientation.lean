import IndexedBridge

namespace ZkBuild.IndexedOrientation
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix
open DeclarationLocations
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- Parameter lists are indexed in stack-pop order; result lists use source
    order. The equality is over bounded naturals, without scalar wraparound. -/
theorem source_position {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (source : VectorRow) (params : Bool) (index : Nat) (previous previousAddress count : Linear)
    (checked : checkVector matrix tokens splits source params index previous previousAddress count = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values (DeclarationMatrix.get source.fields 0) = 1)
    (d : IndexedCell.Decoded) (bounded : IndexedCell.Bounded d)
    (queryKey : E values source.memberQuery.address = ((d.ordinal+2^32*d.head : Nat) : F)) :
    ∃ sourceOrdinal length paramHead resultHead : Nat,
      sourceOrdinal < length ∧ length < 2^32 ∧ paramHead < 2^32 ∧ resultHead < 2^32 ∧
      E values (split splits source.keySplit).low = (sourceOrdinal : F) ∧
      E values (split splits source.spanSplit).high = (length : F) ∧
      E values (split splits source.heads).low = (paramHead : F) ∧ E values (split splits source.heads).high = (resultHead : F) ∧
      d.head = (if params then paramHead else resultHead) ∧
      d.ordinal = (if params then length-1-sourceOrdinal else sourceOrdinal) := by
  have shape := DeclarationVector.vector_metadata matrix tokens splits source params index previous previousAddress count checked
  obtain ⟨_,ordinal,_,length,_,ord,lb,_,_,oi,_,li,_,_⟩ := DeclarationSelection.selected_member matrix tokens splits splitChecks source params index previous previousAddress count checked values oneValue satisfied active
  have hm : split splits source.heads ∈ splits := by
    rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.2.2.2.1
  have hs := shape.2.2.2.2.2.2.2.2.2.2.1
  obtain ⟨_,paramHead,resultHead,_,pb,rb,_,pi,ri,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ hm) values oneValue satisfied
  have pBound : paramHead < 2^32 := by simpa [hs.2.1] using pb
  have rBound : resultHead < 2^32 := by simpa [hs.2.2] using rb
  let head := if params then paramHead else resultHead
  let ordinalTerm := if params then sub (sub (split splits source.spanSplit).high (split splits source.keySplit).low) o else (split splits source.keySplit).low
  let headTerm := if params then (split splits source.heads).low else (split splits source.heads).high
  let memberOrdinal := if params then length-1-ordinal else ordinal
  have hb : head < 2^32 := by cases params <;> assumption
  have ob : memberOrdinal < 2^32 := by cases params <;> dsimp [memberOrdinal] <;> omega
  have headImage : E values headTerm = (head : F) := by cases params <;> assumption
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have ordinalImage : E values ordinalTerm = (memberOrdinal : F) := by
    cases p : params
    · simpa [ordinalTerm,memberOrdinal,p] using oi
    · have sum : length-1-ordinal+ordinal+1 = length := by omega
      have eq := congrArg (fun n : Nat => (n : F)) sum
      simp only [Semiring.natCast_add,Semiring.natCast_one] at eq
      simp only [ordinalTerm,memberOrdinal,p,↓reduceIte]
      rw [eval_sub,eval_sub,li,oi,one]
      grind
  have all := DeclarationVector.vector_holds matrix tokens splits source params index previous previousAddress count checked values satisfied
  have part := DeclarationVector.part_holds values tokens splits source params previous previousAddress count all 16 (by decide)
  have key := multiply_sound values (DeclarationMatrix.get source.fields 0) (scale headTerm (Int.ofNat (2^32))++ordinalTerm) source.memberKey
    (part _ (by simp [DeclarationMatrix.vectorParts,headTerm,ordinalTerm]))
  have query := multiply_sound values (DeclarationMatrix.get source.fields 0) source.memberKey source.memberQuery.address
    (part _ (by simp [DeclarationMatrix.vectorParts,queryGate]))
  have add : E values (scale headTerm (Int.ofNat (2^32))++ordinalTerm) = E values (scale headTerm (Int.ofNat (2^32)))+E values ordinalTerm := eval_append values _ _
  have scaled := eval_scale values headTerm (Int.ofNat (2^32))
  change E values (scale headTerm (Int.ofNat (2^32))) = (Int.ofNat (2^32) : F)*E values headTerm at scaled
  have cast : (Int.ofNat (2^32) : F) = ((2^32 : Nat) : F) := Ring.intCast_natCast _
  have packed : E values source.memberQuery.address = ((memberOrdinal+2^32*head : Nat) : F) := by
    rw [query,active,Semiring.one_mul,key,active,Semiring.one_mul,add,scaled,cast,headImage,ordinalImage]
    simp only [Semiring.natCast_add,Semiring.natCast_mul]
    grind
  have same := natural_equal (F := F) (memberOrdinal+2^32*head) (d.ordinal+2^32*d.head) (by omega)
    (by have b := bounded.1; have c := bounded.2.1; omega) (packed.symm.trans queryKey)
  have components := packed_unique _ _ _ _ ob bounded.2.1 same
  exact ⟨ordinal,length,paramHead,resultHead,ord,lb,pBound,rBound,oi,li,pi,ri,components.2.symm,components.1.symm⟩

theorem checked_orientations {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (params : Bool) (source : VectorRow) (member : source ∈ vectorRows declaration params)
    (active : E values (DeclarationMatrix.get source.fields 0) = 1) :
    ∃ (row : IndexedMatrix.MemberRow) (d : IndexedCell.Decoded) (sourceOrdinal length paramHead resultHead : Nat),
      row ∈ indexed.members ∧ IndexedCell.Represents values splits row d ∧
      sourceOrdinal < length ∧ length < 2^32 ∧ paramHead < 2^32 ∧ resultHead < 2^32 ∧
      E values (split splits source.keySplit).low = (sourceOrdinal : F) ∧
      E values (split splits source.spanSplit).high = (length : F) ∧
      E values (split splits source.heads).low = (paramHead : F) ∧ E values (split splits source.heads).high = (resultHead : F) ∧
      d.head = (if params then paramHead else resultHead) ∧
      d.ordinal = (if params then length-1-sourceOrdinal else sourceOrdinal) := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have splitChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).2
  have decl := (Bool.and_eq_true_iff.mp parts.1).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at decl
  have checks : checkVectors matrix body.tokens splits params (vectorRows declaration params) 0 o z z = true := by
    cases params <;> dsimp [vectorRows] <;> grind only
  have both : source ∈ declaration.params++declaration.results := by
    cases params
    · exact List.mem_append_right _ member
    · exact List.mem_append_left _ member
  obtain ⟨row,d,rm,db,di,_,_,_,key,_,_⟩ := IndexedBridge.source_member matrix body tables splits declaration indexed accepted values oneValue satisfied source both active
  obtain ⟨i,p,a,c,checked⟩ := DeclarationSound.vector_member matrix body.tokens splits params (vectorRows declaration params) 0 o z z checks source member
  obtain ⟨ordinal,len,ph,rh,ob,lb,pb,rb,oi,li,pi,ri,head,order⟩ := source_position matrix body.tokens splits splitChecks source params i p a c checked values oneValue satisfied active d db key
  exact ⟨row,d,ordinal,len,ph,rh,rm,di,ob,lb,pb,rb,oi,li,pi,ri,head,order⟩

#print axioms source_position
#print axioms checked_orientations
end ZkBuild.IndexedOrientation
