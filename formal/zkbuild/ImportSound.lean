import ImportAuditIO
set_option autoImplicit false

namespace ZkBuild.ImportSound
open CircuitShape DeclarationMatrix
def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) : Bool :=
  SignatureSound.check matrix body tables splits declaration indexed signature space &&
    ImportMatrix.check matrix body tables splits signature space imports
end ZkBuild.ImportSound
