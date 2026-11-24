import SegmentPayloadSoundness
import BodySourceSound
import OwnedSoundness
import SignatureNodes
import SignatureFunctionComplete
import DeclarationFunctionCoverage
import PackedAuditIO
import InstructionSourceAuditIO
import ValidationEventAuditIO
import DynamicTypingAuditIO
import StructuredAuditIO
set_option autoImplicit false

open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.ModuleAuditIO ZkBuild.ReadOnlyAuditIO ZkBuild.PackedAuditIO ZkBuild.DeclarationAuditIO ZkBuild.IndexedAuditIO ZkBuild.SignatureAuditIO ZkBuild.ImportAuditIO ZkBuild.OwnedAuditIO ZkBuild.NameFrameAuditIO ZkBuild.NameGraphAuditIO ZkBuild.NameSourceAuditIO ZkBuild.ConstantSourceAuditIO ZkBuild.ScalarPayloadAuditIO ZkBuild.SegmentPayloadAuditIO ZkBuild.ModuleContextAuditIO ZkBuild.BodySourceAuditIO

def checkOne (args : List String) (known : IO.Ref (List (List InstructionDecodeMatrix.TableView))) : IO Unit := do
  let (path,suffix,cases) ← match args with
    | [path] => pure (path,none,none)
    | [path,"--control-cases",manifest] => pure (path,none,some manifest)
    | [path,"--control",suffix] => pure (path,some suffix,none)
    | [path,"--control",suffix,"--control-cases",manifest] => pure (path,some suffix,some manifest)
    | _ => throw (IO.userError "usage: check_structured_control AUDIT [--control SUFFIX] [--control-cases MANIFEST]")
  let tracing := (← IO.getEnv "ZKBUILD_AUDIT_TRACE").isSome
  let trace := fun (message : String) => if tracing then IO.eprintln message else pure ()
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,queries,tokens,tables,fields,owned] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid validation-event audit header")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let queries ← number queries
  let tokens ← number tokens
  let tables ← number tables
  let fields ← number fields
  let owned ← number owned
  if (magic != "ZKSTRUCTURED1" && !((magic == "ZKVALIDATIONEVENT1" || magic == "ZKDYNAMICTYPING1") && suffix.isSome)) || owned > 65536 || wires = 0 || publicCount != 2 || wires > 16777216 || gates > 16777216 || queries > 1048576 || tokens > 1048576 || tables > 65536 || fields > 1048576 then throw (IO.userError "invalid dynamic-typing audit dimensions")
  let mut matrix : Shape := {wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates}
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := {matrix with gates := matrix.gates.push ⟨a,b,c⟩}
  trace "instruction audit: matrix parsed"
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
  let (segments,contextCache) ← readSegmentPayload file wires segmentCache
  let (context,codeCache) ← readModuleContext file wires contextCache
  let (code,localCache) ← readBodySource file wires codeCache
  let (locals,rangeCache) ← readLocalDeclaration file wires localCache
  let (ranges,instructionCache) ← readLocalRange file wires rangeCache
  let (catalog,decoders,instructions,eventCache) ← InstructionSourceAuditIO.readInstructionSource file wires instructionCache
  let (statics,admission,events,typingCache) ← ValidationEventAuditIO.read file wires eventCache
  let embeddedTyping ← if magic == "ZKSTRUCTURED1" || magic == "ZKDYNAMICTYPING1" then
      pure (← DynamicTypingAuditIO.read file wires typingCache).1
    else pure (default : DynamicTypingMatrix.Record)
  let embeddedControl ← if magic == "ZKSTRUCTURED1" then
      pure (← StructuredAuditIO.read file wires typingCache).1
    else pure (default : StructuredMatrix.Record)
  let controlFile ← match suffix with
    | none => pure file
    | some path => IO.FS.Handle.mk path .read
  let control ← match suffix with
    | none => pure embeddedControl
    | some _ => pure (← StructuredAuditIO.read controlFile wires typingCache).1
  if suffix.isSome && (← file.getLine) != "" then throw (IO.userError "trailing source certificate data")
  trace "instruction audit: evidence parsed"
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
  if !ModuleContextMatrix.check matrix body records.reverse streams.reverse space imports graph payload segments constants context then
    if !ModuleContextMatrix.sourceLinks records.reverse space imports graph payload segments constants context then
      throw (IO.userError "module source interfaces rejected")
    match ModuleContextMatrix.replay matrix records.reverse streams.reverse context with
    | .error e => throw (IO.userError e)
    | .ok (result,_) =>
      if !ModuleContextMatrix.outputLinks records.reverse context result then throw (IO.userError "module output interfaces rejected")
      throw (IO.userError "module start binding or primitive audit rejected")
  trace "instruction audit: module context checked"
  if !BodySourceSound.check matrix body packed.reverse records.reverse space indexed context locals ranges code then
    if !LocalRangeMatrix.links records.reverse locals ranges then throw (IO.userError "local range interfaces rejected")
    if !LocalRangeMatrix.check matrix body packed.reverse records.reverse locals ranges then
      match (LocalRangeMatrix.replayProgram matrix body.tokens packed.reverse records.reverse ranges).run (SourceProgram.init ranges.program) with
      | .error message => throw (IO.userError s!"local ranges: {message}")
      | .ok _ => throw (IO.userError "local range closing or table interfaces rejected")
    if !LocalDeclarationMatrix.links records.reverse space indexed context locals then throw (IO.userError "local declaration interfaces rejected")
    if !LocalDeclarationMatrix.check matrix body packed.reverse records.reverse space indexed context locals then
      match (LocalDeclarationMatrix.replayProgram matrix body.tokens packed.reverse records.reverse locals).run (SourceProgram.init locals.program) with
      | .error message => throw (IO.userError s!"local declarations: {message}")
      | .ok _ => throw (IO.userError "local declaration closing or table interfaces rejected")
    if !BodySourceSound.links records.reverse space indexed locals code then throw (IO.userError "code body interfaces rejected")
    match BodySourceMatrix.replay matrix body.tokens packed.reverse records.reverse body code with
    | .error message => throw (IO.userError s!"code bodies: {message}")
    | .ok (result,_) =>
      if !BodySourceSound.outputLinks records.reverse code result then throw (IO.userError "code body output tables rejected")
      throw (IO.userError "code body closing or helper audit rejected")
  trace "instruction audit: bodies checked; checking instruction stream"
  if !InstructionStreamCheck.links records.reverse context code decoders instructions then throw (IO.userError "instruction stream interfaces rejected")
  if !InstructionStreamCheck.checkPayload matrix body.tokens packed.reverse records.reverse context code catalog decoders instructions then
    for i in [:decoders.length] do
      if !InstructionDecodeMatrix.check matrix body.tokens packed.reverse catalog decoders[i]! then
        match (InstructionDecodeMatrix.replay matrix body.tokens packed.reverse catalog decoders[i]!).run (SourceProgram.init decoders[i]!.program) with
        | .error message => throw (IO.userError s!"decoder {i}: {message}")
        | .ok (_,state) => throw (IO.userError s!"decoder {i} closing rejected: {state.base.gate}/{decoders[i]!.program.base.lastGate}, {state.base.used}/{decoders[i]!.program.base.operations.length}, {state.usedBlocks}/{decoders[i]!.program.blocks.length}")
    match InstructionStreamCheck.run matrix body.tokens packed.reverse records.reverse catalog decoders instructions with
    | .error message => throw (IO.userError s!"instruction stream: {message}")
    | .ok (result,state) =>
      if !InstructionStreamCheck.outputLinks records.reverse instructions result then throw (IO.userError "instruction stream tables rejected")
      if !InstructionStreamMatrix.frameCheck matrix instructions result then throw (IO.userError "instruction control memory rejected")
      throw (IO.userError s!"instruction stream closing rejected: {state.base.gate}/{instructions.program.base.lastGate}, {state.base.used}/{instructions.program.base.operations.length}, {state.usedBlocks}/{instructions.program.blocks.length}")
  trace "instruction audit: stream checked; checking opcode catalog"
  let view := catalog.map InstructionDecodeMatrix.tableView
  if !(← known.get).contains view then
    if !InstructionDecodeMatrix.catalogCheck catalog then throw (IO.userError "opcode catalog rejected")
    known.modify (view::·)
  trace "validation audit: checking static/admission catalogs"
  if !ValidationEventAuditIO.catalogs statics admission then throw (IO.userError "validation rule catalog rejected")
  trace "validation audit: checking event programs"
  if !ValidationEventCheck.links events instructions then throw (IO.userError "validation event interfaces rejected")
  if !ValidationEventCheck.check matrix statics admission instructions events then
    for (id,rule) in statics do
      if !StaticLookupEmbedded.check matrix rule then throw (IO.userError s!"static rule matrix {id} rejected")
    for (id,rule) in admission do
      if !LookupEmbedded.check matrix rule then throw (IO.userError s!"admission matrix {id} rejected")
    for stage in events.stages do
      if !ValidationEventCheck.checkStage matrix statics admission stage then
        match (ValidationEventCheck.replay matrix statics admission stage).run (SourceProgram.init stage.program) with
        | .error message => throw (IO.userError s!"validation stage {stage.kind}: {message}")
        | .ok (_,state) => throw (IO.userError s!"validation stage {stage.kind} closing rejected: {state.base.gate}/{stage.program.base.lastGate}, {state.base.used}/{stage.program.base.operations.length}, {state.usedBlocks}/{stage.program.blocks.length}")
    throw (IO.userError "validation memory or per-row rule interfaces rejected")
  if magic != "ZKVALIDATIONEVENT1" && !DynamicTypingCheck.check matrix packed.reverse records.reverse signature context ranges events embeddedTyping then
    if !DynamicTypingCheck.links records.reverse context ranges events embeddedTyping then throw (IO.userError "dynamic typing interfaces rejected")
    for stage in embeddedTyping.stages do
      if !DynamicTypingCheck.checkStage matrix packed.reverse records.reverse signature stage then
        match (DynamicTypingCheck.replay matrix packed.reverse records.reverse signature stage).run (SourceProgram.init stage.program) with
        | .error message => throw (IO.userError s!"dynamic typing stage {stage.kind}: {message}")
        | .ok (_,state) => throw (IO.userError s!"dynamic typing stage {stage.kind} closing rejected: {state.base.gate}/{stage.program.base.lastGate}, {state.base.used}/{stage.program.base.operations.length}, {state.usedBlocks}/{stage.program.blocks.length}")
    throw (IO.userError "dynamic typing table certification rejected")
  if !StructuredCheck.check matrix packed.reverse records.reverse events instructions signature indexed declaration control then
    if !StructuredCheck.links records.reverse events instructions signature indexed declaration control then throw (IO.userError "structured control interfaces rejected")
    for stage in control.stages do
      if !StructuredCheck.checkStage matrix packed.reverse records.reverse indexed control stage then
        match (StructuredCheck.replay matrix packed.reverse records.reverse indexed control stage).run (SourceProgram.init stage.program) with
        | .error message => throw (IO.userError s!"structured stage {stage.kind}: {message}")
        | .ok (_,state) => throw (IO.userError s!"structured stage {stage.kind} closing rejected: {state.base.gate}/{stage.program.base.lastGate}, {state.base.used}/{stage.program.base.operations.length}, {state.usedBlocks}/{stage.program.blocks.length}")
    throw (IO.userError "structured table certification rejected")
  if (← controlFile.getLine) != "" then throw (IO.userError "trailing structured control data")
  IO.println s!"structured control PASS: rows={events.rows.length} stages={control.stages.length} matrix={gates}"
  if let some manifest := cases then
    let original ← match suffix with
      | none => pure #[]
      | some source => pure (((← IO.FS.readFile source).splitOn "\n").dropLast.toArray)
    let checkCandidate := fun (f : IO.FS.Handle) => do
      let (candidate,_) ← StructuredAuditIO.read f wires typingCache
      let complete := (← f.getLine) == ""
      pure (complete && StructuredCheck.check matrix packed.reverse records.reverse events instructions signature indexed declaration candidate)
    for line in (← IO.FS.readFile manifest).splitOn "\n" do
      let path := line.trimAscii.toString
      if !path.isEmpty then
        let accepted ← try
          let f ← IO.FS.Handle.mk path .read
          if (← f.getLine).trimAscii.toString == "ZKCONTROLPATCH1" then
            let count ← number (← f.getLine).trimAscii.toString
            let index ← number (← f.getLine).trimAscii.toString
            let replacement := (← f.getLine).trimAscii.toString
            if original.isEmpty || count + 1 < original.size || count > original.size + 1 || index >= count || (← f.getLine) != "" then
              throw (IO.userError "invalid structured case delta")
            let contents := ((original.toList.take count).toArray ++ Array.replicate (count-original.size) "").set! index replacement
            IO.FS.withTempFile fun output temp => do
              output.putStr (String.intercalate "\n" contents.toList ++ "\n")
              output.flush
              checkCandidate (← IO.FS.Handle.mk temp .read)
          else checkCandidate (← IO.FS.Handle.mk path .read)
        catch _ => pure false
        IO.println s!"{if accepted then "ACCEPT" else "REJECT"} {path}"

def main (args : List String) : IO Unit := do
  let known ← IO.mkRef ([] : List (List InstructionDecodeMatrix.TableView))
  match args with
  | ["--batch",manifest] =>
    for line in (← IO.FS.readFile manifest).splitOn "\n" do
      let fields := line.trimAscii.toString.splitOn "\t"
      if fields != [""] then
        match fields with
        | [path] => checkOne [path] known
        | [path,suffix] => checkOne [path,"--control",suffix] known
        | [path,suffix,cases] => checkOne [path,"--control",suffix,"--control-cases",cases] known
        | _ => throw (IO.userError "invalid validation-event audit batch")
  | _ => checkOne args known
