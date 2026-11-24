import ImportSource
set_option autoImplicit false

namespace ZkBuild.ImportCoverage
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ImportMatrix ImportRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem rows {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (exports : Linear) (items : List Row)
    (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear)
    (checked : checkRows matrix tokens splits exports items index cursor counts previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (functions : Nat) (capacity : functions+items.length < 2^32)
    (fi : E values (DeclarationMatrix.get counts 0) = (functions : F)) :
    ∃ total : Nat, total < 2^32 ∧ functions ≤ total ∧
      E values (DeclarationMatrix.get (final items cursor counts).2 0) = (total : F) ∧
      ∀ key, functions ≤ key → key < total → ∃ row ∈ items,
        E values row.active = 1 ∧ E values row.kind = 0 ∧ E values row.typeQuery.active = 1 ∧
        E values row.typeQuery.address = ((2*key : Nat) : F) := by
  induction items generalizing index cursor counts previous functions with
  | nil =>
    refine ⟨functions,by simpa using capacity,Nat.le_refl _,?_,?_⟩
    · simpa [final] using fi
    · intro key lower upper; omega
  | cons row rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    obtain ⟨d,image,kb,_,indicators,step⟩ := ImportRules.decode matrix tokens splits exports row index cursor counts previous parts.1 values oneValue satisfied
    have incrementBound : increment d 0 ≤ 1 := by unfold increment; split <;> decide
    have next : E values (DeclarationMatrix.get row.counts 0) = ((functions+increment d 0 : Nat) : F) := by
      rw [step 0 (by decide),fi,Semiring.natCast_add]
    obtain ⟨total,tb,lower,finish,covered⟩ := ih (index+1) (readAt row 6).cursor row.counts row.active parts.2 (functions+increment d 0)
      (by simp only [List.length_cons] at capacity; omega) next
    refine ⟨total,tb,by omega,by simpa [final] using finish,?_⟩
    intro key lowerKey upperKey
    by_cases tailKey : functions+increment d 0 ≤ key
    · obtain ⟨found,member,fa,fk,qa,qk⟩ := covered key tailKey upperKey
      exact ⟨found,by simp [member],fa,fk,qa,qk⟩
    · have incrementOne : increment d 0 = 1 := by omega
      have sameKey : key = functions := by omega
      have enabled : d.active = true := by
        cases flag : d.active with
        | true => rfl
        | false => simp [increment,flag] at incrementOne
      have zero : d.kind = 0 := by
        by_cases same : d.kind = 0
        · exact same
        · simp [increment,same] at incrementOne
      have active : E values row.active = 1 := by simpa [enabled] using image.1
      have kind : E values row.kind = 0 := by simpa [zero] using image.2
      have ind : E values (DeclarationMatrix.get row.indicators 0) = 1 := by simpa [incrementOne] using indicators 0 (by decide)
      have shaped := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1).1
      have qa : row.typeQuery.active = DeclarationMatrix.get row.indicators 0 := by simp only [ImportMatrix.shape] at shaped; grind only
      have all := ImportRules.row_holds matrix tokens splits exports row index cursor counts previous parts.1 values satisfied
      have five := ImportRules.part_holds values tokens splits exports row index cursor counts previous all 5 (by decide)
      have q := multiply_sound values (DeclarationMatrix.get row.indicators 0) (scale (DeclarationMatrix.get counts 0) 2) row.typeQuery.address (five _ (by simp [rowParts,queryGate]))
      have scaleImage := eval_scale values (DeclarationMatrix.get counts 0) 2
      change E values (scale (DeclarationMatrix.get counts 0) 2) = ((2 : Int) : F)*E values (DeclarationMatrix.get counts 0) at scaleImage
      have two : ((2 : Int) : F) = ((2 : Nat) : F) := Ring.intCast_natCast 2
      refine ⟨row,by simp,active,kind,by rw [qa,ind],?_⟩
      rw [q,ind,scaleImage,two,fi,Semiring.one_mul,sameKey,Semiring.natCast_mul]

theorem checked_coverage {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ total : Nat, total < 2^32 ∧ E values imports.importedFunctions = (total : F) ∧
      ∀ key, key < total → ∃ row ∈ imports.rows,
        E values row.active = 1 ∧ E values row.kind = 0 ∧ E values row.typeQuery.active = 1 ∧
        E values row.typeQuery.address = ((2*key : Nat) : F) := by
  have imp := (Bool.and_eq_true_iff.mp checked).2
  simp only [ImportMatrix.check,Bool.and_eq_true_iff] at imp
  have shape : imports.rows.length < 2^32 ∧ imports.importedFunctions = space.importedFunctions ∧ links tables signature imports := _root_.of_decide_eq_true (by grind only)
  have rc : checkRows matrix body.tokens splits imports.exportCount imports.rows 0 (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z] o = true := by grind only
  obtain ⟨total,tb,_,ti,covered⟩ := rows matrix body.tokens splits imports.exportCount imports.rows 0 (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z] o rc values oneValue satisfied 0
    (by simpa using shape.1) (by simp [DeclarationMatrix.get,z,eval_constant values oneValue])
  have close : MemoryEvidence.checkSpan matrix imports.closeStart imports.closeEnd (closeGates body imports) = true := imp.2
  have eq := equality_sound values oneValue (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 0) imports.importedFunctions
    (MemoryEvidence.span_sound matrix _ _ _ close values satisfied _ (by simp [closeGates]))
  exact ⟨total,tb,eq.symm.trans ti,fun key bound => covered key (by omega) bound⟩

/-- Every imported function index is covered by an actual row and its
    authenticated type signature, including interleaved import kinds. -/
theorem checked_signatures {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    : ∃ total : Nat, total < 2^32 ∧ E values imports.importedFunctions = (total : F) ∧
      ∀ key, key < total → ∃ target ∈ imports.rows, E values target.active = 1 ∧ E values target.kind = 0 ∧
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded) (row : SignatureMatrix.MetadataRow)
      (importedFunctions typeIndex position length paramHead resultHead : Nat) (params results : List Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      key < importedFunctions ∧ importedFunctions < 2^32 ∧ E values imports.importedFunctions = (importedFunctions : F) ∧ row ∈ signature.metadata ∧ E values row.entry.active = 1 ∧
      E values row.entry.address = ((2*key : Nat) : F) ∧
      E values target.typeQuery.address = ((2*key : Nat) : F) ∧ typeIndex < types.length ∧
      position < message.length ∧ (message.getD position 0).toNat = 0 ∧
      0 < length ∧ length ≤ 5 ∧ position+1+length ≤ message.length ∧
      TokenInteger.decode 1 length (fun i => (message.getD (position+1+i) 0).toNat) = typeIndex ∧
      E values target.typeQuery.value = (typeIndex : F) ∧
      E values (split splits row.heads).low = (paramHead : F) ∧ E values (split splits row.heads).high = (resultHead : F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramHead params ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultHead results ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).paramsStart true params ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).resultsStart false results := by
  obtain ⟨total,tb,ti,covered⟩ := checked_coverage matrix body tables splits declaration indexed signature space imports checked values oneValue satisfied
  refine ⟨total,tb,ti,?_⟩
  intro key kb
  obtain ⟨target,tm,ta,tk,_,qk⟩ := covered key kb
  obtain ⟨message,types,row,index,count,typeIndex,position,length,paramHead,resultHead,params,results,properties⟩ :=
    ImportSource.imported_function matrix body tables splits declaration indexed signature space imports checked values oneValue satisfied target tm ta tk
  have ib : index < count := by grind only
  have cb : count < 2^32 := by grind only
  have ik : E values target.typeQuery.address = ((2*index : Nat) : F) := by grind only
  have same : index = key := by
    have twice := DeclarationLocations.natural_equal (F := F) (2*index) (2*key) (by omega) (by omega) (ik.symm.trans qk)
    omega
  subst index
  exact ⟨target,tm,ta,tk,message,types,row,count,typeIndex,position,length,paramHead,resultHead,params,results,properties⟩

#print axioms checked_coverage
#print axioms checked_signatures
end ZkBuild.ImportCoverage
