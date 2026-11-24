import SignatureNamespace
import IndexedAuditIO

namespace ZkBuild.SignatureAuditIO
open CircuitShape AuditIO ReadOnlyAuditIO IndexedAuditIO TokenAuditIO SignatureMatrix

def readReference (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Reference × Std.HashMap String Int) := do
  let [tag,zero] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid signature reference")
  if tag != "R" then throw (IO.userError "invalid signature reference tag")
  let (query,cache) ← readEntry file wires cache
  return (⟨← number zero,query⟩,cache)

def readMetadata (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (MetadataRow × Std.HashMap String Int) := do
  let [tag,fg,lg,heads] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid signature metadata")
  if tag != "M" then throw (IO.userError "invalid signature metadata tag")
  let (entry,cache) ← readEntry file wires cache
  let (index,cache) ← linear file wires cache
  let (params,cache) ← readReference file wires cache
  let (results,cache) ← readReference file wires cache
  let (addressRange,cache) ← readUse file wires cache
  let (typeRange,cache) ← readUse file wires cache
  let (function,cache) ← linear file wires cache
  let (origin,cache) ← readEntry file wires cache
  return (⟨← number fg,← number lg,← number heads,entry,index,params,results,addressRange,typeRange,function,origin⟩,cache)

def readNode (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (NodeRow × Std.HashMap String Int) := do
  let [tag,fg,lg,node,zero] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid signature node")
  if tag != "N" then throw (IO.userError "invalid signature node tag")
  let (entry,cache) ← readEntry file wires cache
  let (delta,cache) ← linear file wires cache
  let (range,cache) ← readUse file wires cache
  let (reference,cache) ← readReference file wires cache
  return (⟨← number fg,← number lg,← number node,← number zero,entry,delta,range,reference⟩,cache)

def readSignature (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let [tag,metadata,nodes,extraMeta,extraNodes] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid signature header")
  let metadata ← number metadata
  let nodes ← number nodes
  let extraMeta ← number extraMeta
  let extraNodes ← number extraNodes
  if tag != "S" || metadata > 65536 || nodes > 1048576 || extraMeta > 1048576 || extraNodes > 1048576 then throw (IO.userError "invalid signature dimensions")
  let btag::indices := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing signature table indices")
  if btag != "B" || indices.length != 2 then throw (IO.userError "invalid signature table indices")
  let indices ← indices.mapM number
  let (em,cache) ← readEntries file wires extraMeta cache
  let (en,cache) ← readEntries file wires extraNodes cache
  let mut cache := cache
  let mut ms := []
  let mut ns := []
  for _ in [:metadata] do
    let (row,next) ← readMetadata file wires cache
    ms := row::ms
    cache := next
  for _ in [:nodes] do
    let (row,next) ← readNode file wires cache
    ns := row::ns
    cache := next
  return (⟨indices,em,en,ms.reverse,ns.reverse⟩,cache)

def readNamespace (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (SignatureNamespace.Record × Std.HashMap String Int) := do
  let [tag,rows,as_,ae,cs,ce,ts,te,fs,fe] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid signature namespace header")
  let rows ← number rows
  if tag != "D" || rows > 65536 then throw (IO.userError "invalid signature namespace dimensions")
  let (functions,cache) ← linear file wires cache
  let (types,cache) ← linear file wires cache
  let (imported,cache) ← linear file wires cache
  let (first,cache) ← linear file wires cache
  let (importedRange,cache) ← readUse file wires cache
  let mut cache := cache
  let mut records := []
  for _ in [:rows] do
    let [tag,fg,lg] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid namespace row")
    if tag != "Q" then throw (IO.userError "invalid namespace row tag")
    let (entry,next) ← readEntry file wires cache
    let (range,next) ← readUse file wires next
    let (isType,next) ← linear file wires next
    let (index,next) ← linear file wires next
    let (fc,next) ← linear file wires next
    let (tc,next) ← linear file wires next
    cache := next
    records := (⟨← number fg,← number lg,entry,range,isType,index,fc,tc⟩ : SignatureNamespace.Row)::records
  return (⟨← number as_,← number ae,← number cs,← number ce,← number ts,← number te,← number fs,← number fe,functions,types,imported,first,importedRange,records.reverse⟩,cache)
end ZkBuild.SignatureAuditIO
