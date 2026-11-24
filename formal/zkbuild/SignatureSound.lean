import SignatureAuditIO

namespace ZkBuild.SignatureSound
open CircuitShape
def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : DeclarationMatrix.Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record) : Bool :=
  IndexedSound.check matrix body tables splits declaration indexed && SignatureMatrix.check matrix splits tables declaration indexed signature &&
    SignatureNamespace.check matrix declaration signature space
end ZkBuild.SignatureSound
