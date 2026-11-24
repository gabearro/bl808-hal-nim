import SegmentPayloadSoundness
import OwnedSoundness
import SignatureNodes
import SignatureFunctionComplete
import DeclarationFunctionCoverage
import PackedAuditIO
set_option autoImplicit false

open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.ModuleAuditIO ZkBuild.ReadOnlyAuditIO ZkBuild.PackedAuditIO ZkBuild.DeclarationAuditIO ZkBuild.IndexedAuditIO ZkBuild.SignatureAuditIO ZkBuild.ImportAuditIO ZkBuild.OwnedAuditIO ZkBuild.NameFrameAuditIO ZkBuild.NameGraphAuditIO ZkBuild.NameSourceAuditIO ZkBuild.ConstantSourceAuditIO ZkBuild.ScalarPayloadAuditIO ZkBuild.SegmentPayloadAuditIO

def main (args : List String) : IO Unit := do
  let (path,cases) ← match args with
    | [path] => pure (path,none)
    | [path,"--segment-cases",manifest] => pure (path,some manifest)
    | _ => throw (IO.userError "usage: check_segment_payload AUDIT [--segment-cases MANIFEST]")
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
  if magic != "ZKSEGMENTPAYLOAD1" || owned > 65536 || wires = 0 || publicCount != 2 || wires > 16777216 || gates > 16777216 || queries > 1048576 || tokens > 1048576 || tables > 65536 || fields > 1048576 then throw (IO.userError "invalid scalar payload audit dimensions")
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
  let (payload,segmentCache) ← readScalarPayload file wires payloadCache
  let (segments,_) ← readSegmentPayload file wires segmentCache
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
  if !SegmentPayloadMatrix.check matrix body records.reverse packed.reverse streams.reverse imports names payload constants segments then
    if !decide (SegmentPayloadMatrix.links body records.reverse streams.reverse imports names segments) then
      throw (IO.userError "segment links rejected")
    let mut cursor := SegmentPayloadMatrix.atStart body 9
    for i in [:segments.elements.length] do
      let row := segments.elements[i]!
      if !SegmentPayloadMatrix.checkElement matrix body.tokens packed.reverse constants segments.flat row cursor then
        if !decide (SegmentPayloadMatrix.elementShape body.tokens packed.reverse constants segments.flat row cursor) then
          let status := [row.fields.length == (if segments.flat then 14 else 11),row.zeros.length == 1,row.ranges.length == 1,row.reads.length == 4,
            decide (SegmentPayloadMatrix.readMatches body.tokens (SegmentPayloadMatrix.readAt row 0) 1 (SegmentPayloadMatrix.f row 0) cursor),
            decide (SegmentPayloadMatrix.readMatches body.tokens (SegmentPayloadMatrix.readAt row 1) 1 (SegmentPayloadMatrix.f row 2) (SegmentPayloadMatrix.readAt row 0).cursor),
            decide (SegmentPayloadMatrix.constLink constants row 0 (sub (SegmentPayloadMatrix.f row 0) (SegmentPayloadMatrix.bit row 0)) DeclarationMatrix.o (SegmentPayloadMatrix.readAt row 1).cursor),
            decide (SegmentPayloadMatrix.readMatches body.tokens (SegmentPayloadMatrix.readAt row 2) 0 (sub (SegmentPayloadMatrix.bit row 0 ++ SegmentPayloadMatrix.bit row 1) (SegmentPayloadMatrix.f row 6)) (SegmentPayloadMatrix.constEnd constants row 0)),
            decide (SegmentPayloadMatrix.readMatches body.tokens (SegmentPayloadMatrix.readAt row 3) 1 (SegmentPayloadMatrix.f row 0) (SegmentPayloadMatrix.readAt row 2).cursor)]
          throw (IO.userError s!"element row {i} interface rejected: {status}")
        let gates := SegmentPayloadMatrix.elementGates body.tokens packed.reverse constants segments.flat row cursor
        for j in [:gates.length] do
          if row.firstGate+j < matrix.gates.size && normalizeGate matrix.gates[row.firstGate+j]! != normalizeGate gates[j]! then
            throw (IO.userError s!"element row {i} gate {j}: actual={reprStr (normalizeGate matrix.gates[row.firstGate+j]!)} expected={reprStr (normalizeGate gates[j]!)}")
        throw (IO.userError s!"element row {i} range/span rejected")
      cursor := SegmentPayloadMatrix.elementEnd constants segments.flat row
    cursor := SegmentPayloadMatrix.atStart body 11
    for i in [:segments.datas.length] do
      let row := segments.datas[i]!
      if !SegmentPayloadMatrix.checkData matrix body.tokens packed.reverse constants row cursor (SegmentPayloadMatrix.atEnd body 11) then
        if !decide (SegmentPayloadMatrix.dataShape body.tokens constants row cursor) then
          throw (IO.userError s!"data row {i} interface rejected")
        let gates := SegmentPayloadMatrix.dataGates body.tokens packed.reverse constants row cursor (SegmentPayloadMatrix.atEnd body 11)
        for j in [:gates.length] do
          if row.firstGate+j < matrix.gates.size && normalizeGate matrix.gates[row.firstGate+j]! != normalizeGate gates[j]! then
            throw (IO.userError s!"data row {i} gate {j}: actual={reprStr (normalizeGate matrix.gates[row.firstGate+j]!)} expected={reprStr (normalizeGate gates[j]!)}")
        throw (IO.userError s!"data row {i} range/span rejected")
      cursor := SegmentPayloadMatrix.f row 7
    for i in [:segments.items.length] do
      if !SegmentPayloadMatrix.checkItem matrix body.tokens packed.reverse constants segments.items[i]! then
        throw (IO.userError s!"element item {i} rejected")
    let mut previous := DeclarationMatrix.z
    let base := imports.exportCount ++ CircuitShape.scale (ImportMatrix.total imports.rows) 2
    for i in [:segments.customs.length] do
      let row := segments.customs[i]!
      if !SegmentPayloadMatrix.checkCustom matrix packed.reverse row body.envelope.rows[i]! base previous then
        throw (IO.userError s!"custom row {i} rejected")
      previous := SegmentPayloadMatrix.f row 2
    for i in [:3] do
      if !MemoryEvidence.checkSpan matrix (segments.closeStarts.getD i 0) (segments.closeEnds.getD i 0) (SegmentPayloadMatrix.closeGates body constants segments i) then
        throw (IO.userError s!"segment closing {i} rejected")
    let tailGates := SegmentPayloadMatrix.tailGates imports names payload segments
    for j in [:tailGates.length] do
      if segments.tail.firstGate+j < matrix.gates.size && normalizeGate matrix.gates[segments.tail.firstGate+j]! != normalizeGate tailGates[j]! then
        throw (IO.userError s!"custom tail gate {j}: actual={reprStr (normalizeGate matrix.gates[segments.tail.firstGate+j]!)} expected={reprStr (normalizeGate tailGates[j]!)}")
    throw (IO.userError "custom section tail range/span rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing scalar payload audit data")
  IO.println s!"segment payload PASS: elements={segments.elements.length} items={segments.items.length} data={segments.datas.length} custom_slots={segments.customs.length} constants={constants.length} matrix={gates} metadata={signature.metadata.length} streams={streams.length}"
  if let some manifest := cases then
    for line in (← IO.FS.readFile manifest).splitOn "\n" do
      let path := line.trimAscii.toString
      if !path.isEmpty then
        let accepted ← try
          let f ← IO.FS.Handle.mk path .read
          let (candidate,_) ← readSegmentPayload f wires cache
          let complete := (← f.getLine) == ""
          pure (complete && SegmentPayloadMatrix.check matrix body records.reverse packed.reverse streams.reverse imports names payload constants candidate)
        catch _ => pure false
        IO.println s!"{if accepted then "ACCEPT" else "REJECT"} {path}"
