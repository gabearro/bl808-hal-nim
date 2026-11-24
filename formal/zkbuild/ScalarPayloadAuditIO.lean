import ScalarPayloadMatrix
set_option autoImplicit false
namespace ZkBuild.ScalarPayloadAuditIO
open CircuitShape AuditIO ReadOnlyAuditIO TokenAuditIO ScalarPayloadMatrix
def readScalarPayload (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let tag::header := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing scalar payload")
  if tag != "P" || header.length != 12 then throw (IO.userError "invalid scalar payload header")
  let counts ← (header.take 4).mapM number
  if counts.any (· > 1048576) then throw (IO.userError "invalid scalar payload dimensions")
  let ends ← (header.drop 4).mapM number
  let mut allRows := []
  let mut cache := cache
  for kind in [:4] do
    let mut rows := []
    for _ in [:counts.getD kind 0] do
      let [tag,first,last,zero,constant,heads] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid scalar payload row")
      if tag != "L" then throw (IO.userError "invalid scalar payload tag")
      let (active,next) ← linear file wires cache
      let (objectQuery,next) ← readEntry file wires next
      cache := next
      let mut fields := []
      let mut name : ImportMatrix.NameUse := default
      if kind == 3 then
        let (a,next) ← linear file wires cache
        let (b,next) ← linear file wires next
        let [tag,heads] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid export name")
        if tag != "H" then throw (IO.userError "invalid export name tag")
        let (query,next) ← readEntry file wires next
        let (cursor,next) ← linear file wires next
        name := ⟨← number heads,query,cursor⟩
        fields := [a,b]
        cache := next
      let mut range : RangeUse.Record := default
      if kind == 2 then
        let (r,next) ← readUse file wires cache
        range := r
        cache := next
      let mut limits := []
      if kind < 2 then
        let (ls,next) ← IndexedAuditIO.readEntries file wires 4 cache
        limits := ls
        cache := next
      let mut reads := []
      let count := if kind == 0 then 4 else if kind == 1 then 3 else 2
      for _ in [:count] do
        let [tag,index] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid payload read")
        if tag != "R" then throw (IO.userError "invalid payload read tag")
        let (cursor,next) ← linear file wires cache
        cache := next
        reads := (⟨← number index,cursor⟩ : ImportMatrix.Read)::reads
      rows := (⟨← number first,← number last,← number zero,← number constant,← number heads,
        active,objectQuery,fields,range,name,limits,reads.reverse⟩ : Row)::rows
    allRows := rows.reverse::allRows
  return (⟨allRows.reverse,[ends.getD 0 0,ends.getD 2 0,ends.getD 4 0,ends.getD 6 0],
    [ends.getD 1 0,ends.getD 3 0,ends.getD 5 0,ends.getD 7 0]⟩,cache)
end ZkBuild.ScalarPayloadAuditIO
