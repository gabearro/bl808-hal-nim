import NameFrameAuditIO
set_option autoImplicit false
namespace ZkBuild.NameFrameSound
open CircuitShape DeclarationMatrix

def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (names : NameFrameMatrix.Record) : Bool :=
  OwnedSound.check matrix body tables splits declaration indexed signature space imports owned &&
    NameFrameMatrix.check matrix body.tokens tables imports owned names
end ZkBuild.NameFrameSound
