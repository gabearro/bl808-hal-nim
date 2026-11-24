import NameGraphMatrix
set_option autoImplicit false
namespace ZkBuild.NameGraphAuditIO
open CircuitShape AuditIO ReadOnlyAuditIO TokenAuditIO LookupAuditIO NameGraphMatrix

def readNameGraph (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let [tag,nodes,roots,t0,t1] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name graph header")
  let nodes ← number nodes
  let roots ← number roots
  if tag != "G" || nodes > 1048576 || roots > 1048576 then throw (IO.userError "invalid name graph dimensions")
  let mut cache := cache
  let mut ns := []
  let mut rs := []
  for _ in [:nodes] do
    let [tag,fg,lg,zero] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name node header")
    if tag != "J" then throw (IO.userError "invalid name node tag")
    let (entry,next) ← readEntry file wires cache
    let (query,next) ← readEntry file wires next
    let (canonical,next) ← readEntry file wires next
    cache := next
    let mut fields := []
    let mut ranges := []
    for _ in [:7] do
      let (value,next) ← linear file wires cache
      cache := next
      fields := value::fields
    for _ in [:3] do
      let (value,next) ← readUse file wires cache
      cache := next
      ranges := value::ranges
    let (lookup,next) ← readLookup file wires cache
    cache := next
    ns := (⟨← number fg,← number lg,← number zero,entry,query,canonical,fields.reverse,ranges.reverse,lookup⟩ : Node)::ns
  for _ in [:roots] do
    let [tag,fg,lg,zero] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name root header")
    if tag != "R" then throw (IO.userError "invalid name root tag")
    let (head,next) ← linear file wires cache
    let (state,next) ← linear file wires next
    let (query,next) ← readEntry file wires next
    cache := next
    let mut ranges := []
    for _ in [:2] do
      let (value,next) ← readUse file wires cache
      cache := next
      ranges := value::ranges
    rs := (⟨← number fg,← number lg,← number zero,head,state,query,ranges.reverse⟩ : Root)::rs
  return (⟨[← number t0,← number t1],ns.reverse,rs.reverse⟩,cache)
end ZkBuild.NameGraphAuditIO
