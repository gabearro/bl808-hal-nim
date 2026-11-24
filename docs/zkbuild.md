# Proof-carrying WASM: implementation status

This is an experimental, bounded implementation. It is **not** a verified
replacement for the general WASM validator or optimizing JIT. Normal module
admission has not been changed.

The executable prover, verifier, constraint builder, codecs, and target adapter
are Nim. Lean is used only for formal specifications and proofs. The arithmetic
backend is the Nim library Constantine, pinned to commit
`502a868ba2862f2b267120989f035757cc8d5ea5`. The bootstrap leaves its checkout
untouched and creates an ignored build copy with the checked-in RV32 portability
patch. No Rust implementation or runtime is required.

## Supported statements

`validate` proves membership in a bounded, ordinary WASM byte-stream profile:

- One function, type `(i32, i32) -> i32`, with one export.
- No imports, memory, globals, tables, calls, control-flow branches, or start function.
- A three-byte ASCII export name (not necessarily `run`).
- Variable instruction lengths and up to 120 instruction bytes; 156 total bytes.
- Operations: `nop`, the two `local.get` parameter accesses, `i32.const`,
  `i32.add`, `i32.sub`, `i32.mul`, `i32.and`, `i32.or`, and `i32.xor`.
- Maximum operand-stack depth eight, no underflow, exactly one final result.
- Constants use valid signed LEB128 of one to five bytes; valid non-minimal
  encodings are accepted. Parameter indices and section lengths use one byte.
- Exact header/section structure, section lengths, and final `end`.
- No input rewriting or padding in the submitted artifact. Zero padding is used
  only inside the fixed-size circuit and is disambiguated by a public length.

`validate-slots` retains the original fixed-slot profile: sixteen instructions,
each encoded into six bytes with `nop` padding, five-byte signed constants, and
the fixed export name `run`. Existing fixed-slot validation keys retain their
distinct claim identifier; they cannot be used as byte-stream validation keys.

`compile` binds the exact RV32 output of the fixed-slot restricted emitter.
That output has a standard two-argument integer C ABI, uses only caller-saved
registers, and contains no memory access, relocation, or external call. It is
separate from the existing optimizing JIT and its internal ABI.

`compile-bytes` starts from the ordinary byte-stream profile above. It accepts
up to sixteen non-nop operations, removes bytecode nops, and fills the emitter's
remaining leading slots with nops. Signed constants may use any of the valid
one-to-five-byte encodings accepted by `validate`. The original submitted bytes,
their exact length, and the 144-byte native output are all public-input bound.
This is a distinct claim and verification key; existing `compile` keys retain
their original meaning. Semantic soundness and constructive completeness are
proved for the bounded Lean byte-decoder model described below. Mechanical refinement of the compiled
Nim implementation remains open.

These statements start at the WASM binary. They do **not** attest to Nim, Clang,
LLD, `wasm-opt`, source provenance, arbitrary WASM execution, or application
correctness.

## General WASM proof path: in progress

The latest formal extension identifies the complete authenticated control
signature lists, carries them between resets, and proves the list position
and type of every active input/output member on the source-bound event trace.
Its [guarantees and validation results](#control-signature-lists-and-member-positions)
remain component results; full ordinary-control instruction-body composition
and the general build-admission theorem are incomplete. The preceding
extensions derive control-typing gates, natural counters, ordering, terminal
counts, and complete source-bound branch-table action plans.

The requested coverage target is **every feature supported by this repository's
current runtime and compiler**. This is not a target of implementing every
proposal in the current WebAssembly specification. The source coverage
checklist includes:

| Feature family | Source surfaces to cover |
| --- | --- |
| i32/i64, f32/f64, conversions, sign extension, saturating conversions | `numeric_typing.nim`, `runtime.nim`, `runtime_int.nim`, JIT lowering/emission |
| Structured control, branch tables, multi-value signatures, locals, direct/indirect calls, typed selects | `binary.nim`, `validate.nim`, both runtimes, JIT pipeline |
| Linear memories, globals, tables, references, bulk memory/table operations | Decoder/module validation, runtime stores and instructions, JIT implementations |
| Tail calls and implemented exception handling | `opReturnCall`, `opReturnCallIndirect`, `opTryTable`, `opThrow` and their actual runtime/compiler behavior |
| Implemented SIMD subset | `types.nim`, decoder and Tier 2 code generation; the interpreter explicitly traps on SIMD, so its branch labels alone do not establish execution support |
| Imports/exports, start functions, element/data segments, tags, limits, constant expressions | Complete module-level decoding and validation |
| Internal fused opcodes and optimizations | Native-compilation proof stages; validation starts from unfused original instructions with `optimize = false` |

This checklist records the required scope, not completed proof coverage. A
declared enum member or dispatch branch is insufficient evidence of support;
trap-only and backend-specific paths must be distinguished during the audit.

The existing small-proof modes above are still the only proof modes accepted
by the kernel. Expanding them to general modules requires a different
validation relation, with typed control stacks, function/type lookups, locals,
globals, memories, tables, references, and the complete binary encoding bound
to the submitted artifact. Proving one successful execution is insufficient
to establish module validity or correct compilation for every input.

`src/cps/zk/wasm_validation_witness.nim` is the first frontend for that relation.
It decodes original instruction boundaries with `optimize = false`, runs the
general validator, and emits a linear event stream for operand pushes/pops,
control frames, unreachable transitions, and instruction boundaries. It
retains the decoded module, exact submitted bytes, and SHA-256 digest. Its
tests cover a multi-function module larger than the old profile, with a loop,
conditional branch, call, memory load, and i64 local. The witness is private
prover input; it is **not a ZKP or an admission certificate**. Hashing bytes on
the host does not itself prove that the events describe those bytes.

`wasm_trace_check.nim` independently replays the transcript against the decoded
module. It checks function/instruction order, opcode binding, actual LIFO
operand reads and writes, control-frame signatures, unreachable-stack resets,
and final stack closure. Unhandled validator opcodes emit an explicit event;
the witness frontend rejects those events instead of treating a skipped rule
as validation. Fixed signatures are checked; context-dependent instruction
semantics still need additional checks.

`numeric_typing.nim` defines 140 fixed signatures covering core numeric
instructions and saturating conversions, without allocating per-opcode type
lists. Validation and transcript replay both enforce their exact pop/push
types. `WasmNumericTyping.lean` independently describes the signatures and
proves their concrete and polymorphic stack transitions. The conformance test
compares 1,024 opcode tags and exercises all 140 rules, including unreachable
stacks, reference-type rejection, and altered transcripts.

`numeric_lookup.nim` is the first R1CS component for the new relation. A fixed
bit-prefix tree shares selectors between opcodes; all branches are emitted
regardless of witness values. The standalone test circuit has 112 constraints,
including the 16-bit opcode binding and four metadata bindings. It checks
1,028 opcode cases and rejects 5,120 changed public values. `LookupTree.lean`
proves the generic prefix-weight polynomial equals its selected leaf payload.
This lookup component does not yet prove module validity, stack memory
consistency, or correspondence to the submitted binary.

`static_typing.nim` extends the table to 245 fixed signatures: the 140 numeric
rules, scalar memory effects, bulk operations, references, drop, unreachable,
and all 67 SIMD opcodes declared by the current decoder. Inputs use pop order,
with distinct wildcard and reference classes. The validator also checks SIMD
lane bounds, constant-pool indices, memory presence, and natural alignment,
following the [vector validation rules](https://webassembly.github.io/spec/core/valid/instructions.html#vector-instructions).
These immediate/environment checks are not yet constrained by the event circuit.

The composed event relation now uses `static_lookup.nim`. Its decision DAG
shares identical input-match subgraphs across opcodes. All 228 branch nodes
are emitted for every witness; metadata is accumulated through pooled flow.
The standalone circuit uses 264 constraints including opcode/type range
checks, the input ordinal, and six output bindings. Tests compare all
2,097,152 opcode/ordinal/type combinations against the direct rule evaluator,
check 2,724 R1CS cases, and reject 9,216 public substitutions. The caller binds
the full input ordinal only on a fixed-rule pop, allowing future instructions
with larger dynamic arities to share the same event circuit.

`StaticTyping.lean` independently declares all 245 rules, proves their finite
shape invariants and complete 67-opcode SIMD coverage, and exports them for
Nim conformance tests. `LookupFlow.lean` proves pooled-flow conservation under
the node score and flow equations. Source refinement of the generated Nim DAG
remains open. Tests also validate/replay 490 concrete and polymorphic bodies
and cover every known type for drop and both reference types for null tests.

`permutation.nim` and `memory_consistency.nim` add an exact RAM argument for
the general validation circuit. A Beneš network moves packed records from
execution order into address/time order. It uses two constraints per switch
and `N*log2(N)-N/2` switches for a power-of-two capacity `N >= 2`. Its topology
does not depend on private values. This component uses no random multiset
challenge. Range checks make the packed record encoding injective; adjacent
constraints enforce strict ordering, initialized reads, and the most recent
written value. Addresses and payloads support up to 64 bits each. Padding
records must be inactive and zero, and their original timestamps remain bound.

The RAM tests enumerate all 40,347 permutations through capacity eight, test
circuits through capacity 1,024, compare randomized memory traces with an
independent execution-order interpreter, and reject altered public records,
invalid reads, bad padding, changed timestamps, and reordered witnesses. The
eight-access test with eight-bit addresses and values uses 568 constraints.
It also produces and verifies two 192-byte Groth16 proofs using one test key.
These proofs certify the RAM relation only; their public inputs are the
access records, and they are not WASM admission proofs.

`read_only_memory.nim` specializes that argument to immutable module tables.
Initialization entries form a strictly increasing active prefix, followed by
zero padding. Every query is derived as a read after initialization. This
excludes duplicate-key overwrites and prevents changing a query into a write.
Tests cover 480 exhaustive membership cases, 20 randomized histories,
full-width keys/values, missing keys, namespace aliases, changed public
inputs, and adversarial sorted witnesses. The eight-access example uses 601
constraints and verifies two 192-byte proofs with one key.

`ReadOnlyMemory.lean` connects the field RAM constraints to initialized-table
membership, proves that adjacent initializer ordering implies unique active
keys, and derives unique query values. These are table-relation proofs;
module-table construction and its binary binding remain separate obligations.

`wasm_stack_memory.nim` extracts operand reads/writes from the validation
transcript, with separate function namespaces and stack-slot reuse. It skips
synthetic pops in unreachable code because they read no memory. Its test covers a 313-byte, three-function WASM
module and rejects an altered pop type. The extractor's event-to-access map
is a compact host-side witness computation.

`wasm_operand_events.nim` adds the constrained event-to-RAM path. It derives
one RAM record per event row inside R1CS, including inactive zero records for
events that access no operand memory. It constrains push/pop stack heights,
unreachable resets to the supplied control floor, virtual-pop guards,
function-boundary heights, canonical padding, and padding suffixes. The
returned records feed directly into `constrainMemory`; they are not supplied
by an unchecked host projection. The standalone eight-row composed circuit
has 3,097 constraints and produces a 192-byte proof. Tests include real WASM
control events, 40 randomized transcripts, 15 coherently regenerated forged
transcripts, changed field assignments, and witness-independent matrices.

`OperandEvents.lean` proves selector soundness, natural stack-step soundness
for arbitrary satisfying field assignments, the exact RAM projection, its
64-bit address bound, and constructive step completeness. The operand component
accepts control-floor and unreachable inputs; `wasm_control_events.nim`
supplies their authenticated binding. Instruction/event ordering, opcode typing, and byte binding
remain separate obligations. These are component proofs, not general WASM
admission certificates. The dense event path currently favors a direct
binding; compacting inactive event rows is a future optimization.

`wasm_control_events.nim` reads the actual top control frame before each row
and derives writes for frame pushes and unreachable updates. The payload is
the injective 33-bit encoding `2*floor + unreachable`; frame pushes derive
their floor from the prior operand height and begin reachable. The composed
`constrainValidationStacks` entry point generates selectors and both RAM
projections from the same event wires. It enforces control-depth transitions,
frame closure at its floor, nonempty frames for operand accesses, empty
function boundaries, and sequential function namespaces. Its first function
index remains an input that must be bound to the module's import count.

Tests cover 24 randomized control histories, 12 coherent forgeries, two real
WASM bodies, imported-function namespaces, and uint32 function-index boundaries.
Two forged transcripts intentionally pass the operand-only component: one
omits an unreachable-frame update and the other resets through the wrong
frame floor. The composed circuit rejects both. The eight-row proof has
8,187 constraints, an 8,192-point QAP domain, and a 192-byte proof. Packing the
empty-frame context and sharing the function-begin/padding guard save two
constraints per row; the original 8,203-constraint circuit required a
16,384-point domain. This is a domain-size reduction, not a measured overall
proving-speed claim.

`ControlEvents.lean` proves the optimized field constraints enforce the
natural control-depth rules and exact RAM projections. `FunctionEvents.lean`
proves schedule soundness/completeness and namespace continuity without
uint32 wraparound. `ControlMemory.lean` and `ControlRefinement.lean` connect
authenticated RAM reads to actual LIFO frames and show that pushes, pops,
and unreachable updates preserve their representation. Control-frame type
signatures, label lookups, opcode authorization, and binary correspondence
remain required; authenticating a floor alone does not prove a WASM module.

`wasm_instruction_events.nim` connects the opcode table to the event/stack
relation. It enforces instruction opening/closing, the initial root-frame
event, per-function program-counter progression, opcode continuity within
an instruction, final-end metadata, and canonical padding metadata. Fixed
signatures require the exact typed pops followed by their optional result.
Polymorphic unknown pops are allowed. Fixed rules cannot hide control-frame
operations; only unreachable permits a clear, which must occur exactly once.

Tests exercise all 140 numeric signatures with both concrete and unreachable
stacks (280 transcripts). Coherently changed result types and missing/extra
virtual pops pass the stack-only relation but fail the composed numeric
relation. The tests also reject changed input types, opcode changes within
an instruction, wrong program counters, and misplaced instruction boundaries.
The extended table adds 210 nonnumeric concrete/polymorphic transcripts, 362
type mutations, and 11 representative authenticated compositions. A forged
void-store result and a missing unreachable clear pass the stack-only relation
but fail the signature relation. The 16-row composed example uses 21,939
constraints, a 32,768-point QAP, and a 192-byte proof, including a SIMD body.
Its public inputs are event fields, not a WASM byte digest.

`InstructionSchedule.lean` proves schedule and metadata soundness/completeness.
`NumericEvents.lean` proves the field-valued type/count guards, refinement and
bounds of the event counters, and that a completed numeric body consists of
exactly its typed pops followed by its typed result. The automatic numeric
lookup witness is checked against the explicit witness across 1,024 tags,
including matrix/value equality and rejection of high field-bit aliases.
Bit weights use field addition for doubling; this also avoids a reproduced
Nim 2.2.6 compiler VM failure in Constantine's static-multiplier overload.
`StaticEvents.lean` extends the type/count guards to zero-result rules,
wildcards, references, and exactly one clear, with soundness and constructive
body-shape proofs for the fixed signatures.

The composed event circuit is still a partial relation. Dynamic instruction
signatures, control signatures, module/environment and immediate checks, and
raw binary binding remain required. Fixed stack effects alone do not establish
instruction validity, and these component proofs are not accepted by the
kernel as module-admission proofs.

`wasm_type_environment.nim` adds module-backed type lookups for `local.get`,
`local.set`, `local.tee`, global get/set, and table get/set/grow/size/fill.
Local keys contain both the 32-bit function namespace and 32-bit local index.
Global and table keys use disjoint even/odd addresses, preserving imported
index order. Global payloads include mutability, so a setter must query a
mutable declaration. Table queries require a reference type, and declared
unknown types are rejected, including unused initialized declarations. Table
initializers require reference tags and have no mutability flag. Queries are enabled at instruction begin, with
the resolved type held through the instruction. The implementation currently
uses dense query rows, including inactive rows; query compaction remains a
performance improvement.

`wasm_variable_events.nim` constrains exact pop/push counts and types from
those authenticated declarations. `wasm_typed_events.nim` composes it with
the existing fixed signatures and both authenticated stacks. Independent
transcript replay resolves these declarations directly from the decoded module.
Tests compare 7,168 opcode/type combinations against the independent Lean
exporter, then exercise all 45 supported signatures with concrete and
polymorphic stacks (90 transcripts), type substitutions, invalid indices,
imported namespaces, mutability violations, and missing/extra virtual pops.
The coherent result-type, immutable-setter, and virtual-pop forgeries pass the
previous partial relation and fail the new composition. Ten representative
authenticated compositions pass. The 16-row example uses 36,327 constraints
and two 192-byte proofs with one key.

`VariableTyping.lean` proves the 45 signature shapes, exact type matching,
namespace/address injectivity, and mutability encoding. `VariableEvents.lean`
proves field-valued input/output/count guards and completed body shape, plus
constructive body completeness. These proofs assume the specified lookup and
opcode equations; complete mechanical refinement of the Nim generators is
still open. This new entry point accepts table and immediate wires: it does
not bind them to the submitted WASM bytes, authenticate function/control
signatures, or replace kernel admission. Its public-input work also grows with
the event and table capacities; a 192-byte component proof alone does not meet
the requested fast full-module kernel verification target.

`wasm_signature_environment.nim` adds shared, immutable type lists for arbitrary
call arities. Node zero is nil. Every initialized nonzero node stores a known
three-bit type tag and a 32-bit next ID, with `next < id`; every nonzero
reference must resolve through the exact read-only argument, including unused
signature declarations and unused nodes. The prover interns identical
`(tag, next)` cells, so equal lists share a head. This is an exact representation,
not a hash or a random fingerprint. Parameters are stored in pop order and
results in source order.

Function metadata is constrained to equal the metadata of its declared type.
Function/type keys occupy disjoint even/odd namespaces. Function begin looks
up the current function's result head, and calls look up the callee's parameter
and result heads. `wasm_call_events.nim` checks direct/indirect calls and both
tail-call forms: argument pops advance the parameter list, result pushes
advance the result list, and normal-call completion requires both lists to
be exhausted. Indirect calls consume an initial i32 table index and query a
function-reference table using the separate table immediate. Tail calls
require the callee's result head to equal the current function's result head
and perform exactly one unreachable clear after consuming arguments. These
rules follow the repository's flat type model and
[WebAssembly call validation](https://webassembly.github.io/spec/core/valid/instructions.html).

`constrainValidationWithCalls` composes these rules with the prior fixed and
variable instruction checks and both authenticated stacks. Independent replay
resolves call signatures directly from the decoded module. Tests compare
6,048 signature cases with the Lean exporter, check every one of the 2,801
lists of length zero through four over the seven known tags, and exercise
66 valid call transcripts, including 17 parameters and five results.
Coherent forgeries cover argument counts, fabricated/missing results, tail
clear counts, result mismatches, function/type metadata substitution, lookup
bounds, invalid indirect tables, dangling heads, and cyclic/unknown unused
nodes. The 16-row composed example has 60,542 constraints, a 65,536-point QAP,
and two 192-byte proofs verified using one key. Fixed-capacity matrices are
compared across different value types and call arities.

`SignatureLists.lean` proves unique list interpretation, termination from
decreasing initialized references, payload/head packing injectivity, and
tail-result equality. Structural equality implies equal heads for a canonical
interned table; canonical interning is an honest-construction requirement for
completeness, not a soundness assumption about malicious witnesses.
`CallEvents.lean` proves the abstract cursor walk refines variable-arity call
typing, constructive cursor/body completeness, exact normal/tail body shape,
and the field-valued type/order/clear/end guards. Complete refinement of the
Nim generators and binary-to-signature construction remains open. The new
entry point still does not establish control signatures, all module rules,
raw-byte correspondence, or general kernel admission.

`wasm_indexed_signatures.nim` adds a verified indexed view of those shared
lists for control typing. Blocks must pop parameters in reverse order and
push them in declaration order; ends and labels need similar access in both
directions. The cache indexes complete declaration heads and the seven
singleton types, rather than indexing every intermediate list node. Its size
is linear in the declared type vectors, with sharing across repeated heads.
`buildSignatureEnvironment(..., includeSingletons = true)` supplies the
singleton nodes without changing the default call-only profile.

Each cached member records its ordinal, original node ID, and type tag.
Read-only node queries bind that tag and the next-node link to the original
list. Groups start at ordinal zero and their own head, advance through
consecutive ordinals and actual links, and end at nil at exactly the declared
length. Every nonempty length declaration must have a first member. Every
function/type head must have a length entry, including unused declarations.
The nil head has length zero; each singleton has its exact type and length one.
The component exposes authenticated length, member, and singleton queries.

`constrainSignatureMemberQuery` separately range-checks the 32-bit head and
ordinal before forming the 64-bit lookup key. A packed-address range check
alone would let ordinal `2^32` alias ordinal zero of the next head; a regression
demonstrates that alias and verifies that the typed query helper rejects it.
Control-rule callers must use the constrained components when constructing
member queries.

Tests cover all 400 vectors of length zero through three over the seven types,
with 2,268 independent forward/reverse queries. They reject 13 coherent cache
or lookup forgeries, including tag changes, dropped prefixes/suffixes,
relinked cells, missing lengths/heads, singleton substitution, and ordinal
overflow. Several forged caches pass a bare immutable lookup but fail the
node/list binding. The small profile has 25,889 constraints, a 32,768-point QAP,
and two 192-byte proofs with one key; the second witness changes node IDs and
metadata while preserving the matrix.

`IndexedSignatures.lean` proves indexed-group soundness and constructive
completeness, ordinal lookup correctness, bounded field-key injectivity,
reverse-index lookup, and the field-valued start/link/end guards. Connecting
these indexed reads to authenticated control-frame descriptors and all control
instruction transitions remains required. This component is not a completed
block/branch proof or a module-admission certificate; full Nim-generator and
binary-construction refinement also remain open.

`wasm_signature_frames.nim` now authenticates the signature descriptor and kind
of each live control frame. A 36-bit token distinguishes type-index blocks,
function roots, empty blocks, singleton result types, and block/loop/if/else
kinds. Two RAM slots per event bind a selected top/branch descriptor read
and a derived frame push. These reads are mutually exclusive at instruction
begin. Else reuses the authenticated if
descriptor; clears leave descriptors unchanged. Branch slots are range-checked
before address packing, so invalid depths cannot read stale popped frames.
The original floor/reachability RAM remains a separate authenticated column.

`wasm_control_typing.nim` uses these descriptors and the indexed list view to
constrain blocks, loops, if/else/end, simple branches, conditional branches,
and returns. Required frame transitions and exact input/output counts are
checked even for zero-arity signatures. Loop labels use start types; other
labels and returns use the appropriate result types. An if without else must
have equal parameter/result vectors even when actual pops are unknown.
The implicit function end consumes its declared results without pushing them
back. The try-table opening has its block-like stack effects checked; catch
clauses and exception typing are not thereby established.

`wasm_structured_validation.nim` composes the new relations with fixed and
variable instruction typing, calls, all signature/index tables, and both
existing stack arguments. Its tables and instruction metadata are still
unbound to raw WASM bytes. In particular, the current compact IR block-type
field has a 16-bit representation boundary that the binary-to-IR proof must
handle before general admission. This is not a new kernel proof mode.

Tests exercise scalar/vector/reference signatures, multi-value control,
implicit/explicit else, real and polymorphic branches, returns, and imported
function namespaces. Coherent forgeries include conflicting function results,
wrong live branch targets, invalid depths/pads, skipped frame lifecycles,
implicit-else type mismatches, and conditional-branch arities. They pass the
preceding partial relation and fail the new composition. The 16-row composed
profile has 123,858 constraints and a 131,072-point QAP. Two 192-byte proofs use
one key while changing both value types and the control-frame history; the
second witness includes a nested empty block. Public-input work still grows
with the profile, so this is not a constant-work general-module verifier.

This profile opts into structural range-witness reuse and literal folding.
Reuse requires the same unit-coefficient wire and exact width within one
circuit; equal witness values never share a certificate. Literal bits are
fixed matrix constants, and an out-of-range literal emits a contradiction.
Together with the two-slot descriptor RAM, this reduced the initial 150,116
constraints to 122,578 before adding the parametric checks below, and halved
the padded QAP domain. These are circuit-size
measurements, not an end-to-end proving-time benchmark. Reuse defaults off,
preserving the existing profiles and their verification-key matrices.
`make zkbuild-range-reuse-test` checks 45 range/shape comparisons plus alias
and literal regressions. `RangeReuse.lean` proves certificate reuse by exact
wire/width identity and constant-bit certificate validity; mechanical
refinement of the Nim cache implementation remains open.

`SignatureFrames.lean` proves descriptor packing injectivity, preservation of
the signature stack, live target authentication from RAM reads, and natural
target-depth bounds from field constraints. `ControlPlans.lean` proves the
abstract action-plan body and checker soundness/completeness, implicit-else
equality, condition-pop conservation, zero-sum guards, and final count guards.
An independent Lean checker compares action plans extracted from structurally
replayed traces using module block types and actual validation frames; its
mutations include omitted inputs, altered results, and extra frame actions.
The complete field-transition-to-plan composition and mechanical refinement
of the Nim generators remain open. Catch clauses, remaining
instruction/environment checks, module rules, and byte binding are still
required for the requested full runtime profile.

`wasm_parametric_events.nim` constrains `select`, typed `select`, and
`ref.null` in both production compositions. Selects consume exactly three
operands in order, require an i32/unknown condition, and produce one value.
Untyped selects exclude reference operands, compare both concrete value
types, and derive the result from their actual tags. Typed selects bind all
seven supported value-type encodings to the declared output, including in
unreachable code. `ref.null` accepts exactly the two reference encodings and
pushes the matching reference type. These follow the current runtime's
supported types and the [parametric validation rules](https://webassembly.github.io/spec/core/valid/instructions.html#parametric-instructions).

Tests cover 28 valid traces, 18 coherent type/arity/immediate forgeries,
35 independent Lean trace plans, 38,912 finite action/type cases, and three
Lean plan mutations. The standalone 16-row profile has 23,683 constraints,
a 32,768-point QAP, and two 192-byte proofs with one key.
`ParametricEvents.lean` proves inference soundness/completeness, declared-type
bounds, bounded immediate equality, concrete/unknown input guards, reference
exclusion, output selection, and pop ordinals. Full field-trace composition
and mechanical generator refinement remain open.

`instruction_metadata.nim` and `instruction_lookup.nim` add memory/SIMD
immediate metadata. A fixed reduced opcode DAG shares 62 branches; its
standalone circuit has 93 constraints including public output bindings.
All 65,536 opcode payloads match an independently declared Lean table.
Tests compare 1,027 R1CS matrices and reject 8,216 public substitutions,
including high-opcode aliases. The generic DAG builder is deterministic;
`LookupFlow.lean` supplies the shared-flow conservation argument. Mechanical
refinement of the generated Nim graph remains open.

`wasm_memory_metadata.nim` checks memory presence, the supported single-memory
index for size/grow, scalar/SIMD natural alignment, all implemented lane
indices, and vector constant-pool membership. Scalar memargs retain offset
in `imm1` and alignment in `imm2`; SIMD load/store memargs retain alignment in
`imm1` and offset in `imm2`. Pool counts use full function-index namespaces
and exact read-only queries. Counts and indices are separately bounded before
the strict range check. Large offsets remain valid validation inputs: an
out-of-bounds access can trap at execution time.

The host validator now rejects excessive scalar alignment and nonzero
memory size/grow indices, which were previously unchecked. These enforce
the [memory argument validation rules](https://webassembly.github.io/spec/core/valid/instructions.html#memory-instructions)
without changing the runtime's immediate layout. Memory peephole fusions now
retain invalid alignments for rejection, since fused IR omits that metadata.
The host tests cover 229 alignment/index/lane/pool cases, including both
decoded memarg layouts and valid/invalid optimized memory fusions.

`wasm_memory_validation.nim` composes these checks with the branch/parametric
path. It reuses that path's authenticated event projection. The 16-row test
profile has 141,847 constraints and a 262,144-point QAP; two 192-byte proofs
share one key while changing memory presence, opcode types, and pool queries,
starting from ordinary decoded WASM modules. Tests also reject coherently
regenerated bad immediates, missing memories, function/pool namespace aliases,
and out-of-range lane/alignment/count fields: 193 memory/SIMD cases and ten
coherent/environment forgeries pass their expected acceptance/rejection checks.
Its public tables and events are still unbound to raw bytes, and public-input
verification work still grows with the profile. Remaining context rules,
module rules, byte binding, and general kernel
admission remain required.

`InstructionMetadata.lean` proves natural alignment from access widths,
field-valued alignment and strict index guards, bounded lane masks, and
memory presence. These are component theorems; the complete Nim/circuit,
binary-to-table, and module-admission refinement is unfinished.

`wasm_bulk_context.nim` adds data/element segment membership, mandatory
data-count headers for data instructions, supported memory indices, and exact
table/element type compatibility. Element entries use dense indices; table
queries retain the separate global/table namespace. Optional u32 headers now
use int64 storage so high-bit counts and start indices cannot alias the absent
sentinel. Both binary readers use the actual section order, placing tags before
globals and data counts before code, and reject unknown, duplicate, reordered,
or oversized sections.

`wasm_bulk_validation.nim` composes these checks with the memory/branch path.
The test profile has 151,744 constraints for 16 rows and a 262,144-point QAP.
Two 192-byte proofs share one key across ordinary data-drop and element-drop
binaries. Tests compare 36,288 independent Lean cases, 24,192 host validations,
981 circuit shapes, 256 section ranks, 12 composed traces, and 15 coherent or
boundary forgeries. Another 75 host cases exercise header and decoder rules.
`BulkContext.lean` proves bounded index/header guards, table type guards,
dense keys, section ordering, and optional-u32 representability. Segment
initializers, remaining module rules, the complete field-trace composition, and
raw-byte binding remain separate obligations.

`wasm_reference_context.nim` adds `ref.func` declaration membership and
function existence. `reference_context.nim` collects sorted, unique references
from global initializers, element segments, and function exports; imports,
start functions, and uses inside function bodies do not declare references.
The host validator now rejects missing declarations, following the
[reference validation rules](https://webassembly.github.io/exception-handling/core/valid/instructions.html#reference-instructions).
Declaration indices are range-checked once per table entry; each instruction
uses an exact immutable lookup with a constant declaration value.

`wasm_reference_validation.nim` composes that relation with the bulk path. Tests
compare 2,560 independent Lean/R1CS cases with identical matrices, 512 host
validations, nine declaration/context cases, and twelve coherent or boundary
forgeries. Two ordinary binaries (export and declarative-element references)
produce 192-byte proofs using one key. The 16-row profile has 155,773
constraints and a 262,144-point QAP. `ReferenceContext.lean` proves declaration
origins, executable-reference soundness, bounded initializer indices, and
membership-to-function-bound composition. These are component proofs; sorted
collection refinement, raw-byte construction, and full field-trace refinement
remain open. Public events and tables still make verification work grow with
the profile.

Decoder regressions also reject unsupported SIMD sub-opcodes, which previously
could disappear from decoded code, and nonzero exception-tag attributes.
These host fixes prevent those bytes from becoming validation witnesses; the
general decoder still needs a circuit binding and formal refinement.

The broad composition below adds catch typing, module/constant-expression
constraints, full-width block types, and a closed admitted-opcode relation.
Raw bytes still must determine all events and environment tables inside the
proof. Constant-size public claims and general kernel admission must follow
that binding; recursion and complete implementation refinement remain
unfinished. The component profiles above do not establish these claims.

`wasm_throw_events.nim` now links a dense exception-tag table to the shared
type table, requires every tag to have no results, and walks the authenticated
parameter list for `throw`. Each payload value must match its declared type
or the unreachable unknown type. Payloads must finish before the unique
unreachable transition; pushes, extra pops, early clears, and control events
are rejected. Type-table membership is checked once per tag. The host validator
and independent transcript replay now enforce tag existence and payload pops.

`wasm_throw_validation.nim` composes those rules with the reference path.
The tests compare 16,128 independent Lean/Nim body cases and 344 R1CS shapes,
exercise 58 concrete/polymorphic full traces, and reject nine context/type/arity
forgeries. The 16-row profile has 169,025 constraints, a 262,144-point QAP, and
two 192-byte proofs sharing one key across ordinary tagged/opaque throw
binaries. `ThrowEvents.lean` proves the executable body shape and completeness,
shared-list cursor refinement, tag signature resolution, and the result guard.
Full field-trace and implementation refinement remain open.

The opaque `throw_ref` test follows this runtime's existing externref
representation. It does not establish standard exnref typing or exception
object/propagation semantics: the interpreter traps on `throw_ref`, and native
throw lowering currently traps as well. Standard exception-object semantics
and compiler correspondence remain required before any general admission
claim; the catch constraints below cover the current runtime representation. Existing admitted bounded keys remain separate from these components.

`wasm_branch_validation.nim` extends the composition with `br_table`. The
validator's optional `labelChecks = true` trace emits one `veLabelCheck`
marker per nondefault target and one for the default. These markers preserve
both stack heights and make zero-arity targets observable. The existing
trace entry points default to the preceding event profile; its selector
matrix and existing bounded kernel keys are unchanged.

`wasm_branch_environment.nim` interns complete target lists, including the
default as the final node. A bank key contains the full 32-bit function and
table indices; each node stores a 32-bit depth and next-node ID. Authenticated
decreasing links exclude cycles and dangling references. Every marker consumes
one node, the cursor cannot read nil, and the instruction must consume the
entire list. Signature-frame RAM reads authenticate each live target before
its type queries. Invalid depths cannot read a stale popped frame.

`wasm_branch_typing.nim` checks the i32/unknown condition, equal target
arities, each target's label types, complete pop/restore phases, and exactly
one final clear. Loop labels use parameter types; other labels use results.
It permits different target type vectors when unknown operands match them.
A separate exact RAM argument saves actual popped tags by event-row address
and restores them in reverse order for nondefault targets. In particular,
unknown values remain unknown. The ordinal is range-checked before adding
the saved start address, preventing a borrow from aliasing another pop.

The composition shares metadata and indexed lookup slots across ordinary
control events and branch-table events. The two query streams are mutually
exclusive, and each inactive private value is constrained to zero before
merging. A regression preserves the merged ROM value while corrupting both
inputs and verifies rejection of that cancellation attempt.

`BranchLists.lean` proves bounded node packing injectivity, decreasing next
links from field guards, and complete target-list consumption.
`BranchPlans.lean` proves action-plan checker soundness/completeness, uniform
arities, bounded scratch reversal, marker height preservation, and safe query
merging. The reverse field guard rules out an out-of-range restore ordinal
before address construction. Pop/restore lemmas preserve concrete and unknown
tag vectors across subsequent target checks. The independent checker uses
module branch banks and structurally
replayed frame types, without decoding the proving tables. The complete
field-transition-to-plan proof and Nim refinement remain open for this
extension too; these component proofs are not full WASM admission.

Tests cover scalar/vector/reference values, multiple targets and functions,
distinct loop parameter/result types, imports, unknown restoration, and
ordinary decoded WASM bytes. There are 29 valid traces, 15 coherent/environment
forgeries, 33 independent Lean action plans, and four Lean plan mutations.
The 16-row branch composition uses 141,529 constraints and a 262,144-point
QAP. Lookup sharing reduced the preceding version from 172,814 to 140,249
constraints; adding the parametric layer accounts for the current total.
Two 192-byte proofs share one key while changing the target-list
length. The witness builder creates the shared lookup routing once. Public
inputs still contain the tables and trace; kernel work is not yet constant
for general modules.

The new Lean proofs cover Boolean switch soundness for arbitrary field
assignments, multiset preservation for arbitrary switch schedules, bounded
packing injectivity, range and ordering constraints, and RAM read semantics.
`MemoryConstraints.memory_sound` connects the row constraints and exact
record permutation to each address's chronological read/write history.
The concrete permutation and packing checks below connect those components to
the emitted Nim matrices. Routing completeness and full memory-generator
refinement remain open; these proofs do not establish full WASM validation.

The general validator now checks branch-table targets and argument types,
unreachable-stack balance, implicit function results, missing control ends,
if-without-else types, typed selects, indirect-call indices, function/code
counts, and start-function signatures. These repairs follow the
[WebAssembly validation algorithm](https://webassembly.github.io/spec/core/appendix/algorithm.html).
They do not establish full specification conformance: instruction and module
rules still need a coverage audit and independent conformance tests.

Still required for this path are the full binary-to-events constraints,
instruction/type/environment constraints, control signatures and label/table lookups,
aggregation for large modules, a kernel-pinned verification key, and formal
soundness/completeness proofs for the new relation. No general-WASM success
claim is made by the current prover or verifier.

## Commands

From the repository root:

```sh
make zkbuild
make zkbuild-test
make zkbuild-compile-demo
make zkbuild-native-qemu-test
make zkbuild-byte-compile-test
make zkbuild-byte-compile-matrix-test
make zkbuild-byte-decoder-test
make zkbuild-byte-compile-witness-test
make zkbuild-byte-compile-demo
make zkbuild-byte-native-qemu-test
make zkbuild-fv
make zkbuild-model-test
make zkbuild-matrix-test
make zkbuild-slot-matrix-test
make zkbuild-witness-test
make zkbuild-slot-witness-test
make zkbuild-compile-witness-test
make zkbuild-compiler-test
make zkbuild-qap-test
make zkbuild-fft-model-test
make zkbuild-qap-bench
make zkbuild-crypto-test
make zkbuild-verifier-core-test
make zkbuild-scalar-encoding-test
make zkbuild-wasm-validation-test
make zkbuild-numeric-typing-test
make zkbuild-numeric-lookup-test
make zkbuild-permutation-test
make zkbuild-memory-test
make zkbuild-operand-events-test
make zkbuild-control-events-test
make zkbuild-instruction-events-test
make zkbuild-static-typing-test
make zkbuild-static-lookup-test
make zkbuild-static-events-test
make zkbuild-read-only-test
make zkbuild-variable-events-test
make zkbuild-call-events-test
make zkbuild-indexed-signatures-test
make zkbuild-control-typing-test
make zkbuild-parametric-test
make zkbuild-wasm-metadata-test
make zkbuild-instruction-lookup-test
make zkbuild-memory-metadata-test
make zkbuild-bulk-context-test
make zkbuild-reference-context-test
make zkbuild-throw-events-test
make zkbuild-branch-typing-test
make zkbuild-range-reuse-test
make zkbuild-interop-export
make zkbuild-target-check
make zkbuild-validator-target-check
make zkbuild-check
make zkbuild-demo
make zkbuild-bench
```

The first target fetches the pinned dependency into `build/zkbuild-deps`.
Building the CLI through `make zkbuild` also requires the independent Lean
matrix comparison and its mutation checks to pass before compiling the tool.
`zkbuild-test` executes host tests with assertions and bounds checks enabled.
`zkbuild-fv` runs Lean 4.35.0. `zkbuild-target-check` cross-compiles the verifier
and native loader to M0 object files; it does not link a complete firmware or
run hardware.

The CLI supports separate setup, proving, and verification processes:

```sh
build/zkbuild/zkbuild sample build/zkbuild/sample.wasm
build/zkbuild/zkbuild setup validate build/zkbuild/validate.pk build/zkbuild/validate.vk
build/zkbuild/zkbuild prove build/zkbuild/validate.pk build/zkbuild/sample.wasm build/zkbuild/sample.proof
build/zkbuild/zkbuild verify build/zkbuild/validate.vk build/zkbuild/sample.wasm build/zkbuild/sample.proof

build/zkbuild/zkbuild sample-slots build/zkbuild/slots.wasm
build/zkbuild/zkbuild setup compile build/zkbuild/compile.pk build/zkbuild/compile.vk
build/zkbuild/zkbuild prove build/zkbuild/compile.pk build/zkbuild/slots.wasm build/zkbuild/compile.proof build/zkbuild/sample.rv32
build/zkbuild/zkbuild verify build/zkbuild/compile.vk build/zkbuild/slots.wasm build/zkbuild/compile.proof build/zkbuild/sample.rv32

build/zkbuild/zkbuild setup compile-bytes build/zkbuild/compile-bytes.pk build/zkbuild/compile-bytes.vk
build/zkbuild/zkbuild prove build/zkbuild/compile-bytes.pk build/zkbuild/sample.wasm build/zkbuild/compile-bytes.proof build/zkbuild/bytes-compiled.rv32
build/zkbuild/zkbuild verify build/zkbuild/compile-bytes.vk build/zkbuild/sample.wasm build/zkbuild/compile-bytes.proof build/zkbuild/bytes-compiled.rv32
```

An arbitrary existing WASM file will usually be rejected because this first
profile is deliberately restricted. The prover does not silently reinterpret,
normalize, or certify unsupported instructions.

## Proof construction and binding

The first backend is direct [Groth16](https://eprint.iacr.org/2016/260) over BLS12-381. It provides a real 192-byte
compressed proof. It is a baseline for later sumcheck/recursive backends, not an
implementation of the proposed custom multilinear IOP.

Witness-independent R1CS constrains Boolean opcode selectors, immediate bits,
and operand-stack transitions. The compile relation also constrains constant
materialization and instruction encodings. Every artifact byte participates in
public inputs packed into 31-byte little-endian limbs. These are strictly less
than the scalar modulus, so packing is injective. The current verifier's public
input work grows with the profile capacity; no constant-time-in-artifact-size
claim is made. Each profile fixes its public-input count. The byte-stream
profile binds the actual length in addition to the padded byte vector.
The current byte circuit has 8,188 constraints and 6,096 wires, using an
8,192-point QAP domain. Its phase residual replaces two redundant gates per
byte row; the corresponding field identity is proved in Lean. Changes that
cross the next power-of-two domain boundary have a substantial proving cost,
so the host checks enforce this capacity limit.

The ordinary-byte compilation circuit contains 23,555 constraints and 21,277
wires in a 32,768-point domain. Its twelve public inputs bind raw length, six
WASM limbs, and five native limbs. It composes the existing byte-validation
and fixed-slot compilation matrices through fresh private wires. A constrained
LEB accumulator and sixteen-entry operation queue connect the two relations.
Queue overflow is rejected by the constraints, independently of the host parser.
Operation tokens include their kind and exact 32-bit constant. They are compared
directly in the scalar field; no unchecked host normalization or rolling hash
stands in for the connection.

Proof and key codecs use canonical field/curve encodings with point/subgroup
validation, bounded lengths, and rejection of trailing data. Setup, proving,
and verification use the same sparse matrices. Proving rejects a changed matrix
shape, invalid wire references, a changed constant-one wire, and unsatisfied
R1CS equalities. Proofs use fresh operating-system randomness.
Blinding retries a nonce when it produces an infinity A or B point, matching
the verifier's decoding policy. The expensive unblinded MSM results are reused.
Candidate selection stops with an error after 128 unusable nonces. Valid C
points at infinity remain supported.

The QAP stage interpolates the constraint values, evaluates on a disjoint
multiplicative coset, divides by the constant value of `X^n-1` on that coset,
and interpolates the quotient. This is the standard coset route used by
[Bellman's evaluation domain](https://github.com/zkcrypto/bellman/blob/main/src/domain.rs).
It uses three `n`-element polynomial buffers, replacing the previous `2n`
convolution buffers. The original-domain R1CS equalities are checked before
the transforms; coset division alone is not a divisibility check. The code
also rejects an unexpected degree-`n-1` quotient coefficient. A separate
double-domain convolution and remainder checker remains in the test tools.

`src/bl808/wasm_proof.nim` accepts a caller-pinned SHA-256 verification-key digest
and a caller-selected claim. A proof cannot select a new key or downgrade a
compile claim to a validation claim. The module is opt-in and is not called by
the production WASM loader.

For repeated checks, `prepareWasmKey` hashes and validates the pinned key once
and returns an opaque `PinnedWasmKey`. The handle owns its decoded points,
retains its claim, and rejects default/uninitialized handles. Reusing it avoids
key hashing, decompression, and subgroup checks on every module. Proof decoding
still checks canonical encodings and subgroup membership for every proof; the
internal pairing equation is private so callers cannot bypass these checks.

`src/bl808/wasm_verified_loader.nim` adds an explicit proof-gated loading API for
the byte-stream profile. It copies caller bytes, verifies the proof over that
snapshot, and instantiates from the same snapshot. The module handle keeps its
VM private. Changing caller memory after admission cannot change the running
module. The normal validator remains a consistency backstop in this experimental
path. Existing unverified loader APIs retain their behavior.
Both the verifier and proof-gated loader accept a prepared key handle. For
example, after importing the two adapters and `cps/zk/wasm_profile`:

```nim
let policy = prepareWasmKey(trustedDigest, pmValidateBytes, keyBytes)
if policy.status != wprOk:
  raise newException(ValueError, "pinned proof key rejected")
let loaded = loadVerifiedWasm(policy.key, wasmBytes, proofBytes)
if loaded.status == vwlOk:
  let value = loaded.module.invokeI32([20'i32, 22'i32])
```

`src/bl808/wasm_verified_native.nim` provides the corresponding native path for
`compile`. It checks exact artifact/proof lengths, snapshots the inputs, requires
a pinned compilation key, and verifies the proof before allocating executable
code. The admitted handle owns a private, word-aligned copy of the verified
144-byte native artifact. Its code buffer and entry pointer are not exposed.
On M0, admission cleans the data cache, fences, invalidates the instruction
cache, and executes `FENCE.I` before publishing the initialized handle.
Default/uninitialized handles cannot execute. Validation-only keys cannot admit
native code.

After importing `bl808/wasm_verified_native`, use:

```nim
let policy = prepareWasmKey(trustedDigest, pmCompile, keyBytes)
if policy.status != wprOk:
  raise newException(ValueError, "pinned compilation key rejected")
let loaded = loadVerifiedNativeWasm(policy.key, wasmBytes, nativeBytes, proofBytes)
if loaded.status == vnlOk:
  let value = loaded.module.invokeI32([20'i32, 22'i32])
```

Native invocation requires a little-endian RV32 target. It is enabled for M0;
the explicit `zkbuildRv32Ram` test/platform define also permits RV32IM targets
with executable, coherent RAM. Other hosts can test admission but cannot invoke
RV32 bytes. The private handle protects against changes through caller-owned
artifact buffers; it does not provide memory isolation from arbitrary kernel
writes. The caller must retain the handle for the duration of execution.

`loadVerifiedByteNativeWasm` provides the same ownership and publication path
for the distinct `pmCompileBytes` key. It accepts variable-length WASM and
requires the ordinary-byte compilation claim. The existing
`loadVerifiedNativeWasm` continues to require `pmCompile` and a fixed-slot input.

Setup is currently single-party and intended for experiments. Its secret
randomness is never serialized, but a production ceremony and secret-erasure
review are still required. The prover's curve operations are variable-time;
this is not a side-channel-hardened proving service.

## Formal evidence

`formal/zkbuild/ZkBuild.lean` currently proves:

- Successful step checking implies a defined stack step with the stated height.
- Successful program checking implies defined execution and the stated result
  height, for all parameter values.
- An admitted program terminates with one result in the model.
- The restricted stack-register map is injective and uses caller-saved registers.
- The signed LEB128 constant representation reconstructs every 32-bit input.
- LUI plus signed ADDI materializes every 32-bit constant, including carry edges.
- The RV32 portable carry and borrow fallback formulas.
- Injectivity of fixed-length byte packing, including its scalar-field capacity.
- Boolean and selection R1CS algebra over an abstract field.
- The Groth16 scalar completeness identity under the stated key/QAP equations.

`Rv32Encoding.lean` specifies and proves roundtrips for the supported RV32
instruction encodings and little-endian instruction bytes. Its execution model
includes signed ADDI immediates, low-word multiplication, ignored writes to
register zero, and the canonical return instruction.

`Rv32Compiler.lean` proves semantic preservation for every accepted program in
the restricted instruction language and every pair of parameter values. It
tracks the complete operand stack in registers, proves the prologue saves the
parameters before stack writes can overwrite them, and proves the final `a0`
value agrees with WASM execution. All registers outside the ABI caller-saved
set, including the return address, remain unchanged. The theorem covers the
emitted instruction bytes, not just an abstract list of operations.

`make zkbuild-compiler-test` compares the Nim emitter against this Lean model:
297 programs, all 42,768 native bytes, 39,204 WASM bytes, and 7,425 executions
through the independent test RV32 decoder. It also checks both artifact codecs
roundtrip and that decoding WASM preserves the native artifact. It covers all binary operations at every permitted stack
depth, constant carry/sign boundaries at every destination register, parameter
copies, padding, and mixed programs. Both implementations reject underflow,
overflow, and missing-result fixtures. This is conformance evidence rather
than mechanical verification of the Nim compiler. Both sides of a satisfying
`pmCompile` matrix are now connected to this emitter theorem, including the
submitted WASM and native bytes. The theorem does not certify the existing
optimizing JIT.

`formal/zkbuild/ByteStream.lean` additionally proves that the parser's arithmetic
transition equations equal a direct state-machine specification for all 18,432
phase/height/byte combinations. It proves that the equality composes over
arbitrary byte streams and that a successful trace obeys the i32 stack typing
transitions. Representative trace events establish type availability; they do
not claim equality of concrete numeric results from different operations.

`make zkbuild-model-test` exports the reference transition table from Lean and
checks the actual production Nim row gadget against every entry. It compares
all 40 auxiliary selector/product wires to the formally justified symbolic
witness construction: 737,280 wire values across the 18,432 cases. It also
checks that incorrect opcode hints cannot satisfy the row constraints. The
comparison is exhaustive over the discrete row inputs; it is not a formal
verification of the Nim compiler or field-arithmetic implementation.

`formal/zkbuild/R1CS.lean` proves the linear-combination and multiplication,
equality, and Boolean-gate semantics. It also proves that the Boolean-selector
sum has the intended natural-number count for a field of characteristic equal
to the BLS12-381 scalar modulus. This rules out modular wraparound in that count
under the stated field assumptions.
It further proves that arbitrary field-valued opcode selectors satisfying the
Boolean, sum, and byte-binding equations select an allowed opcode, and proves
the phase-residual identity used to reduce the circuit size. These proofs do
not depend on enumerating honest witness values.
It proves injectivity of the actual field-valued 31-byte packing relation under
the scalar-field characteristic assumption, including the no-wrap bound.
For both opcode and non-opcode phases it proves uniqueness of the selector
vector, not merely membership in the allowed opcode set.

`formal/zkbuild/BitPacking.lean` proves that eight constrained Boolean field
values encode a byte, and that two such decompositions of the same byte must
agree in every bit. This prevents an alternative continuation/sign-bit witness
for an already-bound byte under the stated field assumptions.

`formal/zkbuild/CircuitShape.lean` defines the complete integer-coefficient
matrix independently of Nim. `make zkbuild-matrix-test` compares all 8,188
constraints, ordered wire references, coefficients modulo the scalar prime,
and public/witness dimensions against the production Nim builder. It checks
the full matrix, not just evaluated sample witnesses. Six negative variants
exercise rejection of changed dimensions, rewired inputs, changed coefficients,
missing gates, truncation, and trailing data. The Lean model proves that equality
of the canonical matrices transfers satisfaction for every field assignment.
The executable file comparison still relies on the host compiler, file I/O,
and the Nim scalar serializer; it is not a proof of the Nim compiler itself.

`SlotShape.lean` independently specifies the fixed-slot matrices.
`make zkbuild-slot-matrix-test` checks all 11,947 compilation constraints and
1,990 fixed-slot validation constraints against Nim, including every ordered
wire/coefficient term. It runs the six matrix mutation checks in both modes.

`SlotRowSchema.lean` and `SlotRow.lean` eliminate the auxiliary multiplication
wires of a compilation slot and prove its residual equations and byte/depth
outputs for arbitrary satisfying field assignments. `SlotSelection.lean`
proves that the Boolean/sum constraints select exactly one opcode.
`SlotRowSemantics.lean` proves that, given an incoming one-hot stack height,
the slot selects a valid transition and produces the specified next height.
`SlotMatrix.lean` checks all 16 row substitutions into the full compilation
matrix and transfers these row theorems to every satisfying full assignment.
The proofs do not assume that the witness came from the honest prover.

`SlotTrace.lean` composes all 16 rows using checked adjacency and final-result
constraints. Every satisfying full matrix yields a selected opcode sequence
with a valid stack trace from height zero to height one. `SlotProgram.lean`
connects this sequence to the program checker used by the emitter proof, for
any assignment of constant values. Thus the compiler theorem applies to that
recovered sequence, rather than requiring valid intermediate heights as
external assumptions.

`SlotImmediate.lean` recovers the exact 32-bit immediate from any satisfying
bit assignment. Bounds lift the carry equation from the scalar field to an
integer equality; it then forces the emitter's rounded 20-bit LUI immediate
and the overflow bit, including wraparound at `0xfffff800`. It also proves
every packed slice equals the corresponding bitvector extraction.
`SlotMatrix.full_row_immediate` transfers these conclusions to every row of
the full matrix. These arithmetic proofs use kernel-checked reasoning rather
than enumerating immediate values.

`SlotBytes.lean` reduces both byte-output equations to the selected opcode and
incoming height, and connects the five constant payload bytes to the signed
LEB128 encoding of that recovered immediate.

`SlotNative.lean` proves that every row's eight native bytes equal the two
instructions emitted for its selected operation. Its constant proof covers
every 32-bit immediate. `SlotEmission.lean` composes these rows and includes
the exact prologue, epilogue, and return bytes. `SlotNativeBinding.lean` checks
all five native packing gates against the full matrix and uses the 31-byte
packing injectivity theorem to bind the submitted 144-byte native artifact.
Its `native_artifact_sound` theorem recovers a checked 16-operation program
whose compiled bytes equal that artifact; `native_execution` connects those
submitted bytes to the recovered program's execution for arbitrary input
registers. These statements cover arbitrary satisfying witnesses.

`WasmEncoding.lean` specifies the fixed-slot binary encoder and a decoder that
requires exact re-encoding and an accepted stack program. It proves encoding
roundtrips through that decoder. `SlotWasm.lean` binds every WASM row, the
header, and the final end byte to this encoding. `SlotCompilation.lean` checks
the five WASM packing gates and composes them with the native proof. Its
`compilation_soundness` theorem shows that the submitted 132-byte WASM binary
decodes to the same checked program whose emitted bytes equal the submitted
144-byte native artifact. `compilation_execution` gives the same returned i32
for both byte-level execution models for every initial register assignment.

This closes soundness of the complete bounded `pmCompile` matrix under the
documented field, public-input, and model assumptions. It does not refine the
compiled Nim implementation mechanically or cover general WASM programs.

`NativeAdmission.lean` models the fixed-slot native loader's length checks, verification
gate, owned snapshot, and little-endian word copy. It proves that converting
admitted instruction words back to bytes returns exactly the verified native
artifact. Given a verifier that accepts only satisfying compilation relations,
every admitted image returns the same i32 as its saved WASM binary for all
inputs. Verifier soundness is an explicit theorem hypothesis. This is not a
proof of Constantine, the Nim runtime, cache maintenance, or physical memory
isolation; those implementation/platform refinement obligations remain open.

For `compile-bytes`, `ByteCompileShape.lean` independently specifies the full
23,555-constraint matrix. The matrix test compares every wire, coefficient,
gate, and dimension and rejects six deliberately altered matrices.
`ByteCompileComposition.lean` proves that any satisfying combined assignment
projects to satisfying assignments of both established component matrices,
with the submitted raw/native public inputs preserved. Thus the submitted raw
binary is in the supported profile and the native artifact is an emission of
a checked slot program. `ByteCompileQueue.lean` proves operation-token
injectivity, nop-removal semantics, exact queue retention, and overflow rejection.

`ByteCompileRow.lean` checks the 28-gate bridge template at all 121 byte positions
and derives its arithmetic and queue equations for arbitrary satisfying
assignments. `ByteCompileDecodeRow.lean` connects its phases, bits, selectors,
and constant-finished flag to the validated parser state and submitted byte.
`ByteCompileTransition.lean` eliminates the arithmetic temporaries into exact
integer transitions. `ByteCompileScalarStep.lean` proves the signed-LEB update
formula and bounds it for every accepted parser transition and every permitted
integer accumulator. `ByteCompileAccumulator.lean` composes that reasoning
through all 121 rows, proving that every accumulator is the field image of a
32-bit value; it does not assume an honestly generated witness.

`ByteCompileEvents.lean` proves that each event token identifies the concrete
decoded instruction, including its complete i32 constant. `ByteCompileQueueStep.lean`
connects the actual queue gates to shifts and unchanged rows.
`ByteCompileDecodeTrace.lean` composes the decoder and queue through the full
byte stream, proves that no instruction is discarded, and rejects overflow.
`ByteCompileSlotBinding.lean` then binds each final queue entry to the emitter's
opcode and immediate wires. Injectivity of operation tokens forces equality of
the decoded and emitted programs.

`ByteCompileSoundness.binary_execution` proves that any satisfying combined
matrix with the submitted public bytes has the same returned i32 value in the
Lean byte-decoder and RV32 execution models, for every input register state.
Its decoder checks the complete bounded WASM profile before executing the
decoded instruction sequence. `ByteNativeAdmission.lean` carries this property
through the owned-code loader model, with cryptographic verifier soundness as
an explicit hypothesis. These are model-level soundness theorems, not mechanical
verification of the compiled Nim implementation or cryptographic library.

`make zkbuild-byte-decoder-test` compares the independent Lean decoder with Nim:
149 accepted programs, all sixteen output slots, 3,725 input executions, and
seven rejected modules. Cases cover signed-LEB lengths and sign boundaries,
non-minimal encodings, full-capacity nop removal, deterministic mixed programs,
bad headers, malformed immediates, and excess instructions. Every accepted
result also agrees with the existing WASM interpreter and independent RV32
test interpreter. This conformance check is part of both CLI build and full
verification targets.

`ByteCompileTyping.lean` proves independently that every accepted byte decoder
result is a checked emitter program. `ByteCompileRowComplete.lean` constructs
all 27 auxiliary values of a bridge row and proves all 28 gates, conditional
only on the row's overflow guard. Its construction works for arbitrary field
inputs, not just enumerated opcode examples.

`ByteCompileMerge.lean` proves that embedding the byte and emitter witnesses
in their disjoint wire ranges preserves both component relations, regardless
of the bridge values. The executable constructor uses this same embedding.
`ByteCompileAssembly.lean` checks an exhaustive partition of all 23,555 gates
and reduces assembly completeness to bridge assignments, overflow guards,
auxiliary products, and final token equalities. Its row theorem reduces the
bridge constraints to the explicit 27-value constructor and the overflow guard.
The later completeness proof discharges those conditions for the constructed
semantic witness.

`ByteCompileConstructionTrace.lean` independently proves that decoding only
appends operations. For any accepted decoder run with at most sixteen operations,
every operation emission has queue capacity and the corresponding padded queue
has a zero head. This establishes the semantic no-overflow property without
assuming that a circuit witness already exists. It also proves the accumulator
range throughout the accepted run and connects decoder states to parser states.

`ByteCompileCanonicalRow.lean` constructs each bridge row from the actual
decoder state and byte. It proves row satisfaction, the next immediate, and the
complete next queue. `ByteCompileSourceWitness.lean` proves that the embedded
byte witness supplies the same parser inputs, without assuming bridge validity.
`ByteCompileBridgeWitness.lean` connects these rows through the actual global
wire layout and proves all 121 bridge rows for every accepted binary.

`ByteCompileCompleteness.binary_complete` constructs a witness satisfying all
23,555 constraints with the original WASM bytes and exact emitted RV32 bytes as
public inputs. It discharges the final emitter-token and constant-product
constraints. `binary_relation_iff` combines this construction with soundness:
within the admitted artifact lengths, a satisfying public-input-bound witness
exists exactly when the decoder accepts and the native artifact equals its
specified output. This closes constructive completeness of the bounded formal
relation; it does not verify the Nim cryptographic implementation.

`ByteCompileWitness.lean` gives an executable, indexed construction of all
21,277 values, caching the two component witnesses and semantic bridge rows.
`ByteCompileCast.lean` proves that integer and scalar-field constructions agree,
including the packed public inputs. `ByteCompileWitnessRefinement.lean` proves
that every in-range output value equals the canonical completeness witness.
Its `construct_correct` theorem proves the complete matrix and public-input
binding for every successful constructor result, and `construct_exists_iff`
proves that a constructor result exists exactly when the decoder accepts.
The witness exporter imports this checked refinement. These theorems cover the
executable Lean reference; the Nim builder is still connected by conformance
tests rather than a universal implementation-refinement proof.
`make zkbuild-byte-compile-witness-test` compares all 638,310 field values for
30 modules against Nim, covering constant sign/carry boundaries, every binary
operation, deep stacks, non-minimal signed encodings, and maximum-capacity nop
removal. It also rejects a changed public value and an oversized program.

`SlotRowCompleteness.lean` proves constructive completeness for one compilation
row. For every valid opcode/height pair and every 32-bit immediate, it constructs
all 753 local values and proves that they satisfy every row constraint. The
construction includes the signed-immediate carry and all multiplication wires.
`make zkbuild-slot-witness-test` compares 122,739 field values across 163 rows
with the actual Nim builder, covering every valid opcode/height pair and the
constant carry/sign boundaries. It also checks rejection of a mutated witness
and five invalid row inputs. Composing these local witnesses into one complete
16-row witness is handled by the following modules.

`SlotWitness.lean` places the row witnesses in disjoint private-wire ranges and
proves consistency of shared stack depths. `SlotModuleCompleteness.lean`
constructs the ten public packing values and proves all 11,947 constraints,
including final stack depth and both artifact bindings. `SlotCheckedTrace.lean`
derives the height trace from the program checker. `SlotCompleteness.lean`
proves that every accepted sixteen-operation program has a constructed witness
whose public inputs bind its canonical WASM binary and exact native output.
Together with `SlotCompilation.lean`, this gives soundness and constructive
completeness of the specified bounded compilation relation.

`make zkbuild-compile-witness-test` compares every one of the 11,899 witness
values against Nim for 44 full programs: 523,556 field comparisons, including
the public limbs and all row boundaries. The fixtures exercise constant carry
boundaries, deep stacks, every binary operation, parameter copies, and mixed
programs. A mutated public input and an invalid program must be rejected.
This remains conformance evidence for the Nim implementation rather than its
mechanical verification. The reference exporter caches each constructed row;
the cache and public-input computations are proved equal to the uncached
construction.

`RowSoundness.lean`, `InputNormalization.lean`, and `RowMatrix.lean` now connect
the standalone parser-row matrix to the parser transition semantics. The
`matrix_row_sound` theorem covers arbitrary satisfying field-valued row
witnesses, given a correctly encoded input phase/stack height, Boolean byte
bits bound to the input byte, wire zero equal to one, and the stated field
characteristic. It proves both acceptance by the reference transition and the
next phase/height encoding. Selector Booleanity and selector binding are derived
from the matrix rather than assumed to be honest witness choices.

This proof uses a generic proved elimination of fresh multiplication wires and
the ring normalizer bundled with Lean. A checked polynomial certificate matches
the eliminated row assertions and outputs to the algebraic transition model.
Finite certificates cover the parser cases and bound the integer residuals,
while field lemmas rule out nonzero residuals vanishing modulo the scalar prime.

`RowCompleteness.lean` proves the converse for the standalone row matrix.
Every accepted phase/stack/byte transition has a satisfying witness with the
specified next state. Its generic fresh-wire elimination theorem constructs
witnesses from satisfied residual equations. The executable integer witness
used by the conformance test is also proved to satisfy the row matrix after
embedding into any commutative ring.

`BodyCompleteness.lean` assembles all 121 rows into a single module assignment.
It proves that the shared input bytes and adjacent state expressions agree
with the constructed row witnesses. `BinaryCompleteness.lean` adds the header,
public byte packing, final-state, and exact-length constraints. Its
`binary_complete` theorem constructs a satisfying full matrix assignment for
every submitted binary accepted by the supported profile, including the
internal zero padding. `binary_relation_iff` combines this with soundness:
within the admission length bounds, profile acceptance is equivalent to the
existence of a satisfying assignment with the specified public inputs.

`make zkbuild-witness-test` compares all 6,096 Nim witness field values against
the independently executable formal construction. The 46 fixtures cover all
supported arithmetic operations, signed LEB boundaries and non-minimal forms,
the maximum stack depth, and the full byte capacity. All 280,416 field values
match. A changed witness and an unsupported module are rejected. This is
implementation conformance evidence, not a proof of the Nim compiler or the
entire Nim witness generator for every possible input.

`FullMatrix.lean` checks all 121 instantiations of the row template against the
complete module matrix, including every substituted constraint and output
expression. Its substitution proof transfers satisfaction from the full matrix
to each row. It also derives Booleanity of every byte bit from the matrix.
Checked metadata confirms the initial empty state, adjacency of row states,
and the exact bit wires consumed by each row.

`BodySoundness.lean` composes those row proofs over the complete padded
instruction stream. Given byte values bound to the byte-bit wires, its
`full_body_ends_with_one_result` theorem shows that a satisfying module matrix
follows the reference parser from the empty stack to the finished state with
exactly one result. This conclusion includes the final done constraint.

`PublicBinding.lean` proves that the six public packed limbs bind all 156 padded
bytes and every constrained bit. `HeaderSoundness.lean` derives the fixed module
sections, ASCII export-name restriction, and section lengths from the matrix.
`ExactLength.lean` proves that the public length equals the number of bytes up
to the first final `end`; trailing zeros are only circuit padding.

The combined theorem `BinarySoundness.binary_soundness` proves the bounded
matrix relation is sound for an actual submitted byte list: the header is valid
and its exact instruction body is accepted with one result. Its assumptions are
the scalar-field characteristic, wire zero equal to one, the stated public-input
encoding, the 36–156 byte admission bounds, and satisfaction of the full matrix.
It covers arbitrary field-valued witnesses. It does not assume the witness was
generated by the honest prover.

The build prints each theorem's axiom dependencies. Structural proofs use Lean's
standard logical axioms. Finite enumerations and bitvector proofs additionally
use native checker axioms generated by `native_decide` or `bv_decide`; no claim
of fully kernel-reduced enumeration or bit-blasting is made. The source contains
no `sorry` or project-added axioms.

`CosetQap.lean` proves the polynomial algebra for this quotient optimization.
Vanishing on the original root domain forces cancellation of the low and high
coefficient blocks; division on the disjoint coset then recovers the exact high
block. It also proves the coefficient scaling used for coset FFT inversion.
These generic theorems require a correct DFT/inverse pair. `ScalarRoots.lean`
now supplies that pair for the concrete radix-two algorithm and BLS12-381 root
constants, without a forward-DFT assumption. This does not yet verify the
compiled Nim FFT implementation. The test suite checks coset evaluation
against direct polynomial evaluation, quotient coefficients against both a
quadratic reference and the prior doubled-domain algorithm, zero quotients,
domain boundaries through 16,384 points, and invalid input rejection. Root
order and coset separation are checked for every supported power-of-two domain
through `2^32` without allocating those large arrays.

`FftStages.lean`, `FftLayout.lean`, and `FftRadix.lean` prove the inverse-stage
model for arbitrary field-valued arrays. The model reverses the forward
butterfly stages, undoes bit reversal, and divides by the array length once.
The proofs cover the bijection between array indices and butterfly coordinates,
bit reversal as an involution, nonzero twiddle factors, and the accumulated
normalization factor. `FftSplit.lean`, `FftPolynomial.lean`, and `FftForward.lean`
prove that the forward schedule equals the DFT by splitting the polynomial
into its even and odd coefficients and relating this split to bit reversal.

`ScalarRoots.lean` connects this result to the actual generator, modulus, and
repeated-halving exponent rule. For every depth from zero through 32, it proves
the root hierarchy, root-of-unity property, and separation of the coset with
shift seven. Its finite modular exponentiation certificates use Lean kernel
reduction, without the native checker. `forward_correct`, `inverse_correct`,
and `quotient_correct` establish the mathematical transforms and exact coset
quotient recovery under the stated scalar characteristic and satisfied root
constraints. Refining the compiled Nim code to this model remains open.

`FftInPlace.lean` refines these transforms to an execution model with sequential
array writes. It proves that saving both inputs before a butterfly's two
writes preserves the stage result, that different pairs have disjoint indices,
and that the nested block/offset loops visit every pair exactly once. The
model carries the actual repeated `w *= root` update and resets it at each
block. It also proves the swap pass for an involutive permutation and the
forward/reverse stage ordering. The composed model satisfies the DFT and coset
quotient theorems for arbitrary field-valued arrays. The bitwise counter that
computes reversal indices and the width/address schedules are refined
separately below. Field arithmetic, array storage and allocation, and
compilation of Nim to machine code still require refinement proofs.

`FftCounter.lean` proves the actual reversed-index update rule: start the mask
at half the domain size, clear leading set bits with AND/XOR/right shift, then
set the first zero bit. It proves termination within the bit width, in-range
results, and equality to bit reversal for every visited index. Fixed-width
bitvector proofs cover both logical and signed shifts when the domain length
fits a positive machine integer. These results compose with the sequential
stage model and the DFT/quotient theorems. They do not assume a table of correct
permutation indices or use native-checker axioms. The Nim loop calls the same
small inline counter helper exercised by the conformance test.

`FftSchedule.lean` proves the forward and inverse width-loop schedules, including
the final-width break before doubling, and the block-start loop. The generated
addresses match the sequential butterfly model and stay inside the array. It
also proves exact machine-word additions and width shifts under the stated
domain bound. The resulting scheduled transforms satisfy the DFT and quotient
theorems. These are execution-model proofs, not a verification of the Nim
compiler, allocator, or generated machine code.

The Nim inverse now uses that reverse-stage schedule. Its results are compared
against the original inverse algorithm and direct inverse DFT evaluation.
Every forward and inverse basis vector is checked through 64 points.
`make zkbuild-fft-model-test` compares all 33 concrete Nim roots through `2^32`
against exact modular residues exported from Lean. It checks 858 counter
transitions, including every leading-one run length, wraparound, and interior
states across all those domains without allocating large arrays. Another 66
cases check all 1,056 forward/inverse stage widths through `2^32`, using the
same Nim iterator as the prover. It also checks the real loops against the
proved schedules and address generation: 491,490 permutation/butterfly
events across the 15 domain sizes from one through 16,384 points. Trace
instrumentation is enabled only in that test build, not in the normal prover or
verifier.

`ScalarEncoding.lean` proves that the scalar encoding gate accepts exactly
32-byte big-endian values strictly below the BLS12-381 scalar modulus. The
borrow invariant proves that every intermediate wide difference lies in 0–511
and every outgoing borrow is zero or one. A finite certificate connects the
actual 16-bit add/subtract/shift expression to this arithmetic model for all
131,072 byte/borrow inputs. Accepted encodings fit in 255 bits without truncation
and two canonical encodings of the same scalar are identical. The reference
encoder produces a canonical encoding for every integer below the modulus and
roundtrips every accepted byte string.

`src/cps/zk/scalar_encoding.nim` supplies the gate used by `decodeScalar`. It
runs a fixed 32-byte borrow pass and avoids constructing a big-integer modulus
from hexadecimal during each decode. `make zkbuild-scalar-encoding-test` checks
all 131,072 borrow inputs and 25,670 complete encodings against an independent
Lean integer oracle. Cases cover every byte position and value, carry chains,
random encodings, and malformed lengths. It also checks agreement with the
prior predicate, decoded integer values through independent Horner evaluation,
exact accepted roundtrips, and preservation of the destination on rejection.
The RV32 QEMU test separately exercises 8,192 canonical-boundary cases and the
zero, modulus-minus-one, modulus, and high-bit decoding boundaries.

`ScalarWords.lean` proves the shift/add word reader and both native layouts:
eight 32-bit limbs and four 64-bit limbs, stored least-significant limb first.
Recombining either layout gives exactly the submitted big-endian integer, and
accepted encodings fit the 255-bit scalar capacity. The production decoder uses
`src/cps/zk/scalar_words.nim` for this conversion instead of calling the general
unmarshaller. Static checks guard the pinned Constantine limb size, count, and
agreement between its field modulus and the canonical encoding gate.
The scalar test compares 25,603 inputs in both word widths to the Lean oracle,
and checks the host-native layout against the pinned library's reader. QEMU
also checks the RV32-native limb layout. The pinned limb ABI remains an
implementation assumption; this is not full verification of the arithmetic
library.

`ScalarMontgomery.lean` proves the integer Montgomery reduction relation,
including cancellation, the bound that permits one final subtraction, and
conversion in both directions. For every canonical scalar `x`, conversion
produces `x * 2^256 mod r` and converting it back produces exactly `x`.
Both native limb layouts have the same radix `2^256`. The modulus, inverse,
`R^2 mod r`, and native negative-inverse constants are checked by the Lean
kernel; these proofs do not use a native-decision certificate.

The scalar test checks the pinned library's constants and compares raw stored
Montgomery residues and conversion from independently supplied residues with
the Lean integer oracle. It covers 12,576 canonical values in each direction
with both the host-native and portable 32-bit backends. This comparison does
not rely on a roundtrip between the library's two conversion routines. The RV32
QEMU test additionally checks 101 direct-oracle cases, including powers of two,
modulus boundaries, byte boundaries, and deterministic pseudorandom scalars.
In the pinned library, `fromBig` uses the FIPS multiplication schedule;
conversion back uses CIOS on RV32. Both RV32 conversion schedules have the
more detailed models below. Other Montgomery schedules, 64-bit paths,
intrinsics, and generated machine code still require their own implementation
proofs.

`WordArithmetic.lean` models the portable RV32 primitive expressions with
32-bit and 64-bit bitvectors. It proves carry and borrow bounds, exact
multiply/add splitting, the three-word multiply-accumulate operation modulo
`2^96`, and exact accumulation when the result fits. A FIPS column beginning
with a zero high word cannot overflow for up to sixteen products. The proofs
also establish low-word cancellation for the scalar modulus, exact division
by the word radix after cancellation, and bounds for the lower and upper
column indices. These are kernel-checked proofs without native-decision
certificates. The FIPS model connects these operations to its loop and array
updates; compilation of Nim into target instructions remains a trust boundary.

`make zkbuild-word-arithmetic-test` compares the actual pinned portable
primitives with 21,218 independent integer-oracle cases. The cases exercise
carry/borrow chains, multiply/add boundaries, accumulator wraparound,
sixteen-product columns, and FIPS low-word cancellation. The RV32 QEMU run
executes another 494 selected cases against the same oracle through the actual
RV32 build. These checks supplement the expression proofs rather than proving
the Nim-to-machine-code translation.

`FipsMontgomery.lean` models both eight-limb RV32 FIPS passes, including the
shared correction/output array, exact column order, shifts, and final
conditional subtraction. It proves every column's arithmetic equation,
preservation of completed correction words, and that the upper pass only
reads correction words that have not yet been overwritten. `FipsSoundness.lean`
combines these equations with the product convolution identity and proves the
entire model returns `a*b*R^-1 mod r` for all canonical scalar operands. It
proves the final carry is zero, the unreduced output is below `2*r`, and one
conditional subtraction suffices. A corollary proves conversion from a
canonical integer returns `x*R mod r`. These proofs use neither `sorry` nor
native-decision certificates.

`make zkbuild-fips-test` captures the actual pinned Nim routine through a
test-only hook. Across 512 operand pairs it compares all 8,704 array/accumulator
rows to the executable Lean model, compares final outputs to independent
modular arithmetic, and rejects changed trace/result fixtures. RV32 QEMU
repeats sixteen full traces (272 rows). The hook is absent unless
`zkbuildFipsTrace` is enabled. These trace comparisons support correspondence
between the Nim source and the proved model; they do not constitute a universal
proof of the Nim compiler, its C backend, or the generated machine code.

`CiosMontgomery.lean` models the eight-word RV32 conversion from Montgomery
form, including the inner-loop carry, in-place writes, and final subtraction.
It proves that an inner write cannot change a word before it is read.
`CiosSoundness.lean` joins the column equations into exact outer-step and
whole-conversion balances. For every eight-word input, including noncanonical
stored values, the result equals `input*R^-1 mod r`. It also proves that the
FIPS-to-CIOS scalar roundtrip returns every canonical input exactly. The
`CiosReference.lean` evaluator caches arrays for practical execution and proves
that its results and every emitted trace row equal the original model.

`make zkbuild-cios-test` compares the pinned Nim routine with that reference
for 512 inputs and 37,376 complete array/carry rows, including zero, modulus
boundaries, the maximum 256-bit value, limb boundaries, and pseudorandom words.
It independently checks final modular results and rejects changed fixtures.
RV32 QEMU repeats sixteen complete traces (1,168 rows). The instrumentation is
absent unless `zkbuildCiosTrace` is enabled. As with FIPS, conformance tests do
not establish a universal proof of the compiled Nim implementation.

`VerifierCore.lean` proves that the public-input accumulator equals the
constant coefficient plus the coefficient/input dot product, checks index
bounds, and rejects incorrect arity. It proves that the four-pairing schedule
reduces to the Groth16 exponent equation, and connects honest-proof acceptance
to the key/QAP scalar identities. These are algebraic results under the usual
prime-order group/exponent interpretation; they do not verify Constantine's
curve arithmetic, subgroup checks, codecs, or pairing implementation.

The production verifier now calls the small, statically dispatched Nim core in
`src/cps/zk/verifier_core.nim`. The core itself allocates no sequences and retains
the short scalar-multiply loop used by the kernel. `make zkbuild-verifier-core-test`
runs that exact core with symbolic group operations and compares it to the Lean
schedule for all input counts from zero through 32. It checks every coefficient
and input index, pairing order and sign, both pairing verdicts, and rejection
before group arithmetic on invalid arity. It also checks eight weighted sums
using real BLS12-381 points and a sum that cancels to the neutral point. These
conformance checks supplement the algebraic proof; they are not a universal
proof of the Nim compiler or external group operations.

`Blinding.lean` proves the scalar-model selection properties: a nonzero
blinding coefficient has at most one cancellation nonce; at least one of
nonces one and two is admissible in a field where two is nonzero; successful
candidate selection returns an admissible nonce from the supplied list.
This proof does not verify OS entropy or the group implementation. Nim tests
force zero and cancelling candidates before a successful retry in both groups,
and exercise the retry limit.

This establishes soundness of the specified bounded WASM matrix relation. It
does not establish end-to-end correctness of compiled Nim machine code, verify
the entire Constantine implementation, prove computational SNARK soundness from
scratch, or prove the existing full compiler correct. Cryptographic security
still relies on the Groth16 assumptions, subgroup arithmetic, trustworthy setup,
and entropy. Whole-module witness construction is complete in the formal model.
Mechanical refinement of the Nim witness generator and cryptographic verifier,
and broader WASM coverage remain open.

## Executed validation

Host tests include real setup/prove/verify, key serialization and reload,
witness-independent matrix checks, altered artifact/proof rejection, key pinning,
and explicit rejection of on-curve points outside the G1/G2 prime-order subgroups,
stack underflow/overflow (including an invalid binary operation followed by a
compensating push), missing results, and integer carry/sign edge cases.
Generated WASM is checked with the repository's existing parser/validator and
executed by its integer interpreter. Native bytes are independently decoded and
executed by a test-only RV32 interpreter and compared across boundary inputs.

`make zkbuild-native-qemu-test` also runs the real verifier and native loader
inside QEMU's RV32 `virt` machine, then calls the admitted machine code directly.
The passing run covers proof/key checks, native execution, i32 wraparound,
post-admission input mutation, and rejection of altered WASM, code, and proofs.
It builds its own fresh compilation proof with `make zkbuild-compile-demo`.
The runner requires `qemu-system-riscv32` and `riscv64-unknown-elf-gcc`; override
`ZKBUILD_QEMU` and `ZKBUILD_RISCV_CC` to select installed tools. This is CPU-level
execution evidence, not a measurement of BL808 cache behavior or board latency.

`make zkbuild-byte-native-qemu-test` performs that same real CPU execution with
the `compile-bytes` claim, starting from a 44-byte ordinary WASM sample. Its
passing run includes native/WASM/proof substitution rejection and snapshot
isolation. `make zkbuild-byte-compile-test` additionally covers 72 arithmetic
and LEB-boundary programs, five signed LEB encodings of negative one, the maximum
body capacity filled with nops, all public-input mutations, and a seventeen-
operation overflow that is rejected by the circuit itself. One host sample
measured 4.663 seconds for setup, 4.135 seconds for proving, and 0.002 seconds
for verification; the proof was 192 bytes and the verification key 968 bytes.
These timings include CLI key decoding and are not BL808 measurements.

`make zkbuild-crypto-test` runs fixed, independently generated BLS12-381 and
Groth16 vectors in Nim. `tools/ref/zkbuild_crypto_vectors.json` records the
[py_ecc 8.0.0](https://github.com/ethereum/py_ecc/tree/v8.0.0) source hashes and
construction parameters. It covers eight G1/G2 scalar-multiplication vectors,
eleven proof acceptance/decoding cases, and seven actual Nim-generated proof
snapshots that the independent implementation verified. The cases include
large scalar values, a valid proof whose C point is infinity, incorrect public
inputs, altered on-curve proof points, and forbidden infinity encodings for A/B.
The synthetic reference proofs use a two-constraint multiplication relation
and seven public inputs to exercise the wire codec. Their setup parameters are
public test data; these are not WASM validation keys for kernel admission.

For the seven actual Nim proofs, the independent check recomputed public inputs
from raw WASM/native bytes, decoded the curve points, checked subgroup
membership, and evaluated the pairing equation. It also rejected a changed
public input and changed C point for every proof. Six cases cover both variants
of the original three claim modes; the seventh covers ordinary-byte compilation,
including rejection after independently changing each of its twelve public
inputs. This is interoperability evidence,
not formal verification or a cryptographic audit of either library.

`make zkbuild-interop-export` writes fresh proofs, keys, public scalars, and raw
artifacts to `build/zkbuild/interop-proofs.json` for other implementations to
check. It exports no proving keys or setup trapdoors. The normal tests consume
the fixed JSON fixtures in Nim; no Python installation is required to run them.

The standalone sample also passes WABT `wasm-validate`. The M0 verifier has been
cross-compiled to object code, and `examples/m0_wasm_proof_test.nim` links as a
complete RAM-load firmware with a dedicated 32 KiB stack. The measured text size
is 99,254 bytes for that test image, including startup/UART/allocator support.
The integrated loader test links with 186,630 text bytes in its flash layout.
The native proof/execute test also links successfully with 101,026 text bytes
in the isolated M0 flash layout, and its harness dry run passes. No hardware verification run has been
completed; the board was not attached during these checks.

On the development host, one 44-byte sample run took 1.51 seconds for setup and
1.33 seconds for proving, including key deserialization and the prover's final
self-check. A 50-iteration CPU-time benchmark measured about 1.10 ms per check
with a prepared key and 1.60 ms including key preparation. Its proof was 192
bytes and its verification key 728 bytes. These are host measurements for this
bounded relation, not BL808 timings or general WASM performance claims.
`make zkbuild-bench` regenerates the sample and emits machine-readable timings.

One 12-iteration `make zkbuild-qap-bench` run on the host measured
26.11 ms for the prior QAP construction and 20.51 ms for the coset version
at 8,192 points (about 1.27 times faster). Main polynomial buffers occupy
1,310,720 and 786,432 bytes respectively, a 40% reduction. Those buffer counts
exclude the circuit, proving key, and runtime overhead. This benchmark measures
only the QAP stage, not complete proving, key loading, or BL808 verification.

After `make zkbuild-demo`, the hardware test uses the normal harness with an
isolated manifest:

```sh
.venv/bin/python tools/hw_validate.py --manifest tools/zkbuild_hardware_validation.json --list
.venv/bin/python tools/hw_validate.py --manifest tools/zkbuild_hardware_validation.json --test m0_wasm_proof_test --jtag-load --build-only
.venv/bin/python tools/hw_validate.py --manifest tools/zkbuild_hardware_validation.json --test m0_wasm_proof_test --jtag-load --uart ACTUAL_RUNTIME_UART
.venv/bin/python tools/hw_validate.py --manifest tools/zkbuild_hardware_validation.json --test m0_wasm_verified_loader_test --jtag-flash --build-only
make zkbuild-compile-demo
.venv/bin/python tools/hw_validate.py --manifest tools/zkbuild_hardware_validation.json --test m0_wasm_native_proof_test --jtag-flash --build-only
.venv/bin/python tools/hw_validate.py --manifest tools/zkbuild_hardware_validation.json --test m0_wasm_native_proof_test --jtag-flash --uart ACTUAL_RUNTIME_UART
make zkbuild-byte-compile-demo
.venv/bin/python tools/hw_validate.py --manifest tools/zkbuild_hardware_validation.json --test m0_wasm_byte_native_proof_test --jtag-flash --build-only
```

This isolated RAM test occupies upper WRAM and must not be combined with an LP
image. The harness hardware lock, logs, and reset rules still apply.
The integrated loader test also links the existing full WASM interpreter and
does not fit this isolated RAM layout with the reserved stack. Its separate
manifest entry uses its dedicated flash layout (60 KiB stack, separate heap)
and must be built/run with
`--jtag-flash`, not `--jtag-load`.
The native execution test uses the same isolated flash layout. Both layouts
occupy the full M0 RAM/WRAM range and are isolated test images.
Their stack and heap reservations have been link-checked, not measured on board.
The ordinary-byte native firmware test also passes the harness build-only path.

## Broad runtime validation composition

`src/cps/zk/wasm_module_validation.nim` now builds the combined instruction,
control/branch, call/tail-call, memory/SIMD, bulk/reference, throw/catch, module,
and compressed-local relations. `buildModuleValidationCircuit(module,
eventCapacity)` accepts decoded modules; the byte overload decodes without
peephole optimization and independently replays the validation transcript.
Both return a `Circuit` usable by the existing Nim setup/prover/verifier.
The byte overload binds the source envelope, complete type vectors,
defined-function type indices, exception-tag indices, code-body boundaries,
compressed local declarations, complete instruction streams, and the remaining
import/object/name/initializer/segment payloads described below. The
completed-function event count is bound to the number of defined functions,
preventing omitted body traces.
**This is an experimental composition, not a general kernel certificate.**
The raw-byte API keeps derived tables and events private; the public inputs
are the actual byte length and padded 31-byte source limbs. The verifier does
not replay validation or receive the tables. Verification still grows with
source capacity. The decoded-module overload remains a public-metadata test
interface. Array dimensions determine the setup matrix, and capacities do not
yet pad every dimension; a single universal key is not provided.

`wasm_catch_environment.nim` authenticates every catch clause, including
zero-payload catches, before pushing the try frame. Catch depths address the
outer label stack. `wasm_catch_typing.nim` binds tag payloads and target label
signatures; `wasm_type_reversals.nim` authenticates shared forward/reverse type
vectors once per vector. Loop targets use parameters; other targets use
results. Reference catches append the current runtime's opaque externref tag.
The interpreter now preserves loop labels on a caught branch and correctly
addresses outer labels across child calls. Tests exercise 224 source contexts,
7 runtime handler executions, 7,560 independent Lean cases, 48 Lean/R1CS
comparisons, 35 composed traces, and seven catch forgeries. The catch-only
32-row profile has 433,574 constraints and two 192-byte proofs with one key.
This does not establish standard exnref object/propagation semantics.

`module_rules.nim` shares one validated module context across all functions.
`wasm_module_context.nim` adds constraints for complete function/type/object
namespaces, single-memory/table limits, global/element/data constant
initializers, start signatures, export bounds, and exact outside-function
reference origins. Initializers may read already-initialized immutable globals,
matching the runtime's sequential initialization context. Mutable, self, and
future global reads are rejected. Raw declaration provenance remains open.

`wasm_names.nim` checks strict UTF-8 through shared byte/tail cells. An exact
reverse map makes cells canonical, so distinct name heads imply distinct byte
strings. Sorted export-head queries enforce uniqueness without probabilistic
hashes or pairwise string comparisons. Tests compare all 65,536 two-byte inputs
against the independent host UTF-8 validator and exercise scalar boundaries,
embedded NUL, eight name circuits, and two coherent name forgeries.

The full-u32 block type representation keeps `Instr` at 12 bytes. Rare wide
indices use a sparse PC-indexed side table, remapped by peephole optimization.
Decoder, validator, transcript replay, interpreter, JIT lowering, and the
33-bit normalized proof descriptor agree on the representation. Both binary
readers now reject overflowing LEBs, impossible vector/body lengths, unsupported
limits flags, invalid UTF-8, and unsupported instruction encodings. Valid
nonminimal integer encodings remain accepted. The flash scanner handles all
currently supported immediate layouts. Its signed-LEB regression generator was
also corrected to emit valid negative constants.

Compressed local declarations avoid materializing their declared counts.
Only used local types become ROM entries; binary search resolves their ranges.
`wasm_local_ranges.nim` authenticates range coverage, and
`wasm_local_declarations.nim` binds source-order parameter ranges to the shared
signature members and authenticates complete per-function declaration totals.
Nine contexts compare 60 sparse/expanded types and reject three coherent
parameter/final-declaration forgeries. A maximum-u32 local count and a count of
17 share one 16-row matrix and produce two 192-byte proofs.
Those functions are validated/proved, not instantiated with billions of locals.

The combined module fixture covers all supported constant types, imports,
active element/data initialization, UTF-8 exports, and a start function. It
rejects 17 coherent module forgeries and produces two 192-byte proofs with one
key using a 16-event-row profile. These are small integration fixtures,
not real-workload proving-time or BL808 verifier benchmarks. Earlier component
counts above describe their earlier matrices; the wider descriptors change
general-profile matrices. Existing bounded kernel keys remain separate.

`NameLists.lean`, `LocalRanges.lean`, and `ModuleContext.lean` prove canonical
name-head injectivity, range coverage/order/namespace arithmetic, parameter
ordinal selection, initialized immutable-global reads, reference existence,
and origin/uniqueness composition. The catch components add `TypeReversals`,
`CatchTyping`, and `CatchLists`. These are component theorems with explicit
lookup/representation assumptions. They do not prove the complete Nim builder,
UTF-8 generator, binary parser, or full module admission theorem.

Run `make zkbuild-module-context-test zkbuild-module-integration-test` for the
new integrated paths, and `make zkbuild-check` for the broader proof suite.
`make zkbuild-validator-target-check` cross-compiles the decoder, validator,
flash parser, and runtime for M0 without linking/running hardware.

## Authenticated binary source and declaration payloads

`wasm_binary_source.nim` binds a source length and all padded bytes to public
31-byte packed limbs, then provides exact immutable byte reads. Its fixed-shape
readers cover bytes, u32, s32, s33, s64, and little-endian 32/64-bit payloads.
They constrain continuation bits, sign extension, final-byte overflow bits,
encoded length, and source bounds; legal nonminimal LEBs remain valid.
Changing byte values or LEB lengths does not change a reader's matrix.
The tests cover 124 encodings, 17 malformed/read/public-input forgeries, and
two 192-byte proofs with one key for distinct 96-byte-capacity envelopes.
The envelope circuit has 52,655 constraints and five public field elements.
These packed bytes are a transitional linear-size claim, not a digest claim.

`wasm_binary_envelope.nim` binds the magic/version, every section boundary,
section order and uniqueness, exact total source coverage, and standard-section
header words. Those words now constrain the module's namespace counts,
start/data-count fields, code/function agreement, and import-kind totals.
The payload relation below also consumes custom names and bounds their opaque
payload bytes; assigning bytes to a section alone would not establish grammar.

`wasm_binary_declarations.nim` binds all type-section parameter/result bytes,
including unused types, to the authenticated shared signature lists. A flat
member stream avoids a maximum-arity allocation for every type. Its unique,
bounded member keys and exact total count force complete vector coverage.
It also binds the defined-function type-index vector and each tag's zero
attribute/type index. `wasm_binary_code.nim` binds body lengths, local-vector
counts, local types/counts, and terminal end bytes, exporting exact instruction
spans consumed by the instruction-decoding layer below.
Ten coherent source/metadata forgeries are rejected, including an omitted type
member and a changed unused maximum-u32 local count. The combined declaration
fixture uses 733,388 constraints including the function-count guard. Empty
modules are also checked through the raw-byte API with a padded event row.

`opcode_encoding.nim` supplies the binary layout for all 273 admitted unfused
opcodes, including every implemented SIMD/bulk form, tail calls, and exception
instructions. Tests compare all 65,536 catalog entries with the admitted set
and round-trip every supported layout through the independent owning decoder.
The instruction-byte binding below consumes this catalog.

`BinarySource.lean` proves packed-limb injectivity, bit-level read determination,
nonminimal sign-extension preservation, and unique LEB termination.
`BinaryEnvelope.lean` proves complete, nonoverlapping section coverage from
its chain invariant. `BinaryDeclarations.lean` proves flat-vector completeness
from unique bounded keys and equal cardinality, and value-type encoding
injectivity. `FunctionEvents.lean` now relates the completed-body count to the
final function index. These component results do not constitute an end-to-end
parser or Nim-generator refinement theorem.

Run the new binding checks with:

```sh
make zkbuild-binary-source-test zkbuild-binary-declarations-test zkbuild-opcode-encoding-test
```

General admission still needs an audit of the digest relation below, fixed
reusable profiles or recursion, complete formal composition, and target measurements.

## Instruction-byte and validation-trace binding

`wasm_instruction_source.nim` now decodes all 273 admitted opcode layouts
inside the circuit, using the original source byte table. Prefix/sub-opcode,
signed and unsigned immediates, floating-point bit patterns, full-u32 block
types, typed-select vectors, reference encodings, lanes, and vector literals
are consumed with exact byte lengths. `constrainVariantRead` shares one byte
query stream and matrix across all operand encoding modes; it passes the same
124 boundary/nonminimal encoding cases as the fixed readers.

Branch-table and catch-table lists are walked through the existing immutable
banks while their depths, kinds, and tags are read from source bytes. Dense
per-function bank counters prevent index substitutions and unused bank
injection. Vector literal indices are assigned in source order and close at
the authenticated constant-pool count. This is a validation relation; native
execution equivalence and standard exception-object semantics remain open.

A separate exact RAM stack tracks source control openers and else markers.
It authenticates each block's end PC, if/else target, and single else marker;
the final root end must occur at the exact code-body boundary. Source
instructions form immutable `(function, PC)` tables. Validation instruction
begins query their opcode, both immediates, and normalized block descriptor;
function ends query the final source PC. Combined with the existing schedule
and completed-function-count checks, the transcript cannot skip source
instructions or entire functions.

The decoder tests cover all 273 layouts plus two full-u32 block-type cases,
thirteen coherent instruction/list/control forgeries, and identical matrices across
ordinary opcode/immediate forms. A 55,036-constraint decoder profile produces two
192-byte proofs with one key. Typed integration tests cover constants,
conditionals, nested loops, multiple branch/catch banks, tail and indirect
calls, SIMD, memory, exceptions, and bulk operations, and reject well-typed
opcode/constant substitutions, instruction omission, and control-target
substitution. These are source/validation tests, not execution-equivalence
benchmarks. Sixteen combined cases pass the typed/source comparison check;
the 362,097-constraint, 16-event proof fixture exercises constant substitution
using one key and two 192-byte proofs.

`InstructionSource.lean` proves packed-record injectivity, instruction-list
refinement from authenticated equal-length records, byte-span coverage, and
complete branch/catch list consumption. `SourceControl.lean` proves control
frame encoding, RAM-stack preservation, authenticated top-frame reads, and
else-marker updates. Mechanical refinement of the Nim decoder/constraint
generator and the complete field-trace composition remain open.

Run `make zkbuild-instruction-source-test zkbuild-instruction-binding-test`.
General kernel admission remains disabled; the digest relation below and the
complete formal composition require further verification.

## Remaining module payloads and source-only verification

`wasm_payload_source.nim` consumes imports, tables, memories, globals, exports,
element/data segments, and custom names. It authenticates names by walking the
same canonical UTF-8 byte nodes used for export uniqueness. Import-kind
counters select each namespace independently. Table/memory limits and global
type/mutability bytes query the module environment. All supported constant
expression opcodes and their complete encodings are consumed. The low word or
reference index used by validation is linked to the constant record; scalar
high words and vector bytes are consumed but are not a native-execution claim.

All eight implemented element encodings and all three data encodings select
their required fields inside the constraints. Standard payload cursors must
end at their exact section boundary, including the scalar-only start and
data-count sections. Data contents and the remainder of a custom section are
uninterpreted for module validity; their lengths are bounded by the authenticated
section. This follows the supported encodings in the
[WASM binary module grammar](https://webassembly.github.io/spec/core/binary/modules.html),
with coverage restricted to the repository's current runtime.

The combined fixture exercises every import kind, all eight constant opcode
forms, every element flag, every data mode, imported and defined limits,
UTF-8/NUL names, and interleaved custom sections. It rejects 39 independently
valid metadata substitutions and 15 malformed payloads. The isolated payload
fixture has 974,547 constraints at a 1,024-byte source capacity; full validation
has 1,385,699 constraints. These counts make this a correctness baseline, not
an optimized proving implementation. `PayloadSource.lean` proves closed name
read binding, export-name distinctness, all segment-flag formulas, import
namespace totals, bounded opaque payloads, and span encoding injectivity.
These component theorems do not establish full Nim/circuit refinement.

`wasm_module_prover.nim` provides `setupModuleValidation` and
`proveModuleValidation`. `wasm_module_verifier.nim` provides
`verifyModuleValidation(trustedKey, bytes, proof, sourceCapacity)` without
importing a WASM parser or the witness generator. Its key must be pinned to
the complete relation and source capacity by the caller. It cannot select
or certify its own key. `wasm_binary_claim.nim` supplies the shared packing
routine, with overflow-safe limb counts. Existing kernel claim identifiers
and key codecs are unchanged; this general API is not wired into kernel admission.
Packing converts each 31-byte chunk once through the canonical scalar decoder
and skips arithmetic on zero padding. Fifty-five independent byte-encoding
checks cover empty, partial, and complete limbs. The Lean model also proves
that this padded big-endian scalar representation preserves the little-endian
source value and lies below the scalar modulus.

```nim
let profile = ModuleValidationProfile(eventCapacity: 16,
  sourceCapacity: 128, sectionCapacity: 12)
let key = setupModuleValidation(wasm, profile)
let proof = proveModuleValidation(key, wasm, profile)
doAssert verifyModuleValidation(key.verificationKey, wasm, proof,
  profile.sourceCapacity)
```

Setup uses the sample module's matrix. Proving another module with that key
requires the identical matrix shape; mismatches are rejected. The flat source
profile below removes instruction-count and auxiliary-list arity dependencies.
The source-only public interface reduces verifier inputs but does not make
proofs reusable across arbitrary modules. Run
`make zkbuild-payload-source-test zkbuild-module-proof-test` for payload
adversarial checks and real proof/verification round trips respectively.
The latter passes a 483,976-constraint module containing code, a table, memory,
a global, an export, an element segment, data, and a custom section. Two values
share one key and produce 192-byte proofs with six public field inputs.
Changed source bytes, malformed proofs, and a changed proving profile are
rejected. The verifier and claim encoder also pass the M0 compile-only target.

## SHA-256 digest claims

Set `ModuleValidationProfile.digestClaim = true` to replace the growing public
byte vector with two 128-bit limbs of the SHA-256 digest. The source bytes,
length, tables, and events remain private witnesses. `sha256_circuit.nim`
hashes the exact byte table consumed by the complete module relation; computing
the digest on the host is not the source-binding argument. The private length
selects the `0x80` marker, zero padding, big-endian 64-bit bit length, and final
compression state. These are the
[FIPS 180-4 SHA-256 rules](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf).

`verifyModuleDigest(trustedKey, wasm, proof)` recomputes SHA-256 with the existing
Nim hash implementation, then verifies only two public field inputs. Hashing
still reads the binary linearly, while the elliptic-curve input calculation
has constant size. The trusted key pins the digest relation and exact profile;
it must not be supplied by the proof producer. The existing packed-byte mode
remains available. Neither mode is automatically admitted by the kernel.

The circuit uses wire permutations for rotations and shifts, one multiplication
per choice bit, two per majority bit, and bounded integer sums for wrapping
32-bit additions. Its matrix depends on byte capacity, including padding
blocks, rather than the private byte length. It adds about 32,877 constraints
for a standalone one-block hash. Crossing a power-of-two QAP domain boundary
can cost substantially more than the raw constraint increase.

Tests compare 23 length/capacity boundary cases, including both padding branches,
with fixed independent `hashlib` digests and the existing Nim SHA-256. They
reject altered digests, bytes, lengths, and nonzero unused input bytes. The
`Sha256.lean` reference checks the empty and `abc` known answers by kernel
reduction and proves padding size, block-count monotonicity, the extra-block
bit formula, Boolean-gate identities, and modular-addition determination.
The full SHA matrix check and composition proof described below now connect
conforming standalone SHA circuits to that reference. SHA-256 collision
resistance remains a cryptographic assumption; it is not established by the
functional-correctness proof.

```nim
let profile = ModuleValidationProfile(eventCapacity: 16,
  sourceCapacity: 128, sectionCapacity: 12, digestClaim: true)
let key = setupModuleValidation(wasm, profile)
let proof = proveModuleValidation(key, wasm, profile)
doAssert verifyModuleDigest(key.verificationKey, wasm, proof)
```

Run `make zkbuild-sha256-test zkbuild-module-digest-test`. The digest verifier
is also included in the M0 compile-only check.
The combined module fixture has 582,632 constraints in a 1,048,576-point QAP.
It produces two 192-byte proofs with one key and two public inputs, rejecting
changed source, length, proof framing, and claim mode. In the recorded host
run, setup took 161.18 CPU seconds, proving took 7.41 and 7.26 seconds, and
verification took about 1 millisecond. These are host observations, not BL808
measurements or performance guarantees.

`wasm_digest_key.nim` adds a separate 488-byte canonical verification-key
encoding for this claim. It includes source capacity, rejects trailing bytes,
and checks curve points and subgroups during decoding. `prepareModuleDigestKey`
requires a caller-pinned SHA-256 digest of the complete key encoding and returns
an opaque handle that owns its decoded points. Verification with that handle
checks capacity before hashing the module. The pin must come from trusted
policy; computing it from an untrusted candidate key would provide no trust.
Existing bounded key formats and claim identifiers are unchanged.

## Reusable instruction-stream profiles

`wasm_flat_instruction_source.nim` replaces per-function instruction arrays and
per-instruction branch/catch loops with three flat streams. Set positive
`instructionCapacity` and choose `branchCapacity`/`catchCapacity` in the module
profile, together with fixed event, byte, and section capacities. Instruction
capacity includes each function's root `end`; branch capacity counts labels
including defaults, and catch capacity counts clauses across the whole module.
The shared budgets avoid reserving a maximum-size list for every instruction.
Proving cost follows these capacities, including unused rows; the change enables
setup-key reuse but does not itself reduce the per-instruction R1CS cost.

Function indices and PCs are private counters. Authenticated code spans anchor
the first and last byte of each function. A control RAM stack matches openers,
ends, and else targets. Flat auxiliary records use strictly increasing
`(instruction owner, ordinal)` keys, follow the authenticated list links, and
consume exact source spans. Bounded unique keys and total declared cardinality
prevent omitted, duplicated, or reassigned lists. Inactive records are zero.

Local lookup entries, branch banks/nodes, and catch banks/nodes are padded to
the corresponding profile budgets. All 273 admitted opcode layouts and two
full-u32 block-type cases share one source matrix. Twenty-one coherent stream
and metadata forgeries are rejected. The full composition accepts 22 typed bodies
with one matrix, covering numeric values, locals, memory, SIMD, structured
control, branch tables, direct/indirect and tail calls, and exceptions. Separate
checks move instruction rows between functions and include imported function
offsets. Adversarial checks alter owner/ordinal/cursor records, omit rows,
change branch/catch counts, and change code metadata.

```nim
let profile = ModuleValidationProfile(eventCapacity: 32,
  sourceCapacity: 128, sectionCapacity: 12, digestClaim: true,
  instructionCapacity: 8, branchCapacity: 4, catchCapacity: 4)
```

This is an instruction-stream reuse profile, **not a universal module profile**.
Names, imports, objects, and other unpadded dimensions still affect its matrix.
The optional declaration profile below also pads type/function/tag declarations
and local groups. The remaining dimensions and their binary framing need more
work before one key can cover arbitrary modules.
`FlatInstructionSource.lean` proves counter progression, auxiliary completeness
from bounded unique keys/cardinality, packed-key injectivity, and list-binding
components. Complete Nim/circuit refinement remains open.

Run `make zkbuild-flat-source-test zkbuild-flat-module-test` for source layout,
adversarial, typed composition, and actual key-reuse checks.
The 32-event, 8-instruction, 4-label, 4-catch digest profile has about 935,000
constraints. One setup key verifies three 192-byte proofs for empty, branch-table,
and exception-handler bodies, with the same two public digest inputs.

## Reusable declaration profiles

`DeclarationProfile` adds fixed capacities for type definitions, defined
functions, type parameter/result members, tags, local groups, and compressed
local ranges. Set `enabled: true`; zero then means an empty budget. The profile
requires the flat instruction path. Imported functions remain part of the
currently fixed import layout.

Type parameter/result bytes occupy flat, padded member tables. Defined-function
type indices and tag indices have constrained active prefixes, with counts
bound to the original section headers. Shared signature nodes, reversed heads,
indexed members, and per-function metadata are padded before their witnesses
are built. This permits different function counts and signature arities with
one matrix.

Code-body headers have a padded active prefix. Local declaration groups use
one module-wide stream with `(body, ordinal)` keys, source cursors, and exact
group counts. Each row authenticates the count and type bytes and queries the
corresponding compressed local range after the function's parameters. A
zero-variable group still consumes its encoded bytes and counts as a group.
Parameter ranges plus local groups must fit `localRanges`; variables inside a
group are not expanded. This includes full-u32 counts for unused locals.

```nim
let limits = DeclarationProfile(enabled: true,
  types: 3, functions: 2, parameters: 7, results: 7, tags: 2,
  localGroups: 7, localRanges: 8)
let profile = ModuleValidationProfile(eventCapacity: 16,
  sourceCapacity: 128, sectionCapacity: 10, digestClaim: true,
  instructionCapacity: 8, branchCapacity: 2, catchCapacity: 2,
  declarations: limits)
```

Here `parameters` and `results` count members across declared types;
`localRanges` counts parameters across defined functions plus local groups.
The shared signature-table capacities are derived from the declared budgets.
Overflow is rejected; the builder does not truncate source declarations.

Tests check a common matrix across empty modules, unused types, changing
function/tag counts, all seven value types, changing arities and local groups,
and maximum-u32 local counts, plus nonminimal local-count encodings. A separate
pair checks imported function offsets. Thirteen layout cases share an
898,013-constraint matrix. Nine coherent metadata forgeries, eight malformed
local-stream witnesses, and five insufficient-capacity cases are rejected.
One setup key verifies three 192-byte proofs for an empty module, multiple
functions with different signatures, and a maximum-u32 local count. Separate malformed-witness checks alter owners,
ordinals, positions, counts, types, and body activity. `DeclarationProfile.lean`
proves padding length, group completeness, parameter offsets, key injectivity,
and the distinction between variable count and declaration count. Full generator
refinement remains unfinished.

Run `make zkbuild-declaration-profile-test`. Add the payload profile below to
also fix import, name, object, export, and segment dimensions.

## Reusable full-module payload profiles

`PayloadProfile`, together with the declaration, instruction, event, byte, and
section capacities, fixes all remaining module table dimensions. All import
kinds, defined globals, tables, memories, exports, element/data segments, custom
sections, and UTF-8 names remain private witnesses within those budgets. A
single setup key can therefore accept different module layouts, including
changes to the number and kinds of imports. `prove` still checks the complete
R1CS matrix against the setup key.

```nim
let profile = ModuleValidationProfile(
  eventCapacity: 16, sourceCapacity: 256, sectionCapacity: 16,
  instructionCapacity: 8, branchCapacity: 2, catchCapacity: 2,
  digestClaim: true,
  declarations: DeclarationProfile(enabled: true,
    types: 2, functions: 2, parameters: 2, results: 2, tags: 1,
    localGroups: 2, localRanges: 4),
  payloads: PayloadProfile(enabled: true,
    imports: 4, globals: 3, tables: 2, memories: 1,
    exports: 3, elements: 3, elementItems: 4, datas: 3,
    customSections: 3, nameBytes: 40))
```

Here `globals`, `tables`, and `memories` are total namespace capacities,
including imported objects. `functions` remains the capacity for *defined*
functions; the shared signature table additionally reserves `imports` slots.
`nameBytes` bounds the total byte length of all export, import-module,
import-field, and custom-section names. `elementItems` is the total number of
element initializer expressions. Empty strings and empty element lists are
represented explicitly. Zero budgets mean zero, and overflows are rejected.

Name bytes and element initializers use flat module-wide streams. Each row has
an owner, ordinal, and source span. The relation checks active prefixes,
strictly ordered owner/ordinal keys, bounded ordinals, contiguous spans, first
and last boundaries, and exact total cardinality. This prevents omitted lists,
duplicated entries, fabricated padding, or bytes being reassigned to a different
name/segment. Names additionally follow the canonical UTF-8 name nodes exactly.
Element expressions authenticate the parent's expression/legacy encoding mode
and reference type. There is no `max name length × name count` or
`max element length × segment count` expansion.

`inferModuleValidationProfile(bytes)` returns an exact-fit starting profile.
Raise capacities before setup if a key will cover other modules. The CLI offers:

```sh
build/zkbuild/zkbuild module-profile input.wasm profile.json
build/zkbuild/zkbuild module-prove input.wasm module.vk module.proof profile.json
build/zkbuild/zkbuild module-verify TRUSTED_KEY_SHA256 module.vk input.wasm module.proof
```

`module-prove` performs a fresh experimental single-party setup, proves the
module, verifies the result, and writes the 488-byte digest key plus the
192-byte proof. It prints the key's SHA-256 digest. Establish that digest through
a trusted channel; accepting a digest supplied alongside an untrusted proof
would not establish trust. Omit the JSON argument for an exact-fit profile.
For reuse within an application, call `setupModuleValidation` once and
`proveModuleValidation` for each module with the same profile. Use the
persistent setup commands below to reuse a key across processes. A multiparty
setup ceremony is still not implemented.

Run `make zkbuild-payload-profile-test`. Twenty-four distinct module layouts
share one 1,280,776-constraint matrix, including mixed imports and redistributed
element lists. A larger fixture exercises all eight constant encodings, all
eight element flags, and all three data modes; 37 otherwise-valid metadata
substitutions and ten insufficient budgets are rejected. The shared-stream
unit test rejects 15 malformed ownership/span witnesses. Profile inference
also checks duplicated branch/catch lists and JSON round trips. One setup key
verified three 192-byte proofs for an empty module and two different populated module layouts; cross-module digest
substitutions were rejected. The CLI also passed an end-to-end setup/prove/verify
run and rejected a wrong key pin, altered source, and altered proof.
`OwnedStream.lean` proves finite-list coverage, key injectivity, span arithmetic,
and padding lemmas. These component results do not constitute a proof that
the Nim generator refines the full WASM validation semantics.

## Persistent keys and proof-gated engine loading

The host-only `wasm_proving_key_file.nim` module streams a canonical `ZMP1`
format. It contains the fixed profile, the corresponding 488-byte verifier key,
the R1CS matrix, and compressed proving-key points. It serializes neither
witness values nor setup trapdoor scalars. Dimensions, scalar canonicality,
wire indices, subgroup membership, exact point-array lengths, and EOF are
checked on read. A new file is completed in a same-directory temporary file
before replacement; this is not a claim of crash durability across power loss.

```sh
build/zkbuild/zkbuild module-setup exemplar.wasm build.pk module.vk profile.json
build/zkbuild/zkbuild module-prove-key build.pk another.wasm another.proof
build/zkbuild/zkbuild module-verify TRUSTED_KEY_SHA256 module.vk another.wasm another.proof
```

Only setup emits a new verifier key. Every subsequent proof uses the profile
embedded in `build.pk`, and the prover checks the complete matrix before
proving. Add more `INPUT.wasm OUT.proof` pairs to `module-prove-key` to load
the key once for a batch. The command checks each input against the stored
profile before the expensive key load. Changing a profile or file does not
make it trusted by the kernel: the verifier still requires the separately pinned key. Loading checks all curve
points; for many builds, retain `loadModuleProvingKey`'s result and call
`proveModuleValidation` repeatedly to avoid repeated loading and decoding.

`cps/wasm/proven` provides an opt-in adapter for the existing `WasmEngine`:

```nim
import cps/wasm/proven
import bl808/enclave/sha256

let key = prepareModuleDigestKey(trustedDigest, encodedKey)
let engine = newWasmEngine(jit = false)
let loaded = engine.loadProvenBytes(key, wasmBytes, proofBytes)
```

This checks lengths, copies the source/proof, verifies the pinned digest claim,
and validates the unoptimized decoded module before resolving imports or
running a start function. The normal engine API remains available, so an
application must use this entry point consistently to enforce admission. Proof
validity does not imply import availability, successful initialization, or
correctness of later JIT transformations. Host execution remains governed by
the runtime and its normal traps.

The runtime now owns stable copies of instantiated expressions. Releasing or
editing a caller's decoded module cannot change an already instantiated
function. Function export calls resolve through the instance's store mapping,
so later modules do not accidentally invoke an earlier module's functions.

`make zkbuild-persistence-test` checks 17 malformed key encodings, file round trips,
proofs after key reload, source ownership, separate module instances, and proof
checks before host start functions. `ProvingKeyFile.lean` covers framing and
publication arithmetic; `ProvenAdmission.lean` covers admission ordering and
unchanged state on rejection. These models leave cryptographic and Nim/runtime
refinement as explicit obligations.

The checked persistence fixture uses 539,483 constraints: setup took 154.9 CPU
seconds, its 287,081,264-byte key took 0.9 seconds to save and 129.8 seconds to
reload, and each subsequent proof took about 7.2 seconds on the test host.
These are host observations, not BL808 timings or isolated performance claims.
A separate process proved four modules in one batch using that file; all four
192-byte proofs verified against the same pinned key. The engine test confirmed
that a rejected proof cannot run a host start function and that a valid one runs
it once. Runtime ownership and export-resolution tests pass under both ORC and
ARC; the updated instantiation path also compiles for M0. Full end-to-end formal
refinement and hardware validation are still required.

## Checked primitive circuit matrices

`GadgetShape.lean` defines the concrete matrices for multiplication, equality,
materialization, Boolean constraints, conditional selection, zero indicators,
and unsigned decomposition. Its theorems quantify over arbitrary field
assignments. For widths up to 248, a satisfied range matrix determines a unique
unsigned integer below `2^width`; scalar-field wraparound cannot produce a
second value. Boolean selection requires a Boolean or zero-indicator contract
for its selector. Literal-folding proofs cover both accepted constants and the
contradictory gate emitted for a rejected constant.

The pure `conforms` checker verifies dimensions, canonical field coefficients,
and returned linear expressions. `conformance_relation` proves that acceptance
preserves the constraint relation and every returned expression's value.
`conformance_unsigned` connects a checked production range matrix directly to
its unsigned-integer property. The executable checker parses the exported
matrix and calls this proven checker; it does not evaluate an exported witness.

`tools/test_zkbuild_gadget_shapes.nim` calls the production Nim helpers and
exports their matrices. It covers all widths 0 through 248, repeated cached
and uncached ranges, affine/scaled inputs, equal-valued distinct wires,
different widths, and valid/invalid literal folding. Alternate witness values
must produce the same matrices and returned wire expressions. Negative cases
change dimensions, coefficients, outputs, widths, and framing. The checker also
requires the complete case manifest, including every supported unsigned width;
omitting cases does not produce a passing check.

The current run checks 3,304 primitive instances containing 133,945 constraints
and rejects 13 mutated or incomplete exports. The kernel-checked theorems also
cover the returned bits, cached ranges, literal folding, and canonical integer
bounds; they do not assume the witness used to generate the test matrix.

Run `make zkbuild-gadget-matrix-test`. This connects the checked primitive
instances to their algebraic models. SHA-256 composition is covered by the
additional checks below. Source-decoder and cryptographic implementation
refinement remain separate obligations.

## Gadget contracts inside the full module circuit

Build the prover with `-d:zkbuildGadgetAudit` to record the actual wire and gate
intervals, input expressions, and returned expressions of each primitive call.
Nested calls collapse into the enclosing primitive record. The production
helpers perform the same allocations and emit the same constraints; ordinary
builds contain neither the audit tables nor the recording operations.
`gadget_audit.nim` exports these records alongside the complete matrix without
exporting the witness. It also produces separate matrix and witness SHA-256
fingerprints for local regression checks.

`GadgetAudit.lean` contains a pure checker for those records. It checks bounds,
disjoint intervals, exact field-normalized matrices and outputs, and backward
references for reused ranges. A cache reference must name a checked fresh
decomposition of the same expression and width. Literal records must contain
only constant-wire terms; their value is reduced modulo the scalar modulus.
Theorems transfer satisfaction of the complete matrix to every accepted
fragment. Fresh, cached, and folded ranges consequently satisfy the same range
certificate, and checked zero indicators equal the zero test of their input.
For every accepted range record, the represented unsigned integer is unique;
any canonical scalar encoding of its input is below `2^width`.
Additional theorems establish equality, multiplication, materialization,
Boolean outputs, and the arithmetic result of both selection helpers.
These statements quantify over arbitrary satisfying field assignments, not
just the witness that created the audit.

Run `make zkbuild-gadget-audit-test`. It compares ordinary and instrumented
matrix and witness fingerprints, checks valid and contradictory primitive
circuits, checks a full source-bound module circuit, and rejects 13 forged
audits. The module contains 539,483 constraints and 115,380 recorded calls:
513,122 constraints belong to checked fragments, while 26,361 direct constraints
remain unclassified. Those counts describe matrix coverage, not the proportion
of WASM semantics formally proved. Domain-specific equations still require
semantic composition proofs even when their primitive operations are checked.
The same target also checks the 2,425,294-constraint payload fixture covering
all supported import kinds, global constant forms, element-segment modes,
data segments, custom sections, and UTF-8 names. Its 687,533 recorded calls
account for 2,298,007 checked constraints; 127,287 direct constraints remain
unclassified. Both fixtures preserve exactly the same matrix and witness
fingerprints with and without instrumentation.

`make zkbuild-gadget-audit-key-test` creates the ordinary persistent proving-key
fixture and reuses it with the instrumented prover. It checks that the resulting
192-byte proof verifies with the saved verification key. Both targets are
included in `zkbuild-check`. The instrumentation is a development audit aid;
it is not part of the proof wire format or kernel admission path.

## Checked SHA-256 word circuits

`sha256_word.nim` contains the production SHA word operations. The compression
loop calls these shared helpers; the matrix tests exercise the same code.
Rotations and shifts return bit views, while materialization, addition, XOR,
choice, and majority also bind the packed 32-bit value. Addition constrains
the full sum and its carry bits before returning the low 32 bits.

`ShaWordMatrix.lean` defines their concrete matrices and proves their behavior
over arbitrary satisfying assignments in the scalar field. The input ranges
bind the public words to unique Boolean decompositions. The checked-output
theorems cover every returned bit as well as the packed value; addition wraps
modulo `2^32`, with bounds excluding scalar-field wraparound. Constant proofs
cover the actual SHA initial values and all 64 round constants.
`ShaWordFips.lean` connects the bit representation and operations to the
`BitVec 32` SHA reference, including word rotation, shifts, Boolean functions,
and sums of multiple words.

Run `make zkbuild-sha-word-test`. Its independent Lean checker checks 152
operation matrices containing 15,390 constraints: all rotations, shifts from
zero through 32, additions of one through five words, materialization, and
the constants. Alternate input assignments must preserve the complete matrix
and returned expressions. Nine modified or incomplete matrices are rejected.
The target is included in `zkbuild-check`.

The refactor preserves both matrix and witness fingerprints for the
539,483-constraint and 2,425,294-constraint complete module fixtures. The SHA
regression also passes 23 length/capacity boundaries, seven invalid witnesses,
and two real proof round trips. This establishes the word-operation layer;
the complete compression proof below composes those operations. Padding and
digest serialization still require composition for a complete SHA circuit
theorem.

## Checked SHA-256 compression

`ShaProgram.lean` composes the word contracts through a small constraint-building
program. Its composition rule derives each intermediate contract from the
constraints of the complete program. The proof covers initial word loading,
the 48 schedule-extension steps, all 64 compression rounds, and the eight final
state additions. The resulting reference function is proved equal to the
existing FIPS SHA-256 compression specification.

`ShaCompression.lean` connects that program to a concrete matrix. Its public
inputs are eight initial state words and sixteen message words; their range
constraints bind unique 32-bit decompositions. Acceptance by the pure matrix
checker transfers the compression theorem to every satisfying assignment of
the exported matrix. All eight resulting words and their 256 bits are checked.
The theorem for a byte block states the necessary correspondence between the
input message words and the block's big-endian words explicitly.

Run `make zkbuild-sha-compression-test`. It calls the production `compress`
procedure, checks all 32,736 constraints and 264 output expressions against the
proved model, and exercises four distinct witnesses, including the standard
`abc` padded-block answer. Nine forged matrices alter input ranges, schedule
or round gates, outputs, or framing; each must be rejected. The target is part
of `zkbuild-check`.

This closes compression composition under its input representation contract.
The byte wiring, padding, and full-hash composition proofs below discharge
that contract for the standalone hash circuit.

## SHA byte boundaries and padding model

`sha256_boundary.nim` provides the byte-to-word, length-byte, and digest-limb
wiring used by the production circuit. `ShaBoundary.lean` proves that four
bytes map to the expected big-endian 32-bit word, that the length field encodes
the 32-bit byte length times eight in a 64-bit big-endian field, and that four
digest words map to a 128-bit limb. That limb is below the scalar modulus.
The scalar-format proof also establishes canonical decoding of an arbitrary
16-byte limb with the 16 leading zero bytes used by `digestInputs`.

`make zkbuild-sha-boundary-test` checks the exact emitted matrices and returned
expressions for all 64 length-field offsets and the word/digest layouts: 66
cases, 2,281 constraints, and nine rejected forged exports. The test also
compares the digest-limb helper with the host-side `digestInputs` encoder.
The complete 539,483- and 2,425,294-constraint module fixtures preserve their
matrix and witness fingerprints after this refactor.

`ShaPadding.lean` proves that the position-based padding formula equals the
FIPS padded stream at every byte, including positions beyond the final block.
For a fixed capacity, it produces that stream followed by zero bytes. It also
proves the last-block calculation, its capacity bound, and selection of the
corresponding result from a field-valued block sequence. The full-hash proof
below connects this model to the emitted padding-loop constraints. These formal
modules are part of `zkbuild-fv`, and the matrix target is in `zkbuild-check`.

## Complete standalone SHA circuit composition

`ShaHash.lean` models the complete `constrainSha256` emission order: length and
capacity bounds, last-block calculation, every padding byte, every compression
block, final-state selection, and both public digest limbs. `ShaScalar.lean`
connects its scalar operations to the primitive constraint contracts.
`ShaHashLength.lean` proves the length decomposition and selected final block.
`ShaHashPadding.lean` proves each returned byte's value and bit representation,
including the constraint that forces unused source bytes to zero.

`ShaHashBlock.lean` connects those byte vectors to the complete compression
proof and proves digest selection. `ShaHashSound.lean` composes every block and
proves `checked_digest`: for any artifact that passes the complete matrix
conformance check, any satisfying assignment with wire zero equal to one and
the supplied bounded message in its input wires has the FIPS reference hash in
its two public digest wires. Each limb is proved below `2^128`. The theorem
requires the actual message bytes and length to match the input wires; it does
not assume unused source wires are zero. The padding constraints enforce that.
Its reported dependencies are Lean's standard `propext`, `Classical.choice`,
and `Quot.sound`, without `sorryAx` or native-decision axioms.

`make zkbuild-sha-hash-matrix-test` exports the actual Nim matrices for capacities
0, 8, 56, and 128 and checks all constraints and output expressions against the
model. These contain 32,861, 32,877, 65,759, and 98,689 constraints respectively:
230,186 constraints in total. It also checks that changing the private length
and message preserves each matrix and rejects nine forged or malformed exports.
The parser checks dimensions, wire references, canonical coefficients, output
expressions, and end of file. The checker imports the full composition theorem;
this target is included in `zkbuild-check`.

This proves the standalone SHA relation for conforming matrices. The embedded
check below covers the length bits reused by the complete WASM relation. These
proofs do not prove the host SHA implementation, the complete WASM witness
generator, or the cryptographic prover/verifier, and do not establish collision
resistance. The proving and verification implementation remains Nim; Lean is
used for FV.

## SHA composition inside the WASM prover

`ShaEmbedded.lean` proves the hash contract when its length bits come from a
previously constrained 32-bit range. It checks the exact earlier range gates and
returned bit wires, the length expression, every SHA gate at its actual position
in the full matrix, and the binding to the two public digest wires. The range
must precede the hash segment. `cached_bounded_sound` also derives the capacity
bound from the constraints. The checked digest theorem has only Lean's standard
logical dependencies, with no `sorryAx` or native-decision axioms.

Build with `-d:zkbuildShaAudit -d:zkbuildGadgetAudit` to capture this evidence.
`sha256_audit.nim` writes the complete matrix and the SHA records without witness
values. This instrumentation is for offline verification and supports the
unit-wire length used by the WASM prover. Ordinary proving and verification
builds contain no SHA recording operations or record storage. The audit is not
part of the proof format or a kernel admission policy.

`make zkbuild-sha-embedded-test` compares ordinary and instrumented matrix and
witness fingerprints for fresh ranges, cached ranges, ranges separated from SHA
by unrelated constraints, and both complete WASM fixtures. It then runs the
formal checker on the full matrices, including the 539,483-constraint module
and 2,425,294-constraint payload fixture. The checked SHA segments contain
65,742 and 559,452 constraints, respectively, plus each earlier 33-constraint
length range. The test rejects 21 forgeries involving range sources, cached
bits, source order, length/digest bindings, gate spans, coefficients, and
malformed files. It is included in `zkbuild-check`.

This connects the SHA component to real module matrices and closes the cached
length-bit gap. The SHA-only theorem takes the relationship between source
expressions and the supplied message as a precondition. The combined source/hash
check below derives that relationship from the binary-source constraints.

## Binary-source table and SHA binding

`BinarySourceMatrix.lean` models the complete `constrainBinarySource` body:
Boolean activity, byte ranges, prefix ordering, inactive-byte zeroing, running
length, 31-byte limb boundaries, and the final length equality. It proves that
any satisfying assignment represents a canonical byte sequence, with exactly
that sequence's length, bytes, active flags, and table addresses. A separate
uniqueness theorem proves that a fixed assignment cannot represent two different
sequences when the capacity is below `2^32`. The limb theorem connects each
emitted packing equality to its weighted byte value.

`BinarySourceEmbedded.lean` checks the source segment at its actual position in
the whole matrix, including its returned active/address/value expressions and
original length-range constraints. Its `linked_unique_digest` theorem composes
that result with the SHA segment. It derives the represented byte sequence and
its public SHA digest without assuming externally that the source wires already
contain a particular message. Uniqueness is relative to the represented source
table; it is not a claim that SHA-256 has unique preimages. The theorem uses only
Lean's standard logical axioms.

Build with `-d:zkbuildSourceAudit -d:zkbuildShaAudit -d:zkbuildGadgetAudit` and use
`binary_source_audit.nim` for this offline evidence. The exporter includes the
complete matrix, source interface, length-range provenance, and hash interface;
it does not include witness values. Ordinary builds omit the source-record
storage and recording operations. The source/SHA audit currently targets one
binary source and one public digest, as used by a module-validation proof.

`make zkbuild-source-hash-test` covers capacities 0, 1, 30, 31, 32, 62, 63, and
64, empty and full messages at the same capacity, and both complete WASM
fixtures. It compares ordinary and instrumented matrix/witness fingerprints and
checks the exact source and SHA segments. A disconnected-source case supplies
a valid source segment and a valid hash segment referring to different byte
tables; the checker must reject their composition. Other negative cases mutate
prefix, zeroing, byte-range, count, packing, returned-interface, and framing
evidence. All 12 matrices and 29 rejection cases passed. The full module and
payload fingerprints also match the pre-instrumentation fixtures, and the
existing binary-source regression passes its 124 encoding cases, 17 forgeries,
and two 192-byte envelope proofs. The target is included in `zkbuild-check`.

This closes the source-table-to-digest binding, including the reused length
range. The complete parser, validation trace, and authenticated-read-table
refinement must still be composed with this canonical source table before
claiming full WASM validity soundness.

## Exact permutation and memory-record packing

`PermutationMatrix.lean` models each emitted Boolean switch and product gate,
the recursive network topology, and the resulting linear output expressions.
Its soundness theorem quantifies over arbitrary field assignments and input
values, including duplicate records. `PermutationEmbedded.lean` checks every
gate and returned expression at the network's actual location in a complete
matrix and proves that accepted networks preserve the input multiset.

Build with `-d:zkbuildPermutationAudit` to capture these call boundaries.
`permutation_audit.nim` exports the complete matrix, inputs, and outputs without
witness values. Normal builds omit the record storage and instrumentation.
`make zkbuild-permutation-audit-test` covers powers of two from 1 through 1,024,
a mixed RAM trace, and both complete WASM fixtures. The smaller fixture contains
98 separately checked networks containing 23,150 switch constraints. The larger
fixture also has 98 networks, containing 138,328 switch constraints. All 14
matrix cases pass, ordinary/instrumented fingerprints match the earlier fixtures,
and 16 forgeries are rejected. Negative tests mutate switches, products, spans,
dimensions, inputs, outputs, and framing.

`MemoryPacking.lean` connects the packed record and ordering-key expressions to
their integer meanings. It proves injectivity for bounded address, timestamp,
value, and Boolean flags whenever their total width is at most 248 bits, then
lifts field-element multiset equality to equality of the full records.
`make zkbuild-memory-layout-test` checks the actual Nim helper expressions across
80 width profiles, including 64-bit fields and a zero-bit timestamp, and compares
the evaluated outputs with independent bit placement. All 240 bit-layout checks
pass, and ten forged layouts are rejected.

`MemoryPermutation.checked_reads` combines the checked network, injective
packing, chronological timestamps, and the existing sorted-row rules to derive
read/write semantics. The complete constraint check below supplies those
bounds, packed-input/output relations, and sorted-row rules from the surrounding
Nim constraints. Network routing completeness remains separate from the
soundness result. These checks are part of `zkbuild-check`.

## Complete RAM constraint composition

`MemoryEvidence.lean` checks Boolean flags, zeroed inactive fields, and the actual
range constraints for each access. Reused ranges name their original constraints;
folded literals are checked as canonical bounded constants. This avoids assuming
that an input is in range merely because the builder recorded a width.

`MemoryRows.lean` proves the sorted-row constraints: timestamp ranges, packed
record equality, the first-row read restriction, strict ordering-key differences,
and address/value equality for reads. `MemoryEmbedded.checked_memory` combines
these with the checked permutation network and injective record packing. From a
satisfying full-matrix assignment it derives bounded chronological and sorted
traces, exact permutation, chronological timestamps, and valid reads from the
latest preceding write. It no longer takes the access bounds or sorted-row
relations as external assumptions. Its dependencies are Lean's standard
`propext`, `Classical.choice`, and `Quot.sound`.

Build with `-d:zkbuildMemoryAudit -d:zkbuildGadgetAudit -d:zkbuildPermutationAudit`
to record this evidence. `memory_audit.nim` exports the full matrix and compact
range origins, access interfaces, sorted-row spans, and network bindings.
Ordinary builds omit the recording operations and storage.

`make zkbuild-memory-circuit-test` checks 13 complete matrices, including fresh,
cached, literal, mixed-expression, 32-bit and 64-bit accesses, and both WASM
fixtures. The 539,483-constraint fixture has 98 RAM instances with 2,163 accesses;
the 2,425,294-constraint fixture has 98 instances with 8,088 accesses. Their matrix
and witness fingerprints remain unchanged. Thirty-four forged-evidence cases
are rejected, including a correctly formed permutation network detached from
its corresponding memory rows. The target is part of `zkbuild-check`.

This establishes the finite RAM relation for checked constraints. Linking each
access to the canonical binary-source table and the parser's specific byte reads
is the next composition boundary. Compiler/witness completeness, network routing
completeness, and cryptographic implementation FV remain separate work.

## Remaining work before general kernel admission

1. Prove that the Nim witness generator refines the verified executable reference
   for every accepted module, beyond the current conformance tests.
2. Extend the proofs to the end-to-end cryptographic implementation, including
   field/group arithmetic, codecs, and verifier admission checks.
3. Expand independent cryptographic coverage and review production setup/key handling.
4. Run the linked target firmware through the hardware harness to measure
   verifier RAM, stack, latency, and rejection behavior.
5. Audit complete original-binary and digest coverage, finish the full
   field-trace/module refinement. Evaluate recursive aggregation and exercise
   the reusable profiles on real compiler workloads. The
   new general composition is not admitted.
6. Add compilation certificates to the existing optimizer only as each rule and
   backend is justified, then integrate the kernel admission policy.
7. Benchmark direct Groth16 against the proposed sumcheck/lookup and recursive
   design using the same relation and security target.

Passing the current checks demonstrates a working proof path for this bounded
profile. It does not close those remaining obligations.

## Composed source, digest, and byte-read verification

`BinaryReadMemory.lean` connects the source table, the FIPS SHA-256 circuit,
all declared byte queries, and the complete finite-RAM circuit. Its
`checked_queries` theorem assumes only that the full emitted matrix is
satisfied (including wire zero equal to one), that the offline checker accepts,
and that the field has the BLS12-381 scalar characteristic. It derives:

- A unique canonical byte message represented by the source table.
- The two public 128-bit limbs of that message's SHA-256 digest.
- For every declared active byte query, an address inside that message and
  exactly the byte stored at that address.

The checker compares the normalized input expressions of the RAM circuit with
source initializers, the declared read queries, and zero padding, in that
order. Initializers write the source table. Every later record has a constant
zero write flag. `MemoryEmbedded.checked_memory` supplies the decoded trace,
its bounds, and read consistency; `ReadOnlyMemory.membership` then identifies
the source byte for each query. Neither byte values nor read consistency are
assumptions supplied by the audit file. The theorem uses the standard Lean
logical axioms and no `sorry` or native decision axiom.

`-d:zkbuildByteMemoryAudit` records the actual `finishBinaryReads` interface and
its source and RAM record indices. It requires the source, SHA, memory, gadget,
and permutation audit defines. These are offline build diagnostics: normal
prover and kernel builds have no new record storage or recording operations.
`ZKBYTEMEM1` contains the full matrix once, the selected source/hash/RAM records,
and the query expressions. It contains no witness or setup secrets. Its parser
rejects noncanonical field scalars, invalid dimensions and wire indices,
missing records, truncation, and trailing data.

Run the integrated matrix and rejection tests with:

```sh
make zkbuild-byte-memory-test
```

This covers zero-capacity, empty and fully initialized tables, active and
inactive reads of all seven primitive kinds, the small module fixture, and the
full payload fixture. The ordinary and instrumented
matrix **and witness** fingerprints must match. The full fixture has 2,425,294
constraints and authenticates 2,405 byte queries through a 4,096-record RAM
trace. Adversarial cases include independently valid but detached source/RAM
circuits, altered or reordered query expressions, omitted queries, changed
source/hash/RAM/permutation gates, and malformed encodings. The target is also
part of `zkbuild-check`. `make zkbuild-byte-memory-cli-test` checks inferred and
explicit profiles, rejects output/input collisions and partial profiles, and
rejects an otherwise well-formed proving key for a different matrix.

For a real module, use the same `moduleCircuit` builder used by setup/proving:

```sh
make zkbuild-audit-cli
build/zkbuild/zkbuild-audit module-audit program.wasm program.audit profile.json
formal/zkbuild/.lake/build/bin/check_byte_memory program.audit
```

Omit the profile argument to infer an exact-fit full profile. To additionally
check that the audited matrix exactly matches a previously saved proving key:

```sh
build/zkbuild/zkbuild-audit module-audit-key module.pk program.wasm program.audit
formal/zkbuild/.lake/build/bin/check_byte_memory program.audit
```

The key command loads the profile from the key, compares the complete matrix
with `sameShape`, and prints the pinned verification-key digest and matrix
fingerprint. Neither command runs a setup ceremony or generates a new key.
Build `check_byte_memory` with `cd formal/zkbuild && lake build check_byte_memory`
if it has not been built yet. The checker currently limits source/hash capacity
to 16,384 bytes and the RAM depth to 20 for offline resource bounds; these are
checker limits, not a claim that the full prover has the same resource cost.

This closes the source-byte authentication connection. It does **not** yet
prove the complete WASM-validity theorem: the primitive token decoding,
section/declaration/instruction constraints, and typing rules still need their
concrete matrix interfaces composed with this byte-read theorem. It also does
not prove the security or machine-code implementation of the curve/pairing
library, the setup ceremony, or the native backend. The runtime feature
coverage and the end-to-end formal guarantee remain distinct claims.

## Concrete token-reader matrices and authenticated spans

The token audit adds the actual `constrainBinaryRead` and
`constrainVariantRead` bodies to the source/hash/RAM composition. It covers all
seven primitive kinds and the shared dynamic reader without replacing either
implementation or increasing the ordinary circuit's constraint count.

`RangeUse.lean` checks fresh, cached, and folded-literal range calls, including
the original certificate of a cached call. `BinaryTokenMatrix.lean` reconstructs
the complete emitted reader body: selectors, encoded length, input/output bit
ranges, byte addresses, source-bound checks, payload routing, sign extension,
continuations, and terminal checks. `BinaryTokenEmbedded.lean` requires that the
reader query lists concatenate to the complete byte-memory query interface and
that every reader uses the same source length. Independent valid reader
fragments with missing or detached queries therefore cannot certify the whole
interface.

The semantic results currently established from those concrete matrices are:

- `BinaryTokenSchedule.checked_length`: the encoded length is bounded by the
  reader capacity, and it is zero exactly for an inactive reader.
- `BinaryTokenSchedule.checked_schedule`: active queries form the length-sized
  prefix and address consecutive bytes from the range-checked position.
- `BinaryTokenSchedule.checked_variant_mode`: a dynamic reader has one of the
  supported modes 0 through 7, with exact selector values.
- `BinaryTokenSource.checked_spans`: every active reader span lies inside the
  unique digest-bound message, and its query values are exactly that message's
  bytes. Position arithmetic cannot wrap through the scalar field.
- `BinaryTokenBits.checked_rules`: fixed-kind readers satisfy exact payload
  routing, signed extension, high-bit/overflow, and continuation rules, or exact
  little-endian bit routing for raw reads.

All these theorems quantify over arbitrary satisfying field assignments and use
only Lean's standard logical axioms. The token audit is `ZKTOKEN1`: one full
matrix, the source/hash/RAM interface, and the reader/range records. As with the
byte audit, it contains no private witness or setup secret. Reader offsets used
only as diagnostic bounds are not semantic commitments; the checked gate spans,
wire expressions, and query interfaces carry the proof.

Run the reader and CLI checks with:

```sh
make zkbuild-token-circuit-test
make zkbuild-token-cli-test
```

The circuit suite includes empty tables, active and inactive instances of every
fixed and dynamic kind, nonminimal valid LEB encodings, and the complete payload
fixture. That fixture has 609 readers and 2,405 byte queries, with the same
2,425,294-constraint matrix as the ordinary build. The negative cases alter
reader kinds, gate spans, selector and choice wires, byte/value/range bindings,
and remove entire valid reader records. The CLI suite also rejects a valid
proving key for a different matrix. Both targets are in `zkbuild-check`.

For a real WASM module, the stronger CLI uses the existing command names:

```sh
make zkbuild-token-cli
(cd formal/zkbuild && lake build check_tokens)
build/zkbuild/zkbuild-token-audit module-audit program.wasm program.tokens profile.json
formal/zkbuild/.lake/build/bin/check_tokens program.tokens
```

Omit the profile to infer it, or use `module-audit-key module.pk program.wasm
program.tokens` to check the complete stored proving-key matrix first. The
ordinary prover and kernel verifier still do not include audit storage.

The integer interpretation and dynamic-reader payload work described here is
now completed by the next section. Whole-module validity still requires
composing section, declaration, instruction, and typing interfaces. The setup,
curve/pairing implementation, and general native backend have the previously
stated trust boundaries.

## Complete primitive-reader integer interpretation

`BinaryTokenSound.checked_decoding` now composes the concrete reader matrices,
range certificates, immutable byte memory, source table, and SHA-256 statement.
For every reader in an accepted matrix audit and every satisfying assignment,
it derives a position and length and proves one of the following:

- The reader is absent, its length is zero, and its value is zero.
- Its format is one of the seven supported primitive kinds, its entire span is
  inside the unique digest-bound source message, its length obeys that format's
  bound, and its value equals the mathematical decoder applied to those exact
  source bytes.

The mathematical decoder is `TokenInteger.decode`. Its result is the unsigned
bit-pattern representation of the format width: signed LEB inputs therefore
produce the appropriate two's-complement i32/i33/i64 pattern. The reference
packs the lower seven payload bits of LEB bytes, extends the terminating sign
for signed kinds, and packs all eight bits per byte for little-endian kinds.
It accepts the valid nonminimal representations already constrained by the
reader. The external encoding reference is the [WebAssembly binary-value
specification](https://webassembly.github.io/spec/core/binary/values.html).
`TokenInteger.certificate_nat` proves that each checked field-bit
vector is the actual binary representation of its bounded natural value;
`known_byte_bits` connects those bits to the authenticated source byte.

The dynamic reader has the same semantic result as the fixed-kind reader.
`BinaryVariantBits.checked_rules` proves its payload routing, continuation,
sign extension and overflow rules. `BinaryVariantFormat.checked_length`
proves format-specific bounds, including exact lengths 1/4/8 for raw reads;
`upper_bits` proves unused high output bits zero. The absent dynamic mode is
also proved to return zero. The symbolic payload plan used in the proof still
matches the complete emitted Nim matrix; no runtime/prover constraints or
verification-key formats changed.

Run the cross-language reference test with:

```sh
make zkbuild-token-integer-test
```

It compares the actual Nim `readBinaryToken` result with the extracted Lean
mathematical decoder on 1,358 cases across all seven kinds, including signed
extremes, word boundaries, random values, and 82 nonminimal LEB encodings.
This test supplements the universally quantified constraint proofs; it is not
used as a substitute for them. `check_tokens` now imports the final decoding
theorem, and the integer test is included in `zkbuild-check`.

The byte-reader layer is therefore connected through to decoded integer
values. This is still not a proof of full WASM module validity or of correct
native compilation: section traversal, declaration and instruction binding,
and the type-validation rules must be composed above this layer. Cryptographic
soundness, setup trust, and the machine implementation of the arithmetic backend
retain their existing assumptions.

## Authenticated section envelope and directory

The complete section-envelope constraint body now has a matrix checker and a
composed soundness theorem, `EnvelopeSound.checked_envelope`. It builds on the
primitive-reader result above and proves, for every satisfying assignment of an
accepted audit:

- The unique SHA-256-bound source has the exact eight-byte WASM magic/version
  header. All audited integer readers decode bytes from that same source.
- Active section spans form a contiguous chain from byte 8 to the source end.
  The existing `BinaryEnvelope.full_coverage` and `disjoint_sections` theorems
  give coverage and non-overlap. Section starts, bodies, sizes and ends are
  bounded natural numbers; field wraparound cannot manufacture a valid span.
- Active IDs are recognized by the runtime's section policy. Non-custom
  sections have strictly increasing policy ranks, including the runtime's tag
  and data-count placement. Custom sections may repeat without changing rank.
- Each non-custom section's leading unsigned integer fits inside its own
  payload. A custom section consumes no leading integer at this layer.
- All 56 directory outputs (14 IDs times presence count, first integer, payload
  start and section end) equal the corresponding sums over the authenticated
  section rows. The directory theorem intentionally retains sums for repeated
  custom sections; the payload layer handles individual custom sections.

The supporting modules are `EnvelopeMatrix`, `EnvelopeRanges`, `EnvelopeChain`,
`EnvelopeOrder`, `EnvelopeDirectory`, and `EnvelopePayload`. The endpoint and
its dependencies use only `propext`, `Classical.choice`, and `Quot.sound`;
there is no `sorry` or native-decision axiom in this proof chain. This remains a
conditional theorem about satisfying assignments and an accepted concrete
matrix, not a replacement for cryptographic soundness assumptions.

`LookupMatrix` and `LookupEmbedded` also prove the actual reduced decision-DAG
lookup implementation. `check_lookup` checks the runtime section policy over
all 65,536 input words. The envelope checker checks all 256 byte values and
uses the proved byte bound on section IDs. It does not trust a table supplied
by the audit to define the accepted section policy.

The Nim changes add optional evidence recording under
`-d:zkbuildLookupAudit` and `-d:zkbuildEnvelopeAudit`, with explicit dependencies
on the existing token/source/hash/memory evidence flags. The normal circuit,
witness, proof format, and kernel verifier are unchanged. Both the small
module and the complete payload fixture retain their historical matrix and
witness fingerprints; the latter still has 2,425,294 constraints.

Use the integrated CLI as follows:

```sh
make zkbuild-envelope-cli
(cd formal/zkbuild && lake build check_envelope)
build/zkbuild/zkbuild-envelope-audit module-audit program.wasm program.envelope profile.json
formal/zkbuild/.lake/build/bin/check_envelope program.envelope
```

The profile is optional. `module-audit-key module.pk program.wasm
program.envelope` instead uses the stored profile and checks the entire
proving-key matrix before writing evidence. The `ZKENVELOPE1` file contains the
complete matrix and source/hash/RAM/token/lookup/envelope interfaces, without a
private witness or setup secret. This large, offline certification artifact is
separate from the small proof verified by the kernel.

Regression commands, all included in `zkbuild-check`:

```sh
make zkbuild-lookup-circuit-test
make zkbuild-envelope-circuit-test
make zkbuild-envelope-cli-test
```

The lookup suite checks fresh, cached and literal ranges, recognized and
unrecognized IDs, exhaustive policy semantics and 13 altered evidence cases.
The envelope suite compares instrumented and ordinary matrix/witness hashes
for six fixtures: header-only, inactive padding, repeated custom sections,
all supported section IDs, a complete small module, and the full-runtime
payload fixture. It rejects 32 malformed modules or altered evidence cases.
The CLI suite checks explicit/inferred profiles and rejects five unsafe,
partial-profile or mismatched-key requests. The BL808 prover/verifier and
runtime-validator compile checks also pass; these are compile checks, not a
new hardware run.

The next remaining formal boundary is payload/declaration/instruction binding
and its composition with the complete type validator. The new endpoint proves
the authenticated envelope and directory, not full WASM validity or native
compilation. The previously documented setup, curve/pairing implementation,
and machine-arithmetic assumptions still apply.

## Immutable tables and packed field extraction

The source-envelope audit now has a stronger companion for the shared tables
used throughout declarations, payloads and type validation:

```sh
make zkbuild-tables-cli
(cd formal/zkbuild && lake build check_module_tables)
build/zkbuild/zkbuild-tables-audit module-audit program.wasm program.tables profile.json
formal/zkbuild/.lake/build/bin/check_module_tables program.tables
```

As with the envelope CLI, omit the profile to infer it, or use
`module-audit-key module.pk program.wasm program.tables` to require the exact
stored proving-key matrix before emitting evidence. `ZKMODULETABLES2` carries
one complete matrix, the authenticated source/envelope body, read-only table
records, and packed-field records. The ordinary kernel proof and verification
key formats are unchanged.

`ReadOnlyMatrix` models the actual `constrainReadOnly` initializer-order gates,
range calls, and memory interfaces. `ReadOnlySound.checked_membership` composes
those gates with `MemoryEmbedded.checked_memory` and proves:

- Every active initializer follows the previous active initializer at a
  strictly larger address. Active initializer addresses are unique.
- The initializer and query fields have their declared unsigned bounds.
- Initializers write the table; subsequent queries cannot write it. Every
  active query returns the unique initialized value at its address.
- The field expressions exported by a query equal those of an actual active
  table entry. The proof does not assume a host-computed lookup result.

This applies to the concrete tables used for signature metadata, nodes,
lengths, members, names, type indices, local ranges, objects and other module
metadata. `ModuleTables.checked_queries` combines the listed table instances
with the authenticated envelope under the same satisfying assignment.

The companion `PackedFields.checked_split` proves the actual extraction
constraints. The low component is the unsigned remainder modulo `2^lowWidth`;
the high component is the unsigned quotient. Both components are bounded and
recombine to the original word. The generic Nim `splitPackedFields` now backs
both the 32/32-bit signature-head split and the 3/32-bit node split. It uses
open-array slices, preserving the old constraints while avoiding temporary
slice sequences. `ModuleTables.checked_fields` applies the theorem to each
recorded split in the same module matrix.

Evidence recording is enabled with `-d:zkbuildReadOnlyAudit` and
`-d:zkbuildPackedAudit`, using the existing range, RAM and permutation evidence
flags. It is excluded from ordinary builds. The standalone formats
`ZKREADONLY1` and `ZKPACKED1` support smaller independent regression fixtures.

```sh
make zkbuild-readonly-circuit-test
make zkbuild-packed-circuit-test
make zkbuild-tables-cli-test
```

These targets are part of `zkbuild-check`. They exercise empty tables,
inactive padding, repeated reads, absent queries, literal/cached/fresh ranges,
8/32/64-bit boundaries, wrong values, missing keys, duplicate/reordered
initializers, inactive gaps, changed interfaces and packed-field wiring. The
module fixtures also certify the envelope, all emitted table instances and
packed splits in the complete production matrix. Matrix and witness hashes
are compared against ordinary builds, and the small/full module hashes retain
the historical values after the extraction refactor. The new theorem chains
use only Lean's standard logical axioms.

These are table membership and field-extraction guarantees. The next proof
must connect each table's meaning to the WASM declarations/payloads and connect
its consumers to instruction typing. An arbitrary table does not become a
valid signature environment merely because its queries are consistent.
Likewise, certification of listed records does not yet prove that a complete
module's entire validator is covered. Whole-module semantic composition and
the previously documented cryptographic/machine-code obligations remain open.

The combined full-runtime fixture checks 93 table instances and 688 packed
field splits in its unchanged 2,425,294-constraint matrix. The small module
checks 93 tables and 346 splits. Standalone extraction tests compare 45
boundary-value splits across nine fresh/cached/literal matrices, and the
table suite compares eleven complete matrices. The suites include malformed
witnesses and mutated evidence, while the CLI separately tests profile and
proving-key binding. BL808 prover/verifier and validator compile checks still
pass after the helper refactor; no hardware run was performed for this change.

## Source declaration constraint certification

`DeclarationMatrix` now checks the complete source-declaration relation emitted
by `constrainDeclarationSource`: type rows, parameter/result member rows,
defined-function type indices, exception-tag declarations, aggregate counts,
section closure, and the six immutable-table interfaces used by those rows.
It reconstructs the expected constraints, including the reversed parameter
ordinal and the forward result ordinal. Token and packed-field references must
match their consumers; location/member/metadata queries must match the exact
read-only table interfaces in the same full matrix.

The Nim builder records this evidence only with
`-d:zkbuildDeclarationAudit` and its existing envelope/table/packed dependencies.
The instrumentation preserves the ordinary circuit and witness. The small and
full-runtime fixture fingerprints still match the historical values.

The semantic results currently composed above this matrix check are:

- `DeclarationType.decode` derives bounded natural type-row fields.
  `active_layout` derives the parameter/result vector framing and section-end
  bound from the corresponding constraints and bounded cursor/end values.
- `DeclarationHeader.type_header` proves an active type row reads byte `0x60`
  from the unique authenticated source.
- `DeclarationVector.source_type_byte` proves an active member uses one of the
  seven supported value-type tags and that its encoding is the actual source
  byte. `DeclarationSelection.selected_member` proves the member ordinal lies
  inside the selected vector and that its byte position is base plus ordinal.
  `checked_vector_bytes` connects that exact position to the authenticated
  source; `DeclarationOrder.checked_order` proves active member keys unique.
- `DeclarationStreams.function_item` proves the function type-index value is
  the decoded unsigned integer from the source, advances by its exact encoded
  length, and uses the corresponding function-table key.
- `DeclarationStreams.tag_item` proves a tag reads a zero attribute byte
  followed immediately by its decoded unsigned type index, then advances to
  that integer's end.
- `DeclarationCounts.checked_counts` proves that active member counts equal
  the sums of constrained parameter/result arities as natural numbers. Its
  bounds rule out modular wraparound; inactive type rows have zero arities.
- `DeclarationLocations.checked_member` connects each member to its actual
  active source type through the immutable location table. Both halves of
  the packed span are identified as natural numbers, ruling out an unrelated
  vector with a coincidentally valid byte encoding.
- `DeclarationCompleteness.checked_complete_vectors` combines exact counts,
  unique keys and bounded membership: every declared parameter/result ordinal
  occurs exactly once, with no missing or extra members.
- `DeclarationSourceVectors.checked_source_vectors` connects all of those
  ordinals to supported value-type bytes in the authenticated source.
  `DeclarationFraming.checked_type_declarations` also proves the `0x60` header,
  exact decoded U32 arities, vector framing and in-bounds end for every active
  type. Valid nonminimal U32 encodings are included.
- `DeclarationBinding.checked_source_declarations` puts the type-header,
  member-byte, function-index and tag-stream results under one unique public
  SHA-256 source statement.

These theorems quantify over every satisfying assignment to an accepted
matrix. Their proof chains use only Lean's standard logical axioms. They do
not assume that a witness generated by the host parser is correct.

Run the stronger module audit with:

```sh
make zkbuild-declarations-cli
(cd formal/zkbuild && lake build check_declarations)
build/zkbuild/zkbuild-declarations-audit module-audit program.wasm program.declarations profile.json
formal/zkbuild/.lake/build/bin/check_declarations program.declarations
```

Profiles remain optional, and `module-audit-key` retains its full stored-key
matrix check. `ZKDECLARATIONS1` extends the same source/envelope/table/packed
matrix evidence with typed declaration records. It does not change the small
kernel proof format or add evidence storage to normal prover/verifier builds.

```sh
make zkbuild-declaration-circuit-test
make zkbuild-declarations-cli-test
```

The circuit suite passes seven complete matrices: the historical small and
full-runtime fixtures, extra inactive capacity, multivalue signatures,
nonminimal valid LEB encodings, an empty module, and an exception-tag module.
Different modules under the same profile keep the same matrix while changing
the witness. It rejects 34 forged audits that alter declaration counts, row
fields, token/packed references, gate spans, source bindings and stream
metadata. The CLI rejects five unsafe or mismatched key/profile/path requests.
The complete Lean default build passes 427 jobs; the new theorem chains use
only `propext`, `Classical.choice` and `Quot.sound`, without `sorry` or native
decision axioms.

Remaining work includes the function/type origin, code/local, remaining
payload and instruction-typing bindings. The
declaration audit is therefore not yet a complete formal proof of WASM module
validity or native compilation. The earlier cryptographic and
machine-implementation obligations also remain.

## Indexed signature constraint certification

The optional `-d:zkbuildIndexedAudit` layer captures every constraint emitted
by `constrainIndexedSignatures`, including nil, length rows, member groups,
metadata heads, singleton types, and all four read-only table interfaces.
It requires the declaration audit and its dependencies. The corresponding
`IndexedMatrix` checker reconstructs the constraints from typed records in
the complete production matrix. Its interfaces require the indexed length
and member tables to equal the declaration tables and the metadata entries
to equal the signature metadata queried by the source-declaration relation.

The instrumentation leaves the ordinary matrix and witness unchanged. Both
the small module and 2,425,294-constraint runtime fixture retain their
historical fingerprints. Ordinary builds do not store these audit records.

The semantic proof layer includes:

- `IndexedCell.decode`: an active member has bounded head, ordinal, cursor,
  next cursor and a supported tag. Its head and cursor are nonzero, and its
  node query contains the same tag and the authenticated next cursor.
- `IndexedStep`: exact start, continuation and closing rules, including a
  zero final next cursor and the final ordinal matching the declared length.
- `IndexedBoundary`: a length row is empty exactly when its head is zero;
  singleton node queries contain their specified type tag.
- `IndexedBridge.source_member`: every active source-vector entry selects an
  actual indexed member and node, with the same type tag.
- `IndexedOrientation.checked_orientations`: parameter ordinals are reversed
  for stack pops, while result ordinals preserve source order. The proof
  rules out integer packing aliases and scalar wraparound.
- `IndexedSource.checked_source_members`: every parameter/result byte covered
  by the complete source-vector theorem maps to a matching authenticated node
  under the same public SHA-256 source statement.

These are universal results for satisfying assignments of an accepted
matrix, independent of the host parser's witness choices. The new proof chains
use only Lean's standard logical axioms. The complete list and lookup results
below extend the per-cell results; the entire instruction-typing relation is
not yet composed.

```sh
make zkbuild-indexed-cli
(cd formal/zkbuild && lake build check_indexed)
build/zkbuild/zkbuild-indexed-audit module-audit program.wasm program.indexed profile.json
formal/zkbuild/.lake/build/bin/check_indexed program.indexed
make zkbuild-indexed-circuit-test zkbuild-indexed-cli-test
```

`ZKINDEXED1` contains the authenticated source, declaration evidence and indexed
records in one audit. The small kernel proof format is unchanged. The circuit
suite exercises the seven declaration fixtures plus a type-only module with
all seven supported value types, repeated shared signatures, and opposite
parameter/result orders. It compares both matrix and witness fingerprints,
and tests forged counts, spans, references, table interfaces, and detached
fields. The existing indexed-signature regression also passes 400 source
vectors, 2,268 forward/reverse lookups, 13 coherent/lookup forgeries, and two
real 192-byte proofs using the same key. The complete formal default build
passes 445 jobs. BL808 compile checks pass; no hardware run was performed.
Across the regression run and the additional all-types fixture, eight full
matrices pass. All 63 forged indexed audits and five invalid CLI requests are
rejected.

## Complete indexed lists and positional lookups

`IndexedGroups.suffix_cells` follows the actual adjacent constrained rows,
authenticates their node queries, and constructs `IndexedSignatures.Rows` up
to the group's nil terminator. It also retains the exact member-table record
for every list position, including cursor and ordinal bounds. This ties the
positional cache to the represented linked list.

`IndexedLengths.checked_lengths` proves that every active length entry has
a complete `SignatureLists.Represents` interpretation of exactly that length.
It handles nil explicitly and derives nonempty list starts from the checked
first-member lookup. An arbitrary member position is reached through the
actual checked suffix and bounded predecessor coordinates, so the proof does
not assume the host grouped the rows correctly.

`IndexedTypeLists.checked_type_lists` puts the metadata heads and complete
list lengths under the authenticated WASM source statement. Their lengths
equal the actual U32 arities decoded from the type declarations.
`IndexedLookup.checked_lookup` proves that a checked member query returns the
tag at its requested position in that complete list. It applies to separate
read-only circuit instances with the same immutable entries, as used by the
source and instruction consumers.

The node-table interpretation is a functional view of authenticated node
queries. Equal node addresses have equal payloads, and bounded tag/next
packing makes the interpretation unique. No new computation, witness data,
or assumptions are added to the prover by these mathematical definitions.

The source-vector composition below connects these positional lookups to the
binary bytes. Function/type origins and instruction consumers remain separate
obligations. This is still not a complete proof of general WASM validation or
compilation.

The complete-list proof extension passes the full 457-job Lean build. The new
theorem chains depend only on `propext`, `Classical.choice` and `Quot.sound`.
The rebuilt checker accepts the empty module, the shared all-value-types
fixture and the 2,425,294-constraint runtime fixture. This extension changes
formal composition only; it does not change the Nim constraint generator,
witness layout or proof format.

## Exact source type-list contents

`SourceTypeLists.checked_source_type_lists` now connects the complete lists
to every parameter/result byte of each active source type row. The statement
includes the authenticated source message, type framing and metadata heads,
complete list representations, exact arities and `Matches` predicates for
both vectors. `Matches` establishes an in-bounds vector and proves that each
source byte encodes the tag at the corresponding list position: reversed
parameter order and forward result order.

The proof combines four concrete bindings:

- `SourceListSelection.known_selection` fixes the actual type index, source
  ordinal and vector arity using the packed key and immutable location table.
- `SourceListHeads.metadata_heads` proves the source member and type row query
  the same metadata key, then identifies both bounded head fields.
- `SourceListLookup.member_tag` applies the complete-list lookup proof to the
  actual source member query and equates its tag with the queried list tag.
- `SourceTypeLists.vector_matches` lifts the result over every declared
  parameter/result position from the complete source-vector coverage proof.

These theorems require satisfaction of the actual audited matrix, not trust
in the host's decoded module. No proof-format or Nim circuit change is needed
for this extension. Full module validation, function origin binding and
native compilation are still not established by this type-list theorem.

The full Lean build for this extension passes 465 jobs. The new theorem chains
use only `propext`, `Classical.choice` and `Quot.sound`; they contain no proof
placeholders or native-decision axioms.
The rebuilt integrated checker also passes the empty, multivalue, all-types
and complete runtime audit fixtures.

## Signature origins and dense namespaces

`-d:zkbuildSignatureAudit` extends the indexed audit with the complete
`constrainSignatureEnvironment` relation and the signature namespace loop in
`constrainModuleContext`. `SignatureMatrix` reconstructs the origin queries,
type-index ranges, head/node references and decreasing node links.
`SignatureNamespace` reconstructs the function/type counters and their
bindings to the source counts and imported-function boundary. The namespace
entries, origin entries and parallel source type-index table must use the
same immutable records.

The principal semantic results are:

- `SignatureOrigins.namespace_types` derives the dense type namespace and
  proves every active type key is below the source type count.
- `SignatureOrigins.function_origin` proves an active function key selects
  an existing type in that namespace through its constrained U32 type index.
- `SignatureSource.function_source_signature` connects that selection to the
  actual source type's complete parameter/result lists and byte encodings.
- `SignatureFunctionSource.declared_function` additionally binds a selected
  defined-function key to the U32 type index decoded from its source stream.
- `SignatureFunctionComplete.declared_function` derives that key and its
  bound from the actual source row, the checked imported-function boundary
  and the dense namespace, then proves the same source type-list result.
- `DeclarationFunctionCoverage.checked_functions` derives the function
  count and proves that its rows form an active prefix, so padding cannot
  hide a missing declaration. `SignatureFunctionComplete.checked_function_section`
  composes this with the type-list theorem for every ordinal below that count,
  with the exact function index `imported + ordinal`.
- `SignatureNodes.checked_node` proves each active node has a supported tag
  and points either to nil or an active, strictly smaller node.

The complete defined-function theorem needs no externally supplied function
index or range premise. `SignatureBoundary.first_function` authenticates the
existing U32 range certificate for the imported-function count, and
`SignatureBoundary.source_index` derives the source row's ordinal and key.
`SignatureBoundary.namespace_functions` proves that the key is below the
actual function count, ruling out field wraparound in that composition.
`SignatureFunctionComplete.namespace_partition` also proves the natural-number
identity `defined + imported = total`; this is not merely a field equality.
Full module-level composition must still establish the import count and
imported signatures from the import payload bytes, and connect instruction
consumers, code/locals and the remaining payloads. These theorems do not yet
establish general WASM validation or native compilation correctness.

```sh
make zkbuild-signature-cli
(cd formal/zkbuild && lake build check_signatures)
build/zkbuild/zkbuild-signature-audit module-audit program.wasm program.signatures profile.json
formal/zkbuild/.lake/build/bin/check_signatures program.signatures
make zkbuild-signature-circuit-test zkbuild-signature-cli-test
```

`ZKSIGNATURES2` includes the source, declarations, indexed lists, signature
environment, namespace evidence and imported-function range provenance.
The checker rejects the older layout, which lacks that range evidence.
Normal prover/verifier builds omit this instrumentation, and the kernel
proof format is unchanged.

The full Lean build passes 493 jobs. The new semantic theorem chains use only
`propext`, `Classical.choice` and `Quot.sound`, with no proof placeholders or
native-decision axioms. The module-context regression passes 65,536 UTF-8
cases, eight name circuits, two name forgeries, 17 coherent module forgeries
and rejection of an omitted-function transcript; it also produces and verifies
two 192-byte proofs over the same 301,668-constraint circuit. The call regression
passes 6,048 Lean signature cases, 2,801 interned lists, 66 call traces and 26
forgeries, with two 192-byte proofs. The M0 prover/verifier compile check passes;
these runs do not constitute hardware validation or BL808 timing measurements.

The signature audit accepts eight complete matrices, including all seven value
types, padded/shared profiles, nonminimal encodings and the 2,425,294-constraint
runtime fixture. Every matrix and witness fingerprint matches the normal build;
the historical small/runtime fingerprints also remain unchanged. The audit CLI
passes explicit/inferred profile agreement and five unsafe, partial or mismatched
request rejections.
The final circuit suite rejects 55 altered artifacts, including the imported
range certificate, signature origins, namespace counters, table links, spans,
field references, obsolete audit format and trailing data.

## Source import constraint certification

`-d:zkbuildImportAudit` extends signature certification with the entire import
loop in `constrainModulePayload`. `ZKIMPORTS1` records both name-span lookups,
all seven conditional primitive readers, the four kind selectors, object/type
lookups, limit-field splits and counters, and the closing section/count gates.
The checker reconstructs each row in emission order and requires the shared
function type-index table to contain the same entries as the signature layer.
It also authenticates all seven immutable-table query interfaces used by the
loop. The normal circuit and kernel proof format are unchanged.

The semantic composition includes:

- `ImportRules.decode`: Boolean activity, the supported kind range, the exact
  kind selectors, prefix activity, and all four counter transitions.
- `ImportCounts.checked_counts`: counts for function/table/memory/global imports,
  the total active row count, and their non-wrapping natural-number partition.
- `ImportMembers.function_key` and `source_column`: a function import gets its
  key from the checked function counter and selects an actual signature row.
- `ImportFunctionBounds.checked_bound`: that key is strictly below the final
  imported-function count, including when other import kinds are interleaved.
- `ImportCoverage.checked_signatures`: every index below that count has an
  actual function-import row and the authenticated source type-list result.
  This rules out missing imported functions as well as out-of-range keys.
- `ImportRead.active_read`: the reader's expected value is the decoded integer
  at its authenticated source position, and its cursor advances by the exact
  encoded length.
- `ImportSource.imported_function`: the function-kind byte is zero, the following
  U32 type index selects an actual source type, and the imported signature heads
  represent that type's complete parameter/result vectors and source bytes.

The last theorem derives the function key; it does not assume one supplied by
host metadata. Its source position is the checked kind reader's position after
the two name-span lookups. The name-table producer, framing and UTF-8 composition are certified in the
source-name section below. This function-import theorem alone must not be read
as a complete import-section parsing theorem. Object
semantics, remaining payloads, code/locals, instruction validation and the
end-to-end compiler/cryptographic implementation obligations also remain open.

```sh
make zkbuild-import-cli
(cd formal/zkbuild && lake build check_imports)
build/zkbuild/zkbuild-import-audit module-audit program.wasm program.imports profile.json
formal/zkbuild/.lake/build/bin/check_imports program.imports
make zkbuild-import-circuit-test zkbuild-import-cli-test
```

The full Lean build passes 513 jobs. All new semantic theorem chains use only
`propext`, `Classical.choice` and `Quot.sound`, without proof placeholders or
native-decision axioms. The CLI passes explicit/inferred profile agreement and
five unsafe, partial or mismatched request rejections. The M0 prover/verifier
compile check passes. The module-context regression again passes 65,536 UTF-8
cases, eight name circuits, two name forgeries, 17 coherent module forgeries
and omitted-function rejection, and generates/verifies two 192-byte proofs.
No hardware timing or full-WASM soundness claim follows from these checks.

The import matrix suite accepts ten complete matrices. It includes all existing
signature fixtures plus interleaved function/table/memory/global imports and a
nonminimal U32 encoding of an imported function's type index. The two interleaved
fixtures have identical matrices and distinct witness fingerprints. All ten
normal/audited matrix and witness fingerprints agree, including the historical
small and 2,425,294-constraint runtime fixtures.
The final audit suite rejects 76 altered artifacts covering import table links,
row boundaries, selector wires, counters, query fields, both name spans, every
reader index and cursor, range-certificate inputs/widths, and trailing data.

## Shared parent/child stream certification

`-d:zkbuildOwnedAudit` records every `constrainOwnedStream` instance, including
its parent/child range certificates, owner/count/span lookups, ordering checks,
neighbor selectors, boundary equations, total count and immutable tables.
`OwnedMatrix` reconstructs the exact emitted fragments. `ZKOWNED1` extends the
module/import audit; `ZKOWNEDFRAG1` certifies the same shared relation in isolation.
The normal constraint matrix, witness layout and kernel proof format are unchanged.

The formal results cover the shared relation itself:

- `OwnedRules` decodes bounded parent and child fields from the checked ranges.
- `OwnedDecode.parent_inactive` forces a padded parent's count to zero;
  `parent_empty` equates an empty parent's start and finish.
- `OwnedMembership.child_parent` selects an actual active parent and proves
  the child's owner and ordinal are in bounds for that parent's count.
- `OwnedOrder.checked_order` proves strict ordering and uniqueness of active
  `(owner, ordinal)` keys from the concrete 64-bit ordering constraints.
- `OwnedComplete.checked_complete` combines exact counts, bounded ownership
  and uniqueness: every declared child ordinal occurs exactly once.
- `OwnedBounds.split_bounds` identifies the queried span with the actual
  parent's start and finish. `OwnedLinks` proves exact neighbor continuity
  and the first/last child equations, including selector behavior.
- `OwnedUnit.checked_positions` and `checked_parent_spans` prove exact byte
  positions and `finish = start + count` when the consumer establishes that
  each active child has width one. This is the bridge needed by name readers.
- `OwnedSoundness.fragment_verified` and `module_verified` apply coverage to
  every shared-stream record accepted by the standalone or full audit check.

These are matrix-satisfaction theorems, not assumptions that the host supplied
complete child lists. They do not yet certify the name-byte producer, its linked
node/byte correspondence, or UTF-8 composition. Those links are still needed to
finish name framing and the complete import grammar. Other variable-length
payload consumers also need their own semantic composition.

```sh
make zkbuild-owned-cli
(cd formal/zkbuild && lake build check_owned check_owned_fragment)
build/zkbuild/zkbuild-owned-audit module-audit program.wasm program.owned profile.json
formal/zkbuild/.lake/build/bin/check_owned program.owned
make zkbuild-owned-circuit-test zkbuild-owned-cli-test
```

The full Lean build passes 537 jobs. The new theorem chains use only `propext`,
`Classical.choice` and `Quot.sound`, with implicit parameter inference disabled.
The focused suite passes nine matrices (empty, empty parent, one child, multiple
parents, fresh/reused ranges, literal fields, padding and high positions),
rejects 20 malformed normal/audited builds, and rejects 80 altered audit records.
The full-module audit also passes all ten import/signature fixtures, including
interleaved imports and nonminimal encodings. All normal/audited matrix and
witness fingerprints agree; the historical small and runtime fingerprints are
unchanged. The CLI passes five unsafe, partial or mismatched request rejections.
M0 compilation and the module-context regression pass, including two real
192-byte proofs over the unchanged 301,668-constraint relation. These are host
and compile checks, not BL808 hardware timing measurements.

## Name framing and source-byte coverage

`-d:zkbuildNameFrameAudit` extends the owned-stream audit with the actual
`constrainSourceNames` producer. `ZKNAMEFRAME1` carries each U32 name-length
reader, each byte reader, the materialized cursors, and the links to the shared
owned-stream instance and the import name-span table. Both the fixed-capacity
flat path and the older variable-length path are supported. The checker
reconstructs the relevant matrix fragments and rejects missing/duplicated byte
records, changed reader references, changed spans and mismatched table entries.
It also checks all the preceding source/signature/import/owned-stream evidence.
The evidence contains expressions and matrix locations, not witness values.

The new Lean results include:

- `NameFrameRules.header_read` and `byte_read`: length/value decoding and exact
  cursor advancement from the same authenticated source message.
- `NameFrameFlat.unit_width` and `parent_spans`: derive one-byte widths from
  actual reader constraints and establish the complete parent span.
- `NameFrameLegacy.spans`: certify every byte cursor and final span for the
  variable-length reader, including empty names.
- `NameFrameSource.flat_headers` and `legacy_headers`: the count is the U32
  decoded from the committed bytes and `finish = start + headerLength + count`,
  with bounded, non-wrapping positions and counts.
- `NameFrameSoundness.module_verified`: compose those results with the unique
  source message and both public SHA-256 limbs; `query_frame` links active
  immutable-table queries to actual framed name entries.
- `NameFrameBody.complete_bytes`: every declared `(name, ordinal)` has an
  authenticated byte reader at `bodyStart + ordinal`. Completeness is derived
  from the count/order constraints, rather than assumed from host metadata.
  `module_complete_bytes` composes this result with the public digest and
  certified headers.

These results certify physical name framing and byte coverage. The source-name section below identifies these source byte lists with the
interned name strings. The graph, canonical equality and UTF-8 automaton are
certified as a separate component in the next section. The UTF-8 implementation has
an exhaustive/boundary regression of 1,448,741 cases against the runtime
validator; that test is not a formal proof of the automaton. Other payload,
instruction, compiler and cryptographic refinement obligations remain as
listed above. This audit does not establish full-WASM soundness by itself.

```sh
make zkbuild-name-frame-cli
(cd formal/zkbuild && lake build check_name_frames)
build/zkbuild/zkbuild-name-frame-audit module-audit program.wasm program.names profile.json
formal/zkbuild/.lake/build/bin/check_name_frames program.names
make zkbuild-name-frame-circuit-test zkbuild-name-frame-cli-test zkbuild-utf8-names-test
```

Instrumentation leaves the normal constraint matrix and witness unchanged.
The new theorem chains use only `propext`, `Classical.choice` and `Quot.sound`,
with implicit parameter inference disabled. The full Lean build passes 555
jobs. Fixtures cover the runtime payload matrix, all prior signature/import
profiles, legacy names, empty and multibyte names, names over 127 bytes, and
nonminimal name-length encodings. No change to the 192-byte kernel proof
encoding or to the trusted setup format is required.

Validation passes 15 full-module matrices with matching normal/audited matrix
and witness fingerprints, including the historical small/runtime fixtures.
It rejects 14 malformed normal/audited builds, 52 modified audit artifacts and
five unsafe/partial/mismatched CLI requests. The module-context and integration
regressions generate and verify four 192-byte proofs, including full-width
local declarations. M0 prover/verifier compilation passes; these are host and
compile checks, not BL808 hardware timing measurements.

## Name graph and UTF-8 certification

`-d:zkbuildNameGraphAudit` records the actual `constrainNames` circuit, including
node-word decomposition, strictly decreasing tail links, immutable node and
reverse-map tables, root checks, and each reduced UTF-8 decision DAG. The
`ZKNAMEGRAPHFRAG1` format checks the component independently;
`ZKNAMEGRAPH1` includes the complete preceding source/name-framing audit.
The checker exhaustively checks the UTF-8 lookup function on its 14-bit input
domain once and requires every node to use the same function. Each node's
circuit and range checks are still checked separately.

`Utf8Suffix.Valid` models the independent one-, two-, three- and four-byte
Unicode scalar forms. `Utf8Suffix.valid_iff` proves equivalence to a successful
reverse-scanning machine run, including overlong, surrogate and maximum-scalar
boundaries. Its byte classes follow the UTF-8 requirement for
[WASM binary names](https://webassembly.github.io/spec/core/binary/values.html#binary-name)
and [Unicode Table 3-7](https://www.unicode.org/versions/Unicode17.0.0/UnicodeStandard-17.0.pdf).
The argument uses ordinary kernel-checked proofs, not exhaustive native-decision
axioms.

The concrete graph composition covers:

- `NameBits.slices`: bounded integers and exact bit slices from the actual range
  certificates. No host-provided decomposition is assumed.
- `NameGraphLookup.transition`: the emitted lookup gates implement the same
  suffix transition, using bounded byte, state and high-nibble inputs.
- `ReadOnlyInactive.query_zero`: inactive immutable-table queries have zero
  address/value fields, including the nil tail case.
- `NameGraphLinks.decreasing` and `NameGraphTable.details`: every referenced
  node has a strictly smaller tail, with the corresponding checked next-word
  and canonical reverse-map query.
- `NameGraphStrings.represented`: every queried name node represents a finite
  byte list and a valid suffix-machine run, by induction on its node ID.
- `NameGraphStrings.canonical`: equal byte/tail nodes have equal IDs, using the
  checked reverse map. Name equality needs no hash collision assumption.
- `NameGraphRoots.root_valid`: every checked root represents a finite,
  well-formed UTF-8 string.
- `NameGraphSoundness.fragment_verified` and `module_verified`: apply these
  facts to the actual emitted matrix and immutable tables.

The source-name section below now certifies the reader's head, byte-node
lookup, adjacent-head and nil-termination constraints and identifies each
source name's bytes with its graph string. The graph audit alone remains a
component theorem; it must not be treated as a full-WASM validity theorem.
The normal proof relation, witness and 192-byte proof format are unchanged.

```sh
make zkbuild-name-graph-cli
(cd formal/zkbuild && lake build check_name_graph check_name_graph_fragment)
build/zkbuild/zkbuild-name-graph-audit module-audit program.wasm program.graph profile.json
formal/zkbuild/.lake/build/bin/check_name_graph program.graph
make zkbuild-name-graph-circuit-test zkbuild-name-graph-cli-test
```

Validation passes 581 Lean build jobs with only the standard `propext`,
`Classical.choice` and `Quot.sound` axioms in the new theorem chains.
The circuit suite accepts eight standalone graph variants and 15 complete
module fixtures, rejects 12 malformed normal/audited builds, and rejects 57
altered audit records (including 10 direct range-certificate mutations).
All normal/audited matrix and witness fingerprints match; the historical
small and runtime fingerprints also remain unchanged. The CLI passes
explicit/inferred profile agreement and five unsafe/partial/mismatched request
rejections. The module-context/integration regressions verify four 192-byte
proofs, and the M0 prover/verifier compile check passes. These are host and
compile checks, not hardware timing measurements.

## Complete source-name binding

`-d:zkbuildNameSourceAudit` and `ZKNAMESOURCE1` add the missing connection between
the committed source bytes and the interned strings. The format includes the
actual source-reader node queries, byte/tail decompositions, first/adjacent-head
checks, empty-name checks, final-tail checks, and the immutable root/count/node
table interfaces. The checker requires those tables and expressions to match
the previously certified framing and graph components.

Both implementations are covered: the shared fixed-capacity parent/child stream
and the older variable-length reader. In the shared stream, owner and ordinal
coverage come from the checked owned-stream relation. A per-row induction proves
that a reader starts at its selected root and follows exactly one graph node
per source byte. The last declared ordinal must end at nil; empty names have a
nil root. No list length, byte value, root identity, or UTF-8 assertion is taken
on trust from host metadata.

The semantic composition includes:

- `NameSourceNodes.read_node`: the actual source reader consumes the byte of
  the corresponding verified graph node and advances to its tail.
- `NameSourceHeaders.legacy_names`: complete source/string equality for the
  variable-length reader.
- `NameSourceLineage.rows`: root and adjacent-node lineage for every active
  shared-stream row, including owner changes and padding.
- `NameSourceEnd.terminal`: the last ordinal's actual tail is nil, using the
  authenticated count lookup and the emitted equality/selection constraints.
- `NameSourceFlat.bound_names`: each active fixed-capacity name has exactly its
  declared number of bytes, and every byte equals the corresponding committed
  source byte in order.
- `NameSourceSoundness.module_verified`: combine these results with the unique
  source message and both public SHA-256 digest limbs. Each active name has a
  valid U32 length header, the exact complete byte span and a valid UTF-8 string
  represented by the checked root.
- `NameSourceSoundness.equal_heads_iff`: head equality is exactly byte-string
  equality; `query_bound_name` connects name-span consumers to the certified
  strings and source spans.
- `NameSourceConsumers.module_imports`: both names of every active import are
  complete, consecutive UTF-8 encodings in the same committed message, and the
  actual kind reader begins immediately afterward. This covers all four import
  kinds and both source readers.
- `BinaryTokenSyntax.checked_u32` and `NameSourceSyntax.module_verified`:
  concrete continuation, termination and fifth-byte overflow-bit rules for
  every active name-length header in that same message. Valid nonminimal U32
  encodings remain accepted.

This closes the source-name framing, byte/string correspondence, UTF-8 and
canonical-name obligations. Remaining full-system obligations include other
payload semantics, instruction validation, native compilation refinement, and
the cryptographic implementation/soundness boundary. It does not prove program
behavior, source-to-WASM compilation or unrestricted WASM-to-native correctness.

```sh
make zkbuild-name-source-cli
(cd formal/zkbuild && lake build check_name_source)
build/zkbuild/zkbuild-name-source-audit module-audit program.wasm program.names profile.json
formal/zkbuild/.lake/build/bin/check_name_source program.names
make zkbuild-name-source-circuit-test zkbuild-name-source-cli-test
```

The executable prover/audit infrastructure remains Nim; the formal model and
checker are Lean. Instrumentation preserves the normal R1CS, witness and kernel
proof encoding. The new theorem chains use no proof placeholders or native
execution axioms. They are soundness theorems for every satisfying assignment
of an accepted matrix; global prover completeness and cryptographic refinement
remain separate obligations.

The complete Lean build passes 617 jobs. The new source-name theorem chains
depend only on the standard `propext`, `Classical.choice` and `Quot.sound`
axioms. All 15 full-module audit fixtures pass, including both readers,
nonminimal encodings, padding, long names, empty names and Unicode boundary
values. Normal and instrumented matrix and witness fingerprints agree for
every fixture. The adversarial audit suite rejects 70 altered artifacts and 14
malformed normal/audited builds. The CLI accepts matching explicit/inferred
profiles and rejects five unsafe, partial or mismatched requests.

The payload regression covers all four import kinds, eight constant kinds,
eight element flags and three data modes; it rejects 39 independently valid
metadata substitutions and 15 malformed payloads. The module context and
integration suites verify four 192-byte proofs, and the M0 compile check
passes. These runs establish host and compile evidence, not measured hardware
latency or a complete cryptographic implementation proof.

The broader runtime checks also pass 65,536 opcode-catalog cases and 273
independent decoder round trips, 245 static signatures and 140 numeric
signatures, 400 type-reversal vectors, and 7,560 Lean exception-clause cases.
The composed exception circuit passes 48 Lean/R1CS comparisons and 35 traces,
rejects seven context/type/zero-arity forgeries, and verifies two additional
192-byte proofs.

An additional `make zkbuild-module-digest-test` run verifies two source-bound
192-byte proofs with two public digest inputs, and rejects changed source,
length, proof encoding and claim-mode inputs. For its 582,704-constraint
fixture, the Apple M3 Max arm64 host run measured about 160.15 CPU seconds for
one-time setup, 7.20 CPU seconds per proof and 0.96–0.99 milliseconds per verification. These
are measurements of the existing digest fixture, not BL808 timings or a
claim of optimality across proof systems or full-runtime workloads.

## Constant-expression source certification

`-d:zkbuildConstantSourceAudit` and `ZKCONSTANTSOURCE1` extend the complete
source/name audit with the constant reader used by globals, element offsets,
element items and data offsets. Instrumentation records the actual opcode
selectors, six primitive/dynamic read interfaces, cursor transitions, operand
split, and validation-metadata equations. It adds no R1CS constraints or
witness values. The normal matrix, witness and 192-byte proof encoding remain
unchanged.

The reader covers the eight forms accepted by `constantExpressionType` in
`src/cps/wasm/module_rules.nim`:

| Form | Source operand |
| --- | --- |
| `i32.const` | Signed 32-bit LEB |
| `i64.const` | Signed 64-bit LEB |
| `f32.const` | Four little-endian bytes |
| `f64.const` | Eight little-endian bytes |
| `v128.const` | `0xfd`, U32 subopcode 12, two eight-byte words |
| `ref.null` | Reference-type byte |
| `ref.func` | U32 function index |
| `global.get` | U32 global index |

Legacy element items are prefix-free U32 function indices. Their validation
record must describe `ref.func`. Modern records must contain exactly one
instruction and its end byte. For 64-bit scalar constants, the decoded operand
is retained while the existing validation metadata uses its low 32 bits. SIMD
records have vector arity one and the validation immediate zero. This is a
validation-metadata correspondence, not a value-preserving compiler theorem.

The composed proofs establish:

- `ConstantSourceSelection.selection`: exactly one supported modern opcode,
  or the legacy function-index mode, for every active record.
- `ConstantSourceModes.mode_value` and `prefix_value`: the selected operand
  format and actual external opcode prefix, including the SIMD encoding.
- `ConstantSourceValues.modern_value`: bounded 64-bit operand decomposition,
  correct validation immediate and vector arity.
- `ConstantSourceRead`: decoded values at the committed source positions;
  inactive readers have zero value, consume zero bytes and preserve the cursor.
- `ConstantSourceTrace.checked_trace`: all six read interfaces use consecutive
  natural-number positions, without field wraparound.
- `ConstantSourceSoundness.module_verified`: all listed reader records use
  the same message and two public SHA-256 limbs, with literal source opcode/end
  bytes, operand formats, SIMD subopcode/second word and legacy behavior.

The constant-reader checker certifies each listed invocation. The stronger
scalar-payload checker below also certifies the enclosing global loop. The complete payload-loop checker below covers segment traversal as well.
Composition with type/index-availability rules remains a separate obligation. The constant-only claim is
`source-sha256-constant-readers`; it does not enable general kernel admission or
assert complete WASM validity.

```sh
make zkbuild-constant-source-cli
(cd formal/zkbuild && lake build check_constant_source)
build/zkbuild/zkbuild-constant-source-audit module-audit program.wasm program.constants profile.json
formal/zkbuild/.lake/build/bin/check_constant_source program.constants
make zkbuild-constant-source-circuit-test zkbuild-constant-source-cli-test
make zkbuild-constant-proofs-test
```

The complete Lean build passes 637 jobs. The new theorem chains use only
`propext`, `Classical.choice` and `Quot.sound`, with implicit parameter
inference disabled and no proof placeholders or native-execution axioms.

Positive validation covers 16 full-module matrices, including 40 constant
readers in the fixed-capacity payload fixture and 37 in its variable-length
counterpart. Dedicated cases cover every constant form, both reference types,
negative signed constants, raw NaN payloads, and nonminimal SIMD subopcodes.
Every normal/instrumented matrix and witness fingerprint agrees; the prior
small and full-module fingerprints also remain unchanged.

The adversarial checker suite rejects 102 altered artifacts across modern and
legacy readers, covering selector locations, record fields, operand modes,
split references, all six read indices/cursors, record counts and trailing
data. The final CLI checks pass with a nonempty constant fixture, matching
explicit/inferred profiles and five rejected unsafe, partial or mismatched
requests.

The expanded payload regression rejects 39 independently valid metadata
substitutions and 22 malformed source payloads. The added source mutations
change opcodes, terminal bytes, scalar values, signed overflow encodings,
extra instructions and the second SIMD word while holding decoded metadata
fixed. Module-context/integration tests verify four 192-byte proofs, and the
M0 compile check passes. These are host and compile checks, not hardware runs.

All ten dedicated constant fixtures have the same matrix fingerprint. The
`zkbuild-constant-proofs-test` target uses one full digest-profile key for a
signed scalar initializer, a SIMD initializer with nonminimal subopcode
encoding, and a legacy element index. All three 192-byte proofs verify;
changing the source, source length or proof encoding is rejected. On the
Apple M3 Max host, the 422,763-constraint fixture took about 106.38 CPU seconds
for setup and 3.88 CPU seconds per proof. This measures that reusable profile,
not BL808 verification latency or all possible WASM workloads.


## Scalar section loop certification

`-d:zkbuildScalarPayloadAudit` and `ZKSCALARPAYLOAD1` extend the constant-source
certificate with the complete table, memory, global and export source loops
(sections 4–7). The CLI identifies this stronger claim as
`source-sha256-scalar-payloads`. The normal prover and verifier are still Nim;
Lean checks the exported matrix and proves the source interpretation.

Instrumentation records each actual row span, its read tokens/cursors,
read-only queries, packed limits, global initializer reference, export name
consumer, and the two closing gates for each section. The checker reconstructs
the row sequence from the envelope's payload start, uses each row's actual
output as the next input, and compares the final cursor and active-row count
with that section's envelope outputs. Altering the audit list does not alter
those matrix constraints.

The formal composition includes:

- Every active recorded read decodes bytes from the unique source message
  bound to the two public SHA-256 limbs. Consecutive reads have consecutive natural
  positions, and active U32 reads have terminating, bounded LEB encodings.
- The active-row count is a natural number below `2^32`, with no field wrap,
  and agrees with the section-count wire. The final cursor agrees with the
  section-end wire.
- Each active global consumes its type and mutability bytes, then the exact
  linked modern constant expression. A legacy element index cannot substitute
  for a global initializer. All eight supported initializer forms remain
  covered by the constant reader.
- Each active export consumes a complete UTF-8 name from the canonical name
  graph, then its kind and U32 index.
- Table and memory bounds split into two 32-bit words. Their disjoint memory
  queries and one-bit flag banks force the source limit flag to zero or one.

`ScalarPayloadSoundness.module_verified` composes these properties for all
four loops, including empty sections, inactive capacity padding and the older
variable-length payload representation. `global_prefix`, `global_modern`,
`export_name`, `ScalarPayloadRead.consecutive`, and `ScalarPayloadLimits`
provide the corresponding local results. The new theorems use only the
standard `propext`, `Classical.choice` and `Quot.sound` axioms.

```sh
make zkbuild-scalar-payload-cli
(cd formal/zkbuild && lake build check_scalar_payload)
build/zkbuild/zkbuild-scalar-payload-audit module-audit program.wasm program.scalar profile.json
formal/zkbuild/.lake/build/bin/check_scalar_payload program.scalar
make zkbuild-scalar-payload-circuit-test zkbuild-scalar-payload-cli-test
make zkbuild-scalar-payload-proofs-test
```

The audit regression checks normal/instrumented matrix and witness
fingerprints for ten modules. They include all four defined scalar sections,
nonminimal U32 indices, the full payload fixture in both representations,
empty sections, imports, SIMD initializers, and padding. Its hostile payload
cases cover row omission/duplication, whole-section omission, counts, closing
gates, queries, packed-field references, global initializer references, export
names and every read cursor/token. The optional `--payload-cases MANIFEST`
checker mode evaluates these candidate payload records against one already
validated complete artifact, avoiding repeated parsing of the common matrix;
its output reports each acceptance or rejection explicitly.

The full Lean build passes 653 jobs. All ten audit fixtures pass with matching
normal/audited matrix and witness fingerprints. The hostile-record batch
rejects all 104 altered payloads, including omissions and duplicates, while
accepting its unchanged control payload. The large fixed-capacity fixture has
2,425,294 constraints and 40 constant readers; its variable-length counterpart
has 2,133,577 constraints and 37 readers.

The new end-to-end proof regression uses one key for both minimal and
nonminimal export indices, with defined tables, memory and globals. Both
variants pass proof verification and retain the 192-byte proof encoding;
changed source, source length and proof encoding are rejected. Their shared
profile has 423,413 constraints. The CLI passes with explicit and inferred
profiles and rejects five unsafe, partial or mismatched requests. The M0
verifier compile check passes; no hardware run was performed.
Instrumentation adds no circuit constraints, witness variables, or kernel
verification work.

This is source-loop certification, not a proof of complete WASM validity.
The segment-payload layer below extends these source guarantees to
elements, data and custom sections. Full composition with module type/index
rules and instruction validation, and cryptographic implementation refinement,
remain separate obligations. Native compilation correctness and source-language
compilation are separate goals. The audit claim deliberately does not enable
general kernel admission. Host test results do not establish BL808 timing.


## Element, data and custom-section source certification

`-d:zkbuildSegmentPayloadAudit`, the `ZKSEGMENTPAYLOAD1` artifact and the
`source-sha256-payload-loops` CLI claim extend scalar certification across the
remaining module payload loops. The normal executable prover and verifier
remain Nim. The Lean checker reconstructs the additional matrix spans and
checks their interfaces to the earlier source, name, constant and owned-stream
certificates.

The layer covers all eight element flag encodings, expression and legacy
function-index items, all three data modes, the singleton start/data-count
payload boundaries, and every custom-section slot in the ordered envelope.
Flattened element children are linked to their actual owned-stream parents,
ordinals, start/end positions and mode lookup table. The variable-length
representation records every constant invocation in the enclosing row. A
missing or duplicated row changes the checked interface or matrix span.

`SegmentPayloadSoundness.module_verified` composes, for the same unique
public-digest source message:

- The earlier four scalar-section traces and active U32 grammar.
- Active primitive reads for element and data headers and indices.
- Three-bit element flags and data flags restricted to 0, 1 or 2.
- Constant-reader traces for segment offsets and element items.
- Complete enclosing element/data traversal, natural active counts below
  `2^32`, and exact section-end equations.
- Custom-section selection by the envelope's actual active/id fields, complete
  UTF-8 name spans, and bounded uninterpreted payload suffixes.
- Owned-child coverage with the parent and child field values tied to the
  concrete source traversal records.

Data and custom payload bytes remain uninterpreted; the SHA-256 source
commitment binds their contents. The data cursor advances by its decoded
length, and a checked 32-bit remaining-length witness bounds it relative to
the section end.

Interface expressions are compared modulo the scalar field. This accepts the
Nim exporter's canonical residue for a negative coefficient, while retaining
exact matrix-span checks and range bounds. No constraints or witness variables
are added to the normal proving relation.

```sh
make zkbuild-segment-payload-cli
(cd formal/zkbuild && lake build check_segment_payload)
build/zkbuild/zkbuild-segment-payload-audit module-audit program.wasm program.payload profile.json
formal/zkbuild/.lake/build/bin/check_segment_payload program.payload
make zkbuild-segment-payload-circuit-test zkbuild-segment-payload-cli-test
```

The regression suite includes both payload representations, all element flags
and data modes, padding, empty sections, UTF-8 custom names and the large full
module fixtures. It compares matrix and witness fingerprints and tests hostile
row counts, omissions, duplicates, ordering, range certificates, constant
references, read interfaces and custom-section metadata. The checker supports
`--segment-cases MANIFEST` to test candidate segment records against one
already validated full artifact.

The full Lean build passes 669 jobs. All eight audit fixtures pass, including
both payload representations, all element flags/data modes, the two large
module fixtures, padding, empty sections and UTF-8 custom names. Normal and
audited matrix/witness fingerprints agree; retained fixtures also match the
previous implementation. The checker rejects 428 altered segment records
across both representations, including omitted, duplicated and reordered
rows, while accepting the unchanged controls.

The CLI accepts matching explicit/inferred profiles containing nonempty data
and custom sections and rejects five unsafe, partial or mismatched requests.
The normal source-binding regression rejects 39 independently valid metadata
substitutions and 22 malformed payloads. The M0 verifier compile check passes;
no hardware run or BL808 latency measurement was performed. The existing
192-byte proof encoding is unchanged.

This certifies source traversal and its exposed metadata interfaces. It does
not yet constitute a complete proof of WASM validity: composition with the
module type/index/arity rules and instruction-validation relation remains
open. In particular, the source-loop certificate is not a substitute for the
module-context proof connecting legacy element arities, initializer types,
index availability, and start/data-count rules to the WASM specification.
Cryptographic implementation refinement and WASM-to-native compilation
correctness also remain open. The claim does not enable general kernel
admission.

## Module-context matrix certification

`-d:zkbuildModuleContextAudit` adds `ZKMODULECONTEXT1` evidence and the
`source-sha256-module-context` claim. It includes the complete segment-payload
certificate and replays `constrainModuleContext` against the same R1CS matrix.
The extra records contain expressions, primitive descriptions, table indices
and constraint spans; they do not contain the private assignment.

The replay covers dense function/type/global/table namespaces, body counts,
limits and imported/defined counts, initializer opcode selection and type
arithmetic, prior-global availability, immutable-global lookups, reference
existence and declaration origins, element types and item arities, data offsets,
start-function signatures, export bounds, and export-name uniqueness. Flat
items are connected to the checked ownership stream and element-type table;
legacy item lists are replayed directly. Initializers, element/data fields,
exports, limits, names, and namespace counters are compared with the existing
source certificates. Start presence and index have an explicit checked binding
to the source envelope.

`ModuleProgram` checks each primitive's matrix fragment, argument expressions,
outputs, range-reuse evidence and position. Raw constraints advance the same
cursor. A program must consume its entire recorded operation list and finish
at the declared boundary. `ModuleContextMatrix` reconstructs the Nim rule
sequence, checks the ownership/table boundaries, and compares all six final
read-only interfaces. This catches omitted, reordered, substituted and
unconsumed operations without adding constraints to the production relation.

`ModuleProgramSound` establishes the checked primitive contracts for any
satisfying assignment, including finite natural ranges, and establishes every
raw gate. `ModuleContextSound.replay_sound` lifts these results to the accepted
module replay and its final interfaces. `start_binding` establishes equality
with the source envelope's start fields. The proofs use only Lean's standard
`propext`, `Classical.choice`, and `Quot.sound` axioms.

Reproduce with:

```sh
make zkbuild-module-context-circuit-test
make zkbuild-module-context-cli-test
make zkbuild-validator-target-check
```

The checker accepts `--module-cases MANIFEST` for testing standalone replacement
module records against one checked matrix and source prelude. The regression
harness exercises both flat and legacy modules, padded/empty sections, scalar
limits and nonminimal encodings, and the full fixture's eight constant forms,
eight element flags, start function and three data modes. It compares normal
and instrumented matrix **and witness** fingerprints.

Validation passes 679 Lean build jobs, eight complete audit fixtures, and
1,156 hostile module-record cases (603 flat and 553 legacy). Four valid
controls, including harmless prior-certificate index renaming, are accepted.
All eight normal/audited matrix and witness fingerprints match. The module
regression rejects 17 coherent module forgeries and an omitted function
transcript, checks 65,536 UTF-8 cases, and verifies two 192-byte proofs. The
binary-source regression checks 124 primitive encodings, rejects 17 forgeries,
and verifies two more 192-byte envelope proofs. Both explicit/inferred CLI
profiles pass, all five invalid requests are rejected, and the M0 verifier
compile check passes. No hardware or latency measurement was performed.
Machine-readable results and exact source/fingerprint hashes are recorded in
`build/zkbuild/module-context-validation.json`.

This adds a concrete matrix certificate for the module rule sequence. A
complete refinement theorem from the composed instruction/module relation to
the runtime's full WASM validator is still required. In particular, this does
not close instruction/body-event composition, parser/witness completeness,
cryptographic implementation refinement, or WASM-to-native compilation
correctness. It does not enable general kernel admission. The audit adds no
production constraints and does not alter the 192-byte proof encoding.

## Code-body and compressed-local matrix certification

`-d:zkbuildBodySourceAudit` emits `ZKBODYSOURCE1` and the
`source-sha256-code-bodies` claim. This extends the module-context artifact
with three checked programs: code-body framing, local-declaration totals and
parameter types, and sparse local lookup against compressed declarations.
Both fixed-capacity and legacy body representations use the same checker.

The code-body program binds each body-size and local-group-count read to the
committed byte stream, checks body/section bounds and the final `end` byte,
and reconstructs the instruction-span table. Local group counts and type
bytes are bound to the range/type tables. In the flat representation, ordered
owner/ordinal keys, exact per-body counts and boundary cursors cover every
local group, including zero-count groups. Large local counts remain one
compressed declaration; the proof does not expand them into one row per local.

The local-declaration program checks function-index availability, parameter
counts and parameter types against the existing signature/member certificate.
It binds final local/declaration totals to the last compressed range. The
local-range program checks declaration ordering, contiguous intervals, matching
range/type keys, and each sparse local lookup's function, interval and type.
The three programs share checked immutable table interfaces.

`SourceProgram` treats already checked binary readers and packed-field splits
as atomic operations. It retains ordinary primitive calls and raw constraints
between them, and requires exact helper/primitive ordering and end positions.
Helper internals are omitted from this extra transcript; they are already
covered by the existing token/packed-field certificates. This avoids repeating
those internals in the new audit format. No private assignment is exported.

`SourceProgramSound` proves active reader values, byte values, packed low/high
fields and ordinary primitive/raw-gate facts. `BodySourceTheorems` lifts these
facts to all three accepted programs and checks their closing interfaces.
`BodySourceCommitted.verified` binds the accepted programs to one unique
SHA-256 source message and supplies integer, byte and U32-LEB syntax facts for
their readers. These are concrete R1CS certificates; they do not replace the remaining full
refinement theorem for instruction decoding, validation events and runtime
WASM semantics. General kernel admission remains disabled.

Reproduce with:

```sh
make zkbuild-body-source-circuit-test
make zkbuild-body-source-cli-test
make zkbuild-body-source-binding-test
make zkbuild-validator-target-check
```

`check_body_source AUDIT --body-cases MANIFEST` validates replacement body,
local-declaration and local-range records against one already checked source
prelude and matrix. The test harness includes empty/padded bodies, both body
representations, all seven local types, nonminimal LEBs, zero-count groups and
very large compressed local counts. Production constraints, witness sizes and
the 192-byte proof encoding are unchanged by the audit instrumentation.

Validation passes 699 Lean build jobs and ten complete audit fixtures, with
all normal/audited matrix and witness fingerprints equal. The checker rejects
1,231 corrupted records across the flat (705) and legacy (526) cases and
accepts both unchanged controls. Separately, 26 independently valid decoded
module substitutions are rejected against the original committed bytes: 22
produce unsatisfied circuits and four cannot construct a matching witness.
Explicit/inferred CLI profiles containing a local group, global, data segment
and custom section pass; all five invalid CLI requests are rejected. The M0
verifier compile check passes. No hardware run was performed.

The small-local fixture and the fixture with a group of 4,294,967,294 locals
have exactly the same 931,540-constraint matrix under the fixed profile. This
validates constant circuit size as the local count increases; it does not assert that the target
can allocate that many runtime locals. The audit adds no constraints or witness
variables and does not change the 192-byte proof encoding. Exact fingerprints,
source hashes, test counts and remaining obligations are recorded in
`build/zkbuild/body-source-validation.json`. These checks are included in
`make zkbuild-check`.

## Complete instruction-source matrix certification

`-d:zkbuildInstructionSourceAudit` emits `ZKINSTRUCTIONS1` with the
`source-sha256-instruction-stream` claim. It extends the body/local certificate
with every instruction decoder and the complete instruction-stream controller,
for both fixed-capacity and legacy representations. This is an audit of the
existing Nim proving relation; it does not add constraints or change proof
encoding.

The witness constructor also binds SIMD constant words from the decoded
compiler pool to the source readers. Previously those words were populated
from the source alone, so substituting the compiler's constant pool could go
unnoticed by witness construction. Both 64-bit halves now use the compiler
pool as the claimed reader value, retaining the same gates and variables.
This closes that substitution path without changing existing valid matrices.

The decoder certificate covers the complete runtime opcode catalog, including
prefixed SIMD/bulk instructions, all fourteen immediate layouts, signed and
unsigned LEBs, float bits, reference types, lanes, vector constants, typed
selects, and block type encodings. The stream certificate reconstructs function
and PC progression, instruction spans, branch-table labels, exception clauses,
control-stack reads/writes, root ends, and the instruction fields consumed by
validation events. Immutable-table queries and the control-memory permutation
are checked against their recorded matrix gates. Nested decoder/reader helpers
are recorded once and linked through explicit input/output interfaces.

`OpcodeCatalog` supplies an independent declarative layout table. Every
16-bit opcode input is checked against the recorded decision diagram.
`OpcodeCatalogSound.values` proves that an accepted lookup returns this table's
values. `LookupReferenceFast` uses array-backed flow state and proves its
results equal the original reference interpreter, including out-of-range node
references; this accelerates certification without weakening the table check.
Coefficient normalization uses a proved compiler substitution to skip
big-integer remainders for coefficients already in the scalar field range.
A batch can reuse an identical, already checked catalog view. Replacement
records must retain that view and independently pass their matrix checks.

`InstructionSourceSound.verified` connects closed decoder and stream replays
to a single committed SHA-256 message, and provides primitive/raw-gate facts,
integer and byte readers, variant-format immediate readers, packed-field
relations, output-table bindings, and control-memory certification. The theorem
is conditional on matrix satisfaction and the existing source/table certificate.
It is not yet the final refinement theorem from the entire composed validation
relation to the runtime's WASM validation semantics. Validation-event schedule
and typing composition, witness completeness, cryptographic implementation
refinement, and native-code semantic preservation remain separate obligations.
General kernel admission remains disabled.

Use:

```sh
make zkbuild-instruction-source-circuit-test
make zkbuild-instruction-source-cli-test
make zkbuild-instruction-metadata-binding-test
make zkbuild-target-check
make zkbuild-validator-target-check
```

`check_instruction_source AUDIT --instruction-cases MANIFEST` checks replacement
instruction/catalog/controller records against the original matrix and source
prelude. `check_instruction_source --batch MANIFEST` accepts one audit path per
line, or an audit path and replacement-case manifest separated by a tab.
`ZKBUILD_AUDIT_TRACE=1` enables stage diagnostics. The supported WASM instruction
set is selected by the runtime catalog, not by a small example-program whitelist;
profiles bound program/table sizes and can be generated for larger modules.

The instruction audit regression supports `ZKBUILD_AUDIT_JOBS=1..8`
(default 2). It partitions independent module and corruption cases across
checker processes, retaining every case and checking their combined results.
Reduce the worker count on memory-limited hosts.

The completed instruction-source validation run passes 719 Lean build jobs,
24 full module audits, and 2,503 corrupted-record cases, with both unchanged
controls accepted. All 24 normal/audited matrix and witness fingerprints agree.
Fixtures exercise empty/padded modules, local declarations, control flow,
branch tables, all four exception-clause kinds, signed/wide immediates,
SIMD constants/lanes, typed selects, and bulk-memory immediates in both
representations.

The independent source decoder regression passes 275 layouts and rejects
16 forgeries; it also generates and verifies two fresh 192-byte proofs.
Another regression rejects 32 independently valid decoded-program
substitutions (30 unsatisfied circuits and two rejected witness constructions),
including SIMD constant-pool changes in both 64-bit halves. Explicit/inferred
CLI profiles pass and five invalid CLI requests are rejected. M0 verifier and
runtime/validator compile checks pass. Hardware execution and kernel latency
were not tested. Results, fingerprints, source hashes, and remaining obligations
are recorded in `build/zkbuild/instruction-source-validation.json`.

## Source-linked validation-event certification

`-d:zkbuildValidationEventAudit` emits `ZKVALIDATIONEVENT1` with the
`source-sha256-validation-events` claim. It includes the complete preceding
source certificate, then certifies five connected parts of the existing Nim
validation relation: opcode admission, operand-event projection, control-event
projection, instruction scheduling with fixed typing rules, and parametric
typing (`select`, typed select, and `ref.null`). The operand and control memory
arguments are checked against the access expressions produced by those same
event rows. This adds no proving gates, witness variables, or proof bytes.

The event certificate reconstructs selector allocation, stack heights, floors,
polymorphic pops, unreachable states, function boundaries, canonical padding,
control depths, instruction PCs, operand order, and per-instruction pop/push/
clear counts. Its interfaces use the exact instruction and immediate expressions
bound by the source decoder. Helpers consume explicit input/output interfaces
and gate spans; missing, reordered, or extra operations fail a closed replay.

`StaticLookupMatrix` describes the Nim rule DAG, including nodes which emit a
shared output and continue traversal. `StaticLookupFast` proves its array-backed
interpreter equal to the reference interpreter. The canonical check compares
all admitted opcodes, four operand positions, and eight value-type tags with
the independent `StaticTyping` definition. Admission separately checks all
65,536 opcode inputs. Restricting the rule-table comparison to admitted opcodes
is valid only with that admission premise; `ValidationEventSound.static_values`
states the premise explicitly. The Nim lookup regression additionally compares
all 2,097,152 opcode/position/type combinations.

`ValidationEventSound.checked` establishes closed stage replays, primitive and
raw-gate facts, and ordered read/write memory consistency. `admitted_rows`
proves that every event opcode is in the runtime catalog; `static_rows` returns
the canonical fixed-rule outputs for that same event opcode and value type.
These conclusions read the same gates already consumed by the stage replays.
The memory theorem
includes range bounds, chronological timestamps, the permutation to sorted
records, and valid reads from initially empty memory. `ValidationSourceSound.checked`
composes these facts with instruction decoding for one unique SHA-256-committed
message and proves that the event expressions are the same on both sides.
These theorems assume matrix satisfaction and the checked source/circuit
certificates; they do not turn finite test results into universal claims.

Dynamic variable/call typing, signature-frame and branch typing, exception
typing, bulk/reference context composition, parser/witness completeness, the
final refinement to the runtime validator, and cryptographic implementation
refinement remain obligations. General kernel admission remains disabled.

Run the complete exported-circuit and CLI regressions with:

```sh
make zkbuild-validation-event-circuit-test
make zkbuild-validation-event-cli-test
```

`check_validation_events AUDIT --event-cases MANIFEST` checks replacement event
records against one checked source prelude and matrix. `--batch MANIFEST` has
the same one-path or tab-separated path/case-manifest format as the instruction
checker. `ZKBUILD_AUDIT_JOBS=1..8` selects the number of independent checker
processes in the regression harness. Both targets are part of `make zkbuild-check`.

The completed validation-event run passes 739 Lean build jobs and 24 complete
module audits. All 24 matrix and witness fingerprints match the normal build
and the retained instruction-source fixtures. It rejects 1,912 corrupted
records and accepts both unchanged controls. The fixtures cover both source
representations, all four exception-clause forms, branch tables, scalar and
vector immediates, typed selects, bulk memory, locals, and padded/empty modules.

The accompanying regressions pass the exhaustive lookup comparison, 2,724
lookup circuits, 9,216 public-field mutations, fixed-rule typing, operand and
control transitions, instruction scheduling, and parametric typing. Six fresh
192-byte component proofs verify; the parametric regression also checks
38,912 finite cases with Lean. Explicit and inferred CLI profiles pass and five
invalid requests fail. Both M0 compile checks pass. These are host checks;
there was no hardware run or measurement of kernel verification latency.
The full-module regression also produces two fresh 192-byte proofs for
private-metadata circuits with 484,048 constraints, rejecting changed source
bytes, malformed proofs and incompatible profiles. Exact fingerprints, log
hashes, and remaining obligations are recorded in
`build/zkbuild/validation-event-validation.json`.


## Source-linked variable and call typing

`-d:zkbuildDynamicTypingAudit` extends the preceding certificate with four
programs: opcode selectors for variables/tables, authenticated type lookup,
variable/table instruction typing, and direct/indirect ordinary/tail call
checking. Executable prover, verifier, witness and audit code remain Nim;
Lean checks the emitted matrix and proves properties of accepted certificates.
The format is `ZKDYNAMICTYPING1`, with claim
`source-sha256-dynamic-typing`.

The checker derives local keys from the current function and local index,
separates global/table keys by parity, checks mutable-global writes, verifies
reference table element types, and connects declared types to the source-bound
local and object tables. Variable instruction replay checks operand order,
polymorphic input types, output types, and exact pop/push counts. Call replay
checks indirect indices, exact signature-list traversal, multi-value results,
tail-call result agreement, and clear counts. It uses the already certified
signature environment and packed-field helpers. The audit adds no gates or
witness variables.

`DynamicTypingSound.checked` proves closed replays and active-query membership,
plus canonical zero values for inactive queries. `DynamicSelectors.rows`
proves each selector equals the opcode comparison it implements.
`DynamicTypingSource.environment_origins` connects local and object reads to
the source-bound initializer records; `source_bound` composes the dynamic programs with the
instruction and event certificates for a single SHA-256-committed message.
These are conditional circuit/source-certificate theorems. Full semantic
refinement of variable and call traces, structured branch/exception typing,
bulk/reference context composition, witness completeness and cryptographic
implementation refinement remain obligations. General kernel admission stays
disabled.

Run:

```sh
make zkbuild-dynamic-typing-circuit-test
make zkbuild-dynamic-typing-cli-test
make zkbuild-dynamic-typing-binding-test
```

The checker accepts either a complete audit or a retained
`ZKVALIDATIONEVENT1` prelude with a separate dynamic suffix:
`check_dynamic_typing AUDIT --typing SUFFIX`. The suffix cannot replace any
source prerequisite; both the original source certificate and the new matrix
interfaces are checked. `--typing-cases MANIFEST` checks replacement dynamic
records. A batch contains tab-separated `AUDIT`, `SUFFIX`, and optional case
manifest paths. This avoids duplicating large source matrices in test artifacts.
`ZKBUILD_AUDIT_REUSE=1` reuses generated fixtures during local regression work;
normal Make targets regenerate them. The private fixture tool's
`ZKBUILD_TYPING_SUFFIX=1` emits only the suffix; the production CLI always
emits the complete certificate.


This pass validates 753 Lean build jobs and 32 complete dynamic-typing audits:
24 retained source/event fixtures plus eight modules exercising locals,
globals, table access/growth/fill, direct and indirect calls, both tail-call
forms, and multi-value signatures. Every audited matrix and witness fingerprint
matches its ordinary build. The checker rejects 2,274 corrupted records and
accepts all three unchanged controls. The table fixture has 128 validation
rows and a 32-instruction source vector; it exposed and fixed an audit-reader
limit that incorrectly treated variable-length vectors as fixed 16-field
records. Owning matrix checkers continue to enforce exact record shapes.

A separate regression rejects 26 independently valid alternate decoded modules
against the original committed source, with 16 valid controls across both
source representations. Variable/call tests cover 90 and 66 transcripts,
respectively, 6,048 call signature cases, and 2,801 interned type lists. Four
fresh 192-byte component proofs verify. Both CLI profile modes and both M0
compile checks pass; no hardware execution or kernel latency measurement was
performed. Full results and source/log hashes are in
`build/zkbuild/dynamic-typing-validation.json`.

## Source-linked structured control and exceptions

`-d:zkbuildStructuredControlAudit` adds the integrated `ZKSTRUCTURED1`
certificate and `source-sha256-structured-control` CLI claim. This includes the
preceding source, instruction, validation-event and dynamic-typing certificates.
The executable prover, verifier, audit exporter and witness generation remain
Nim. Lean checks the exported matrix rather than trusting recorded stage names.

Ten programs cover catch-list traversal, branch-label projection, branch-table
traversal, signature-frame memory, block/loop/if/else/end/return typing, branch
argument pop/restore, merged indexed-signature queries, throw/tag typing,
signature-list reversal, and catch payload/target typing. The checker binds their
inputs and outputs to the same validation rows and authenticates all read-only
table queries. Frame memory uses 64-bit addresses and 36-bit descriptors; branch
restoration uses 32-bit addresses and 3-bit types. Both include exact
chronological clocks, bounds, permutation checks and valid reads from initially
empty memory.

`StructuredSound.checked` establishes closed replays, primitive/raw-gate facts,
read-only membership and inactive-query zero values, plus the two memory
relations. `StructuredSource.source_bound` composes the stages with the unique
SHA-256-committed message, its instruction decoding, and the earlier dynamic
typing stages. `StructuredOrigins.control_origins` connects catch/branch reads to
the instruction certificate's initializer entries for either source layout;
`type_origins` connects signature/list reads to their corresponding checked
initializers. These theorems use only `propext`, `Classical.choice`, and
`Quot.sound`. They assume the checked certificates and matrix satisfaction.
`StructuredMergeSound` separately proves boolean union and active-value
preservation from the merge gates. These are not a proof of the final
refinement to the runtime's whole validator.

Run the integrated checks with:

```sh
make zkbuild-structured-control-circuit-test
make zkbuild-structured-control-cli-test
```

For retained fixtures, the offline checker also accepts
`check_structured_control AUDIT --control SUFFIX`. A `ZKDYNAMICTYPING1` prelude
checks all earlier dynamic stages. A `ZKVALIDATIONEVENT1` prelude checks through
validation events and the new structured stages; it does not claim to contain a
dynamic-typing certificate. The production CLI always emits the full format.
`--control-cases MANIFEST` checks replacement records against that same matrix
and source prelude. Test-only `ZKCONTROLPATCH1` files encode one-line changes and
truncation/extension; the checker reconstructs the complete record and runs the
ordinary parser and checker. This avoids duplicating multi-megabyte evidence
for every mutation. Normal case files containing complete records remain valid.

Audit instrumentation adds no gates or witness values. The integration suite
compares both fingerprints across the 32 retained fixtures: both byte-source
layouts, all four catch forms, branch tables, scalar/SIMD/bulk instructions,
locals/globals/tables, ordinary and tail calls, and multi-value signatures.
Separate regressions exercise coherent substitutions, runtime handler behavior,
and freshly generated Groth16 proofs. A full private-metadata module regression
also verifies two 192-byte proofs and rejects changed source bytes, malformed
proofs and incompatible profiles. The flat-module regression checks 22 typed
bodies against one 935,271-constraint matrix. Detailed run results are recorded in
`build/zkbuild/structured-control-validation.json`.

The final build passes 779 Lean jobs. All 32 matrix/witness fingerprint pairs
match. The main sweep rejects 6,969 corrupted records; the dedicated memory
sweep rejects another 858. Each sweep accepts its three unchanged controls.
Together these cover 7,755 distinct mutations after deduplication. The component
suites generate eight 192-byte proofs; the full-module suite generates two
more. Both M0 compile checks and both CLI profile modes pass, with five invalid
CLI requests rejected. These are host tests, not a hardware measurement.

Still open: full structured-trace semantic refinement, memory/bulk/reference
context certification, whole-parser/validator and witness completeness,
cryptographic implementation refinement, and general WASM-to-native semantic
preservation. General kernel admission remains disabled. These offline
certificates are not additional bytes in the 192-byte Groth16 proof and do not
establish a kernel verification latency measurement.

## Source-linked memory, SIMD, bulk and reference context

`-d:zkbuildRuntimeContextAudit` extends the complete certificate with three
context programs. Its full format is `ZKRUNTIMECONTEXT1`, and the CLI reports
`source-sha256-runtime-context`. Executable code remains Nim; Lean checks the
same matrix and its source interfaces.

The memory program checks memory existence and index zero, scalar/SIMD memory
alignment, lane bounds and vector-pool indices. Its seven-column decision DAG
is compared with the independent `InstructionMetadata.payload` for every
16-bit opcode. The bulk program checks the data-count section, data and element
indices, memory/table indices, table element types and table-copy agreement.
The reference program checks that each `ref.func` names a declared function.
All active queries use authenticated immutable tables; inactive query fields
remain canonical zero values.

`RuntimeContextSound` proves the three closed matrix replays and table facts.
`RuntimeContextSource.source_bound` composes them with the preceding source,
instruction, validation and structured-control certificates for one unique
SHA-256-committed message. `RuntimeContextOrigins` proves lookup outputs match
the canonical instruction metadata, traces vector/object/reference queries to
source-bound initializer entries, and binds bulk data counts to the original
section header. These are conditional matrix/source-certificate theorems, not
a completed refinement of the whole runtime validator.

Run:

```sh
make zkbuild-runtime-context-circuit-test
make zkbuild-runtime-context-cli-test
make zkbuild-runtime-context-binding-test
make zkbuild-runtime-context-substitution-test
```

The retained-fixture interface is
`check_runtime_context AUDIT --control CONTROL --context CONTEXT`. It checks
every prerequisite present in the source prelude, the separate structured
record and the context suffix. `--context-cases MANIFEST` supports complete
replacement records and compact `ZKCONTEXTPATCH1` one-line mutations. Only
unchanged decision-DAG topology and payloads reuse an already checked canonical
table; changes force a fresh comparison.

The additional complete fixtures exercise scalar and vector loads/stores,
memory size/grow, memory init/copy/fill, data/element drop, table init/copy,
function/reference declarations and all six SIMD lane operation families. The
separate substitution suite rejects 20 valid alternate decoded modules while
retaining the original bytes, with eight unchanged controls. Normal and audited
circuits match in both matrix and witness fingerprints. The component suites
exercise 193 memory/alignment/lane/pool cases, 36,288 Lean bulk cases, 24,192
host bulk validations, and 2,560 reference circuit cases, producing six fresh
192-byte proofs.

Whole-trace semantic refinement, parser/witness completeness, cryptographic
implementation refinement and arbitrary WASM-to-native correctness remain
open. General kernel admission remains disabled until those obligations are
met.


This context pass validates 791 Lean build jobs and 36 complete module audits:
32 retained source/control fixtures plus four new modules covering the context
families above. All 36 matrix and witness fingerprints match their ordinary
builds. It rejects 3,402 corrupted records and accepts all three unchanged
controls. The CLI passes both explicit and inferred profiles and rejects five
invalid requests; both M0 compile checks pass. Exact fingerprints and log/source
hashes are in `build/zkbuild/runtime-context-validation.json`. No hardware run
or kernel latency measurement was performed.

## Operand, control and function semantic certificates

`check_event_semantics` strengthens the existing `ZKRUNTIMECONTEXT1` offline
certificate. It consumes the same Nim-generated record; it adds no witness
variables, constraints, public inputs or proof bytes. The audited CLI prints
this checker in `check_with`. Its claim string remains
`source-sha256-runtime-context`: generating an audit alone does not prove the
semantic check passed.

The additional checker reconstructs operand/control rows from the existing
primitive-call schedule. It checks exact normalized gate membership, reused
range certificates, selector bindings, previous-row links, stack projections
and closing gates. There is no asserted numeric trace in the audit. The Lean
soundness results quantify over every satisfying field assignment:

- `OperandRowSound` derives all eleven event kinds, including label checks,
  bounded natural values, polymorphic-pop guards, push/pop/clear transitions,
  boundary zero heights, padding constraints and operand addresses.
- `OperandTraceSound` joins consecutive rows and proves final zero height.
  `OperandMemorySound` identifies the projected events with the checked RAM
  trace, proving reads from initially empty memory. `OperandCertificate.sound`
  composes these results using only the decidable certificate checks, matrix
  satisfaction and the constant-one assignment.
- `ControlRowSound` proves depth transitions, empty/top guards, function
  scheduling and both frame-memory projections. `ControlCertificate` binds
  its rows and selectors to the operand trace; `ControlTraceSound` proves the
  depth trace and final empty depth. `ControlMemorySound` proves the projected
  frame-memory read history. `FunctionTraceSound` proves function-index
  continuity, open/close scheduling and final closed state.
- `OperandSourceSound` and `ControlSourceSound` connect these conclusions to
  the earlier unique SHA-256 message and checked instruction interfaces.

These proofs use Lean's `propext`, `Classical.choice`, and `Quot.sound`; the new
semantic theorems have no `sorry` or added axioms. They do not yet establish
that every admitted instruction sequence implements the runtime's complete
validator, or that the Nim compiler preserves semantics for arbitrary native
output. At this earlier stage, the control-frame LIFO induction and instruction/type-state
composition were still open. The following pass closes both stack inductions and
the fixed-signature instruction composition. Dynamic instruction semantics,
parser/witness completeness and cryptographic implementation refinement remain
open. General kernel admission stays disabled.

Run the integrated checks with:

```sh
make zkbuild-event-semantics-test
make zkbuild-event-semantics-cli-test
```

For retained fixtures:

```sh
formal/zkbuild/.lake/build/bin/check_event_semantics \
  SOURCE.audit --control CONTROL.control --context CONTEXT.context
```

The checker also accepts a full `ZKRUNTIMECONTEXT1` record directly. `--batch`
uses the runtime-context manifest format, and `--mutations` rejects corrupted
operand/control records against the original matrix. The Nim test driver
reuses the 32 retained fixtures and four complete memory/bulk/reference/SIMD
fixtures, avoiding another copy of the large audit corpus.

This pass completes 827 Lean build jobs and checks all 36 retained complete
module certificates, totaling 2,384 event rows. The combined checker rejects
200,256 operand/control mutations, with all unchanged controls accepted. A
separate operand-only sweep rejects 104,896 mutations. All 36 matrix and
witness fingerprints match the preceding runtime-context pass. Three fresh
192-byte component proofs, both CLI profile modes, five invalid CLI requests
and both M0 compile checks pass. Full results, theorem assumptions, source
hashes and log hashes are recorded in
`build/zkbuild/event-semantics-validation.json`. No hardware execution or
kernel verification timing was measured.


## Instruction semantics and complete stack inductions

The event certificate now also checks the instruction stage. The Nim prover and
kernel verifier keep their existing circuit and proof format. These additions
strengthen the offline certificate checked before a circuit can become a trusted
relation; they add no circuit constraints, witness variables or proof bytes.

`InstructionSemanticSource.source_bound` joins the committed SHA-256 message,
instruction stream, dynamic/structured/runtime-context replays, operand type
stack, control-frame stack and instruction schedule. Its conclusions quantify
over every satisfying field assignment, with the certificate checks and the
constant-one wire as hypotheses. It does not assume a supplied semantic trace.

The new semantic results establish:

- Control-frame LIFO behavior over the complete trace, including authenticated
  floors/unreachable flags, function namespace changes and empty closure.
- Operand-stack behavior over the complete trace. Ordinary pops return the
  actual top type; polymorphic pops require the unreachable floor and unknown
  type; clear truncates to the floor. Function closure leaves no operand types.
- Instruction open/close scheduling, required root-frame placement, PC/opcode
  continuity, label-check opcode restrictions, bounded counters and closed
  final instruction state.
- Static instruction typing from the canonical lookup table. Every recognized
  fixed signature has a proved shape bound. Pops respect the input type/class
  and ordering, pushes respect output type/arity and uniqueness, clears respect
  their permission/count, and instruction ends have exact counts. This includes
  numeric, scalar memory, bulk, reference and SIMD fixed signatures. Additional
  immediate/environment validity is supplied by the separately checked records;
  its complete semantic refinement remains an obligation.

`InstructionRowCheck` reconstructs records from the existing operation schedule
and checks both gate spans around each static-lookup helper. It includes the
lookup's normalized inputs and all instruction row/state links. The integrated
`check_event_semantics --mutations` exercises 143 corruptions per event row:
44 operand, 40 control and 59 instruction mutations. The Nim driver validates
the new count across all retained complete modules. Existing commands remain:

```sh
make zkbuild-event-semantics-test
make zkbuild-event-semantics-cli-test
```

The remaining end-to-end obligations include dynamic instruction semantic
composition (variables/calls/selects/branches/structured exceptions), complete
runtime-context and parser refinement, witness completeness, cryptographic
implementation refinement and trusted-key certification. Arbitrary native
compilation and the upstream source compiler also remain outside the proved
claim. General kernel admission remains disabled: this pass does not establish
that the kernel may accept arbitrary WASM builds using only a proof.

The variable-stage follow-up adds `VariableRowCheck`, `VariableRowSound` and
`VariableRuleFields`. The first checks the emitted local/global/table gate span
and operation layout. The second derives its counter recurrence and
`VariableEvents.Gates`; that latter theorem explicitly requires a `RuleImage`
premise for the authenticated environment/opcode expressions. The third proves
the signature formulas for every natural opcode and pop index. These are not
yet a complete dynamic-type certificate: deriving `RuleImage` from the environment
lookup and composing the full variable trace remain work to finish.

`check_variable_semantics` requires a dynamic-typing certificate and checks the
variable matrix as well as the combined instruction certificate. Its mutation
suite changes 50 used fields, links or spans per event row. Run it with
`make zkbuild-variable-semantics-test`. A successful run certifies these matrix
checks, not the remaining dynamic semantic refinement.

`VariableSelectorFields` proves the selector sums have the canonical arities;
`VariableRuleImageSound.rule_image` derives the rule expressions from those
selector images, the declared-type image and bounded pop counter. This removes
an algebraic assumption from the variable-row connection. Authenticating the
declared type through the environment and joining the variable rows with the
full trace are still required for the complete certificate.

The combined pass adds 21 default formal libraries and completes 869 Lean build
jobs. All 36 retained module audits pass, totaling 2,384 event rows and 340,912
rejected operand/control/instruction corruptions. The variable-stage suite
passes four complete runtime-context audits with 512 rows and rejects 25,600
additional corruptions. All 36 retained matrix/witness fingerprints still match.
Four fresh 192-byte component proofs pass, including the SIMD composition;
the numeric/static suites cover 280/210 opcode traces. Both CLI profile modes
pass and all five invalid CLI requests are rejected. New semantic theorems use
only `propext`, `Classical.choice` and `Quot.sound`, with no proof placeholders.
No new hardware execution, M0 compilation or kernel latency measurement was
performed in this pass. Exact evidence, source hashes and remaining obligations
are in `build/zkbuild/instruction-semantics-validation.json`.

## Authenticated variable instruction semantics

`VariableSemanticSource.source_bound` now extends the instruction certificate
with the local/global/table environment and variable typing rules. The Nim
prover and verifier keep the same circuit and proof format. The additions are
executable offline certificate checks and Lean proofs about the existing gates;
they add no constraints, witness variables, or proof bytes.

The certificate connects all three dynamic stages to the canonical instruction
rows. `VariableSelectorCheck` derives exact opcode selectors and local/global/
table category sums. `EnvironmentRowCheck` checks the emitted query, address,
range, packed-type, mutability, and state-selection equations, including the
read-only query interfaces. `VariableCertificate` and `VariableCountTrace`
connect variable operand counts to the same instruction trace.

The semantic conclusions establish:

- Each packed environment value has a declared type below seven and one
  mutability bit. Instruction/function starts select that type; other events
  retain the preceding declared type.
- Local queries use the current function namespace and a 32-bit local index.
  Global/table queries use the separate even/odd object namespaces. Active
  queries resolve to the checked local or module-object tables; the inactive
  companion query contributes zero to the packed value.
- Local and table queries carry no mutability bit. Global setters require a
  mutable global. Table instructions require a funcref or externref type.
- Variable rows use the canonical opcode, authenticated declared type, actual
  operand-stack type, and bounded per-instruction pop/push counters. Pops,
  pushes, instruction ends, and prohibited control events satisfy the variable
  event specification.
- Every recognized variable opcode has a signature at every row where it
  occurs. `VariableSignatureTrace` propagates the table reference-type invariant
  through the instruction schedule, so the result is not conditional on an
  unproved signature-existence premise.

The theorem includes the prior source SHA-256, decoder/stream interfaces,
control/operand stacks, fixed-signature typing, and checked dynamic/structured/
runtime records. `EnvironmentOriginSound.row` connects the selected type back
to an active source-table entry at the computed address. The result quantifies
over satisfying assignments; test witnesses are not theorem assumptions.

`check_variable_semantics --mutations` now checks the complete combined
certificate and rejects 106 mutations per row: 50 variable-gate changes,
33 environment-gate/query changes, 15 selector substitutions, and eight cross-
stage link substitutions. The Nim test driver covers nine retained dynamic
modules (including locals, globals, every supported table-variable operation,
and direct/indirect/tail/multi-value call contexts) plus four complete runtime
context modules. The target builds those fixtures through the existing harness:

```sh
make zkbuild-variable-semantics-test
```

This does not establish full WASM validation or compilation correctness.
At that stage, instruction-body grouping, the remaining
call/select/branch/exception semantic composition, full parser/runtime-context
refinement, witness completeness, cryptographic implementation refinement, and
trusted-key certification remain necessary. The native compiler and upstream
source compiler also remain outside this theorem. General kernel proof-only
admission remains disabled; the existing opt-in loader retains validation.

The authenticated-variable pass adds 13 default formal libraries and passes
895 Lean build jobs. All 13 complete module audits pass: 1,104 event rows and
117,024 rejected corruptions. Their retained matrix/witness fingerprints match
the preceding instruction-semantics report. The Nim variable suite passes
45 signatures, 90 concrete/polymorphic transcripts, 90 type substitutions,
10 authenticated compositions, and two fresh 192-byte component proofs.
Both existing checker adapters pass their regression cases. New theorems use
only Lean's `propext`, `Classical.choice`, and `Quot.sound`, with no proof
placeholders. No hardware, new M0 compilation, or kernel latency measurement
was performed. Exact evidence and source/log hashes are recorded in
`build/zkbuild/variable-authenticated-validation.json`.

## Complete fixed and variable instruction bodies

`InstructionBodySource.source_bound` extends the authenticated-variable theorem
with whole instruction bodies. It has the same checked-certificate, satisfying-
assignment, and constant-one hypotheses. It establishes the result for every
satisfying assignment, without assuming a supplied partition or typed body.

`InstructionSpans` and `InstructionPartition` prove that each instruction start
has a unique later end, spans do not overlap, every open event belongs to a span,
and every end has a matching start. Outside instructions, the schedule permits
only boundaries, padding, or the pending function root frame. These grouping
results apply to the complete event trace, including dynamic instructions whose
body semantics still need to be connected.

`InstructionSpanState` proves opcode and declared-type continuity through each
span and the zero initial operand counters. `StaticInstructionBody` and
`VariableInstructionBody` then derive the recursive body relations from the
existing per-event constraints. For all 245 fixed signatures and 45 variable
signatures, the resulting body has the exact required input/output order and
arity, or the required clear. No control or label event can be hidden by the
token projection; the theorem proves that its length equals the interior row
count. Variable signatures use the authenticated environment type and include
the previously proved signature-existence result.

`InstructionBodies.complete` collects those results for every instruction
start. The integrated `check_variable_semantics` executable imports the new
source theorem. Its certificate format and acceptance checks are unchanged;
this pass adds no circuit constraints, witness variables, public inputs, or
proof bytes.

The new `InstructionBodyDecision` Boolean functions are proved equivalent to
the fixed and variable body relations in both directions. The offline
`check_instruction_bodies` test oracle uses them on bodies emitted by the actual
Nim validator. It is a regression oracle, not a ZK verifier. Run its full corpus
with:

```sh
make zkbuild-instruction-bodies-test
```

The corpus covers 580 concrete/polymorphic bodies and rejects 24,624 mutations:
missing or repeated rows, unexpected boundaries/control/labels, wrong opcode
or type, reordered inputs/outputs, and invalid variable declarations. The new
shared variable fixture helper also passes the existing variable proving suite.
Eight new default formal libraries pass the full 911-job Lean build; their
printed theorem dependencies contain only `propext`, `Classical.choice`, and
`Quot.sound`. Fresh Nim regressions verify two 192-byte variable proofs and one
192-byte SIMD proof. The integrated source certificate regression and exact
source/log hashes are recorded in
`build/zkbuild/instruction-body-validation.json`.

This is still a validation/type-trace result. Full call/select/branch/exception
body refinement, complete parser/runtime-context semantics, witness
completeness, cryptographic implementation refinement, and trusted-key
certification remain open. Arbitrary WASM-to-native compilation and upstream
source compilation are also not proved. General kernel proof-only admission
remains disabled, and the opt-in loader retains the ordinary validator. No
hardware execution, new M0 compilation, or kernel timing was performed here.

## Call-state circuit semantics and authenticated node reads

`CallSemanticSource.source_bound` now extends the complete instruction-body
certificate with call-state semantics. The additional checked relation is
`CallCertificate.check`. The theorem also requires
`SignatureMatrix.check`, which the integrated CLI already enforces through its
source-signature prerequisite. These are checked matrix conditions, not
assertions about one test witness.

`CallRowCheck` reconstructs the call stage's 34 primitive operations and two
packed-field helpers per event row. It checks the exact selector, address,
query, state-selection, match, ordering, clear, and closing equations, along
with both 32-bit immediates and the packed signature heads/node payloads.
`CallCertificate` binds those records to the canonical operand rows, opcode,
flags, and source instruction immediates. The existing circuit, witness format,
public inputs, and 192-byte proof format are unchanged.

The formal results establish:

- Exact selectors for direct, indirect, direct-tail, and indirect-tail calls;
  32-bit parameter/result/root cursors, node successors, and immediates.
- All 45 interpreted call-row equations from the actual checked R1CS gates.
- A complete trace induction starting at zero. Signature heads reset the
  cursors; parameter/result reads advance them; pending-index, pushed, and
  cleared state remains Boolean. A clear cannot overflow its Boolean state.
- An indirect index pop accepts i32 or the polymorphic unknown type. Argument
  pops match the selected node type or unknown, and result pushes match their
  node type. Pops cannot follow pushes/clears; pushes require exhausted
  arguments, no pending index, no clear, and an ordinary call.
- Tail clears require exhausted arguments and index and happen once. Ends
  require exhausted arguments/index, the exact tail-clear state, and exhausted
  ordinary result cursors. Calls cannot emit control-frame push/pop events.
- Tail-call starts require the callee result head to equal the current function
  result head. Indirect-call starts require a funcref table; immediates are zero
  outside instruction starts.
- Every active call-list query resolves to a checked signature-node entry.
  Its type is below seven and its successor is strictly smaller than its
  nonzero address. `CallNodeSource.payload` connects these facts to the decoded
  payload fields, ruling out nil reads, unknown node types, and cycles.

The new state induction derives cursor bounds and Boolean state from the
matrix; they are not unproved premises of the top-level source theorem.
At this stage, complete instruction-body refinement to the source function/type
lists was still required. The next section records the subsequent connection
between these per-event guards, authenticated reads, source heads, and complete
call bodies.

Run the integrated certificate and mutation suite with:

```sh
make zkbuild-call-semantics-test
```

`check_call_semantics --mutations` tests 90 corruptions per row: 86 gate,
helper, state, or query-record changes plus four cross-stage substitutions.
The driver uses the same nine dynamic modules and four complete runtime-context
modules as the variable certificate. `RuntimeContextCli.runWithCalls` provides
the checked split and signature records while preserving the existing event,
variable, and runtime checker adapters.

The 12 new default formal libraries pass the 935-job Lean build. All 13 module
certificates pass: 1,104 event rows and 99,360 rejected corruptions. All three
existing checker adapters pass their regression cases. The fresh Nim call suite passes 6,048 signature-oracle cases, 2,801 interned-list cases,
66 normal/tail direct/indirect traces, 26 coherent/environment forgeries, and
two 192-byte proofs. It exercises arities through 17 parameters/five results;
those are test sizes, not restrictions in the call-body definitions. Detailed
certificate results, theorem dependencies, and source/log hashes are recorded
in `build/zkbuild/call-semantic-validation.json`.

Full validator refinement, the remaining dynamic body semantics, complete
parser/runtime-context semantics, witness completeness, cryptographic
implementation refinement, trusted-key certification, arbitrary native
compilation, and upstream source compilation remain open. General proof-only
kernel admission stays disabled. No hardware run, M0 compilation, or kernel
latency measurement was performed in this pass.

## Source-bound call bodies and signature-list consumption

`CallBodySource.source_bound` now derives complete argument/result body
refinement for `call`, `call_indirect`, `return_call`, and
`return_call_indirect`. It starts from the existing source, signature-namespace,
instruction, event, dynamic-typing, structured-control, runtime-context, and
call-row certificate checks, plus satisfaction of the audited matrix. Its
conclusion includes the unique SHA-256-bound source message, decoded instruction
stream, canonical event schedule, operand-stack trace, instruction partition,
and source-matched call bodies. The caller does not supply a semantic call
trace, guessed signature lists, or an arbitrary initial cursor as a premise.

Nine new default Lean libraries provide the connection:

- `SharedNodeRead` proves that queries in independently checked read-only banks
  agree when the banks share initializer entries. It then proves that a call
  read consumes exactly one node of a source signature list.
- `CallReadSound` derives the active query and its parameter/result cursor
  address from the checked call gates. Active node origins exclude reads of
  the nil terminator. `CallReadTrace` applies this to every canonical row.
- `SignatureTypeSource` proves that an odd metadata key selects the actual
  type at that index in the binary. The existing direct-function source theorem
  and source-type list theorem now also expose bounded-head variants, while
  preserving their previous APIs.
- `CallHeadSource` authenticates the initial callee heads for both direct and
  indirect calls. Its list-uniqueness theorem identifies the lists consumed by
  the call body with the lists encoded in the same source message. Parameter
  lists are in pop order; result lists are in declaration order.
- `CallBodyRun` and `CallInstructionBody` compose the per-row equations over
  the entire instruction span. Indirect calls consume exactly one initial
  i32/unknown index. Arguments are consumed in order, ordinary results are
  produced in order, and tail calls contain exactly one clear after their
  arguments. No event within the span is silently discarded.
- `CallBodySource` composes these results with source authentication.
  `CallBodyDecision.correct` proves that the executable body checker decides
  the same inductive relation used by this theorem.

The production prover, constraints, witness layout, public inputs, and kernel
admission policy are unchanged. These proofs establish additional meaning for
the circuit already generated by Nim. The integrated `check_call_semantics`
executable imports the new source theorem and continues checking all of its
certificate prerequisites, including `SignatureSound.check`.

Run the new validator/Lean differential suite with:

```sh
make zkbuild-call-bodies-test
```

The suite extracts 1,960 actual Nim validator call bodies across all four call
opcodes, seven value types, ordinary and polymorphic stacks, zero arities,
and arities through 33 parameters/nine results. The proved Lean decider accepts
them and rejects 93,954 deletions, duplications, type changes, reordered
events, inserted events, and mode changes. These are test sizes; the call-body
theorems quantify over arbitrary finite signature lists and instruction spans.
`zkbuild_call_test_modules.nim` supplies shared fixtures to this suite and the
existing call-circuit/prover suite.

The full default Lean build passes 953 jobs. Printed dependencies for the new
theorems contain only Lean's standard `propext`, `Classical.choice`, and
`Quot.sound`; no new axiom or admitted proof was added. A fresh call-circuit
suite also passes 6,048 signature cases, 2,801 interned-list cases, 66 traces,
26 coherent/environment forgeries, and two 192-byte Groth16 component proofs.
The rebuilt integrated checker passes all 13 retained module audits, covering
1,104 event rows and rejecting 99,360 matrix/cross-stage corruptions. Their
matrix and witness fingerprints match the previous retained fixtures.
Detailed evidence is saved in `build/zkbuild/call-body-validation.json`.

This establishes source-type-list/body composition for the four call opcodes,
not the entire compilation proof. Direct calls select a checked function
metadata row whose heads represent an actual source type; the full connection
of that function metadata to defined/imported function declarations remains a
separate composition obligation. The current-function result-root and indirect
table guards also need their complete semantic connection to the source
runtime context. Other dynamic instruction bodies, full parser/validator
refinement, witness completeness, cryptographic implementation refinement,
trusted-key certification, arbitrary WASM-to-native semantic preservation, and
upstream source compilation remain open. General proof-only kernel admission
remains disabled. No hardware run, M0 compile, or kernel timing measurement was
performed for this change.

### Call declaration origins, caller results, and table reads

`CallRuntimeSource.source_bound` composes call bodies with function declaration
origins and the current function's result signature. Its hypotheses are the
checked source/import/signature, event, typing, structured, and runtime-context
certificates, a satisfied R1CS assignment, and the constant-one wire. It derives
the source message, digest limbs, canonical event trace, instruction partition,
complete call bodies, and their signature/context properties. The theorem does
not assume a semantic call trace supplied by the prover.

Ten additional default Lean libraries implement this composition:

- `FunctionMetadataOrigin` partitions function keys into imported and defined
  functions and identifies the exact checked declaration query for each key.
  `FunctionMetadataBytes` ties its type-index value to a bounded unsigned decode
  in the committed source message. `CallFunctionSource` composes those facts
  with the selected source type and parameter/result lists.
- `CallEntrySource`, `CallRootTrace`, and `CallRootSource` connect each
  instruction to its preceding function-begin event, that event's function
  index, and its source-selected result signature. Tail-call result-head
  equality therefore yields equality of the complete result lists, using
  uniqueness of authenticated list representations.
- `CallTableSource` connects each indirect call's bounded secondary immediate
  to an active object entry at `2 * tableIndex + 1` whose value is `funcref`.
  This is membership in the authenticated context object bank. Refinement of
  that bank to complete source table-declaration semantics is still separate.
- `CallSignatureBody` proves that a complete body realizes `callSignature`,
  including parameter pop order, the leading indirect index, ordinary result
  pushes, and exactly one tail clear. `CallRuntimeSource` combines these facts
  for all four call opcodes. Both primary and secondary immediate values remain
  explicit in the resulting statement.
- `CallRuntimeDecision` proves the executable context/body checker equivalent
  to the inductive run plus active-opcode, table-kind, and caller-result guards;
  acceptance implies the same `callSignature` and complete body shape.

The integrated `check_call_semantics` executable imports this composed theorem.
Its existing import/signature and runtime-context checks discharge the same
certificate checks; no new circuit constraints or witness variables were
needed. All new proofs pass Lean's kernel with only standard `propext`,
`Classical.choice`, and `Quot.sound` dependencies, and the full default build
passes 973 jobs.

`make zkbuild-call-runtime-test` runs the new Nim/Lean differential suite. It
obtains 3,920 complete call bodies from the actual Nim validator, covers direct
calls to imported and defined functions, all four call opcodes, seven value
types, concrete and polymorphic stacks, and arities through 33 parameters and
nine results. Caller-result substitutions, defined/imported `externref` tables,
missing tables, and extra clear events yield 23,520 cases: 11,760 accepted and
11,760 rejected. Context outcomes are compared with Nim's `callRule` resolver.

`make zkbuild-call-mode-proofs-test` generates and verifies four actual Groth16
component proofs, one for each call opcode, using one key and a fixed circuit
of 122,341 constraints over 32 event rows (QAP domain 131,072). Each compressed
proof is 192 bytes. All 12 substitutions between different call-mode statements
and four changed-public-input substitutions are rejected, as are eight
truncated or extended encodings. The four proof blobs are retained under
`build/zkbuild/call-mode-proof-tests`; their test key is ephemeral. These
statements expose the component's trace and environment as public inputs and
are not source-digest module-admission certificates. The existing call-event
suite independently generates and verifies two more 192-byte component proofs.

The rebuilt integrated checker passes all 13 retained module audits, covering
1,104 event rows and rejecting 99,360 matrix/cross-stage mutations. Matrix and
witness fingerprints match the retained baseline. No hardware run, M0 build,
or kernel timing measurement was performed for this change.

The source, executable, proof-blob, fixture, and validation-log fingerprints
for this pass are recorded in `build/zkbuild/call-runtime-validation.json`.

This closes the call-specific declaration-origin and caller-result composition
obligations described above. It does not establish arbitrary WASM compilation
correctness. Remaining work includes complete context-bank/source semantics,
other dynamic instruction bodies, full parser/validator refinement, witness
completeness, production cryptographic implementation refinement and trusted-key
certification, and arbitrary WASM-to-native semantic preservation. General
proof-only kernel admission remains disabled.

## Parametric instruction-body soundness (2026-11-14)

The actual `constrainParametricEvents` stage now has semantic proofs for untyped
`select` (27), typed `select` (28), and `ref.null` (208). The implementation and
proof generation remain Nim; Lean checks the formal statements. This change
adds no circuit constraints or witness variables.

`ParametricRowCheck` and `ParametricRowSound` connect the 46 primitive operations
per event row, including the final raw guards, to their field equations. The
checked certificate includes each used reciprocal, all five carried registers,
primary-immediate range evidence, row boundaries, and canonical cross-stage
links. `ParametricMode` and `ParametricBegin` derive the opcode selectors and
valid immediates. `ParametricState`, `ParametricTransition`, and
`ParametricTraceSound` establish the register invariant over the entire trace;
row-count bounds exclude wraparound in natural-number pop and push counts.

`ParametricGuardCounts` and `ParametricGuardTypes` prove ordered operand counts,
condition typing, declared-type matching, reference exclusion, and unknown-type
inference. `ParametricBodyRun` and `ParametricInstructionBody` compose these row
facts into whole instruction bodies and prove that every interior event is
accounted for. Each select consumes its condition and two values before exactly
one result push; `ref.null` has exactly one reference result push. Active bodies
cannot hide control, label, or clear actions.

`ParametricBodySpec.correct` proves the executable body checker equivalent to
an inductive stack-effect specification. `ParametricSourceSound.source_bound`
derives these properties on the same canonical trace as the existing source,
operand-stack, instruction-partition, and call proofs. It preserves the
committed source/digest facts, opcode and primary-immediate wire images, and
complete call-body conclusions. It does not assume a semantic parametric trace
as an input. The integrated `check_parametric_semantics` executable checks both
`CallCertificate` and `ParametricCertificate`, alongside the existing complete
source/runtime prerequisites.

All 15 new libraries are default formal targets. The full default Lean build
passes 1,003 jobs. The 28 printed theorem dependency checks contain only
`propext`, `Classical.choice`, and `Quot.sound`; there are no admitted proofs or
new axioms.

`make zkbuild-parametric-test` passes 28 actual validator traces, rejects 18
coherent forgeries, and checks 35 trace plans plus 38,912 finite semantic cases
against the Lean checker. It generates and verifies two fresh 192-byte Groth16
component proofs. `make zkbuild-parametric-mode-proofs-test` generates 15 more
proofs using one fixed component key: five concrete untyped select types,
unknown-type inference, all seven typed select types, and both reference kinds.
The 32-row component has 47,857 constraints and a 65,536-point QAP domain.
All 225 statement substitutions and 30 truncated/extended encodings are rejected.
The fifteen 192-byte proof blobs are retained in
`build/zkbuild/parametric-mode-proof-tests`; their test key is ephemeral.

These proof statements expose component trace inputs and are not full module
compilation certificates. The broader goal remains incomplete: other dynamic
and control instruction bodies, complete context-bank/source semantics, parser
and Nim validator refinement, witness completeness, production cryptographic
refinement and trusted-key certification, and arbitrary WASM-to-native semantic
preservation still require proofs. The proof-gated loaders retain validation
backstops; general proof-only kernel admission is not enabled. No new M0 build,
hardware validation, or kernel verification timing measurement was performed.

`make zkbuild-parametric-semantics-test` checks the new certificate against
complete module audits and rejects 91 matrix/cross-stage mutations per row.
The rebuilt integrated checker passes all 13 retained audits (1,104 rows) and
rejects all 100,464 mutations. Retained matrix/witness metadata fingerprints
match `call-runtime-validation.json`; the large witnesses were not regenerated.
To rerun only these retained audits without rebuilding the fixtures:

```sh
lake -d formal/zkbuild build check_parametric_semantics
build/zkbuild/test_parametric_semantics \
  formal/zkbuild/.lake/build/bin/check_parametric_semantics \
  build/zkbuild/runtime-context-tests \
  build/zkbuild/runtime-context-binding-tests
```

Source, executable, proof-blob, log, and baseline fingerprints and the exact
remaining obligations are recorded in `build/zkbuild/parametric-validation.json`.

## Authenticated br_table target-list completeness (2026-11-14)

The branch environment now has semantic proofs connected to the actual Nim
R1CS emitter. This covers the complete target-list traversal for `br_table`,
including zero-arity targets and the final default target. It adds no circuit
constraints or witness variables. Proving and verification remain Nim; Lean
checks the formal statements about the emitted constraint matrix.

`BranchRowCheck`, `BranchRowSound`, and `BranchRowImages` certify the eleven
primitive operations per event row, their raw guards, both authenticated table
queries, the primary-immediate range, and the packed depth/next-node payload.
`BranchCertificate` links those rows to the canonical operand/instruction trace
and proves the filtered label selector used by the branch stage.

`BranchListCheck` and `BranchListSound` certify the variable initializer prefix:
three primitive operations per bank entry and five per list node, plus the
packed-field gadgets. Active bank heads are nonzero. Every active node's next
pointer is strictly smaller than its address, and every nonzero next pointer
has an authenticated node. `BranchStore` constructs the represented store,
proves cell uniqueness, and derives closure and acyclicity from these checks.

`BranchStep` and `BranchTraceSound` derive the bounded cursor invariant over
the whole canonical trace. `BranchInstructionBody` proves that an instruction
consumes exactly its authenticated target list, with no omitted or extra label
markers. `BranchHeadSound` excludes empty selected lists. `BranchLastMarker`
proves that the terminal output is true exactly when no later label remains in
the instruction body; an earlier zero-arity target cannot act as the default.
`BranchComplete` combines these facts, including the selected bank address and
primary-immediate image, without assuming a semantic branch trace as input.

`BranchOrigins` connects represented nodes and active bank queries to the
checked instruction-stream initializer entries. `BranchSourceSound.source_bound`
composes the result with the existing source/digest, operand-stack, instruction
partition, call, and parametric proofs on the same canonical trace. This is
instruction-stream provenance; the full raw byte-vector semantics of branch
tables remain a separate refinement obligation.

All fifteen new libraries are default formal targets. The full default Lean
build passes 1,033 jobs. The 26 printed theorem dependency checks use only
`propext`, `Classical.choice`, and `Quot.sound`, with no admitted proofs or new
axioms.

`make zkbuild-branch-typing-test` passes 29 actual validator traces, rejects 15
coherent/environment forgeries, and checks 33 independent Lean action plans and
four plan mutations. It generates and verifies two fresh 192-byte Groth16
component proofs. The 16-row component has 142,057 constraints and a 262,144-point
QAP domain.

`make zkbuild-branch-mode-proofs-test` generates six more proofs using one fixed
component key: default-only, repeated targets, five targets, distinct block
depths, distinct loop depths, and unreachable code. The 32-row component has
267,478 constraints and a 524,288-point QAP domain. All 36 statement substitutions
and twelve truncated/extended encodings are rejected. The six 192-byte blobs
are retained in `build/zkbuild/branch-mode-proof-tests`; their test key is
ephemeral. These statements expose trace/environment inputs and are component
tests, not full module-digest compilation certificates.

`check_branch_semantics` checks the branch certificate and list initializers
alongside the full source/structured/runtime matrix audit. When the fixture
also contains dynamic typing, it checks the combined call certificate.
Legacy validation-event fixtures explicitly report `calls=false`; they still
exercise the branch theorem but do not establish the combined call theorem.
The mutation suite rejects 47 changes per event row, nine per bank initializer,
and nineteen per node initializer. `RuntimeContextCli` exposes the structured
record to this checker while preserving its existing callback APIs.

The retained-audit driver covers thirteen prior fixtures plus four
branch/control fixtures in both flat and legacy source formats. To run those
audits without regenerating the large witness files:

```sh
lake -d formal/zkbuild build check_branch_semantics
build/zkbuild/test_branch_semantics \
  formal/zkbuild/.lake/build/bin/check_branch_semantics \
  build/zkbuild/runtime-context-tests \
  build/zkbuild/runtime-context-binding-tests
```

All seventeen audits pass: 1,360 event rows, 340 bank entries, ten list nodes,
and 67,170 rejected mutations. Three fixtures have nonempty branch lists;
fourteen exercise the empty-list case. The driver requires both cases, and
checks thirteen combined call certificates. The final rebuilt checker also
passes a fresh active-branch audit with all 3,228 mutations rejected. Matrix
and witness metadata fingerprints match the retained baseline reports.

The full regeneration target is `make zkbuild-branch-semantics-test`. Validation
counts, source and artifact fingerprints, baseline matrix/witness metadata,
and remaining obligations are recorded in `build/zkbuild/branch-validation.json`.

This result does not yet prove the complete branch operand-type relation,
frame authentication, or scratch-stack restoration semantics. Other control
and exception bodies, complete context-bank/source semantics, parser and Nim
validator refinement, witness completeness, production cryptographic refinement
and key certification, and arbitrary WASM-to-native semantic preservation also
remain. General proof-only kernel admission stays disabled, with the existing
validation backstops retained. No hardware run, new M0 compile, or kernel timing
measurement was performed for this change.

## Branch operand guards and scratch authentication (2026-11-14)

The branch-typing certificate now checks the actual stage-five circuit: 53
primitive operations and two packed splits per event row, its raw guards,
query interfaces, and scratch-memory accesses. `BranchTypeRowCheck`,
`BranchTypeRowSound`, and `BranchTypeRowImages` prove the equations and bounded
packed images. `BranchTypeCertificate` ties the fields, selectors, frame
inputs, and terminal marker to the canonical event and structured traces.

The shared control/branch lookup now has an explicit semantic certificate.
`InactiveAddress` proves inactive query addresses are zero;
`BranchMergeCheck` and `BranchMergeSound` check disjoint activation and zero
inactive values. Thus an inactive control query cannot shift the selected
branch address or value. `BranchLookupCheck` checks all four routes into the
actual authenticated metadata, length, member, and singleton banks.
`BranchLookupSound` proves origin and bounds for every active branch query.

`BranchTypeScalar` derives the condition's i32-or-unknown requirement, the
argument's matching-type-or-unknown requirement, and the reverse restoration
ordinal. `BranchMemberTag` connects active member queries to checked indexed
signature initializers: the declared expected tag is in 0..6, while unknown
(tag 7) is permitted only on the operand side. This excludes accepting unknown
as a declared signature type.

`BranchTypePending` derives the boolean pending-condition state by induction
over the entire canonical trace. The first branch pop while that state is set
is a condition; subsequent pops are arguments. Its theorem also identifies the
begin, pop, push, clear, and finish masks from canonical event kinds and
opcodes. These selector facts are derived from the circuit, not supplied as
semantic witness assumptions.

`BranchTypeScratch` proves the emitted write/read addresses, values, clocks,
and consecutive write positions. `MemoryPriorWrite` proves that every valid
read from initially empty chronological memory has an earlier matching write.
`BranchScratchTrace` connects that result to the checked RAM argument:
active writes use their row index as address, every active access carries the
canonical operand tag, and a read identifies an earlier active write with the
same tag. Unknown tags are preserved as well. This proves authentication of
individual restorations; the complete sequence of restorations still needs
the whole-body count and arity invariant.

`BranchTypeSound` combines the row, lookup, and scratch facts.
`BranchTypeSource.source_bound` composes them with the existing digest/source,
stack, instruction partition, call, parametric, and complete target-list
results, plus the declared-type and pending-condition theorems. It uses the
same canonical trace throughout. The conclusions do not yet assert that an
entire branch body satisfies the WASM operand-type rule.

All eighteen added libraries are default formal targets. The complete Lean
build passes 1,069 jobs. The 37 printed dependency checks for these libraries
use only `propext`, `Classical.choice`, and `Quot.sound`. No admitted proof or
new axiom is used by these theorems. No circuit constraints or witness variables
were added; this change certifies the existing Nim emitter.

The retained-audit command from the preceding section now also requires the
branch-typing, merge, and lookup certificates. `BranchTypeMutations` rejects
251 additional changes per event row: 120 row/interface changes, eleven
canonical-event link changes, 27 changes for each of four merged queries,
and three authenticated-route changes for each query. The seventeen retained
modules cover 1,360 event rows and reject 341,360 new mutations, in addition
to the 67,170 existing branch-list mutations. Thirteen fixtures also carry the
combined call certificate; four legacy fixtures do not.

Fresh `zkbuild-branch-typing-test` and `zkbuild-branch-mode-proofs-test` runs
retain the preceding section's counts: 29 validator traces, fifteen coherent
forgeries rejected, 33 Lean plans, four plan mutations, and eight 192-byte
Groth16 component proofs. The six-mode suite rejects 36 statement substitutions
and twelve malformed proof encodings. These are trace/environment component
proofs; they are not arbitrary-module compilation or kernel-admission proofs.
The exact validation logs, baseline metadata, source/artifact hashes, theorem
dependencies, and remaining obligations are recorded in
`build/zkbuild/branch-type-validation.json`.

Remaining branch obligations include the complete count/arity state invariant,
source interpretation of selected frame signatures, exact ordered restoration
for every target, and whole-body typing. Other control and exception bodies,
full raw-byte/parser and Nim validator refinement, complete context-bank
semantics, witness completeness, production cryptographic refinement and
setup/key certification, and arbitrary WASM-to-native preservation remain
open. General proof-only kernel admission remains disabled and validation
backstops remain active. This change includes no hardware run or kernel
verification-time measurement.

## Branch counters, arity, and restoration positions (2026-11-14)

The branch-typing proof now derives the natural-number state behind the field
variables. `BranchTypeData` extracts a bounded authenticated length and a
boolean terminal marker for every event row, including inactive rows.
`BranchTypeState` proves the reset, target selection, and increment equations
for length, arity, pop/push counts, seen/last flags, clear count, and scratch
start position. `BranchTypeTrace` lifts those equations to the entire canonical
trace. Length and arity stay below 2^32; the counters and scratch start are
bounded by the processed event prefix. No semantic counter history is assumed
as an input to the theorem.

`BranchTypeGuards` uses these bounds to interpret the raw field equations as
natural-number requirements, excluding modular cancellation. A new label
requires the condition to have been consumed and forbids following a terminal
target or a clear. A repeated target requires exactly the preceding target's
number of pops and restores, and the same arity. Argument pops require
consecutive scratch write positions and precede restoration or clearing.
Restore pushes require all arguments to have been popped, a nonterminal
target, and an in-range reverse ordinal. Clearing requires a terminal target,
completed pops, no restores, and no previous clear. Instruction completion
requires a seen terminal target, no pending condition or restores, completed
pops, and exactly one clear.

`BranchTypeRestoration` connects the derived counter state to the authenticated
scratch trace. Every restore push at event `i` has an earlier argument-pop
event at exactly `start + length - 1 - pushed`; the two events carry identical
type tags, including unknown. This proves the reverse index and type of each
restore. It does not yet identify a complete target vector with the formal
`BranchPlans.plan` list.

`BranchTypeArity` proves that selected length and arity agree throughout the
trace. After the first target, arity persists until the next instruction reset.
Consequently, any two target markers in the same instruction have identical
authenticated arity, including zero-arity targets. `BranchTypeBehavior` combines
these conclusions, and `BranchTypeSource.source_bound` now includes them on
the existing source-bound trace.

Eight additional formal libraries are default targets. The complete Lean build
passes 1,085 jobs; 22 printed dependency checks covering these libraries and
the updated source theorem use only `propext`, `Classical.choice`, and
`Quot.sound`. No admitted proofs or new axioms are used. Prover, verifier,
circuit emitter, and executable certificate checks are unchanged, so this adds
no proving constraints or witness variables.

The rebuilt checker is exercised on three complete retained audits: active
branch tables in flat and legacy source formats, and the full memory/runtime
fixture with the combined call certificate. The earlier seventeen-module
matrix audit and eight generated component proofs are retained evidence;
this step does not regenerate those proofs. Runtime source and acceptance-check
fingerprints are compared with `branch-type-validation.json`. Fresh audit logs,
formal dependencies, source/artifact fingerprints, and precise remaining
obligations are recorded in `build/zkbuild/branch-behavior-validation.json`.

The count/arity invariant and per-push restoration positions are now proved.
Remaining branch work includes authenticating the selected control-frame
semantics and its source signature, deriving the complete ordered target-vector
plan, and composing operand-stack behavior across all targets. Raw-byte branch
vector refinement, remaining control/exception and context semantics, complete
parser/validator and witness refinement, production cryptographic/key
certification, and arbitrary native-code preservation also remain open.
General proof-only kernel admission remains disabled, and validation backstops
remain active. No hardware or kernel-timing run was performed.

## Signature-frame circuit semantics (2026-11-14)

The signature-frame circuit now has a row certificate tied to its emitted
matrix. `FrameRowCheck` accounts for all 46 primitive operations per event,
five range certificates, the 22 output fields, two chronological RAM accesses,
carried state, and the final root-pending guard. The raw guard expressions retain
the emitter's form, including zero coefficients required by the current matrix
normalizer. `FrameRowSound` derives the zero tests, multiplication, selection,
materialization, and guard equations from matrix satisfaction.

`FrameDescriptor` proves exact decoding of the bounded 36-bit token: kind is
`token % 4`, descriptor is `token / 4`, and index is `token / 16`. The four
signature-category flags are precisely the four possible values of
`descriptor % 4`. `FrameOpcodes` proves the nine opcode selectors and their
opening, branching, closing, and combined categories. These conclusions cover
all bounded opcode values; they do not assume the flags supplied by a witness.

`FrameAccessSound` proves that an active read has a nonempty frame stack. Given
bounded count and selected depth images, a non-return read has `depth < count`
and slot `count - 1 - depth`; a return reads slot zero. Reads and writes use the
function namespace `functionIndex * 2^32`, with writes at the previous depth.
An `else` begin requires kind 2 and constructs kind 3 with the same descriptor.
These are row theorems: deriving every selected depth and maintaining the live
signature stack across the complete trace remain separate obligations.

`FrameCertificate` binds the frame rows to the canonical operand kinds,
function indices, instruction opcodes, and bounded control depths.
`FrameMemorySound` connects active reads to an earlier frame write at the same
address and with the same token, using the checked chronological RAM relation.
`FrameSound` identifies that writer as a canonical control-push event.
`BranchTypeSource.source_bound` now includes these facts on the same source-bound
trace as the existing branch typing results. Its additional frame-certificate
premise is checked by `check_branch_semantics`.

Ten new formal libraries are default targets. The full build passes 1,105 jobs.
The 21 dependency checks for the new theorems and the updated source theorem
use only `propext`, `Classical.choice`, and `Quot.sound`; these proofs introduce
no admitted terms or new axioms. Nim prover, verifier, witness builder, and
circuit emitter are unchanged. The additional formal evidence adds no proving
constraints or witness variables.

`check_signature_frames --mutations` checks 130 row-certificate substitutions
and eight canonical-link substitutions per event. Fresh validation covers flat
and legacy branch/control fixtures plus the complete memory/runtime fixture.
The combined branch checker is also rerun with its new frame prerequisite.
Logs, matrix metadata, theorem dependencies, and source/artifact fingerprints
are recorded in `build/zkbuild/frame-validation.json`. The earlier component
Groth16 proofs remain retained evidence, not freshly generated proofs of the
expanded theorem. No hardware or kernel verification-time measurement is made.

This establishes descriptor decoding and earlier-write provenance, not yet the
complete semantic identity of the live target frame. Remaining work includes
block-type/source-signature interpretation, signature-stack LIFO preservation,
selection of the correct live frame, the full ordered branch action plan, and
whole-body operand typing. The broader parser, validator, exception/context,
cryptographic implementation/setup, and arbitrary native-code preservation
obligations remain open. General proof-only kernel admission remains disabled;
validation backstops remain active.

## Live signature-frame stack and encoded writes (2026-11-14)

The frame semantics now derive the live token stack from the checked
chronological RAM accesses and canonical event schedule. `ControlDepthTrace`
reconstructs the natural depth at every prefix from push and pop events and
binds it to the frame circuit. `FrameDepthCheck` binds each label-depth input to
the branch and handler packed-field certificates. Their two 32-bit components
provide a 33-bit bound on the sum; the proof does not assume that the combined
label depth fits in 32 bits. `FrameTargetSound` uses the checked slot range to
prove that every active read addresses a live slot without field wraparound.

`FrameTokenStack` proves push, pop, and function-namespace invariants for the
entire trace. `FrameTraceMemory` connects those invariants to the checked RAM
certificate. `FrameLifoSound` proves that the stack closes empty and that an
active read returns the token currently at the selected live position. The
source-descriptor wire contains that same token, as shown by `FrameReadSource`.
This closes live-stack preservation and current-target selection for numeric
frame tokens, including the bounded selection needed by label checks.

`FrameBlockEncoding` derives the proposed token directly from the row gates.
With kind 1 for `loop`, kind 2 for `if`, and kind 0 otherwise, its encoding is:

| Normalized block pad | Descriptor | Token |
| --- | --- | --- |
| 0 (empty) | 2 | `4 * descriptor + kind` |
| 1 through 7 (value type) | `4 * (pad - 1) + 3` | `4 * descriptor + kind` |
| 256 through `2^32 + 255` (type index) | `4 * (pad - 256)` | `4 * descriptor + kind` |

Satisfaction excludes pads 8 through 255 and type indices outside 32 bits.
`FramePadTrace` derives the held pad's 33-bit bound from its checked input,
reset selection, and carry between rows. `FrameWriteValue` proves that an
active write encodes either the function root (`16 * functionIndex + 4`), an
`else` frame (`4 * (sourceToken / 4) + 3`), or the proposed block token. Each
written token fits in 36 bits. The natural-valued write theorem uses the same
RAM witness as the live-stack theorem, so these results describe one stack.
Root selection is tied to the preceding
canonical function-begin event, and `else` preserves the source descriptor.

These results are composed in `BranchTypeSource.source_bound` with the existing
source, instruction, call, branch, and operand facts. The theorem additionally
requires `FrameDepthCheck.checkStage`; both semantic audit executables check
this premise. There are twelve new default formal libraries. The full Lean
build passes 1,129 jobs. All 31 selected dependency checks are free of admitted
proofs or additional axioms: one is axiom-free and the others use only the
standard `propext`, `Classical.choice`, and `Quot.sound` axioms. The Nim circuit
emitter, prover, and verifier are unchanged, so these proofs add no constraints
or witness variables.

`tools/test_zkbuild_frame_semantics.nim` and `make zkbuild-frame-semantics-test`
run the frame checker over seventeen retained complete module matrices,
including flat and legacy branch/control streams, calls, memory, bulk,
references, and SIMD lanes. Every event receives 138 frame/link mutations and
15 depth-certificate mutations. The completed run covers 1,360 event rows and
rejects all 208,080 mutations. The depth cases also substitute a split field
and its linked input together, checking that a coherent substitution still
fails against the actual matrix. Run results, fresh component Groth16 evidence,
source/artifact hashes, and remaining obligations are recorded in
`build/zkbuild/frame-lifo-validation.json`. Six fresh Groth16 component proofs
pass with one reused test key, each encoded in 192 bytes; verification rejects
36 statement substitutions and 12 malformed proof encodings.

The precise guarantee remains conditional on the named certificate checks and
matrix satisfaction. Numeric frame identity and encoding do not by themselves
establish the complete source-signature interpretation or the ordered branch
operand plan. Full raw-byte/parser/validator and witness refinement, remaining
control/exception/context semantics, production cryptographic implementation
and setup certification, and arbitrary WASM-to-native preservation remain
open. The component proof statements expose their trace/environment inputs;
they are not general module-admission keys. General proof-only kernel admission
remains disabled and runtime validation backstops remain active. This work does
not include a hardware run or a kernel verification-time measurement.

### Source instruction events and frame signatures

`InstructionEventCheck` and `InstructionInfoCheck` now check the matrix rows
that bind validation events to the instruction stream. They reuse the emitted
constraints and add no prover constraints or witness variables. The event
checker identifies the final eleven-operation block for every event, checks
all six field ranges and both event-kind indicators, and locates the final
queries in the instruction-info, immediate, and function-end tables. Locating
queries from the tail is necessary because those tables can also contain
queries from earlier frame or function processing. Both flat and legacy
instruction streams are supported.

`InstructionEventSound` reconstructs bounded function indices, PCs, opcodes,
immediates, and block pads. Instruction-begin rows activate the two instruction
lookups at the same packed function/PC address. Function-end rows activate a
lookup for their own function index and match its recorded endpoint.
`InstructionInfoSound.selected` then identifies one active source instruction
row matching the event's opcode, primary immediate, secondary immediate, and
block pad individually. The source field ranges prevent cancellation within
the packed values: all encodings are below the scalar modulus. Both lookups
are tied to the same source row, including when the tables use distinct wire
representations. The source-row function/PC correspondence is currently a
packed-key equality; this theorem does not independently decode both source
key components.

`FrameInstructionSource` connects the instruction certificate to the canonical
validation events and frame inputs. At every instruction-begin event, the held
pad and proposed token use the authenticated source instruction's pad and
opcode. `FramePadOrigin` proves the reset/carry invariant across the whole
trace: function entry clears the pad, and a later nonzero held pad originates
at an earlier instruction-begin row with no intervening reset. This composes
with the existing natural block encoding and live frame-stack proofs.

`FrameSignatureSource` connects a checked signature-metadata initializer and
a checked pair of 32-bit list heads to the authenticated source type lists.
`BranchFrameMetadata` binds branch selectors to the descriptor emitted by the
same checked frame row. `BranchFrameSource` follows the actual merged branch
metadata query back through its immutable table to that source signature.
For typed-block and function-root descriptor modes, the theorem identifies
the source parameter and result lists and proves that the label head selects
parameters for typed loops and results for other labels. An inactive singleton
query is proved to have zero value; it cannot alter the selected result head.
The empty and singleton descriptor modes are not included in this new
source-list selection theorem.

All of these results are composed in `BranchTypeSource.source_bound` on its
existing canonical trace. The combined branch checker now enforces both new
instruction certificates. `RuntimeContextCli.runWithInstructionSource` passes
the already parsed instruction stream, decoder catalog, and decoders to
semantic checkers; the older callback interfaces remain available. These are
offline formal-certificate checks. The production prover, verifier, circuit
emitter, and witness generator remain Nim and are unchanged by this extension.

Validation passes the full 1,149-job Lean build and 25 selected theorem
dependency checks, using only the standard `propext`, `Classical.choice`, and
`Quot.sound` axioms. No admitted proofs or additional axioms are used. The new
`tools/test_zkbuild_instruction_source.nim` driver and
`make zkbuild-instruction-source-semantics-test` audit seventeen retained
complete module matrices: 1,360 event rows and 352 source instruction rows.
All 65,920 substitutions are rejected: 42 per event and 25 per source
instruction, including coherent field/range-input changes and modified
initializer keys or values. The fixtures include flat and legacy streams,
branch/control events, calls, memory, bulk, references, and SIMD lanes.
Three combined branch audits also pass, including a call-bearing module.
Six fresh Groth16 component proofs pass, each encoded in 192 bytes; verification
rejects 36 statement substitutions and 12 malformed proof encodings.
Detailed source/artifact hashes and results are recorded in
`build/zkbuild/instruction-source-validation.json`.

This extension does not finish arbitrary-WASM compilation correctness.
Remaining work includes the complete interpretation of raw instruction bytes,
source-key component decoding, empty/singleton source-label lists, ordered
whole-body branch operand plans, remaining control/exception/context semantics,
parser/validator and witness refinement, production cryptographic and setup
certification, and arbitrary WASM-to-native preservation. The Groth16 component
proofs remain distinct from a complete module-admission proof: their statements
expose trace/environment inputs and their setup is for testing. General
proof-only kernel admission remains disabled, with runtime validation
backstops active. No hardware or kernel timing measurement is claimed.


### Complete branch label lists and operand reads

`BranchLabelLists` now covers all four frame descriptor modes: typed blocks,
function roots, empty blocks, and singleton blocks. It binds each canonical
`br_table` label to a complete authenticated type list and its exact length.
`IndexedSingletonList` derives a singleton's one-element representation from
its checked length and node lookups. `BranchSimpleHeads` and
`BranchSimpleLists` prove that empty and singleton loop labels select the empty
list, while singleton non-loop labels select exactly the encoded value type.
The singleton tag is proved to be below seven; all inactive metadata and
singleton values used in selection are proved zero. Typed loops retain their
parameter lists, while other typed/function labels use result lists.

`IndexedMemberRead` derives the member ordinal's bounds from the authenticated
member suffix and closing row. The caller does not supply an assumption that
the ordinal is valid. `BranchListRead` then connects each active argument pop
through the actual merged member query to the element at that ordinal in a
complete list. Its operand check includes the existing polymorphic-unknown
rule.

`BranchHeadOrigin` proves that a nonzero held label head originates at the most
recent `br_table` label, with no intervening instruction/function reset or
branch-label update. `BranchOperandSource` composes this with the complete
source-list proof: every active argument pop checks an in-range element of
that earlier label's authenticated source type list. A zero head cannot service
an active argument, because its list is empty. The label is strictly earlier
than the pop. `BranchOperandOrder` separately proves that the member ordinal
is the running pop count for loop descriptors and the reverse ordinal for
other descriptors. Bounded natural sums exclude modular wraparound and
subtraction underflow.

`BranchLabelCarry` proves that both the frame token and the running state's
length/start offset remain attached to that earlier label. It uses the opcode
schedule to exclude an intervening label belonging to another instruction.
`BranchTypedOperands` combines these facts: an active argument at row `i`,
following label row `j`, checks the exact source type at offset `i-j-1` for a
loop or `length-1-(i-j-1)` for another frame. The offset is strictly below the
source list length. Its theorem derives the correspondence between the label,
frame, count, and authenticated list rather than assuming that correspondence.
These facts are composed on the canonical trace in
`BranchTypeSource.source_bound`.

The production prover, verifier, circuit emitter, and witness generator remain
Nim. This extension adds no circuit constraints or witness variables. The eleven
new Lean libraries check properties of the existing emitted relation. The
full 1,171-job Lean build passes, including twenty-three selected theorem dependency
checks with only the standard `propext`, `Classical.choice`, and `Quot.sound`
axioms. No admitted proofs or additional axioms are used.

`tools/test_zkbuild_branch_label_proofs.nim` generates and verifies sixteen fresh
Groth16 component proofs using one reused test key: empty blocks and loops, and
blocks and loops for each of i32, i64, f32, f64, v128, funcref, and externref.
Each fixture has three repeated branch targets. The test independently checks
the expected arity, singleton query, selected head, and argument tag before
proving. All proofs encode to 192 bytes. Verification rejects all 256 statement
substitutions and 32 malformed encodings. The fixed circuit has 545,369
constraints for 64 event rows and a QAP domain of 1,048,576. Reproduce this with
`make zkbuild-branch-label-proofs-test`, which is included in `zkbuild-check`.
The complete-module branch audit passes all seventeen retained fixtures,
including thirteen combined call certificates. Across 1,360 event rows it
rejects all 408,530 mutations: 341,360 branch-typing substitutions and 67,170
branch row, initializer, and list-node substitutions. Reproducibility hashes
for 857 sources, 44 artifacts, and nine logs are recorded in
`build/zkbuild/branch-label-validation.json`.

This closes empty/singleton source-list interpretation and exact ordered
source typing for active branch arguments. It does not yet establish the
complete whole-body branch action plan: coverage of every required argument,
restoration/clear sequence, and instruction-boundary composition still need to
be connected to the source-level branch specification. Remaining obligations
also include complete
raw instruction decoding and source-key interpretation, the remaining
control/exception/context semantics, parser/validator and witness refinement,
production cryptographic implementation and trusted setup/key certification,
and arbitrary WASM-to-native preservation. These component proofs expose their
trace/environment inputs and use an ephemeral test setup; they are not general
module-admission proofs. General proof-only kernel admission remains disabled,
and runtime validation backstops remain active. No hardware run or kernel
verification-time measurement is claimed.


### Complete branch action plans and source compatibility

`BranchActionLanguage` derives the complete finite action language from the
branch counters and guards. `BranchActionAlphabet` excludes extra control
pushes/pops inside the instruction using the actual frame certificate.
`BranchActionSequence` composes the language with instruction spans: the body
contains exactly one condition pop, a label and full operand group for every
target, reversed restorations for all nondefault targets, and one final clear.
This closes the action-coverage obligation described in the preceding section.

`BranchConditionTrace` proves the first pop has i32 or unknown type and that
every subsequent argument pop activates its type check. `BranchActionLayout`
derives exact row positions for all labels, pops, restorations, and the clear.
`BranchActionCounters` connects each restoration to the mirrored pop in its
own target group using the actual scratch-memory restoration theorem.
`BranchActionSource` then proves each complete group checks the authenticated
source signature, with the descriptor-dependent list orientation and common
arity. The updated `BranchTypedOperands` theorem retains the no-reset and
no-label-update interval needed to identify that exact group.

`BranchFloorInvariant` derives a fixed floor from the authenticated control
stack. The final clear truncates the operand stack to that floor and leaves
the frame unreachable. `BranchOperandRuns` and `BranchCommonOperands` prove
that restoring one group's actual operands makes the next group read the same
vector. This includes unknown values produced in unreachable code: once
restored above the floor, they are concrete stack entries and the next group
must read them exactly.

`BranchValuePlan` reconstructs the full value-carrying action list from these
rows. `BranchPlanSource` proves that it equals the existing `BranchPlans.plan`,
that every target is compatible with the common actual vector, and that
`BranchPlans.check` accepts. Target signatures retain their authenticated frame
token, head, and source-list origin. These conclusions compose with the source
hash, instruction stream, operand stack, control stack, and branch-target
provenance in `BranchTypeSource.source_bound`.

The production circuit, witness generator, prover, and verifier remain Nim and
are unchanged by this extension. No constraints or witness variables were
added. Twelve new Lean libraries are part of the default formal build. The
full 1,195-job build passes, including thirty-two selected theorem dependency
checks with only the standard `propext`, `Classical.choice`, and `Quot.sound`
axioms; there are no admitted proofs or new axioms.

`tools/test_zkbuild_branch_action_proofs.nim` independently checks full emitted
action kinds and operand/restoration tags, then generates sixteen fresh
192-byte Groth16 component proofs with one reused test key. Cases cover arities
zero through two, blocks and loops, known and unknown operands, and nested
mixed block/loop targets at different depths. Verification rejects all 256
statement substitutions and 32 malformed encodings. The fixed circuit uses
533,283 constraints for 64 event rows and a QAP domain of 1,048,576. Run
`make zkbuild-branch-action-proofs-test`, included in `zkbuild-check`. The test
also accepts `WORK_DIR --check` for circuit satisfaction and shape preflight.

A fresh audit of seventeen retained complete-module matrices checks 1,360 event
rows and rejects 408,530 mutations, including 341,360 branch-typing substitutions
and 67,170 branch row/list substitutions. Thirteen fixtures include combined
call certificates. Reproducibility hashes for 871 sources, 61 artifacts, and
ten logs are recorded in `build/zkbuild/branch-action-validation.json`.

This is a source-bound branch-table validation result, not a complete
arbitrary-WASM compilation theorem. Remaining work includes full raw decoder
and source-key interpretation, the remaining control/exception/context
semantics, parser/validator and witness refinement, production cryptographic
implementation and trusted setup/key certification, and arbitrary
WASM-to-native preservation. The fresh proofs expose their trace/environment
inputs and use an ephemeral component setup. General proof-only kernel
admission remains disabled, and runtime validation backstops remain active.
No hardware validation or kernel verification-time measurement is claimed.

### Ordinary control-typing gates and state

`ControlTypeRowCheck` checks all 63 operations in each ordinary control-typing
row, including its three packed fields, four range checks, and six lookup
interfaces. `ControlTypeRowSound` and `ControlTypeRowImages` derive their
meaning from the actual emitted matrix. `ControlTypeCertificate` binds those
rows to the canonical operand-event selectors and the authenticated frame
stage. `ControlTypeModes` derives the opcode flags for block, loop, if, else,
end, br, br_if, return, and try_table from that frame stage.

`ControlTypeMasks` proves the exact activation conditions for resets,
condition pops, argument pops, pushes, frame transitions, clearing, and
instruction completion. `ControlTypeState` and `ControlTypeTrace` connect the
field recurrences to natural counters for arguments, outputs, opened frames,
closed frames, and clears, together with the pending-condition bit. Each
counter is bounded by the event position. The checked row-count bound excludes
modular wraparound when interpreting the gates as natural arithmetic.

`ControlTypeScalar` proves the condition's i32-or-unknown check, argument
compatibility with the packed member tag, exact output tags, equality of
the tags at an active implicit-else comparison, and equal selected input/output
lengths when that comparison starts. `ControlTypeGuards` derives
phase ordering: operands precede frame changes, outputs require the correct
frame changes and completed inputs, and clears occur after all inputs with
no pending condition or prior output/frame changes. A selected clear requires
the opcode to be br or return. At instruction completion,
the counters equal the selected input/output lengths and the opcode's required
frame/clear counts, and no condition remains pending.

`ControlTypeSemanticSound` composes these facts for every canonical row.
`ControlTypeSource.source_bound` retains the unique source message, SHA-256
digest binding, decoded instruction stream, opcode schedule, and operand/control
trace while adding the control-typing conclusion. This theorem does not yet
identify the selected signature heads and members with complete source lists,
prove whole-list equality for implicit else, or reconstruct the full
value-carrying `ControlPlans.plan` for every instruction body. Those remain
explicit obligations rather than premises silently treated as proved.

The thirteen new Lean libraries are default build targets. The full 1,221-job
formal build passes, with thirty selected theorem dependency checks using
only `propext`, `Classical.choice`, and `Quot.sound`. There are no admitted proofs
or new axioms. The production Nim circuit, witness generator, prover, and
verifier are unchanged; this extension adds no constraints or witness variables.

`tools/test_zkbuild_control_mode_proofs.nim` exercises all nine modes with known
and unknown operands and two-value i32/i64 signatures. Its try_table cases have
empty catch lists; exception-handler semantics are a separate obligation. It independently checks
58 action plans and generates eighteen fresh 192-byte Groth16 component proofs
using one reused test key. Verification rejects all 324 statement substitutions
and 36 malformed encodings. The fixed circuit has 443,522 constraints for 64
event rows and a QAP domain of 524,288. Run
`make zkbuild-control-mode-proofs-test`; the executable also accepts
`CHECKER WORK_DIR --check` for circuit and plan preflight.

`check_control_typing` checks complete emitted module matrices and tests 160
mutations per row: gate operands/results, lookup and packed interfaces, range
checks, row shape, gate spans, and canonical event/frame links. Run
`make zkbuild-control-type-semantics-test`. Both new targets are included in
`zkbuild-check`. A fresh audit of seventeen complete-module matrices checks
1,360 event rows and rejects all 217,600 mutations. The reproducibility report,
`build/zkbuild/control-typing-validation.json`, records hashes for 888 sources,
83 artifacts, all 43 complete-audit input files, and twelve logs.

These proofs expose their trace/environment inputs and use an ephemeral
component setup. Full raw instruction decoding and source-key interpretation,
remaining control/exception/context semantics, parser/validator and witness
refinement, production cryptographic implementation and trusted setup/key
certification, and arbitrary WASM-to-native preservation remain open. General
proof-only kernel admission stays disabled and runtime validation backstops
remain active. No hardware run or kernel verification-time measurement is
claimed.

### Control signature lists and member positions

`ControlLookupCheck` and `ControlLookupSound` check all six control-signature
lookup families against the actual merged immutable-table interfaces. Active
queries reach authenticated initializers with matching keys and values;
inactive interfaces cannot retain stale query values. The checker covers both
the four families shared with branch typing and the two direct result-length
and implicit-else comparison families.

`ControlFrameMetadata`, `ControlSignatureHeads`, `ControlLengthLists`,
`ControlSimpleLists`, and `ControlSignatureLists` identify complete parameter
and result lists for all four descriptor forms: type index, function index,
empty block, and inline singleton. Empty descriptors have canonical index zero;
singletons have one of the seven declared value-type tags. Function-root
parameter lists are empty. Lengths and heads have natural 32-bit bounds, and
list provenance reaches the authenticated source type/function signatures.
`ControlMemberLists` proves that each active member lookup returns an in-range
entry of its complete indexed list, with a declared tag below seven.

`ControlHeadTrace` and `ControlHeldLists` prove that the selected heads and
lengths remain unchanged until the next reset. An inactive reset produces
empty heads and lengths. `ControlMemberRouting` derives the actual parameter
versus result selectors, their input/output ordinal formulas, and the separate
parameter-member route used by an implicit-else comparison.

`ControlMemberPositions` excludes modular wraparound when interpreting those
formulas. `ControlRoutedMembers` and `ControlMemberSource` identify each member
with the exact position in the selected authenticated list: forward or reverse
order as required by the actual selector. Input tags must match the selected
type or be the polymorphic unknown tag; output tags match exactly. Comparison
members use the parameter list at the current argument index and match the
ordinary member payload. The index bounds are derived from accepted lookups
and range checks, not supplied as assumptions. These facts apply to every
canonical row; they do not yet establish whole-list equality for an implicit
else or reconstruct the full value-carrying `ControlPlans.plan` of each body.

`ControlSignatureSource.source_bound` composes the new list, carry, routing,
and typed-member conclusions with the unique source message, SHA-256 binding,
decoded stream, instruction schedule, operand/control trace, and preceding
control-typing theorem. Its premises remain explicit certificate checks and
R1CS satisfaction; raw instruction interpretation and implementation refinement
are separate obligations. The eighteen new Lean libraries are default targets.
The full 1,257-job formal build passes, with forty-five selected theorem
dependency checks using only `propext`, `Classical.choice`, and `Quot.sound`.
There are no admitted proofs or new axioms. The production Nim circuit,
witness generator, prover, and verifier are unchanged; no constraints or
witness variables were added.

`tools/test_zkbuild_control_signature_proofs.nim` exercises empty and all seven
inline singleton types in blocks and loops, typed multi-value blocks and loops,
function-root results, and an implicit-else case. It checks 58 independent
action plans and generates twenty fresh 192-byte Groth16 component proofs
with one reused test key. All 400 statement substitutions and 40 malformed
encodings are rejected. The fixed component circuit uses 448,945 constraints
for 64 event rows and a QAP domain of 524,288. Run
`make zkbuild-control-signature-proofs-test`; its executable also supports
`CHECKER WORK_DIR --check` for preflight. These tests have public trace and
environment inputs and use an ephemeral setup; they are not module-admission
or arbitrary-program compilation proofs.

`check_control_typing` now also checks and mutates the signature interfaces.
A fresh complete-matrix audit covers seventeen modules and 1,360 event rows.
It rejects all 282,880 substitutions: the preceding 160 control-typing
mutations per row plus 48 signature producer/merge/consumer mutations per row.
`tools/test_zkbuild_control_signature_semantics.nim` checks this coverage through
`make zkbuild-control-signature-semantics-test`; the Makefile reuses the output
of the extended control-typing audit rather than rerunning it. Both new targets
are included in `zkbuild-check`. The reproducibility report is
`build/zkbuild/control-signature-validation.json`, covering 909 sources,
106 artifacts, all 43 complete-audit input files, and twelve logs.

Full body/action composition, whole-list implicit-else equality, raw instruction
and source-key interpretation, remaining exception/context semantics,
parser/validator and witness refinement, production cryptographic refinement,
trusted setup/key certification, and arbitrary WASM-to-native preservation
remain open. General proof-only kernel admission remains disabled, and runtime
validation backstops stay active. No hardware run or kernel verification-time
measurement is claimed.
