import ConstantSourceAuditIO
set_option autoImplicit false
namespace ZkBuild.ConstantSourceSound
open CircuitShape DeclarationMatrix
def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) : Bool :=
  NameSourceSound.check matrix body tables splits declaration indexed signature space imports owned frame graph source &&
    constants.all (ConstantSourceMatrix.check matrix body.tokens splits)
end ZkBuild.ConstantSourceSound
