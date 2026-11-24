import SignatureOrigins
import DeclarationBinding

namespace ZkBuild.SignatureBoundary
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem namespace_functions {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ total : Nat, total < 2^32 ∧ E values space.functions = (total : F) ∧
      ∀ row ∈ signature.metadata, E values row.entry.active = 1 → ∀ index : Nat, index < 2^33 →
        E values row.entry.address = ((2*index : Nat) : F) → index < total := by
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
  obtain ⟨ds,images,bounds,dense,functions,_⟩ := SignatureDense.decode_rows matrix space.rows z z rc _ (List.all_eq_true.mp tableChecks _ cm) cmembers values oneValue satisfied 0 0 (by simpa using shape.1) zero zero
  have close : MemoryEvidence.checkSpan matrix space.closeStart space.closeEnd
      [eqGate (SignatureNamespace.final space.rows z z).1 space.functions,eqGate (SignatureNamespace.final space.rows z z).2 space.types] = true := by grind only
  have closed := MemoryEvidence.span_sound matrix _ _ _ close values satisfied
  have ce := equality_sound values oneValue (SignatureNamespace.final space.rows z z).1 space.functions (closed _ (by simp))
  have countImage : E values space.functions = (SignatureDense.fCount ds : F) := by
    rw [← ce,functions]
    simp
  have countBound : SignatureDense.fCount ds < 2^32 := by
    have count := SignatureDense.function_count_bound ds
    have len := related_length _ _ _ images
    omega
  refine ⟨SignatureDense.fCount ds,countBound,countImage,?_⟩
  intro row member active index ib address
  have mapped : row.entry ∈ space.rows.map SignatureNamespace.Row.entry := by rw [shape.2.2]; exact List.mem_map.mpr ⟨row,member,rfl⟩
  obtain ⟨ns,nsm,same⟩ := List.mem_map.mp mapped
  obtain ⟨d,dm,di⟩ := BinaryReadMemory.left_member _ _ _ images ns nsm
  have da : d.active = true := by
    have bit : (d.active.toNat : F) = 1 := di.1.symm.trans (by rw [same]; exact active)
    cases flag : d.active with
    | true => rfl
    | false => simp only [flag,Bool.toNat_false,Semiring.natCast_zero] at bit; exact False.elim (Field.zero_ne_one bit)
  have addr : d.address = 2*index := DeclarationLocations.natural_equal (F := F) _ _ (by have b := bounds d dm; omega) (by omega)
    (di.2.symm.trans (by rw [same]; exact address))
  simpa using SignatureDense.function_bound ds 0 0 dense d dm da index addr


theorem first_function {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (space : SignatureNamespace.Record) (declaration : DeclarationMatrix.Record) (signature : SignatureMatrix.Record)
    (checked : SignatureNamespace.check matrix declaration signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ imported : Nat, imported < 2^32 ∧ E values declaration.firstFunction = (imported : F) ∧ E values space.importedFunctions = (imported : F) := by
  have parts := checked
  simp only [SignatureNamespace.check,Bool.and_eq_true_iff] at parts
  have shape : space.rows.length < 2^32 ∧ space.firstFunction = declaration.firstFunction ∧ space.rows.map SignatureNamespace.Row.entry = signature.metadata.map SignatureMatrix.MetadataRow.entry := _root_.of_decide_eq_true (by grind only)
  have range : RangeUse.check matrix space.importedRange space.importedFunctions 32 = true := by grind only
  obtain ⟨imported,ib,ii,_⟩ := TokenInteger.certificate_nat values oneValue space.importedFunctions (RangeUse.bits space.importedRange) 32
    (RangeUse.checked_certificate matrix space.importedRange space.importedFunctions 32 range values oneValue satisfied)
  have aliasCheck : MemoryEvidence.checkSpan matrix space.firstAliasStart space.firstAliasEnd [eqGate space.firstFunction space.importedFunctions] = true := by grind only
  have aliasImage := equality_sound values oneValue space.firstFunction space.importedFunctions
    (MemoryEvidence.span_sound matrix _ _ _ aliasCheck values satisfied _ (by simp))
  exact ⟨imported,ib,by rw [← shape.2.1,aliasImage,ii],ii⟩

theorem function_member_bounded (matrix : Shape) (tokens : Tokens) (first : Linear) (rows : List FunctionRow)
    (index : Nat) (cursor previous count : Linear)
    (accepted : checkFunctions matrix tokens first rows index cursor previous count = true)
    (r : FunctionRow) (member : r ∈ rows) :
    ∃ i c p n, index ≤ i ∧ i < index+rows.length ∧ checkFunction matrix tokens r i first c p n = true := by
  induction rows generalizing index cursor previous count with
  | nil => simp at member
  | cons row rows ih =>
    have parts := Bool.and_eq_true_iff.mp accepted
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨index,cursor,previous,count,by omega,by simp,parts.1⟩
    · obtain ⟨i,c,p,n,lower,upper,checked⟩ := ih (index+1) row.cursor row.active row.count parts.2 later
      exact ⟨i,c,p,n,by omega,by simp only [List.length_cons]; omega,checked⟩

theorem source_index {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (source : FunctionRow) (member : source ∈ declaration.functions) (active : E values source.active = 1) :
    ∃ imported ordinal : Nat, imported < 2^32 ∧ ordinal < declaration.functions.length ∧ ordinal < 2^32 ∧
      E values declaration.firstFunction = (imported : F) ∧ E values source.query.address = ((2*(imported+ordinal) : Nat) : F) := by
  have outer := Bool.and_eq_true_iff.mp accepted
  obtain ⟨imported,ib,ii,_⟩ := first_function matrix space declaration signature outer.2 values oneValue satisfied
  have dc := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp outer.1).1).1
  have shapeCheck := (Bool.and_eq_true_iff.mp dc).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at shapeCheck
  have shape : Metadata body.envelope declaration := _root_.of_decide_eq_true (by grind only)
  have fc : checkFunctions matrix body.tokens declaration.firstFunction declaration.functions 0 declaration.functionStart o z = true := by grind only
  obtain ⟨ordinal,c,p,n,_,ob,checked⟩ := function_member_bounded matrix body.tokens declaration.firstFunction declaration.functions 0 declaration.functionStart o z fc source member
  have holds := MemoryEvidence.span_sound matrix source.firstGate source.lastGate _ (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have qg := multiply_sound values source.active (scale (declaration.firstFunction++DeclarationMatrix.n ordinal) 2) source.query.address
    (holds _ (by simp only [functionGates,queryGate,List.mem_append,List.mem_cons]; grind))
  have scaled := eval_scale values (declaration.firstFunction++DeclarationMatrix.n ordinal) 2
  change E values (scale (declaration.firstFunction++DeclarationMatrix.n ordinal) 2) = ((2 : Int) : F)*E values (declaration.firstFunction++DeclarationMatrix.n ordinal) at scaled
  have add := eval_append values declaration.firstFunction (DeclarationMatrix.n ordinal)
  change E values (declaration.firstFunction++DeclarationMatrix.n ordinal) = E values declaration.firstFunction+E values (DeclarationMatrix.n ordinal) at add
  have oi : E values (DeclarationMatrix.n ordinal) = (ordinal : F) := (eval_constant values oneValue (Int.ofNat ordinal)).trans (Ring.intCast_natCast ordinal)
  have two : ((2 : Int) : F) = ((2 : Nat) : F) := Ring.intCast_natCast 2
  have key : E values source.query.address = ((2*(imported+ordinal) : Nat) : F) := by
    rw [qg,active,scaled,add,ii,oi,two,Semiring.one_mul,Semiring.natCast_mul,Semiring.natCast_add]
  exact ⟨imported,ordinal,ib,by omega,by have bound := shape.2.2.2.1; omega,ii,key⟩

theorem function_at (matrix : Shape) (tokens : Tokens) (first : Linear) (items : List FunctionRow)
    (index : Nat) (cursor previous currentCount : Linear)
    (checked : checkFunctions matrix tokens first items index cursor previous currentCount = true)
    (ordinal : Nat) (inside : ordinal < items.length) :
    ∃ c p n, checkFunction matrix tokens (items.getD ordinal default) (index+ordinal) first c p n = true := by
  induction items generalizing index cursor previous currentCount ordinal with
  | nil => simp at inside
  | cons row rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    cases ordinal with
    | zero => exact ⟨cursor,previous,currentCount,by simpa using parts.1⟩
    | succ ordinal =>
      obtain ⟨c,p,n,found⟩ := ih (index+1) row.cursor row.active row.count parts.2 ordinal (by simpa using inside)
      exact ⟨c,p,n,by simpa [Nat.add_assoc,Nat.add_comm,Nat.add_left_comm] using found⟩

theorem source_index_at {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (ordinal : Nat) (inside : ordinal < declaration.functions.length)
    (active : E values (declaration.functions.getD ordinal default).active = 1) :
    ∃ imported : Nat, imported < 2^32 ∧ ordinal < 2^32 ∧
      E values declaration.firstFunction = (imported : F) ∧ E values (declaration.functions.getD ordinal default).query.address = ((2*(imported+ordinal) : Nat) : F) := by
  have outer := Bool.and_eq_true_iff.mp accepted
  obtain ⟨imported,ib,ii,_⟩ := first_function matrix space declaration signature outer.2 values oneValue satisfied
  have dc := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp outer.1).1).1
  have shapeCheck := (Bool.and_eq_true_iff.mp dc).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at shapeCheck
  have shape : Metadata body.envelope declaration := _root_.of_decide_eq_true (by grind only)
  have fc : checkFunctions matrix body.tokens declaration.firstFunction declaration.functions 0 declaration.functionStart o z = true := by grind only
  obtain ⟨c,p,n,checked⟩ := function_at matrix body.tokens declaration.firstFunction declaration.functions 0 declaration.functionStart o z fc ordinal inside
  simp only [Nat.zero_add] at checked
  have holds := MemoryEvidence.span_sound matrix (declaration.functions.getD ordinal default).firstGate (declaration.functions.getD ordinal default).lastGate _ (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have qg := multiply_sound values (declaration.functions.getD ordinal default).active (scale (declaration.firstFunction++DeclarationMatrix.n ordinal) 2) (declaration.functions.getD ordinal default).query.address
    (holds _ (by simp only [functionGates,queryGate,List.mem_append,List.mem_cons]; grind))
  have scaled := eval_scale values (declaration.firstFunction++DeclarationMatrix.n ordinal) 2
  change E values (scale (declaration.firstFunction++DeclarationMatrix.n ordinal) 2) = ((2 : Int) : F)*E values (declaration.firstFunction++DeclarationMatrix.n ordinal) at scaled
  have add := eval_append values declaration.firstFunction (DeclarationMatrix.n ordinal)
  change E values (declaration.firstFunction++DeclarationMatrix.n ordinal) = E values declaration.firstFunction+E values (DeclarationMatrix.n ordinal) at add
  have oi : E values (DeclarationMatrix.n ordinal) = (ordinal : F) := (eval_constant values oneValue (Int.ofNat ordinal)).trans (Ring.intCast_natCast ordinal)
  have two : ((2 : Int) : F) = ((2 : Nat) : F) := Ring.intCast_natCast 2
  have key : E values (declaration.functions.getD ordinal default).query.address = ((2*(imported+ordinal) : Nat) : F) := by
    rw [qg,active,scaled,add,ii,oi,two,Semiring.one_mul,Semiring.natCast_mul,Semiring.natCast_add]
  exact ⟨imported,ib,by have bound := shape.2.2.2.1; omega,ii,key⟩

#print axioms namespace_functions
#print axioms first_function
#print axioms source_index
#print axioms source_index_at
end ZkBuild.SignatureBoundary
