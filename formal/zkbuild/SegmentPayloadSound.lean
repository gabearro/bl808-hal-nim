import SegmentPayloadAuditIO
set_option autoImplicit false
namespace ZkBuild.SegmentPayloadSound
open CircuitShape DeclarationMatrix
def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (scalar : ScalarPayloadMatrix.Record) (segments : SegmentPayloadMatrix.Record) : Bool :=
  ScalarPayloadSound.check matrix body tables splits declaration indexed signature space imports owned frame graph source constants scalar &&
    SegmentPayloadMatrix.check matrix body tables splits owned imports frame scalar constants segments
end ZkBuild.SegmentPayloadSound
