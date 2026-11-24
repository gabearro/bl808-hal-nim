import ModuleContextMatrix
import SegmentPayloadAuditIO
set_option autoImplicit false
namespace ZkBuild.ModuleContextAuditIO
open CircuitShape AuditIO ModuleProgram ModuleContextMatrix

def readFields (file : IO.FS.Handle) (wires count : Nat) (cache : Std.HashMap String Int) : IO (Fields × Std.HashMap String Int) := do
  let mut cache := cache
  let mut fields := []
  for _ in [:count] do
    let (value,next) ← linear file wires cache
    fields := value::fields
    cache := next
  pure (fields.reverse,cache)
def countLine (file : IO.FS.Handle) (tag : String) (limit : Nat := 1048576) : IO Nat := do
  let [actual,count] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError s!"invalid {tag} header")
  let count ← number count
  if actual != tag || count > limit then throw (IO.userError s!"invalid {tag} dimensions")
  pure count
def readRows (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (List Fields × Std.HashMap String Int) := do
  let count ← countLine file "A"
  let mut cache := cache
  let mut rows := []
  for _ in [:count] do
    -- Some rows are variable-length vectors (selected locals, instruction
    -- bodies), not fixed records. Their owning checker validates the shape.
    let width ← countLine file "D" 1048576
    let (row,next) ← readFields file wires width cache
    rows := row::rows
    cache := next
  pure (rows.reverse,cache)
def readPrimitive (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (GadgetAudit.Record × Std.HashMap String Int) := do
  let tag::fields := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing module primitive")
  if tag != "R" || fields.length != 9 then throw (IO.userError "invalid module primitive header")
  let ns ← fields.mapM number
  let kind := ns.getD 0 99
  let width := ns.getD 1 0
  let inputs := ns.getD 7 0
  let outputs := ns.getD 8 0
  if kind > 10 || width > 248 || inputs > 3 || outputs > 248 then throw (IO.userError "invalid module primitive dimensions")
  let (args,next) ← readFields file wires inputs cache
  let (results,next) ← readFields file wires outputs next
  pure (⟨kind,width,ns.getD 2 0,ns.getD 3 0,ns.getD 4 0,ns.getD 5 0,ns.getD 6 0,args,results⟩,next)
def readOperation (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (RangeUse.Record × Std.HashMap String Int) := do
  let [tag,reused] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid module operation")
  if tag != "U" || (reused != "0" && reused != "1") then throw (IO.userError "invalid module operation tag")
  let (call,next) ← readPrimitive file wires cache
  if reused == "1" then
    let (source,next) ← readPrimitive file wires next
    pure (⟨call,some source⟩,next)
  else pure (⟨call,none⟩,next)
def readModuleContext (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let tag::fields := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing module context")
  if tag != "M" || fields.length != 5 then throw (IO.userError "invalid module context header")
  let ns ← fields.mapM number
  if ns.getD 0 2 > 1 then throw (IO.userError "invalid module context mode")
  let (counts,cache) ← readFields file wires 14 cache
  let (memories,cache) ← readRows file wires cache
  let (tables,cache) ← readRows file wires cache
  let (globals,cache) ← readRows file wires cache
  let elementCount ← countLine file "E"
  let mut elements := []
  let mut elementCache := cache
  for _ in [:elementCount] do
    let (rows,next) ← readRows file wires elementCache
    if rows.length != 2 then throw (IO.userError "invalid element context")
    let (items,next) ← readRows file wires next
    elements := (⟨rows.getD 0 [],rows.getD 1 [],items⟩ : Element)::elements
    elementCache := next
  let (items,cache) ← readRows file wires elementCache
  let (datas,cache) ← readRows file wires cache
  let (exports,cache) ← readRows file wires cache
  let (unique,cache) ← readRows file wires cache
  let (bodies,cache) ← readRows file wires cache
  let (bulk,cache) ← readRows file wires cache
  let heads ← countLine file "H"
  let (heads,cache) ← readFields file wires heads cache
  let tag::banks := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing module banks")
  let banks ← banks.mapM number
  if tag != "T" || banks.head? != some 6 || banks.length != 7 then throw (IO.userError "invalid module banks")
  let count ← countLine file "P" 2
  let mut programs := []
  let mut cache := cache
  for _ in [:count] do
    let [tag,first,last,count] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid module program")
    let count ← number count
    if tag != "K" || count > 1048576 then throw (IO.userError "invalid module program dimensions")
    let mut ops := []
    for _ in [:count] do
      let (op,next) ← readOperation file wires cache
      ops := op::ops
      cache := next
    programs := (⟨← number first,← number last,ops.reverse⟩ : Program)::programs
  pure (⟨ns.getD 0 0 == 1,ns.getD 1 0,ns.getD 2 0,ns.getD 3 0,ns.getD 4 0,counts,memories,tables,globals,elements.reverse,items,datas,exports,unique,bodies,bulk,heads,banks.drop 1,programs.reverse⟩,cache)
end ZkBuild.ModuleContextAuditIO
