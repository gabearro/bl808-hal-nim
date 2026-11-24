import DeclarationSound
namespace ZkBuild.DeclarationSelection
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem selected_member {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (r : VectorRow) (reverse : Bool) (index : Nat) (previous previousAddress count : Linear)
    (accepted : checkVector matrix tokens splits r reverse index previous previousAddress count = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values (get r.fields 0) = 1) :
    ∃ typeIndex ordinal base length : Nat,
      typeIndex < 2^32 ∧ ordinal < length ∧ length < 2^32 ∧ base < 2^32 ∧
      E values (split splits r.keySplit).high = (typeIndex : F) ∧ E values (split splits r.keySplit).low = (ordinal : F) ∧
      E values (split splits r.spanSplit).low = (base : F) ∧ E values (split splits r.spanSplit).high = (length : F) ∧
      E values r.position = ((base+ordinal : Nat) : F) ∧ E values r.location.address = (typeIndex : F) := by
  have shape := DeclarationVector.vector_metadata matrix tokens splits r reverse index previous previousAddress count accepted
  have keyShape := shape.2.2.2.2.2.2.2.2.1
  have spanShape := shape.2.2.2.2.2.2.2.2.2.1
  have keyMember : split splits r.keySplit ∈ splits := by
    rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.2.1
  have spanMember : split splits r.spanSplit ∈ splits := by
    rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.2.2.1
  obtain ⟨_,ordinal,typeIndex,_,ordinalBound,typeBound,_,ordinalImage,typeImage,_⟩ := PackedFields.checked_split matrix _
    (List.all_eq_true.mp splitChecks _ keyMember) values oneValue satisfied
  obtain ⟨_,base,length,_,baseBound,lengthBound,_,baseImage,lengthImage,_⟩ := PackedFields.checked_split matrix _
    (List.all_eq_true.mp splitChecks _ spanMember) values oneValue satisfied
  have ob : ordinal < 2^32 := by simpa only [keyShape.2.1] using ordinalBound
  have tb : typeIndex < 2^32 := by simpa only [keyShape.2.2] using typeBound
  have bb : base < 2^32 := by simpa only [spanShape.2.1] using baseBound
  have lb : length < 2^32 := by simpa only [spanShape.2.2] using lengthBound
  have rangeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).2
  obtain ⟨gap,gb,gi⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix r.withinRange r.within 32 rangeCheck values oneValue satisfied)
  have holds := DeclarationVector.vector_holds matrix tokens splits r reverse index previous previousAddress count accepted values satisfied
  have core := DeclarationVector.part_holds values tokens splits r reverse previous previousAddress count holds 9 (by decide)
  change AllHold values [mulGate (get r.fields 0) (sub (sub (split splits r.spanSplit).high (split splits r.keySplit).low) o) r.within] at core
  have equation := multiply_sound values (get r.fields 0) (sub (sub (split splits r.spanSplit).high (split splits r.keySplit).low) o) r.within (core _ (by simp))
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  rw [gi,active,eval_sub,eval_sub,lengthImage,ordinalImage,one] at equation
  have order : ordinal < length := ReadOnlyMemory.order_gate (F := F) (2^32) ordinal length gap ob lb gb (by decide) (by simpa [Semiring.one_mul] using equation.symm)
  have positions := DeclarationVector.part_holds values tokens splits r reverse previous previousAddress count holds 12 (by decide)
  have posGate : Holds values (mulGate (get r.fields 0) ((split splits r.spanSplit).low++(split splits r.keySplit).low) r.position) := by
    exact positions _ (by simp [vectorParts])
  have pos := multiply_sound values (get r.fields 0) ((split splits r.spanSplit).low++(split splits r.keySplit).low) r.position posGate
  have added := FullMatrix.eval_append values (split splits r.spanSplit).low (split splits r.keySplit).low
  change E values ((split splits r.spanSplit).low++(split splits r.keySplit).low) = E values (split splits r.spanSplit).low+E values (split splits r.keySplit).low at added
  have posImage : E values r.position = ((base+ordinal : Nat) : F) := by
    rw [pos,active,added,baseImage,ordinalImage,Semiring.natCast_add]
    simp [Semiring.one_mul]
  have query := DeclarationVector.part_holds values tokens splits r reverse previous previousAddress count holds 7 (by decide)
  change AllHold values [queryGate (get r.fields 0) (split splits r.keySplit).high r.location] at query
  have qg := multiply_sound values (get r.fields 0) (split splits r.keySplit).high r.location.address (query _ (by simp [queryGate]))
  have qi : E values r.location.address = (typeIndex : F) := by rw [qg,active,typeImage]; simp [Semiring.one_mul]
  exact ⟨typeIndex,ordinal,base,length,tb,order,lb,bb,typeImage,ordinalImage,baseImage,lengthImage,posImage,qi⟩

theorem selected_source_member {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : VectorRow) (reverse : Bool) (index : Nat) (previous previousAddress count : Linear)
    (accepted : checkVector matrix tokens splits r reverse index previous previousAddress count = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values (get r.fields 0) = 1) (message : List Sha256.Byte) (messageBound : message.length < 2^32)
    (decoded : ∀ t ∈ tokens, ∃ position length, BinaryTokenSound.Result values t message position length) :
    ∃ (tag : Fin 7) (typeIndex ordinal base length : Nat),
      typeIndex < 2^32 ∧ ordinal < length ∧ length < 2^32 ∧ base < 2^32 ∧ base+ordinal < message.length ∧
      E values (get r.fields 2) = (tag.val : F) ∧ E values r.location.address = (typeIndex : F) ∧
      (message.getD (base+ordinal) 0).toNat = BinaryDeclarations.encodedType tag := by
  obtain ⟨typeIndex,ordinal,base,length,tb,ord,lb,bb,_,_,_,_,positionImage,queryImage⟩ := selected_member matrix tokens splits splitChecks r reverse index previous previousAddress count accepted values oneValue satisfied active
  obtain ⟨tag,position,pb,tagImage,pi,byte⟩ := DeclarationVector.source_type_byte matrix tokens splits tokenChecks r reverse index previous previousAddress count accepted values oneValue satisfied active message decoded
  have pSmall : position < scalarModulus := by
    have big : 2^32 < scalarModulus := by decide
    omega
  have sumSmall : base+ordinal < scalarModulus := by
    have big : 2^33 < scalarModulus := by decide
    omega
  have same : position = base+ordinal := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus pSmall sumSmall).mp (pi.symm.trans positionImage)
  exact ⟨tag,typeIndex,ordinal,base,length,tb,ord,lb,bb,by omega,tagImage,queryImage,by simpa [same] using byte⟩

theorem checked_vector_bytes {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits) (r : DeclarationMatrix.Record)
    (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      ∀ row ∈ r.params++r.results, E values (get row.fields 0) = 1 →
        ∃ (tag : Fin 7) (typeIndex ordinal base length : Nat),
          typeIndex < 2^32 ∧ ordinal < length ∧ length < 2^32 ∧ base < 2^32 ∧ base+ordinal < message.length ∧
          E values (get row.fields 2) = (tag.val : F) ∧ E values row.location.address = (typeIndex : F) ∧
          (message.getD (base+ordinal) 0).toNat = BinaryDeclarations.encodedType tag := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have splitChecks := (Bool.and_eq_true_iff.mp parts.1).2
  have envelope := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelope).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  obtain ⟨message,meaning,d0,d1,_,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have linked := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).1).1).1
  have sourceCheck := (Bool.and_eq_true_iff.mp linked).1
  have shape : BinarySourceEmbedded.metadata matrix body.source := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp sourceCheck).1
  have bound : message.length < 2^32 := Nat.lt_of_le_of_lt meaning.1 shape.2.2.2.2.2.2.2.2.2.2.1
  have paramChecks : checkVectors matrix body.tokens splits true r.params 0 o z z = true := by
    have checked := parts.2
    simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checked
    grind only
  have resultChecks : checkVectors matrix body.tokens splits false r.results 0 o z z = true := by
    have checked := parts.2
    simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checked
    grind only
  refine ⟨message,meaning,d0,d1,?_⟩
  intro row member active
  rcases List.mem_append.mp member with param | result
  · obtain ⟨i,p,a,c,checked⟩ := DeclarationSound.vector_member matrix body.tokens splits true r.params 0 o z z paramChecks row param
    exact selected_source_member matrix body.tokens splits splitChecks tokenChecks row true i p a c checked values oneValue satisfied active message bound decoded
  · obtain ⟨i,p,a,c,checked⟩ := DeclarationSound.vector_member matrix body.tokens splits false r.results 0 o z z resultChecks row result
    exact selected_source_member matrix body.tokens splits splitChecks tokenChecks row false i p a c checked values oneValue satisfied active message bound decoded

#print axioms selected_member
#print axioms selected_source_member
#print axioms checked_vector_bytes
end ZkBuild.DeclarationSelection
