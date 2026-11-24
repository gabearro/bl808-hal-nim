import LocalRangeMatrix
import SourceProgramIO
set_option autoImplicit false
namespace ZkBuild.BodySourceAuditIO
open CircuitShape AuditIO ModuleContextAuditIO SourceProgramIO

def readBanks (file : IO.FS.Handle) : IO (List Nat) := do
  let tag::fields := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing body tables")
  let fields ← fields.mapM number
  if tag != "T" || fields.length != fields.getD 0 0+1 || fields.length > 8 then throw (IO.userError "invalid body tables")
  pure (fields.drop 1)
def entries (rows : List (List Linear)) : IO (List ReadOnlyMatrix.Entry) := do
  if rows.any (fun row => row.length != 3) then throw (IO.userError "invalid local entry")
  pure (rows.map fun row => ⟨DeclarationMatrix.get row 0,DeclarationMatrix.get row 1,DeclarationMatrix.get row 2⟩)

def readBodySource (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (BodySourceMatrix.Record × Std.HashMap String Int) := do
  let [tag,flat,count] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid code source header")
  let flat ← number flat
  let count ← number count
  if tag != "Y" || flat > 1 || count > 1048576 then throw (IO.userError "invalid code source dimensions")
  let (firstFunction,cache) ← linear file wires cache
  let mut cache := cache
  let mut bodies := []
  for _ in [:count] do
    let (fields,next) ← readRows file wires cache
    if fields.length != 1 then throw (IO.userError "invalid body fields")
    let (locals,next) ← readRows file wires next
    bodies := (⟨fields.getD 0 [],locals⟩ : BodySourceMatrix.Body)::bodies
    cache := next
  let (locals,next) ← readRows file wires cache
  let (spans,next) ← readRows file wires next
  let banks ← readBanks file
  let (program,next) ← readProgram file wires next
  pure (⟨flat == 1,firstFunction,bodies.reverse,locals,spans,banks,program⟩,next)

def readLocalDeclaration (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (LocalDeclarationMatrix.Record × Std.HashMap String Int) := do
  if (← file.getLine).trimAscii.toString != "L" then throw (IO.userError "missing local declaration record")
  let (firstFunction,cache) ← linear file wires cache
  let (functionCount,cache) ← linear file wires cache
  let (ranges,cache) ← readRows file wires cache
  let (tags,cache) ← readRows file wires cache
  let (totals,cache) ← readRows file wires cache
  let banks ← readBanks file
  let (program,cache) ← readProgram file wires cache
  pure (⟨firstFunction,functionCount,← entries ranges,← entries tags,← entries totals,banks,program⟩,cache)

def readLocalRange (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (LocalRangeMatrix.Record × Std.HashMap String Int) := do
  if (← file.getLine).trimAscii.toString != "Z" then throw (IO.userError "missing local range record")
  let (locals,cache) ← readRows file wires cache
  let (ranges,cache) ← readRows file wires cache
  let (tags,cache) ← readRows file wires cache
  let (selected,cache) ← readRows file wires cache
  if selected.length != 1 then throw (IO.userError "invalid local range selections")
  let banks ← readBanks file
  let (program,cache) ← readProgram file wires cache
  pure (⟨← entries locals,← entries ranges,← entries tags,selected.getD 0 [],banks,program⟩,cache)
end ZkBuild.BodySourceAuditIO
