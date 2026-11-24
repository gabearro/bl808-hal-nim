import ScalarPayloadSoundness
import OwnedSoundness
import SignatureNodes
import SignatureFunctionComplete
import DeclarationFunctionCoverage
import PackedAuditIO
set_option autoImplicit false

open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.ModuleAuditIO ZkBuild.ReadOnlyAuditIO ZkBuild.PackedAuditIO ZkBuild.DeclarationAuditIO ZkBuild.IndexedAuditIO ZkBuild.SignatureAuditIO ZkBuild.ImportAuditIO ZkBuild.OwnedAuditIO ZkBuild.NameFrameAuditIO ZkBuild.NameGraphAuditIO ZkBuild.NameSourceAuditIO ZkBuild.ConstantSourceAuditIO ZkBuild.ScalarPayloadAuditIO

def main (args : List String) : IO Unit := do
  let (path,cases) ← match args with
    | [path] => pure (path,none)
    | [path,"--payload-cases",manifest] => pure (path,some manifest)
    | _ => throw (IO.userError "usage: check_scalar_payload AUDIT [--payload-cases MANIFEST]")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,queries,tokens,tables,fields,owned] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid scalar payload audit header")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let queries ← number queries
  let tokens ← number tokens
  let tables ← number tables
  let fields ← number fields
  let owned ← number owned
  if magic != "ZKSCALARPAYLOAD1" || owned > 65536 || wires = 0 || publicCount != 2 || wires > 16777216 || gates > 16777216 || queries > 1048576 || tokens > 1048576 || tables > 65536 || fields > 1048576 then throw (IO.userError "invalid scalar payload audit dimensions")
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
  let (imports,next) ← readImport file wires next
  cache := next
  let mut streams := []
  for _ in [:owned] do
    let (stream,next) ← readOwned file wires cache
    streams := stream::streams
    cache := next
  let (names,nextCache) ← readNameFrame file wires cache
  let (graph,sourceCache) ← readNameGraph file wires nextCache
  let (source,constantCache) ← readNameSource file wires sourceCache
  let (constants,payloadCache) ← readConstantSources file wires constantCache
  let (payload,_) ← readScalarPayload file wires payloadCache
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
  for i in [:streams.length] do
    if !OwnedMatrix.check matrix records.reverse packed.reverse streams[i]! then
      throw (IO.userError s!"owned stream {i} rejected")
  if !NameFrameMatrix.check matrix body.tokens records.reverse imports streams.reverse names then
    throw (IO.userError "name framing rejected")
  if !NameGraphMatrix.check matrix records.reverse graph then
    throw (IO.userError "name graph rejected")
  if !NameSourceMatrix.check matrix body.tokens records.reverse names graph source then
    throw (IO.userError "name source linkage rejected")
  for i in [:constants.length] do
    if !ConstantSourceMatrix.check matrix body.tokens packed.reverse constants[i]! then
      if !decide (ConstantSourceMatrix.shape body.tokens packed.reverse constants[i]!) then
        throw (IO.userError s!"constant source {i} interface rejected")
      let row := constants[i]!
      let parts := ConstantSourceMatrix.parts body.tokens packed.reverse row
      let mut offset := row.firstGate
      for j in [:parts.length] do
        let part := parts[j]!
        if !MemoryEvidence.checkSpan matrix offset (offset+part.length) part then
          throw (IO.userError s!"constant source {i} part {j} rejected at gate {offset}")
        offset := offset+part.length
      throw (IO.userError s!"constant source {i} rejected")
  if !ScalarPayloadMatrix.check matrix body records.reverse packed.reverse imports constants payload then
    if !decide (ScalarPayloadMatrix.links records.reverse imports payload) then
      throw (IO.userError "scalar payload interfaces rejected")
    for kind in [:4] do
      let mut start := ScalarPayloadMatrix.start body kind
      let mut previous := DeclarationMatrix.o
      let rows := ScalarPayloadMatrix.getRows payload kind
      for i in [:rows.length] do
        let row := rows[i]!
        if !ScalarPayloadMatrix.checkRow matrix body.tokens packed.reverse imports constants kind row i start previous then
          if !decide (ScalarPayloadMatrix.shape body.tokens packed.reverse constants kind row start) then
            throw (IO.userError s!"scalar payload {kind} row {i} shape rejected")
          let gates := ScalarPayloadMatrix.rowGates body.tokens packed.reverse imports constants kind row i start previous
          for j in [:gates.length] do
            if row.firstGate+j < matrix.gates.size && normalizeGate matrix.gates[row.firstGate+j]! != normalizeGate gates[j]! then
              throw (IO.userError s!"scalar payload {kind} row {i} gate {j}: actual={reprStr (normalizeGate matrix.gates[row.firstGate+j]!)} expected={reprStr (normalizeGate gates[j]!)}")
          throw (IO.userError s!"scalar payload {kind} row {i} range/span rejected")
        start := ScalarPayloadMatrix.rowEnd constants kind row
        previous := row.active
      if !MemoryEvidence.checkSpan matrix (payload.closeStarts.getD kind 0) (payload.closeEnds.getD kind 0) (ScalarPayloadMatrix.closeGates body constants payload kind) then
        throw (IO.userError s!"scalar payload {kind} closing rejected")
    throw (IO.userError "scalar payload rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing scalar payload audit data")
  IO.println s!"scalar payload PASS: constants={constants.length} matrix={gates} metadata={signature.metadata.length} streams={streams.length}"
  if let some manifest := cases then
    for line in (← IO.FS.readFile manifest).splitOn "\n" do
      let path := line.trimAscii.toString
      if !path.isEmpty then
        let accepted ← try
          let f ← IO.FS.Handle.mk path .read
          let (candidate,_) ← readScalarPayload f wires cache
          let complete := (← f.getLine) == ""
          pure (complete && ScalarPayloadMatrix.check matrix body records.reverse packed.reverse imports constants candidate)
        catch _ => pure false
        IO.println s!"{if accepted then "ACCEPT" else "REJECT"} {path}"
