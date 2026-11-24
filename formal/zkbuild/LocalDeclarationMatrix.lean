import BodySourceMatrix
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.LocalDeclarationMatrix
open CircuitShape GadgetShape DeclarationMatrix SourceProgram
abbrev Fields := List Linear
abbrev Entries := List ReadOnlyMatrix.Entry
structure Record where
  firstFunction : Linear
  functionCount : Linear
  ranges : Entries
  tags : Entries
  totals : Entries
  banks : List Nat
  program : Program
  deriving Inhabited

def table (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) := tables.getD (r.banks.getD i 0) default
def query (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : Record) (queries : List Entries)
    (bank : Nat) (active key : Linear) : Eval (Linear × List Entries) := do
  let rows := (table tables r bank).queries
  let i := (queries.getD bank []).length
  require (decide (i < rows.length)) s!"missing local declaration query {bank}:{i}"
  let row := rows.getD i default
  let address ← mul matrix r.program active key
  require (decide (ModuleContextMatrix.normalizedEntries [row] = ModuleContextMatrix.normalizedEntries [⟨active,address,row.value⟩])) "local declaration query rejected"
  pure (row.value,BodySourceMatrix.addQuery queries bank row)
def parameter (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (r : Record)
    (queries : List Entries) (active fn : Linear) : Eval ((Linear × Linear) × List Entries) := do
  let (metadata,queries) ← query matrix tables r queries 0 active (scale fn 2)
  let (head,_) ← split matrix tokens splits r.program metadata
  let (length,queries) ← query matrix tables r queries 1 active head
  pure ((head,length),queries)

def replayProgram (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (r : Record) : Eval (List Entries) := do
  let p := r.program
  let mut queries : List Entries := List.replicate 5 []
  for i in List.range r.ranges.length do
    let row := r.ranges.getD i default
    let tag := r.tags.getD i default
    let key ← split matrix tokens splits p row.address
    let span ← split matrix tokens splits p row.value
    let lower ← mul matrix p row.active (sub key.2 r.firstFunction)
    let _ ← range matrix p lower 32
    let upper ← mul matrix p row.active (sub (sub r.functionCount key.2) o)
    let _ ← range matrix p upper 32
    let (param,next) ← parameter matrix tokens splits tables r queries row.active key.2
    queries := next
    let difference ← range matrix p (sub (key.1++n (2^32)) param.2) 33
    let enabled ← mul matrix p row.active (sub o (get difference 32))
    raw matrix (gate enabled (sub span.2 o))
    let head ← mul matrix p enabled param.1
    let ordinal ← mul matrix p enabled (sub (sub param.2 key.1) o)
    let _ ← range matrix p head 32
    let _ ← range matrix p ordinal 32
    let members := (table tables r 2).queries
    let atIndex := (queries.getD 2 []).length
    require (decide (atIndex < members.length)) "missing parameter member"
    let member := members.getD atIndex default
    require (decide (ModuleContextMatrix.normalizedEntries [member] =
      ModuleContextMatrix.normalizedEntries [⟨enabled,scale head (Int.ofNat (2^32))++ordinal,member.value⟩])) "parameter member rejected"
    queries := BodySourceMatrix.addQuery queries 2 member
    let (actual,_) ← split matrix tokens splits p member.value 3 32
    raw matrix (gate enabled (sub tag.value actual))
    let (total,next) ← query matrix tables r queries 3 row.active key.2
    queries := next
    let declared ← split matrix tokens splits p total
    let margin ← mul matrix p row.active (sub (sub declared.2 key.1) o)
    let _ ← range matrix p margin 32
  let mut count := z
  let mut previous := o
  for i in List.range r.totals.length do
    let row := r.totals.getD i default
    boolean matrix p row.active
    raw matrix (gate row.active (sub o previous))
    raw matrix (gate row.active (sub (sub row.address r.firstFunction) (n i)))
    let total ← split matrix tokens splits p row.value
    let (param,next) ← parameter matrix tokens splits tables r queries row.active row.address
    queries := next
    let values ← mul matrix p row.active (sub total.1 param.2)
    let _ ← range matrix p values 32
    let declarations ← mul matrix p row.active (sub total.2 param.2)
    let _ ← range matrix p declarations 32
    let empty ← zero matrix p total.2
    let nonempty ← mul matrix p row.active (sub o empty)
    raw matrix (gate (sub row.active nonempty) total.1)
    let address := sub (scale row.address (Int.ofNat (2^32))++total.2) o
    let (last,next) ← query matrix tables r queries 4 nonempty address
    queries := next
    let span ← split matrix tokens splits p last
    raw matrix (gate nonempty (sub (sub total.1 span.1) span.2))
    count ← materialize matrix p (count++row.active)
    previous := row.active
  eq matrix p count (sub r.functionCount r.firstFunction)
  pure queries

def links (tables : List ReadOnlyMatrix.Record) (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record) (context : ModuleContextMatrix.Record) (r : Record) : Bool :=
  decide (r.banks.length = 5 ∧ (∀ i ∈ r.banks, i < tables.length) ∧ r.tags.length = r.ranges.length ∧
    ModuleProgram.sameInputs [r.firstFunction,r.functionCount] [space.firstFunction,ModuleContextMatrix.counter context 11] ∧
    ModuleContextMatrix.normalizedEntries (table tables r 0).entries = ModuleContextMatrix.normalizedEntries (space.rows.map (·.entry)) ∧
    ModuleContextMatrix.normalizedEntries (table tables r 1).entries = ModuleContextMatrix.normalizedEntries (indexed.lengths.map (·.entry)) ∧
    ModuleContextMatrix.normalizedEntries (table tables r 2).entries = ModuleContextMatrix.normalizedEntries (indexed.members.map (·.entry)) ∧
    ModuleContextMatrix.normalizedEntries (table tables r 3).entries = ModuleContextMatrix.normalizedEntries r.totals ∧
    ModuleContextMatrix.normalizedEntries (table tables r 4).entries = ModuleContextMatrix.normalizedEntries r.ranges) &&
  (List.range 5).all (fun i =>
    let bank := table tables r i
    decide ((bank.memory.addressBits,bank.memory.valueBits) = ([(33,64),(32,32),(64,35),(32,64),(64,64)].getD i (0,0))))
def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record) (context : ModuleContextMatrix.Record) (r : Record) : Bool :=
  links tables space indexed context r && match (replayProgram matrix body.tokens splits tables r).run (init r.program) with
  | .error _ => false
  | .ok (queries,state) => decide (finished r.program state ∧ r.program.base.lastGate = (table tables r 0).firstGate) &&
      (List.range 5).all (fun i => decide (ModuleContextMatrix.normalizedEntries (queries.getD i []) = ModuleContextMatrix.normalizedEntries (table tables r i).queries)) &&
      auditState matrix body.tokens splits state
end ZkBuild.LocalDeclarationMatrix
