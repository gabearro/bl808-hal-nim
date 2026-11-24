import DeclarationMatrix
import ReadOnlyAuditIO
namespace ZkBuild.DeclarationAuditIO
open CircuitShape AuditIO TokenAuditIO ReadOnlyAuditIO DeclarationMatrix

def readLines (file : IO.FS.Handle) (wires count : Nat) (cache : Std.HashMap String Int) : IO (List Linear × Std.HashMap String Int) := do
  let mut cache := cache
  let mut values := []
  for _ in [:count] do
    let (value,next) ← linear file wires cache
    cache := next
    values := value::values
  return (values.reverse,cache)

def readType (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (TypeRow × Std.HashMap String Int) := do
  let [tag,fg,lg,header,param,result,heads] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid declaration type row")
  if tag != "Y" then throw (IO.userError "invalid declaration type tag")
  let (fields,cache) ← readLines file wires 7 cache
  let (counts,cache) ← readLines file wires 4 cache
  let mut cache := cache
  let mut ranges := []
  for _ in [:6] do
    let (range,next) ← readUse file wires cache
    cache := next
    ranges := range::ranges
  let (pp,next) ← linear file wires cache
  let (rp,next) ← linear file wires next
  let (remaining,next) ← linear file wires next
  let (range,next) ← readUse file wires next
  let (metadata,next) ← readEntry file wires next
  let (pl,next) ← readEntry file wires next
  let (rl,next) ← readEntry file wires next
  return (⟨← number fg,← number lg,fields,counts,ranges.reverse,← number header,← number param,← number result,← number heads,pp,rp,remaining,range,metadata,pl,rl⟩,next)

def readVector (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (VectorRow × Std.HashMap String Int) := do
  let [tag,fg,lg,tagZero,extended,key,span,heads,node,byteToken,order] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid declaration vector row")
  let order ← number order
  if tag != "V" || order > 1 then throw (IO.userError "invalid vector row tag")
  let (fields,cache) ← readLines file wires 3 cache
  let (location,cache) ← readEntry file wires cache
  let (metadata,cache) ← readEntry file wires cache
  let (memberQuery,cache) ← readEntry file wires cache
  let (ar,cache) ← readUse file wires cache
  let (vr,cache) ← readUse file wires cache
  let (orderRange,cache) ← if order = 1 then readUse file wires cache else pure (default,cache)
  let (withinRange,cache) ← readUse file wires cache
  let (delta,cache) ← linear file wires cache
  let (within,cache) ← linear file wires cache
  let (code,cache) ← linear file wires cache
  let (position,cache) ← linear file wires cache
  let (memberKey,cache) ← linear file wires cache
  let (count,cache) ← linear file wires cache
  return (⟨← number fg,← number lg,← number tagZero,← number extended,← number key,← number span,← number heads,← number node,← number byteToken,
    fields,location,metadata,memberQuery,ar,vr,orderRange,withinRange,order == 1,delta,within,code,position,memberKey,count⟩,cache)

def readFunction (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (FunctionRow × Std.HashMap String Int) := do
  let [tag,fg,lg,byteToken] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid function row")
  if tag != "F" then throw (IO.userError "invalid function row tag")
  let (active,cache) ← linear file wires cache
  let (cursor,cache) ← linear file wires cache
  let (count,cache) ← linear file wires cache
  let (query,cache) ← readEntry file wires cache
  return (⟨← number fg,← number lg,← number byteToken,active,cursor,count,query⟩,cache)

def readTag (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (TagRow × Std.HashMap String Int) := do
  let [tag,fg,lg,attr,index] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid tag row")
  if tag != "G" then throw (IO.userError "invalid tag row tag")
  let (active,cache) ← linear file wires cache
  let (typeIndex,cache) ← linear file wires cache
  let (position,cache) ← linear file wires cache
  let (cursor,cache) ← linear file wires cache
  return (⟨← number fg,← number lg,← number attr,← number index,active,typeIndex,position,cursor⟩,cache)

def readDeclaration (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (DeclarationMatrix.Record × Std.HashMap String Int) := do
  let [tag,types,params,results,functions,tags] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid declaration header")
  let types ← number types
  let params ← number params
  let results ← number results
  let functions ← number functions
  let tags ← number tags
  if tag != "C" || types > 65536 || params > 65536 || results > 65536 || functions > 65536 || tags > 65536 then throw (IO.userError "invalid declaration dimensions")
  let (first,cache) ← linear file wires cache
  let (ts,cache) ← linear file wires cache
  let (te,cache) ← linear file wires cache
  let (tc,cache) ← linear file wires cache
  let (fs,cache) ← linear file wires cache
  let (fe,cache) ← linear file wires cache
  let (fc,cache) ← linear file wires cache
  let (gs,cache) ← linear file wires cache
  let (ge,cache) ← linear file wires cache
  let [tag,tcs,tce,pcs,pce,rcs,rce,fcs,fce,gcs,gce] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid declaration close spans")
  if tag != "K" then throw (IO.userError "invalid close spans tag")
  let (pt,cache) ← linear file wires cache
  let (rt,cache) ← linear file wires cache
  let (pr,cache) ← readUse file wires cache
  let (rr,cache) ← readUse file wires cache
  let btag::indices := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing declaration table indices")
  if btag != "B" || indices.length != 6 then throw (IO.userError "invalid declaration table indices")
  let indices ← indices.mapM number
  let mut cache := cache
  let mut t := []
  let mut p := []
  let mut r := []
  let mut f := []
  let mut g := []
  for _ in [:types] do
    let (row,next) ← readType file wires cache
    cache := next
    t := row::t
  for _ in [:params] do
    let (row,next) ← readVector file wires cache
    cache := next
    p := row::p
  for _ in [:results] do
    let (row,next) ← readVector file wires cache
    cache := next
    r := row::r
  for _ in [:functions] do
    let (row,next) ← readFunction file wires cache
    cache := next
    f := row::f
  for _ in [:tags] do
    let (row,next) ← readTag file wires cache
    cache := next
    g := row::g
  return (⟨first,ts,te,tc,fs,fe,fc,gs,ge,t.reverse,p.reverse,r.reverse,f.reverse,g.reverse,indices,
    ← number tcs,← number tce,← number pcs,← number pce,← number rcs,← number rce,← number fcs,← number fce,← number gcs,← number gce,pt,rt,pr,rr⟩,cache)
end ZkBuild.DeclarationAuditIO
