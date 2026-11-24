import NameSourceAuditIO
set_option autoImplicit false
namespace ZkBuild.NameSourceSound
open CircuitShape DeclarationMatrix

def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (names : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record) : Bool :=
  NameGraphSound.check matrix body tables splits declaration indexed signature space imports owned names graph &&
    NameSourceMatrix.check matrix body.tokens tables names graph source
end ZkBuild.NameSourceSound
