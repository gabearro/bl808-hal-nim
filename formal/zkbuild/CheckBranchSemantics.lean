import RuntimeContextCli
import BranchSourceSound
import BranchLookupSound
import BranchTypeSource
import BranchTypeMutations
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape

def rowCandidates (matrix : Shape) (r : BranchRowCheck.Record) : List BranchRowCheck.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  [1,8].map (fun i => {r with row := r.row.set i bad}) ++
  [0,1,7,9].map (fun i => {r with flags := r.flags.set i bad}) ++
  ((List.range 11).filter (· != 2)).map (fun i => {r with after := r.after.set i bad}) ++
  [0,5,7].map (fun i => {r with reciprocals := r.reciprocals.set i bad}) ++
  [{r with before := bad},{r with primary := bad},
   {r with payload := {r.payload with value := bad}},
   {r with payload := {r.payload with low := bad}},{r with payload := {r.payload with high := bad}},
   {r with payload := {r.payload with lowWidth := 31}},{r with payload := {r.payload with highWidth := 31}},
   {r with primaryRange := {r.primaryRange with call := {r.primaryRange.call with width := 255}}},
   {r with bankQuery := {r.bankQuery with active := bad}},{r with bankQuery := {r.bankQuery with address := bad}},
   {r with bankQuery := {r.bankQuery with value := bad}},
   {r with nodeQuery := {r.nodeQuery with active := bad}},{r with nodeQuery := {r.nodeQuery with address := bad}},
   {r with nodeQuery := {r.nodeQuery with value := bad}},
   {r with outputs := r.outputs.set 0 bad},{r with outputs := r.outputs.set 1 bad},
   {r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1},
   {r with row := []},{r with flags := []},{r with after := []},{r with reciprocals := []},{r with outputs := []}]

def bankCandidates (matrix : Shape) (r : BranchListCheck.Bank) : List BranchListCheck.Bank :=
  let bad : Linear := [(matrix.wires+1,1)]
  [{r with entry := {r.entry with active := bad}},{r with entry := {r.entry with value := bad}},
   {r with query := {r.query with active := bad}},{r with query := {r.query with address := bad}},
   {r with range := {r.range with call := {r.range.call with width := 255}}},
   {r with selected := bad},{r with reciprocal := bad},
   {r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1}]

def nodeCandidates (matrix : Shape) (r : BranchListCheck.Node) : List BranchListCheck.Node :=
  let bad : Linear := [(matrix.wires+1,1)]
  [0,2,3,4].map (fun i => {r with after := r.after.set i bad}) ++
  [{r with entry := {r.entry with active := bad}},{r with entry := {r.entry with address := bad}},
   {r with entry := {r.entry with value := bad}},
   {r with query := {r.query with active := bad}},{r with query := {r.query with address := bad}},
   {r with payload := {r.payload with value := bad}},
   {r with payload := {r.payload with low := bad}},{r with payload := {r.payload with high := bad}},
   {r with payload := {r.payload with lowWidth := 31}},{r with payload := {r.payload with highWidth := 31}},
   {r with delta := {r.delta with call := {r.delta.call with width := 255}}},
   {r with reciprocal := bad},{r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1},
   {r with after := []}]

def main (args : List String) : IO Unit := do
  let testing := args.head? == some "--mutations"
  let args := if testing then args.drop 1 else args
  RuntimeContextCli.runWithInstructionSource args fun matrix splits tables signature statics events typing structured indexed instructions catalog decoders => do
    -- Legacy validation-event fixtures do not carry dynamic typing. They still
    -- exercise the branch theorem, but cannot exercise the combined call theorem.
    if !typing.stages.isEmpty && !CallCertificate.check matrix splits tables signature statics events typing then
      throw (IO.userError "call prerequisite certificate rejected")
    if !ParametricCertificate.check matrix statics events then
      throw (IO.userError "parametric prerequisite certificate rejected")
    if !InstructionEventCheck.checkStage matrix tables instructions then
      throw (IO.userError "instruction event source prerequisite rejected")
    if !InstructionInfoCheck.checkStage matrix tables catalog decoders instructions then
      throw (IO.userError "instruction source fields prerequisite rejected")
    let stage := StructuredMatrix.stage structured 2
    if !BranchRowCheck.checkStage matrix splits tables stage then
      for i in List.range stage.rows.length do
        if !BranchRowCheck.check matrix (BranchRowCheck.record splits tables stage i) then
          throw (IO.userError s!"branch row {i} rejected: operations={stage.program.base.operations.length}, prefix={BranchRowCheck.offset tables stage}, rows={stage.rows.length}, blocks={stage.program.blocks.length}")
      throw (IO.userError "branch stage shape rejected")
    if !BranchCertificate.check matrix splits tables statics events structured then
      throw (IO.userError "branch canonical-event certificate rejected")
    if !BranchListCheck.check matrix splits tables stage then
      throw (IO.userError "branch list initializer certificate rejected")
    if !FrameCertificate.check matrix events structured then
      throw (IO.userError "signature frame prerequisite certificate rejected")
    if !FrameDepthCheck.checkStage matrix splits tables structured then
      throw (IO.userError "signature frame depth prerequisite certificate rejected")
    let typed := StructuredMatrix.stage structured 5
    if !BranchTypeRowCheck.checkStage matrix splits structured.scratch typed then
      for i in List.range typed.rows.length do
        if !BranchTypeRowCheck.check matrix (BranchTypeRowCheck.record splits structured.scratch typed i) then
          throw (IO.userError s!"branch typing row {i} rejected: operations={typed.program.base.operations.length}, rows={typed.rows.length}, blocks={typed.program.blocks.length}")
      throw (IO.userError "branch typing stage shape rejected")
    IO.println s!"branch typing matrix PASS: rows={typed.rows.length}"
    if !BranchMergeCheck.checkStage matrix structured then
      for i in List.range typed.rows.length do
        for family in List.range 4 do
          if !BranchMergeCheck.check matrix (BranchMergeCheck.record structured i family) then
            throw (IO.userError s!"branch lookup merge rejected: row={i} family={family}")
      throw (IO.userError s!"branch lookup merge shape rejected: controlOps={(StructuredMatrix.stage structured 4).program.base.operations.length}, rows={typed.rows.length}")
    IO.println s!"branch lookup merge PASS: rows={typed.rows.length}"
    if !BranchTypeCertificate.check matrix splits tables statics events structured then
      throw (IO.userError "branch typing canonical-event certificate rejected")
    if !BranchLookupCheck.check matrix tables indexed structured then
      throw (IO.userError "branch lookup authentication interfaces rejected")
    let typeRejected ← if testing then BranchTypeMutations.run matrix splits tables events structured indexed else pure 0
    IO.println s!"branch typing certificate PASS: rows={typed.rows.length} rejected={typeRejected}"
    let banks := (DynamicTypingMatrix.bank tables stage 0).entries.length
    let nodes := (DynamicTypingMatrix.bank tables stage 1).entries.length
    let mut rejected := 0
    if testing then
      for i in List.range stage.rows.length do
        let changes := rowCandidates matrix (BranchRowCheck.record splits tables stage i)
        if changes.length != 42 then throw (IO.userError "branch row mutation coverage drift")
        for j in List.range changes.length do
          if BranchRowCheck.check matrix (changes.getD j default) then
            throw (IO.userError s!"branch row mutation accepted: row={i} change={j}")
          rejected := rejected+1
        let bad : Linear := [(matrix.wires+1,1)]
        for changed in ([0,7,9].map (fun k => {stage with flags := stage.flags.set i ((stage.flags.getD i []).set k bad)}) ++
            [{stage with rows := stage.rows.set i ((stage.rows.getD i []).set 8 bad)},
             {stage with inputs := stage.inputs.set i ((stage.inputs.getD i []).set 0 bad)}]) do
          let altered := {structured with stages := structured.stages.map (fun s => if s.kind == 2 then changed else s)}
          if BranchCertificate.linked matrix events altered then
            throw (IO.userError s!"branch link mutation accepted: row={i}")
          rejected := rejected+1
      for i in List.range banks do
        let changes := bankCandidates matrix (BranchListCheck.bankRecord tables stage i)
        if changes.length != 9 then throw (IO.userError "branch bank mutation coverage drift")
        for j in List.range changes.length do
          if BranchListCheck.checkBank matrix (changes.getD j default) then
            throw (IO.userError s!"branch bank mutation accepted: entry={i} change={j}")
          rejected := rejected+1
      for i in List.range nodes do
        let changes := nodeCandidates matrix (BranchListCheck.nodeRecord splits tables stage i)
        if changes.length != 19 then throw (IO.userError "branch node mutation coverage drift")
        for j in List.range changes.length do
          if BranchListCheck.checkNode matrix (changes.getD j default) then
            throw (IO.userError s!"branch node mutation accepted: entry={i} change={j}")
          rejected := rejected+1
    IO.println s!"branch matrix PASS: rows={stage.rows.length} banks={banks} nodes={nodes} rejected={rejected} calls={!typing.stages.isEmpty}"
    pure true
