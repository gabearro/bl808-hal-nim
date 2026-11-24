import ImportMatrix

set_option autoImplicit false

namespace ZkBuild.ImportAuditIO
open CircuitShape AuditIO ReadOnlyAuditIO IndexedAuditIO TokenAuditIO ImportMatrix

def readImport (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let [tag,rows,cs,ce] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid import header")
  let rows ← number rows
  if tag != "I" || rows > 65536 then throw (IO.userError "invalid import dimensions")
  let btag::indices := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing import tables")
  if btag != "B" || indices.length != 7 then throw (IO.userError "invalid import tables")
  let indices ← indices.mapM number
  let (exports,cache) ← linear file wires cache
  let (functions,cache) ← linear file wires cache
  let (tables,cache) ← linear file wires cache
  let (memories,cache) ← linear file wires cache
  let (globals,cache) ← linear file wires cache
  let mut cache := cache
  let mut records := []
  for _ in [:rows] do
    let [tag,fg,lg,tz,lh,z0,z1,z2,z3] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid import row")
    if tag != "J" then throw (IO.userError "invalid import row tag")
    let (active,next) ← linear file wires cache
    let (kind,next) ← linear file wires next
    let (objectIndex,next) ← linear file wires next
    let (kindRange,next) ← readUse file wires next
    let (objectRange,next) ← readUse file wires next
    cache := next
    let mut fields := []
    for _ in [:8] do
      let (value,next) ← linear file wires cache
      fields := value::fields
      cache := next
    fields := fields.reverse
    let (typeQuery,next) ← readEntry file wires cache
    let (objectQuery,next) ← readEntry file wires next
    let (limits,next) ← readEntries file wires 4 next
    cache := next
    let mut names := []
    for _ in [:2] do
      let [tag,heads] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid import name")
      if tag != "H" then throw (IO.userError "invalid import name tag")
      let (query,next) ← readEntry file wires cache
      let (cursor,next) ← linear file wires next
      cache := next
      names := (⟨← number heads,query,cursor⟩ : NameUse)::names
    let mut reads := []
    for _ in [:7] do
      let [tag,token] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid import read")
      if tag != "E" then throw (IO.userError "invalid import read tag")
      let (cursor,next) ← linear file wires cache
      cache := next
      reads := (⟨← number token,cursor⟩ : Read)::reads
    records := (⟨← number fg,← number lg,← number tz,← number lh,← [z0,z1,z2,z3].mapM number,
      active,kind,objectIndex,kindRange,objectRange,fields.take 4,fields.drop 4,typeQuery,objectQuery,limits,names.reverse,reads.reverse⟩ : Row)::records
  return (⟨← number cs,← number ce,indices,exports,functions,tables,memories,globals,records.reverse⟩,cache)
end ZkBuild.ImportAuditIO
