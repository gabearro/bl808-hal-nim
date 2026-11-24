import SignatureDense

namespace ZkBuild.SignatureOrigins
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem type_count_bound (ds : List SignatureDense.Decoded) : SignatureDense.tCount ds ≤ ds.length := by
  induction ds with
  | nil => exact Nat.le_refl 0
  | cons d ds ih =>
    have bit : SignatureDense.tInc d ≤ 1 := by unfold SignatureDense.tInc; split <;> decide
    simp only [SignatureDense.tCount,List.length_cons]
    omega

theorem namespace_types {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ total : Nat, total < 2^32 ∧ E values declaration.typeCount = (total : F) ∧
      ∀ row ∈ signature.metadata, E values row.entry.active = 1 → ∀ index : Nat, index < 2^32 →
        E values row.entry.address = ((2*index+1 : Nat) : F) → index < total := by
  have outer := Bool.and_eq_true_iff.mp accepted
  have inner := Bool.and_eq_true_iff.mp outer.1
  have moduleTables := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp inner.1).1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleTables).1).2
  have sigChecks := inner.2
  simp only [SignatureMatrix.check,Bool.and_eq_true_iff] at sigChecks
  have links : SignatureMatrix.checkLinks tables declaration indexed signature = true := by grind only
  have linkFacts := _root_.of_decide_eq_true links
  have cm : SignatureMatrix.table tables signature 0 ∈ tables := by
    have b : 0 < signature.tables.length := by rw [linkFacts.1]; decide
    have m : signature.tables.getD 0 0 ∈ signature.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold SignatureMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (linkFacts.2.1 _ m)
  have spaceChecks := outer.2
  simp only [SignatureNamespace.check,Bool.and_eq_true_iff] at spaceChecks
  have shape : space.rows.length < 2^32 ∧ space.firstFunction = declaration.firstFunction ∧ space.rows.map SignatureNamespace.Row.entry = signature.metadata.map SignatureMatrix.MetadataRow.entry := _root_.of_decide_eq_true (by grind only)
  have rc : SignatureNamespace.checkRows matrix space.rows z z = true := by grind only
  have cmembers : ∀ row ∈ space.rows, row.entry ∈ (SignatureMatrix.table tables signature 0).entries := by
    intro row member
    rw [linkFacts.2.2.1,← shape.2.2]
    exact List.mem_map.mpr ⟨row,member,rfl⟩
  have zero : E values z = ((0 : Nat) : F) := by simp [z,eval_constant values oneValue]
  obtain ⟨ds,images,bounds,dense,_,types⟩ := SignatureDense.decode_rows matrix space.rows z z rc _ (List.all_eq_true.mp tableChecks _ cm) cmembers values oneValue satisfied 0 0 (by simpa using shape.1) zero zero
  have close : MemoryEvidence.checkSpan matrix space.closeStart space.closeEnd
      [eqGate (SignatureNamespace.final space.rows z z).1 space.functions,eqGate (SignatureNamespace.final space.rows z z).2 space.types] = true := by grind only
  have closed := MemoryEvidence.span_sound matrix _ _ _ close values satisfied
  have ce := equality_sound values oneValue (SignatureNamespace.final space.rows z z).2 space.types (closed _ (by simp))
  have bind : MemoryEvidence.checkSpan matrix space.typeBindStart space.typeBindEnd [eqGate declaration.typeCount space.types] = true := by grind only
  have be := equality_sound values oneValue declaration.typeCount space.types (MemoryEvidence.span_sound matrix _ _ _ bind values satisfied _ (by simp))
  have countImage : E values declaration.typeCount = (SignatureDense.tCount ds : F) := by
    rw [be,← ce,types]
    simp
  have countBound : SignatureDense.tCount ds < 2^32 := by
    have count := type_count_bound ds
    have len := related_length _ _ _ images
    omega
  refine ⟨SignatureDense.tCount ds,countBound,countImage,?_⟩
  intro row member active index ib address
  have mapped : row.entry ∈ space.rows.map SignatureNamespace.Row.entry := by rw [shape.2.2]; exact List.mem_map.mpr ⟨row,member,rfl⟩
  obtain ⟨ns,nsm,same⟩ := List.mem_map.mp mapped
  obtain ⟨d,dm,di⟩ := BinaryReadMemory.left_member _ _ _ images ns nsm
  have da : d.active = true := by
    have bit : (d.active.toNat : F) = 1 := di.1.symm.trans (by rw [same]; exact active)
    cases flag : d.active with
    | true => rfl
    | false => simp only [flag,Bool.toNat_false,Semiring.natCast_zero] at bit; exact False.elim (Field.zero_ne_one bit)
  have addr : d.address = 2*index+1 := DeclarationLocations.natural_equal (F := F) _ _ (by have b := bounds d dm; omega) (by omega)
    (di.2.symm.trans (by rw [same]; exact address))
  simpa using SignatureDense.type_bound ds 0 0 dense d dm da index addr

theorem function_origin {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : SignatureMatrix.MetadataRow) (member : row ∈ signature.metadata) (functionIndex : Nat) (fb : functionIndex < 2^32)
    (active : E values row.entry.active = 1) (address : E values row.entry.address = ((2*functionIndex : Nat) : F)) :
    ∃ typeIndex totalTypes : Nat, ∃ source : SignatureMatrix.MetadataRow,
      typeIndex < totalTypes ∧ totalTypes < 2^32 ∧ E values declaration.typeCount = (totalTypes : F) ∧
      E values row.typeIndex = (typeIndex : F) ∧ source ∈ signature.metadata ∧ E values source.entry.active = 1 ∧
      E values source.entry.address = ((2*typeIndex+1 : Nat) : F) ∧ E values source.entry.value = E values row.entry.value := by
  have outer := Bool.and_eq_true_iff.mp accepted
  have inner := Bool.and_eq_true_iff.mp outer.1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp inner.1).1).1).1).2
  have checks := inner.2
  simp only [SignatureMatrix.check,Bool.and_eq_true_iff] at checks
  have rows : signature.metadata.all (SignatureMatrix.checkMetadata matrix splits) = true := by grind only
  obtain ⟨tid,tb,ti,oa,ok,ov⟩ := SignatureRules.function_origin matrix row splits (List.all_eq_true.mp rows row member) values oneValue satisfied functionIndex fb active address
  have links : SignatureMatrix.checkLinks tables declaration indexed signature = true := by grind only
  have facts := _root_.of_decide_eq_true links
  have cm : SignatureMatrix.table tables signature 0 ∈ tables := by
    have b : 0 < signature.tables.length := by rw [facts.1]; decide
    have m : signature.tables.getD 0 0 ∈ signature.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold SignatureMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (facts.2.1 _ m)
  have qm : row.origin ∈ (SignatureMatrix.table tables signature 0).queries := by rw [facts.2.2.2.1]; exact List.mem_append_left _ (List.mem_map.mpr ⟨row,member,rfl⟩)
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix _ (List.all_eq_true.mp tableChecks _ cm) values oneValue satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := membership row.origin qm oa
  rw [facts.2.2.1] at em
  obtain ⟨source,sm,same⟩ := List.mem_map.mp em
  subst entry
  obtain ⟨total,totalBound,countImage,bounded⟩ := namespace_types matrix body tables splits declaration indexed signature space accepted values oneValue satisfied
  have key : E values source.entry.address = ((2*tid+1 : Nat) : F) := ek.trans ok
  exact ⟨tid,total,source,bounded source sm ea tid tb key,totalBound,countImage,ti,sm,ea,key,ev.trans ov⟩

#print axioms namespace_types
#print axioms function_origin
end ZkBuild.SignatureOrigins
