import NameFrameMatrix
set_option autoImplicit false
namespace ZkBuild.NameFrameAuditIO
open CircuitShape AuditIO ReadOnlyAuditIO TokenAuditIO NameFrameMatrix

def readNameFrame (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let [tag,flat,owned,headers,bytes] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name framing header")
  let flat ← number flat
  let headers ← number headers
  let bytes ← number bytes
  if tag != "N" || flat > 1 || headers > 1048576 || bytes > 1048576 then throw (IO.userError "invalid name framing dimensions")
  let mut cache := cache
  let mut hs := []
  let mut bs := []
  for _ in [:headers] do
    let [tag,fg,lg,tk,start,count,close] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name header")
    if tag != "H" then throw (IO.userError "invalid name header tag")
    let mut fields := []
    let mut ranges := []
    for _ in [:5] do
      let (value,next) ← linear file wires cache
      fields := value::fields
      cache := next
    if flat = 0 then
      for _ in [:2] do
        let (value,next) ← readUse file wires cache
        ranges := value::ranges
        cache := next
    hs := (⟨← number fg,← number lg,← number tk,← number start,← number count,← number close,fields.reverse,ranges.reverse⟩ : Header)::hs
  for _ in [:bytes] do
    let [tag,fg,lg,tk] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name byte")
    if tag != "Y" then throw (IO.userError "invalid name byte tag")
    let mut fields := []
    for _ in [:5] do
      let (value,next) ← linear file wires cache
      fields := value::fields
      cache := next
    bs := (⟨← number fg,← number lg,← number tk,fields.reverse⟩ : ByteRow)::bs
  return (⟨flat = 1,← number owned,hs.reverse,bs.reverse⟩,cache)
end ZkBuild.NameFrameAuditIO
