import OwnedMatrix

set_option autoImplicit false

namespace ZkBuild.OwnedAuditIO
open CircuitShape AuditIO ReadOnlyAuditIO TokenAuditIO OwnedMatrix

def readOwned (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let [tag,parents,children,cs,ce] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid owned stream header")
  let parents ← number parents
  let children ← number children
  if tag != "O" || parents > 1048576 || children > 1048576 then throw (IO.userError "invalid owned dimensions")
  let [tag,t0,t1] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid owned tables")
  if tag != "B" then throw (IO.userError "invalid owned table tag")
  let mut cache := cache
  let mut ps := []
  let mut cs_ := []
  for _ in [:parents] do
    let [tag,fg,lg,zero] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid owned parent")
    if tag != "P" then throw (IO.userError "invalid owned parent tag")
    let mut fields := []
    let mut ranges := []
    for _ in [:4] do
      let (value,next) ← linear file wires cache
      fields := value::fields
      cache := next
    for _ in [:3] do
      let (value,next) ← readUse file wires cache
      ranges := value::ranges
      cache := next
    ps := (⟨← number fg,← number lg,← number zero,fields.reverse,ranges.reverse⟩ : Parent)::ps
  for i in [:children] do
    let [tag,fg,lg,heads,prior,next] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid owned child")
    if tag != "C" then throw (IO.userError "invalid owned child tag")
    let mut fields := []
    let mut ranges := []
    for _ in [:5] do
      let (value,next) ← linear file wires cache
      fields := value::fields
      cache := next
    for _ in [:4] do
      let (value,next) ← readUse file wires cache
      ranges := value::ranges
      cache := next
    let (countQuery,nextCache) ← readEntry file wires cache
    let (spanQuery,nextCache) ← readEntry file wires nextCache
    let (within,nextCache) ← linear file wires nextCache
    let (order,nextCache) ← linear file wires nextCache
    let (same,nextCache) ← linear file wires nextCache
    let (continues,nextCache) ← linear file wires nextCache
    let (withinRange,nextCache) ← readUse file wires nextCache
    let (orderRange,nextCache) ← if i = 0 then pure (default,nextCache) else readUse file wires nextCache
    cache := nextCache
    cs_ := (⟨← number fg,← number lg,← number heads,← number prior,← number next,
      fields.reverse,ranges.reverse,countQuery,spanQuery,within,order,same,continues,withinRange,orderRange⟩ : Child)::cs_
  return (⟨← number cs,← number ce,[← number t0,← number t1],ps.reverse,cs_.reverse⟩,cache)
end ZkBuild.OwnedAuditIO
