import ScalarPayloadAuditIO
set_option autoImplicit false
namespace ZkBuild.ScalarPayloadSound
open CircuitShape DeclarationMatrix
def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (payload : ScalarPayloadMatrix.Record) : Bool :=
  ConstantSourceSound.check matrix body tables splits declaration indexed signature space imports owned frame graph source constants &&
    ScalarPayloadMatrix.check matrix body tables splits imports constants payload
end ZkBuild.ScalarPayloadSound
