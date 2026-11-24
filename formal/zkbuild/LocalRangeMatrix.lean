import LocalDeclarationMatrix
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.LocalRangeMatrix
open CircuitShape GadgetShape DeclarationMatrix SourceProgram
abbrev Entries := List ReadOnlyMatrix.Entry
structure Record where
  locals : Entries
  ranges : Entries
  tags : Entries
  selected : List Linear
  banks : List Nat
  program : Program
  deriving Inhabited

def table (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) := tables.getD (r.banks.getD i 0) default
def replayProgram (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (r : Record) : Eval (Entries × Entries) := do
  let p := r.program
  let mut previousFunction := z
  let mut previousOrdinal := z
  let mut previousEnd := z
  let mut previousActive := z
  for i in List.range r.ranges.length do
    let entry := r.ranges.getD i default
    let tag := r.tags.getD i default
    eq matrix p entry.active tag.active
    eq matrix p entry.address tag.address
    let invalid ← zero matrix p (sub tag.value (n 7))
    eq matrix p invalid z
    let key ← split matrix tokens splits p entry.address
    let span ← split matrix tokens splits p entry.value
    let equality ← zero matrix p (sub key.2 previousFunction)
    let continuing ← mul matrix p previousActive equality
    let same ← mul matrix p entry.active continuing
    raw matrix (gate (sub entry.active same) key.1)
    raw matrix (gate same (sub (sub key.1 previousOrdinal) o))
    let start ← mul matrix p continuing previousEnd
    raw matrix (gate entry.active (sub span.1 start))
    let _ ← range matrix p (span.1++span.2) 32
    previousFunction := key.2
    previousOrdinal := key.1
    previousEnd := span.1++span.2
    previousActive := entry.active
  let mut dataQueries : Entries := []
  let mut tagQueries : Entries := []
  for i in List.range r.locals.length do
    let row := r.locals.getD i default
    let key ← split matrix tokens splits p row.address
    let selected := get r.selected i
    let declared ← split matrix tokens splits p selected
    raw matrix (gate row.active (sub declared.2 key.2))
    let data := (table tables r 0).queries.getD i default
    let tag := (table tables r 1).queries.getD i default
    let dataAddress ← mul matrix p row.active selected
    let tagAddress ← mul matrix p row.active selected
    dataQueries := dataQueries++[⟨row.active,dataAddress,data.value⟩]
    tagQueries := tagQueries++[⟨row.active,tagAddress,tag.value⟩]
    let span ← split matrix tokens splits p data.value
    let lower ← mul matrix p row.active (sub key.1 span.1)
    let _ ← range matrix p lower 32
    let upper ← mul matrix p row.active (sub (sub (span.1++span.2) key.1) o)
    let _ ← range matrix p upper 32
    raw matrix (gate row.active (sub row.value tag.value))
  pure (dataQueries,tagQueries)

def links (tables : List ReadOnlyMatrix.Record) (declarations : LocalDeclarationMatrix.Record) (r : Record) : Bool :=
  decide (r.banks.length = 2 ∧ (∀ i ∈ r.banks, i < tables.length) ∧ r.ranges.length = r.tags.length ∧
    r.selected.length = r.locals.length ∧ (table tables r 0).queries.length = r.locals.length ∧ (table tables r 1).queries.length = r.locals.length ∧
    ModuleContextMatrix.normalizedEntries r.ranges = ModuleContextMatrix.normalizedEntries declarations.ranges ∧
    ModuleContextMatrix.normalizedEntries r.tags = ModuleContextMatrix.normalizedEntries declarations.tags ∧
    ModuleContextMatrix.normalizedEntries (table tables r 0).entries = ModuleContextMatrix.normalizedEntries r.ranges ∧
    ModuleContextMatrix.normalizedEntries (table tables r 1).entries = ModuleContextMatrix.normalizedEntries r.tags ∧
    (table tables r 0).memory.addressBits = 64 ∧ (table tables r 0).memory.valueBits = 64 ∧
    (table tables r 1).memory.addressBits = 64 ∧ (table tables r 1).memory.valueBits = 3)
def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declarations : LocalDeclarationMatrix.Record) (r : Record) : Bool :=
  links tables declarations r && match (replayProgram matrix body.tokens splits tables r).run (init r.program) with
  | .error _ => false
  | .ok ((data,tags),state) => decide (finished r.program state ∧ r.program.base.lastGate = (table tables r 0).firstGate ∧
      ModuleContextMatrix.normalizedEntries data = ModuleContextMatrix.normalizedEntries (table tables r 0).queries ∧
      ModuleContextMatrix.normalizedEntries tags = ModuleContextMatrix.normalizedEntries (table tables r 1).queries) &&
      auditState matrix body.tokens splits state
end ZkBuild.LocalRangeMatrix
