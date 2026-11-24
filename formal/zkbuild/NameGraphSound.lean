import NameGraphAuditIO
set_option autoImplicit false
namespace ZkBuild.NameGraphSound
open CircuitShape DeclarationMatrix

def fragmentCheck (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (graphs : List NameGraphMatrix.Record) : Bool :=
  tables.all (ReadOnlyMatrix.check matrix) && graphs.all (NameGraphMatrix.check matrix tables)
def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (names : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) : Bool :=
  NameFrameSound.check matrix body tables splits declaration indexed signature space imports owned names &&
    NameGraphMatrix.check matrix tables graph
end ZkBuild.NameGraphSound
