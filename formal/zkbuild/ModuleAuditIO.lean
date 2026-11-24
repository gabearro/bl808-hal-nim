import EnvelopeAuditIO

namespace ZkBuild.ModuleAuditIO
open CircuitShape AuditIO TokenAuditIO EnvelopeAuditIO

structure SourceEnvelope where
  source : BinarySourceEmbedded.Record
  hash : ShaEmbedded.Record
  memory : MemoryEmbedded.Record
  queries : List BinarySourceMatrix.Entry
  tokens : List BinaryTokenMatrix.Record
  envelope : EnvelopeMatrix.Record

def readBody (file : IO.FS.Handle) (wires queries tokens : Nat) (cache : Std.HashMap String Int) :
    IO (SourceEnvelope × Std.HashMap String Int) := do
  let (source,cache) ← readSource file wires cache
  let (hash,cache) ← readHash file wires cache
  let (memory,cache) ← readMemory file wires cache
  let mut cache := cache
  let mut inputs := []
  for _ in [:queries] do
    let (active,next) ← linear file wires cache
    let (address,next) ← linear file wires next
    let (value,next) ← linear file wires next
    cache := next
    inputs := ⟨active,address,value⟩::inputs
  let mut readers := []
  for _ in [:tokens] do
    let (reader,next) ← readToken file wires cache
    cache := next
    readers := reader::readers
  let (envelope,finalCache) ← readEnvelope file wires cache
  return (⟨source,hash,memory,inputs.reverse,readers.reverse,envelope⟩,finalCache)
end ZkBuild.ModuleAuditIO
