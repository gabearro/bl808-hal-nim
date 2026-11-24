import IndexedMatrix
import DeclarationAuditIO

namespace ZkBuild.IndexedAuditIO
open CircuitShape AuditIO ReadOnlyAuditIO IndexedMatrix

def readLength (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (LengthRow × Std.HashMap String Int) := do
  let [tag,fg,lg,hz,lz] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid indexed length row")
  if tag != "L" then throw (IO.userError "invalid indexed length tag")
  let (entry,cache) ← readEntry file wires cache
  let (nonempty,cache) ← linear file wires cache
  let (firstMember,cache) ← readEntry file wires cache
  return (⟨← number fg,← number lg,← number hz,← number lz,entry,nonempty,firstMember⟩,cache)

def readMember (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (MemberRow × Std.HashMap String Int) := do
  let [tag,fg,lg,a,c,n,hz,cz,tz,co] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid indexed member row")
  if tag != "M" then throw (IO.userError "invalid indexed member tag")
  let (entry,cache) ← readEntry file wires cache
  let (node,cache) ← readEntry file wires cache
  let (length,cache) ← readEntry file wires cache
  let (continuing,cache) ← linear file wires cache
  return (⟨← number fg,← number lg,← number a,← number c,← number n,← number hz,← number cz,← number tz,← number co,entry,node,length,continuing⟩,cache)

def readMetadata (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (MetadataRow × Std.HashMap String Int) := do
  let [tag,fg,lg,heads] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid indexed metadata row")
  if tag != "H" then throw (IO.userError "invalid indexed metadata tag")
  let (entry,cache) ← readEntry file wires cache
  let (params,cache) ← readEntry file wires cache
  let (results,cache) ← readEntry file wires cache
  return (⟨← number fg,← number lg,← number heads,entry,params,results⟩,cache)

def readSingleton (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (SingletonRow × Std.HashMap String Int) := do
  let [tag,fg,lg] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid indexed singleton row")
  if tag != "S" then throw (IO.userError "invalid indexed singleton tag")
  let (entry,cache) ← readEntry file wires cache
  let (node,cache) ← readEntry file wires cache
  return (⟨← number fg,← number lg,entry,node⟩,cache)

def readEntries (file : IO.FS.Handle) (wires count : Nat) (cache : Std.HashMap String Int) : IO (List ReadOnlyMatrix.Entry × Std.HashMap String Int) := do
  let mut cache := cache
  let mut entries := []
  for _ in [:count] do
    let (entry,next) ← readEntry file wires cache
    entries := entry::entries
    cache := next
  return (entries.reverse,cache)

def readIndexed (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let [tag,lengths,members,metadata,singletons] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid indexed header")
  let lengths ← number lengths
  let members ← number members
  let metadata ← number metadata
  let singletons ← number singletons
  if tag != "X" || lengths = 0 || lengths > 65536 || members > 1048576 || metadata > 65536 || singletons != 7 then
    throw (IO.userError "invalid indexed dimensions")
  let [tag,ns,ne] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid indexed nil span")
  if tag != "N" then throw (IO.userError "invalid indexed nil tag")
  let btag::indices := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing indexed tables")
  if btag != "B" || indices.length != 4 then throw (IO.userError "invalid indexed table indices")
  let indices ← indices.mapM number
  let [tag,el,em,es] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid indexed extra dimensions")
  let el ← number el
  let em ← number em
  let es ← number es
  if tag != "E" || el > 1048576 || em > 1048576 || es > 1048576 then throw (IO.userError "invalid indexed extra count")
  let (el,cache) ← readEntries file wires el cache
  let (em,cache) ← readEntries file wires em cache
  let (es,cache) ← readEntries file wires es cache
  let mut cache := cache
  let mut ls := []
  let mut ms := []
  let mut cs := []
  let mut hs := []
  let mut ss := []
  for _ in [:lengths] do
    let (row,next) ← readLength file wires cache
    cache := next
    ls := row::ls
  for _ in [:members] do
    let (row,next) ← readMember file wires cache
    cache := next
    ms := row::ms
  for _ in [:members] do
    let [tag,fg,lg] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid indexed close span")
    if tag != "J" then throw (IO.userError "invalid indexed close tag")
    cs := (⟨← number fg,← number lg⟩ : CloseRow)::cs
  for _ in [:metadata] do
    let (row,next) ← readMetadata file wires cache
    cache := next
    hs := row::hs
  for _ in [:singletons] do
    let (row,next) ← readSingleton file wires cache
    cache := next
    ss := row::ss
  return (⟨← number ns,← number ne,indices,el,em,es,ls.reverse,ms.reverse,cs.reverse,hs.reverse,ss.reverse⟩,cache)
end ZkBuild.IndexedAuditIO
