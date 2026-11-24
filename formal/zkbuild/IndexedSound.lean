import IndexedAuditIO

namespace ZkBuild.IndexedSound
open CircuitShape

def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (splits : DeclarationMatrix.Splits) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) : Bool :=
  DeclarationSound.check matrix body tables splits declaration && IndexedMatrix.check matrix splits tables declaration indexed

end ZkBuild.IndexedSound
