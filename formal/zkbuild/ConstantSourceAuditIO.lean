import ConstantSourceMatrix
set_option autoImplicit false
namespace ZkBuild.ConstantSourceAuditIO
open CircuitShape AuditIO ConstantSourceMatrix
def readConstantSources (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (List Record × Std.HashMap String Int) := do
  let [tag,count] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid constant source header")
  let count ← number count
  if tag != "C" || count > 1048576 then throw (IO.userError "invalid constant source count")
  let mut result := []
  let mut cache := cache
  for _ in [:count] do
    let tag::first::last::heads::starts := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid constant source record")
    if tag != "K" || starts.length != 8 then throw (IO.userError "invalid constant source selectors")
    let mut fields := []
    for _ in [:26] do
      let (value,next) ← linear file wires cache
      cache := next
      fields := value::fields
    fields := fields.reverse
    let mut reads := []
    for _ in [:6] do
      let [tag,index] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid constant source read")
      if tag != "R" then throw (IO.userError "invalid constant source read tag")
      let (cursor,next) ← linear file wires cache
      cache := next
      reads := (⟨← number index,cursor⟩ : Read)::reads
    result := (⟨← number first,← number last,← number heads,← starts.mapM number,fields.take 18,fields.drop 18,reads.reverse⟩ : Record)::result
  return (result.reverse,cache)
end ZkBuild.ConstantSourceAuditIO
