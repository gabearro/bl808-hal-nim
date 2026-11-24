import SegmentPayloadMatrix
set_option autoImplicit false
namespace ZkBuild.SegmentPayloadAuditIO
open CircuitShape AuditIO TokenAuditIO ReadOnlyAuditIO SegmentPayloadMatrix

def numbers (file : IO.FS.Handle) (tag : String) (count : Nat) : IO (List Nat) := do
  let t::xs := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing segment indices")
  if t != tag || xs.length != count then throw (IO.userError "invalid segment indices")
  xs.mapM number

def readRow (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Row × Std.HashMap String Int) := do
  let [tag,first,last,heads,fields,zeros,ranges,constants,queries,reads] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid segment row")
  let fields ← number fields
  let zeros ← number zeros
  let ranges ← number ranges
  let constants ← number constants
  let queries ← number queries
  let reads ← number reads
  if tag != "B" || fields > 32 || zeros > 8 || ranges > 8 || constants > 1048576 || queries > 4 || reads > 8 then throw (IO.userError "invalid segment row dimensions")
  let mut fs := []
  let mut rs := []
  let mut qs := []
  let mut ds := []
  let mut cache := cache
  for _ in [:fields] do
    let (f,next) ← linear file wires cache
    fs := f::fs
    cache := next
  let zs ← numbers file "Z" zeros
  let cs ← numbers file "I" constants
  for _ in [:ranges] do
    let (r,next) ← readUse file wires cache
    rs := r::rs
    cache := next
  for _ in [:queries] do
    let (q,next) ← readEntry file wires cache
    qs := q::qs
    cache := next
  for _ in [:reads] do
    let [tag,token] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid segment reader")
    if tag != "R" then throw (IO.userError "invalid segment reader tag")
    let (cursor,next) ← linear file wires cache
    ds := (⟨← number token,cursor⟩ : ImportMatrix.Read)::ds
    cache := next
  return (⟨← number first,← number last,← number heads,fs.reverse,zs,rs.reverse,cs,qs.reverse,ds.reverse⟩,cache)

def readSegmentPayload (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (SegmentPayloadMatrix.Record × Std.HashMap String Int) := do
  let tag::xs := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing segment payload")
  if tag != "V" || xs.length != 13 then throw (IO.userError "invalid segment payload header")
  let ns ← xs.mapM number
  if ns.getD 0 2 > 1 || (ns.drop 3 |>.take 4).any (· > 1048576) then throw (IO.userError "invalid segment payload dimensions")
  let mut rows := []
  let mut cache := cache
  for count in (ns.drop 3).take 4 do
    let mut rs := []
    for _ in [:count] do
      let (r,next) ← readRow file wires cache
      rs := r::rs
      cache := next
    rows := rs.reverse::rows
  rows := rows.reverse
  let (tail,finalCache) ← readRow file wires cache
  return (⟨ns.getD 0 0 == 1,ns.getD 1 0,ns.getD 2 0,rows.getD 0 [],rows.getD 1 [],rows.getD 2 [],rows.getD 3 [],tail,
    [ns.getD 7 0,ns.getD 9 0,ns.getD 11 0],[ns.getD 8 0,ns.getD 10 0,ns.getD 12 0]⟩,finalCache)
end ZkBuild.SegmentPayloadAuditIO
