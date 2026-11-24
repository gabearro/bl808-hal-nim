import OwnedAuditIO
set_option autoImplicit false
namespace ZkBuild.OwnedSound
open CircuitShape DeclarationMatrix

def fragmentCheck (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (splits : Splits) (records : List OwnedMatrix.Record) : Bool :=
  tables.all (ReadOnlyMatrix.check matrix) && splits.all (PackedFields.check matrix) && records.all (OwnedMatrix.check matrix tables splits)
def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (records : List OwnedMatrix.Record) : Bool :=
  ImportSound.check matrix body tables splits declaration indexed signature space imports && records.all (OwnedMatrix.check matrix tables splits)
end ZkBuild.OwnedSound
