import InstructionStreamCheck
import LookupAuditIO
set_option autoImplicit false
namespace ZkBuild.InstructionSourceAuditIO
open CircuitShape AuditIO ModuleContextAuditIO SourceProgramIO

def header (file : IO.FS.Handle) (tag : String) (maximum : Nat) : IO Nat := do
  let [actual,value] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError s!"missing {tag}")
  let value ← number value
  if actual != tag || value > maximum then throw (IO.userError s!"invalid {tag}")
  pure value

def readInstructionSource (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (InstructionDecodeMatrix.Catalog × List InstructionDecodeMatrix.Record × InstructionStreamMatrix.Record × Std.HashMap String Int) := do
  let count ← header file "K" 1048576
  let mut catalog := []
  let mut cache := cache
  for _ in [:count] do
    let id ← header file "J" 1048576
    let (record,next) ← LookupAuditIO.readLookup file wires cache
    catalog := (id,record)::catalog
    cache := next
  let count ← header file "D" 1048576
  let mut decoders := []
  for _ in [:count] do
    let (fields,next) ← readRows file wires cache
    let (program,next) ← readProgram file wires next
    if fields.length != 3 then throw (IO.userError "invalid decoder fields")
    decoders := (⟨fields.getD 0 [],fields.getD 1 [],fields.getD 2 [],program⟩ : InstructionDecodeMatrix.Record)::decoders
    cache := next
  let [tag,flat,count] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing instruction stream")
  let flat ← number flat
  let count ← number count
  if tag != "I" || flat > 1 || count > 1048576 then throw (IO.userError "invalid instruction stream")
  let (firstFunction,next) ← linear file wires cache
  cache := next
  let tag::bodySizes := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing instruction body sizes")
  let bodySizes ← bodySizes.mapM number
  if tag != "B" || bodySizes.isEmpty || bodySizes.getD 0 0+1 != bodySizes.length then throw (IO.userError "invalid body sizes")
  let mut rows := []
  for _ in [:count] do
    let [tag,decoder,labels,catches] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing instruction row")
    if tag != "R" then throw (IO.userError "invalid instruction row")
    let (fields,next) ← readRows file wires cache
    if fields.length != 2 || (fields.getD 1 []).length != 1 then throw (IO.userError "invalid instruction fields")
    rows := (⟨fields.getD 0 [],(fields.getD 1 []).getD 0 [],← number decoder,← number labels,← number catches⟩ : InstructionStreamMatrix.Row)::rows
    cache := next
  let (spans,next) ← readRows file wires cache
  let (functions,next) ← readRows file wires next
  let (labels,next) ← readRows file wires next
  let (catches,next) ← readRows file wires next
  let (events,next) ← readRows file wires next
  let tag::banks := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing instruction banks")
  let banks ← banks.mapM number
  if tag != "T" || banks.isEmpty || banks.length != banks.getD 0 0+1 || banks.length > 17 then throw (IO.userError "invalid instruction banks")
  let (program,next) ← readProgram file wires next
  let (memory,next) ← readMemory file wires next
  pure (catalog.reverse,decoders.reverse,⟨flat == 1,firstFunction,bodySizes.drop 1,rows.reverse,← BodySourceAuditIO.entries spans,
    functions,labels,catches,events,banks.drop 1,program,memory⟩,next)
end ZkBuild.InstructionSourceAuditIO
