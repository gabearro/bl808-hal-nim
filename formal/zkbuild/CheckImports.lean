import ImportCoverage
import SignatureNodes
import SignatureFunctionComplete
import DeclarationFunctionCoverage
import PackedAuditIO
set_option autoImplicit false

open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.ModuleAuditIO ZkBuild.ReadOnlyAuditIO ZkBuild.PackedAuditIO ZkBuild.DeclarationAuditIO ZkBuild.IndexedAuditIO ZkBuild.SignatureAuditIO ZkBuild.ImportAuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_imports AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,queries,tokens,tables,fields] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid signature audit header")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let queries ← number queries
  let tokens ← number tokens
  let tables ← number tables
  let fields ← number fields
  if magic != "ZKIMPORTS1" || wires = 0 || publicCount != 2 || wires > 16777216 || gates > 16777216 || queries > 1048576 || tokens > 1048576 || tables > 65536 || fields > 1048576 then throw (IO.userError "invalid signature audit dimensions")
  let mut matrix : Shape := {wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates}
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := {matrix with gates := matrix.gates.push ⟨a,b,c⟩}
  let (body,next) ← readBody file wires queries tokens cache
  cache := next
  let mut records := []
  for _ in [:tables] do
    let (table,next) ← readTable file wires cache
    cache := next
    records := table::records
  let mut packed := []
  for _ in [:fields] do
    let (record,next) ← readPacked file wires cache
    cache := next
    packed := record::packed
  let (declaration,next) ← readDeclaration file wires cache
  let (indexed,next) ← readIndexed file wires next
  let (signature,next) ← readSignature file wires next
  let (space,next) ← readNamespace file wires next
  let (imports,_) ← readImport file wires next
  if !SignatureSound.check matrix body records.reverse packed.reverse declaration indexed signature space then
    throw (IO.userError "source signature prerequisite rejected")
  if !ImportMatrix.check matrix body records.reverse packed.reverse signature space imports then
    if !decide (ImportMatrix.links records.reverse signature imports) then
      throw (IO.userError "import table links rejected")
    let mut cursor := DeclarationMatrix.get body.envelope.outputs 10
    let mut counts := [DeclarationMatrix.z,DeclarationMatrix.z,DeclarationMatrix.z,DeclarationMatrix.z]
    let mut previous := DeclarationMatrix.o
    for i in [:imports.rows.length] do
      let row := imports.rows[i]!
      if !ImportMatrix.checkRow matrix body.tokens packed.reverse imports.exportCount row i cursor counts previous then
        if !decide (ImportMatrix.shape body.tokens packed.reverse row cursor) then
          throw (IO.userError s!"import row {i} shape rejected")
        let mut gate := row.firstGate
        let parts := ImportMatrix.rowParts body.tokens packed.reverse imports.exportCount row i cursor counts previous
        for j in [:parts.length] do
          let part := parts[j]!
          if !MemoryEvidence.checkSpan matrix gate (gate+part.length) part then
            for k in [:part.length] do
              if gate+k < matrix.gates.size && normalizeGate matrix.gates[gate+k]! != normalizeGate part[k]! then
                throw (IO.userError s!"import row {i} part {j} gate {gate+k}: actual={reprStr (normalizeGate matrix.gates[gate+k]!)} expected={reprStr (normalizeGate part[k]!)}")
            throw (IO.userError s!"import row {i} part {j} rejected at gate {gate}")
          gate := gate+part.length
        throw (IO.userError s!"import row {i} range or closing span rejected")
      cursor := (ImportMatrix.readAt row 6).cursor
      counts := row.counts
      previous := row.active
    let closing := ImportMatrix.closeGates body imports
    for k in [:closing.length] do
      if imports.closeStart+k < matrix.gates.size && normalizeGate matrix.gates[imports.closeStart+k]! != normalizeGate closing[k]! then
        throw (IO.userError s!"import closing gate {k}: actual={reprStr (normalizeGate matrix.gates[imports.closeStart+k]!)} expected={reprStr (normalizeGate closing[k]!)}")
    throw (IO.userError "import namespace totals rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing import audit data")
  IO.println s!"imports PASS: matrix={gates} metadata={signature.metadata.length} rows={imports.rows.length}"
