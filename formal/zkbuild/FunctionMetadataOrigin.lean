import ImportCoverage
import SignatureFunctionComplete
set_option autoImplicit false
namespace ZkBuild.FunctionMetadataOrigin
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

def Defined {F : Type} [Field F] (values : Nat → F) (declaration : DeclarationMatrix.Record)
    (row : SignatureMatrix.MetadataRow) (key : Nat) : Prop :=
  ∃ imported ordinal : Nat, ordinal < declaration.functions.length ∧ key = imported+ordinal ∧
    E values declaration.firstFunction = (imported : F) ∧
    E values (declaration.functions.getD ordinal default).active = 1 ∧
    E values (declaration.functions.getD ordinal default).query.address = ((2*key : Nat) : F) ∧
    E values row.typeIndex = E values (declaration.functions.getD ordinal default).query.value

def Imported {F : Type} [Field F] (values : Nat → F) (imports : ImportMatrix.Record)
    (row : SignatureMatrix.MetadataRow) (key : Nat) : Prop :=
  ∃ source ∈ imports.rows, E values source.active = 1 ∧ E values source.kind = 0 ∧
    E values source.typeQuery.active = 1 ∧ E values source.typeQuery.address = ((2*key : Nat) : F) ∧
    E values row.typeIndex = E values source.typeQuery.value

def Origin {F : Type} [Field F] (values : Nat → F) (declaration : DeclarationMatrix.Record) (imports : ImportMatrix.Record)
    (row : SignatureMatrix.MetadataRow) (key : Nat) : Prop :=
  Defined values declaration row key ∨ Imported values imports row key

theorem imported_index {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : SignatureMatrix.MetadataRow) (member : row ∈ signature.metadata) (active : E values row.entry.active = 1)
    (source : ImportMatrix.Row) (sm : source ∈ imports.rows) (qa : E values source.typeQuery.active = 1)
    (same : E values row.entry.address = E values source.typeQuery.address) :
    E values row.typeIndex = E values source.typeQuery.value := by
  have sig := (Bool.and_eq_true_iff.mp checked).1
  have declarationCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp sig).1).1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp declarationCheck).1).1).2
  have imp := (Bool.and_eq_true_iff.mp checked).2
  simp only [ImportMatrix.check,Bool.and_eq_true_iff] at imp
  have shape := _root_.of_decide_eq_true imp.1.1
  have links := shape.2.2
  let bank := ImportMatrix.table tables imports 2
  have bm : bank ∈ tables := by
    have im : imports.tables.getD 2 0 ∈ imports.tables := by
      rw [← List.getElem_eq_getD 0]; exact List.getElem_mem (by rw [links.1]; decide)
    change tables.getD (imports.tables.getD 2 0) default ∈ tables
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (links.2.1 _ im)
  have qm : source.typeQuery ∈ bank.queries := (links.2.2.2.1 source sm).2.2.1
  have em : SignatureMatrix.indexEntry row ∈ bank.entries := by
    change SignatureMatrix.indexEntry row ∈ (ImportMatrix.table tables imports 2).entries
    rw [links.2.2.1]; exact List.mem_map.mpr ⟨row,member,rfl⟩
  exact (ReadOnlySound.checked_expected matrix bank (List.all_eq_true.mp tableChecks _ bm) values one satisfied
    source.typeQuery (SignatureMatrix.indexEntry row) qm em qa active same).symm

theorem defined_index {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (checked : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : SignatureMatrix.MetadataRow) (member : row ∈ signature.metadata) (active : E values row.entry.active = 1)
    (source : FunctionRow) (sm : source ∈ declaration.functions) (sa : E values source.active = 1)
    (same : E values row.entry.address = E values source.query.address) :
    E values row.typeIndex = E values source.query.value := by
  have sig := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1)
  have declarationCheck := (Bool.and_eq_true_iff.mp sig.1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp declarationCheck).1).1).2
  have dec := (Bool.and_eq_true_iff.mp declarationCheck).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at dec
  have linkCheck : DeclarationMatrix.checkLinks tables declaration = true := by grind only
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp linkCheck).1
  have functions : checkFunctions matrix body.tokens declaration.firstFunction declaration.functions 0 declaration.functionStart o z = true := by grind only
  obtain ⟨i,c,p,n,fc⟩ := DeclarationBinding.function_member matrix body.tokens declaration.firstFunction declaration.functions 0 declaration.functionStart o z functions source sm
  have qa := (_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp fc).1).2.1
  have sigChecks := sig.2
  simp only [SignatureMatrix.check,Bool.and_eq_true_iff] at sigChecks
  have sl := _root_.of_decide_eq_true sigChecks.2
  let bank := DeclarationMatrix.table tables declaration 5
  have bm : bank ∈ tables := by
    have im : declaration.tables.getD 5 0 ∈ declaration.tables := by
      rw [← List.getElem_eq_getD 0]; exact List.getElem_mem (by rw [links.1]; decide)
    change tables.getD (declaration.tables.getD 5 0) default ∈ tables
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (links.2.1 _ im)
  have qs : bank.queries = declaration.functions.map FunctionRow.query := by grind only
  have es : bank.entries = signature.metadata.map SignatureMatrix.indexEntry := by grind only
  have qm : source.query ∈ bank.queries := by rw [qs]; exact List.mem_map.mpr ⟨source,sm,rfl⟩
  have em : SignatureMatrix.indexEntry row ∈ bank.entries := by rw [es]; exact List.mem_map.mpr ⟨row,member,rfl⟩
  exact (ReadOnlySound.checked_expected matrix bank (List.all_eq_true.mp tableChecks _ bm) values one satisfied
    source.query (SignatureMatrix.indexEntry row) qm em (by rw [qa]; exact sa) active same).symm

/-- Every active even metadata key comes from an imported or defined function,
    and its type-index field equals that exact declaration's checked read. -/
theorem origin {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : SignatureMatrix.MetadataRow) (member : row ∈ signature.metadata) (key : Fin (2^32))
    (active : E values row.entry.active = 1) (address : E values row.entry.address = ((2*key.val : Nat) : F)) :
    Origin values declaration imports row key.val := by
  have sig := (Bool.and_eq_true_iff.mp checked).1
  have namespaceCheck := (Bool.and_eq_true_iff.mp sig).2
  have declarationCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp sig).1).1).1
  obtain ⟨defined,imported,total,db,ib,tb,partition,di,ii,ti⟩ :=
    SignatureFunctionComplete.namespace_partition matrix body tables splits declaration indexed signature space sig values one satisfied
  obtain ⟨total',tb',ti',bounded⟩ := SignatureBoundary.namespace_functions matrix body tables splits declaration indexed signature space sig values one satisfied
  have totalSame := DeclarationLocations.natural_equal (F := F) total' total (by omega) (by omega) (ti'.symm.trans ti)
  have kb : key.val < total := by
    have b := bounded row member active key.val (by have := key.isLt; omega) address
    omega
  obtain ⟨first,firstBound,firstImage,firstImported⟩ := SignatureBoundary.first_function matrix space declaration signature namespaceCheck values one satisfied
  have firstSame := DeclarationLocations.natural_equal (F := F) first imported (by omega) (by omega) (firstImported.symm.trans ii)
  subst first
  by_cases importedKey : key.val < imported
  · obtain ⟨count,cb,ci,covered⟩ := ImportCoverage.checked_coverage matrix body tables splits declaration indexed signature space imports checked values one satisfied
    have imp := (Bool.and_eq_true_iff.mp checked).2
    simp only [ImportMatrix.check,Bool.and_eq_true_iff] at imp
    have alias := (_root_.of_decide_eq_true imp.1.1).2.1
    have countSame := DeclarationLocations.natural_equal (F := F) count imported (by omega) (by omega) (ci.symm.trans (by rw [alias]; exact ii))
    obtain ⟨source,sm,sa,sk,qa,qk⟩ := covered key.val (by omega)
    exact Or.inr ⟨source,sm,sa,sk,qa,qk,imported_index matrix body tables splits declaration indexed signature space imports checked
      values one satisfied row member active source sm qa (address.trans qk.symm)⟩
  · obtain ⟨count,cb,ci,capacity,covered⟩ := DeclarationFunctionCoverage.checked_functions matrix body tables splits declaration declarationCheck values one satisfied
    have countSame := DeclarationLocations.natural_equal (F := F) count defined (by omega) (by omega) (ci.symm.trans di)
    have ordinalBound : key.val-imported < count := by omega
    obtain ⟨sm,sa⟩ := covered (key.val-imported) ordinalBound
    obtain ⟨first,fb,ob,fi,qk⟩ := SignatureBoundary.source_index_at matrix body tables splits declaration indexed signature space sig values one satisfied
      (key.val-imported) (by omega) sa
    have same := DeclarationLocations.natural_equal (F := F) first imported (by omega) (by omega) (fi.symm.trans firstImage)
    have keySame : first+(key.val-imported) = key.val := by omega
    rw [keySame] at qk
    exact Or.inl ⟨imported,key.val-imported,by omega,by omega,firstImage,sa,qk,
      defined_index matrix body tables splits declaration indexed signature space sig values one satisfied row member active _ sm sa (address.trans qk.symm)⟩

#print axioms imported_index
#print axioms defined_index
#print axioms origin
end ZkBuild.FunctionMetadataOrigin
