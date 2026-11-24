import NameSourceMatrix
set_option autoImplicit false
namespace ZkBuild.NameSourceAuditIO
open CircuitShape AuditIO ReadOnlyAuditIO TokenAuditIO NameSourceMatrix

def readNameSource (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let [tag,headers,bytes,ends,tables] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name source header")
  let headers ← number headers
  let bytes ← number bytes
  let ends ← number ends
  let tables ← number tables
  if tag != "S" || headers > 1048576 || bytes > 1048576 || ends > 1048576 || tables > 3 then throw (IO.userError "invalid name source dimensions")
  let tag::ts := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing name source tables")
  if tag != "B" || ts.length != tables then throw (IO.userError "invalid name source tables")
  let ts ← ts.mapM number
  let mut cache := cache
  let mut hs := []
  let mut bs := []
  let mut es := []
  for _ in [:headers] do
    let [tag,first,last,zero,nil] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name source root")
    if tag != "H" then throw (IO.userError "invalid name source root tag")
    let (head,next) ← linear file wires cache
    let (finish,next) ← linear file wires next
    cache := next
    hs := (⟨← number first,← number last,← number zero,← number nil,head,finish⟩ : Header)::hs
  for _ in [:bytes] do
    let [tag,first,last,zero,tail] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name source byte")
    if tag != "J" then throw (IO.userError "invalid name source byte tag")
    let (nodeQuery,next) ← readEntry file wires cache
    let (rootQuery,next) ← readEntry file wires next
    cache := next
    let mut fields := []
    for _ in [:3] do
      let (value,next) ← linear file wires cache
      cache := next
      fields := value::fields
    let (range,next) ← readUse file wires cache
    cache := next
    bs := (⟨← number first,← number last,← number zero,← number tail,nodeQuery,rootQuery,fields.reverse,range⟩ : ByteRow)::bs
  for _ in [:ends] do
    let [tag,first,last,zero] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name source ending")
    if tag != "E" then throw (IO.userError "invalid name source ending tag")
    let (tail,next) ← linear file wires cache
    let (selector,next) ← linear file wires next
    let (query,next) ← readEntry file wires next
    let (range,next) ← readUse file wires next
    cache := next
    es := (⟨← number first,← number last,← number zero,tail,selector,query,range⟩ : Ending)::es
  return (⟨ts,hs.reverse,bs.reverse,es.reverse⟩,cache)
end ZkBuild.NameSourceAuditIO
