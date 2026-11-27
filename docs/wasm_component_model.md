# Component Model implementation status

`ComponentVersion` identifies the 0.2 MVP base profile, and
`ComponentSpecRevision` pins binary and ABI semantics to
`585526aa1f2c7f76f07557d16e265dede38b3acb`. This revision also defines the
async facilities being added behind build flags. `wasm-tools 1.263.0`
generates and validates the test components. The decoder accepts the binary
header `00 61 73 6d 0d 00 01 00`. Full conformance remains in progress.
[Pinned binary format](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/Binary.md)
[Pinned Canonical ABI](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md)

`src/cps/wasm/component.nim` validates and links multiple embedded core modules
within one component using the full interpreter's store. Core functions, tables,
memories, globals and exception tags link by identity. A module importing mutable state sees
changes made by the other module. The linker validates the full core graph before
running guest start functions. The decoder accepts valid empty components and
checks kebab-case labels, name collisions, and qualified interface name syntax.

Embedded core modules and module type declarations support Core WebAssembly
function-only recursive type groups with scalar signatures. The decoder
handles the Component Model's prefixed non-final subtype encoding and the
unprefixed Core encoding inside a module type. Function imports and exports
match declared ancestors across separately encoded modules. Indirect calls,
including tail calls, check that same subtype relation. A plain canonical
lift requires the ABI's final singleton type. Core GC reference types and
aggregate types remain outside the interpreter's supported profile.

`python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-core-function-types`
checks cross-module imports, indirect calls and indirect tail calls. LP uses
a smaller two-module import fixture and the same indirect-call fixture as
M0 and D0. It runs with the standard 16 KiB writable layout and a 4,096-byte
stack. With the larger typed-module ascription fixture, the expanded-RAM LP
diagnostic peaked at 11,904 bytes of heap, exceeding the standard layout.

| Core function type QEMU profile | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 17,392 | 3,976 |
| D0 | 56,048 | 6,960 |
| LP | 7,728 | 3,600 |

Core tag imports use the supplying module's store address. Whole-instance
imports, synthesized instances, aliases, and typed core module re-exports
preserve that address. A tag defined by a module receives a fresh address on
each instantiation, so a typed catch only matches the imported tag even when
another tag has the same payload signature. Imports and exports of core tags
remain outside the zkbuild proof profile.

`python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-tags`
runs the pinned distinct-tag case on M0 and D0. The LP fixture combines the
tag definition and thrower in each of two instances. It catches one tag by
identity and handles the other through catch-all, using the default
4,096-byte stack reservation in its 16 KiB QEMU layout.

| Core tag QEMU fixture | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0, pinned upstream | 16,160 | 4,064 |
| D0, pinned upstream | 54,608 | 7,104 |
| LP, combined tag and thrower | 7,984 | 3,612 |

Nested components link functions by name and type, with nominal checks for
resources inside parameters and results.
Instantiation checks parameter names, parameter and result types, duplicate
arguments, and missing arguments before any guest code runs. Each child
has private core state. A caller can canonically lower an alias of a child
function, including when the caller and child use different string encodings.
The nested instances share the store's trap state. Component depth, total
instances and cross-component call depth are capped per core.
LP allows one nested level, eight component instances including the root,
and two active component calls. The M0 and D0 builds allow two nested levels
and four active component calls, with total instance caps of 32 and 128.

A synchronous `canon lower` can target a function lifted in the same
component. The shared interpreter uses the existing core store and restores
its execution stacks after the nested guest call. Each synchronous entry
has its own borrow scope. The host fixtures cover calls from core start and
from an active export, boolean normalization and resource ownership transfer.

`python3 tools/run_wasm_component.py --qemu-local-lower` runs the startup
and active-export fixture on M0 and D0 and a smaller active-export fixture
on LP. The LP QEMU build uses `-d:wasmComponentLocalReentry` and reserves
6,400 stack bytes within the existing 16 KiB writable layout. The default LP
profile rejects this adapter at decode time. Device RAM and stack admission
remain open.

| QEMU core | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 12,880 | 6,976 |
| D0 | 49,320 | 8,120 |
| LP | 6,288 | 5,656 |

The synchronous result resolver lowers the result into the caller while the
callee is still active. It then runs the callee's post-return hook before
returning control to the caller's core code. The same ordering applies to
calls within an instance, calls across instances and calls through component
function re-exports. A trap during result lowering skips the post-return
hook and locks the component store. The [pinned Canonical ABI](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#canon-lower)
describes this ordering through the synchronous result callback.

`python3 tools/run_wasm_component.py --qemu-cross-post-return` runs a
provider, a relay and a consumer. The host cases cover a successful string
copy, a trapping post-return, and precedence of an invalid caller realloc
over a trapping post-return. The QEMU case inspects the caller's linear
memory after a post-return trap and confirms that the payload byte was
already written.

| Cross-component post-return QEMU fixture | Peak heap | Peak native stack | Stack reserved |
| --- | ---: | ---: | ---: |
| M0 | 27,952 | 6,880 | 16,384 |
| D0 | 103,624 | 10,128 | 16,384 |
| LP, 32 KiB diagnostic | 17,072 | 6,576 | 8,192 |

The full relay exceeds LP's physical writable RAM budget. D0 needs a stack
larger than its default 8 KiB reservation for this fixture. The separate
small nested Boolean fixture still runs on LP within 16 KiB.

A `canon lift` can reference the core function generated by `canon lower`
or by a canonical resource operation. Generated functions have typed
addresses in the same core store as module exports. A reference can also use
a generated function for realloc, post-return or a resource destructor if its
core signature matches. The linker resolves these addresses before dependent
core starts, including when a child uses a parent adapter during instantiation.
The normal Canonical ABI guards still apply during realloc and post-return.
`python3 tools/run_wasm_component.py --qemu-generated-core` exercises the
direct lift of a lower through an inline core alias. It uses no embedded core
module. Host fixtures also check child startup order, resource constructors
called directly and via a core import, and destructor behavior. Generated
lowerings used as realloc and post-return validate with the required core
signatures and trap before calling the component import when invoked.

| Generated core function QEMU fixture | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 2,656 | 3,808 |
| D0 | 4,112 | 5,760 |
| LP | 2,656 | 3,652 |

The LP fixture fits the default 4,096-byte stack reservation in the 16 KiB
QEMU layout. It does not enable LP same-component reentry.

Named WIT interfaces with supported value types can be imported, exported,
and passed between nested components. The linker supports synthesized
function instances, instance and function export aliases, and type
ascriptions. It resolves defined value type exports, equality-bound type
imports, and scoped outer value aliases. Instance arguments must supply each
required method and named type with compatible types and can supply extra
members. Embedders bind a host interface through `ComponentHostInterface`
and call a named export through `invokeInterface`. Host bindings are
resolved before instantiation.

A named interface export annotation projects the explicitly listed members.
An equality-bound resource in the annotation must refer to the same nominal
resource as the provider. The check also applies to resource handles inside
named aggregate types and function signatures.

Function types can themselves be imported or exported under a `type (eq …)`
bound, passed as instantiation arguments, and aliased out of an instance.
The linker compares parameter names and value shapes and preserves the nominal
identity of any referenced resources. An exported signature can use a named
record from a publicly exported instance. A type from a private instance
does not make that signature externally visible.

Instance types and inline instances can export nested instances. The linker
resolves arguments and function aliases along the declared path, so equal
method names in separate nested instances keep separate bindings. Type
annotations project the nested tree. Resource types remain nominal through
aliases and typed component substitution. The resource fixture creates an
owner through one nested instance and uses a sibling alias of the same
resource to drop it. The reference validator and the runtime reject a
sibling that substitutes an unrelated resource.

Outer aliases can refer to nominal resources and handle types in the same
component scope. An instance type can also refer to resources and
resource-bearing value types in enclosing type scopes. The linker follows
aliases to their original resource and retains the visibility of named
aggregate types when rebasing their handles. Resource-bearing value aliases
that cross a component definition boundary are rejected.

Outer function type aliases preserve their Canonical ABI signature and
resolve named value types in the scope where the signature is used. Outer
instance type aliases preserve resources bound by the type and rebase
captured resources in enclosing declarations. Crossing a concrete
component boundary rejects a type with a free resource dependency. Unused
local declarations in an instance type can remain private.

Instance type visibility is checked when the type is used as a component
import or export. Declarations can describe an instance that cannot cross
that boundary because it uses a private type. Imports also reject
references to names introduced only by exports. The lexical resource
fixture aliases an instance type across a component boundary, creates a
resource, calls an aliased signature that borrows it through an option of
a record, and drops the owner. Invalid fixtures exercise the distinction
between bound and free resources and the visibility rules.

Instance types can themselves be imported, exported, and passed as
`type (eq …)` arguments. A supplied type may describe additional members.
The declared bound determines which members a type alias exposes. The
comparison preserves the identity of resources declared within a type and
the identity of resources captured from the surrounding component. Importing
two instance values of the same type still introduces separate resources.

Host callers can use the path overload of `invokeInterface` to call a
nested export. `ComponentHostInterface.interfaces` supplies nested host
function bindings. The instance nesting cap is two on LP and eight on M0,
D0, and the host. Expanded import trees and exported instance tables use
the component function profile limit to bound memory use.

A component can import a component definition and instantiate the supplied
definition. Contracts support direct functions, resources, defined value
types, and instance imports and exports that describe named WIT interfaces.
The linker matches an instance import against the members the provider
requires and projects instance exports to the members the consumer expects.
It resolves the definition and checks its contract before executing guest
code. An embedder can supply a decoded
provider through the `components` argument to `instantiateComponent` with a
`ComponentHostDefinition` named by the consumer's import. The same contract
checker handles definitions passed between guests. The host tests check that
missing, duplicate, incompatible, and unvalidated bindings fail before a
guest start runs, even if the consumer never instantiates the import.

Each instantiation assigns fresh identities to resources defined by the
provider. A provider may expose the same resource through multiple abstract
exports or re-export an imported resource. The typed linker preserves the
underlying identity for both cases. The host fixtures exercise a resource
across two export names and move an owner through an abstract re-export back
to its defining instance. Calls across independent resource instances still
trap. A typed instance export can also re-export a resource from an imported
interface by equality, including in a defined aggregate such as
`list<own<ticket>>`. The reference validator and the host runner reject
substitution of a different nominal resource and omission of a required
interface method.

Component-valued contracts can themselves import and export component
definitions. The linker checks those positions recursively. A provider must
accept each definition allowed by the declared input type and supply a
definition that satisfies the declared output type. An explicit export
annotation limits which members subsequent aliases can use. A definition
can be a member of a typed or synthesized instance, including a nested
instance. Its consumer can alias it, forward it as a definition, or
instantiate it. Host embeddings supply definitions under
`ComponentHostInterface.components` at the matching path.

Component types can also be imported and exported as types with `type (eq …)`.
The linker checks the supplied type against the bound using the same component
subtyping rules. A provider may offer extra exports or require fewer imports.
A type alias exposes the declared bound, so a subsequent component import
cannot assume the extra members. Components can forward these types through
typed and synthesized instance exports. A component type declaration starts
its own set of external names, so a captured record used by a declared method
must be named within that declaration.

Component-type declarations can capture resources and resource-bearing type
aliases from enclosing type scopes. The contract keeps the original resource
identity. A signature that uses the resource must refer to a type named in
the contract. A concrete provider can accept the captured resource through an
explicit type import. When a public contract refers to a resource defined by
its enclosing component, the resource itself also needs an export.

Outer aliases of component values carry the enclosing resource identity with
the value. The linker resolves the owning instance before any guest code
runs. Each application of a component definition creates a separate resource
environment. Captures used only inside a concrete component do not change
its external type.

Each instantiation creates independent mutable state. The relay fixtures
route same-name definitions along separate interface paths and check
independent instances of a forwarded definition. Negative cases cover
incompatible input types, missing projected members, and aliases to
members or exports hidden by an annotation. Component type syntax and
comparison depth are capped at two on LP and eight on M0, D0, and the
host. The cap applies when component and instance types alternate.
A matching pass visits at most 32 type pairs on LP or 1,024 on the
other profiles.

Components can import, export, and forward typed core WebAssembly modules.
Core module types cover function, table, memory, and global externs. A
supplied module may require fewer imports and export additional members.
Table and memory limits are checked in the appropriate direction for each
side. An explicit module export annotation fixes the visible signature.
The linker validates the definition and resolves its module bindings before
guest start functions run. The core interpreter resolves the actual imports
and exports by name when a supplied module's declaration order differs
from its contract.

Embedders can supply core bytes through the `coreModules` argument to
`instantiateComponent` using a named `ComponentHostCoreModule`. Core
modules can also be members of typed or synthesized instances, including
nested instances. Embedders supply those modules through
`ComponentHostInterface.coreModules` at the corresponding path. The
host and guest paths share the type checks and execute through the same
core interpreter.

The instance relay fixture forwards two modules with the same member name
at separate paths. It matches component imports contravariantly and exports
covariantly, with different declaration orders on either side. An instance
annotation projects the visible module members and their types. Negative
checks cover missing and duplicate bindings, malformed module bytes,
incompatible nested types, and aliases to hidden modules or hidden core
exports. Other module fixtures cover reordered core imports and exports
and single-memory limit subtyping.

Outer aliases can capture component definitions and core modules supplied
as imports or exported by preceding child instances. The linker binds
each captured definition at its declaration during preflight. Captured
values can then move with the definition through typed exports and
instance members. Each use retains the values from its original scope.
The host capture fixture creates two live instances of the same decoded
plan with different imports and checks both the captured bindings and
the independence of mutable guest state.

The implemented Canonical ABI subset covers scalar types including `char`,
strings in UTF-8, UTF-16 and Latin-1 plus tagged UTF-16, flags, enums, and
recursive records, tuples, generic lists, variants, options, and results.
The decoder checks composite types structurally
across component boundaries and validates references to named field, element,
and case types. Memory lifting checks alignment and the complete value range.
A generic list transfer has a cumulative 4 KiB byte budget and a limit of 32
decoded value nodes on LP or 512 elsewhere. Composite type nesting is capped
at four on LP and eight elsewhere. Each record or variant layout is capped
at 4 KiB and 4,096 expanded type nodes. Flat calls concatenate record fields
and join each variant payload lane independently. A short variant payload is
padded with zero lanes, and lifting consumes those lanes without interpreting
them. Functions with more than 16 flattened parameters
use an aligned tuple in guest memory. Both lift and lower validate
the complete tuple range. The layout preserves scalar widths, record padding,
variant payload alignment, and pointer and length pairs. One flattened result
is returned directly. Larger supported results use bounds-checked return
areas, including caller-provided return areas for lowered imports. Canonical
realloc runs even for zero-length lists. A guest or ABI trap locks the component store
against future calls. Guest callbacks during realloc and post-return are
guarded.

Local `resource.new`, `resource.rep`, and `resource.drop` use the bounded
nominal table in `src/cps/wasm/component_resources.nim`. Canonical handles use
the upstream LIFO reuse order and are scoped to the holding instance. A
component can import an abstract resource directly or through an instance
interface. The linker substitutes the supplied nominal type in function
signatures, checks equality constraints and member names, and keeps the
definition's destructor when an owner moves through another guest's table.

The synchronous ABI moves `own` values between executing guests, including
handles inside records, lists, tuples and variant payloads. Each `borrow`
pins its source handle until the call finishes. Borrowed handles can appear
inside parameters but are rejected transitively in results. A host-owned
value keeps its defining component graph alive until consumed or dropped.
The defining guest receives a borrow as its representation. Another
guest receives a scoped handle. Returning with such a handle still live traps
and locks the store. The host tests exercise resource moves, re-lending
protection, slot reuse, stale and wrong-type handles, destructor dispatch,
foreign borrows, and explicit component close. WASI services remain separate
from language support.

## Upstream conformance checks

The upstream gate reads WAST and generates binaries and assertions using
`wasm-tools json-from-wast`. Tests run through the Nim decoder and interpreter.
The selected subset covers binary framing and core linking, Canonical ABI
validation, name syntax and visibility, nested component function linking,
scalar normalization, UTF-8 boundary cases, cross-component string and
`list<string>` transcoding, realloc traps, parameter and result pointer
alignment and bounds,
variant discriminants and joined payload lanes, recursive records and
tuples, flags masking, structural value type equality, nominal resource
substitution, cross-guest resource moves, borrow lifetimes and table reuse.
The pinned revision passed 849 selected checks across 45 instantiations, 66
definition validations, 394 rejections, 306 return assertions and 38 trap
assertions. Eleven local core function type checks cover subtype linking,
contravariant imports, canonical lift identity, indirect calls and rejection
of malformed subtype declarations. All 44 returns in `values/concat.wast`
run, including nine map cases. Nine synchronous rejections from
`validation/map.wast` and five local map cases cover key and value
validation, named type visibility, linking, map results, and alignment.
The other four upstream map validation cases involve streams or futures.
The generated core function cases exercise lifting `resource.drop` through
resource visibility and identity rules.
All 72 cases in `validation/resources.wast` run. The `resources/borrows.wast`,
`resources/multiple-resources.wast`, and
`resources/handle-table.wast` runtime files run in full. All 11 cases in
`validation/core-modules.wast` run. The runner also covers the full
`linking/unit.wast`, `linking/tags.wast`,
`linking/link-time-virtualization.wast`,
`linking/shared-everything-dynamic-linking.wast`,
`validation/defined-types.wast`, `validation/external-visibility.wast`,
`validation/annotated-names.wast`, `validation/version-suffix.wast`,
`values/numerics.wast`, and `values/realloc.wast` files. All 25 binary
cases in `validation/attributes.wast` run. The other four cases test
malformed WAT source. The selected cases include synchronous
post-return checks and the two-memory variance case in
`validation/instantiation.wast`.
The runner prints the number of excluded cases per selected WAST file.
All 62 external-visibility cases pass, including the two instance
re-exports at lines 459 and 475. The linker substitutes parent type names
when they are supplied as child arguments. Instance export validation checks
each member in declaration order. Five local WAST checks also cover that
ordering, an ascribed instance with a renamed nested type, a function that
uses an imported type across a component boundary, and an alias of an
ascribed function export.

Resource validation tracks the external name separately from the nominal
resource identity used at runtime. An instance method can use a name already
published by its enclosing component, including a name supplied as a child
argument. A raw type reference to the same resource still needs its own
publication. Nine local checks cover nested export order, publication
through aliases, the separation of import and export names, and destruction
of a resource relayed through a child component. A child also binds a
`[constructor]` import by its declared name, calls it, and drops the
returned owner.

Explicit `(eq ...)` export ascriptions preserve a resource's nominal type.
Defined value types compare structurally and check the nominal identity of
embedded handles. `(sub resource)` export ascriptions introduce a fresh
static resource type backed by the original implementation and destructor.
An abstract export permits `resource.drop`. `resource.new` and `resource.rep`
require a local concrete resource definition.

The pinned Component Model text describes abstract export ascription.
[Type definitions](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/Text.md#type-definitions)

`wasm-tools 1.263.0` assembles these exports and rejects them at validation.
The reference gate recognizes that specific validator diagnostic and runs
the assembled fixtures through the Nim decoder and runtime. The upstream
negative case reaches the intended type substitution check. Local tests
exercise destructor dispatch through an abstract re-export and reject
incompatible identities and representation operations on an abstract type.

The decoder validates `implements` and `external-id` attributes on the
binary name encoding. Version suffixes require
`-d:wasmComponentCanonicalNames`, matching the opt-in `cm-canon-names`
profile in `wasm-tools 1.263.0`. The linker uses literal declared names
for host bindings and child instantiation. The attribute values are
metadata. A host can inspect the attributes on a component's immediate
definitions with `componentNameAttributes`. The fixture in
`python3 tools/run_wasm_component.py --qemu-interface` imports a service
under a plain attributed name, calls it from core Wasm, and re-exports the
interface under its declared versioned name.

| Name attribute QEMU profile | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 13,400 bytes | 4,256 bytes |
| D0 | 50,448 bytes | 7,568 bytes |
| LP | 7,872 bytes | 3,828 bytes |

The LP attribute fixture runs separately from the earlier interface fixture.
The attribute case uses 16 KiB of writable RAM and the default 4,096-byte
stack reservation.

```sh
mkdir -p build/wasm-component/spec
git -C build/wasm-component/spec init
git -C build/wasm-component/spec fetch --depth=1 \
  https://github.com/WebAssembly/component-model.git \
  585526aa1f2c7f76f07557d16e265dede38b3acb
git -C build/wasm-component/spec checkout --detach FETCH_HEAD
python3 tools/run_wasm_component_spec.py build/wasm-component/spec
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-tags
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-multi-memory
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-resource-visibility
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-resource-ascription
```

The resource-ascription QEMU probe moves handles across components on M0
and D0. LP runs a smaller graph that drops through an equality-bound alias
of an abstract export. Both fixtures check two calls to the original
destructor. The native probe uses the smaller fixture and publishes
`0x57524100` at the existing scalar probe status address after both calls
pass. Generate the fixture with `--qemu-resource-ascription` before building.

| QEMU profile | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 29,504 bytes | 8,048 bytes |
| D0 | 105,432 bytes | 11,136 bytes |
| LP | 8,744 bytes | 3,996 bytes |

The native LP probe reserves 336 bytes of `.data`, 2,212 bytes of `.bss`,
9,740 bytes of heap, and a 4,096-byte stack. Those are link sizes. The native
probe still needs a coordinated Ox64 run to measure actual stack and heap use.

```sh
for core in m0 d0 lp; do
  nim c -d:bl808"$core" -d:bl808kernel -d:bl808WasmFull \
    -d:wasmComponentResourceAscriptionFirmware \
    --nimcache:build/wasm-component/resource-audit/"$core"-ascription-cache \
    --out:build/wasm-component/resource-audit/"$core"-ascription.elf \
    examples/wasm_component_scalar_build_test.nim
done
```

Embedded core modules validate and execute indexed memory32 instructions in
the full interpreter. Standalone managed jobs and the native backends retain
single-memory admission. The multi-memory fixture writes to two separate
memories and lifts a string through the Canonical ABI using memory index one.
It passed on all three QEMU CPU profiles.

| QEMU profile | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 10,760 bytes | 3,952 bytes |
| D0 | 46,264 bytes | 6,928 bytes |
| LP | 5,296 bytes | 3,576 bytes |

The LP QEMU build links 336 bytes of `.data`, 3,040 bytes of `.bss`,
8,896 bytes of heap, and a 4,096-byte stack within 16 KiB of writable RAM.
The host regression exercises indexed load and store, grow, cross-memory
copy and data initialization, bounds checks after `data.drop`, and fault
routing to the correct backing memory. The test runs with and without
chunked memory and interpreter peephole optimization.

```sh
mkdir -p build/wasm-component/multi-memory
wasm-tools parse tools/wasm_multi_memory.wat \
  -o build/wasm-component/multi-memory/guest.wasm
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --out:build/wasm-component/multi-memory/host tools/test_wasm_multi_memory.nim \
  build/wasm-component/multi-memory/guest.wasm
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  -d:wasmChunkedMemory -d:WasmMemoryChunkBytesConfig=512 \
  --out:build/wasm-component/multi-memory/chunked tools/test_wasm_multi_memory.nim \
  build/wasm-component/multi-memory/guest.wasm
```

The resource relay QEMU gate runs two transfers on each CPU profile.
M0 and D0 run the full fixture. A core Wasm caller lowers a function from
the child's re-exported interface, transfers each handle, and reads the
parent guest destructor's cumulative values of 42 and 84. The compact LP
fixture invokes the same ownership path through the exported interface and
checks that each source handle is unusable after the child consumes it.
The full fixture exceeded the 16 KiB LP layout. With 32 KiB in QEMU, it used
14,424 bytes of peak heap and 6,656 bytes of native stack.

| Resource relay QEMU profile | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0, guest caller and destructor | 19,904 bytes | 7,040 bytes |
| D0, guest caller and destructor | 60,528 bytes | 9,680 bytes |
| LP, component interface ownership transfer | 7,928 bytes | 3,692 bytes |

## WIT maps

The linker treats `map<K,V>` as a distinct value type. Canonical lowering
and lifting use the existing list memory layout with a two-field entry.
Keys can be integers, Boolean, Unicode scalars, or strings. Map values can
use the supported synchronous types and must be free of handles. The host
API exposes ordered entries via `componentMap` and `cpMap`. It preserves
duplicate keys on the wire. Language bindings that expose an associative
container use the last entry for a duplicate key.
[Pinned map validation](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/Binary.md#type-definitions)
[Pinned Canonical ABI](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#despecialization)
[Pinned WIT rules](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/WIT.md#value-types)

`python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-map`
builds the component from `tools/wasm_component_map.wit` and exercises
an empty map, duplicate keys, and an aligned u64 value including its
maximum. The same fixture runs on all three QEMU CPU profiles. The
build-only native map probe uses `-d:wasmComponentMapFirmware` and
status prefix `0x574D5000` with the firmware command below. For LP add
`-d:WasmLpNativeStackBytes=4608` and
`--passL:-Wl,--defsym=__bl808_lp_stack_bytes=4608`. Both LP binaries link
with 336 bytes of `.data`, 2,728 bytes of `.bss`, 8,712 bytes of heap,
and a 4,608-byte stack. Physical validation remains pending.

| Map round-trip QEMU profile | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 12,920 bytes | 4,704 bytes |
| D0 | 49,272 bytes | 7,152 bytes |
| LP | 7,304 bytes | 4,008 bytes |

The QEMU LP profile uses a 4,096-byte stack within 16 KiB and has 88 bytes
of measured stack headroom for this fixture. The native LP probe links with
336 bytes of `.data`, 2,728 bytes of `.bss`, 8,712 bytes of heap and a
4,608-byte stack.

## WIT fixed-length lists

`-d:wasmComponentFixedLists` enables `list<T,N>`, matching the opt-in
`cm-fixed-length-lists` feature of the pinned toolchain. Length is part
of the component type. The Canonical ABI uses repeated element lanes
for flat calls and consecutive aligned elements for memory-backed calls.
The host constructs values with `componentFixedList` and reads their
`cpFixedList` fields. Validation checks the spec's strict 2²⁸-byte limit
for both pointer widths without allocating individual elements. The
firmware executes the memory32 Canonical ABI with its existing transfer
quotas. [Pinned Binary Format](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/Binary.md#type-definitions)
[Pinned Canonical ABI](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#element-size)

`python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-fixed-list`
builds two WIT worlds and validates them using `wasm-tools`. The host
checks the default feature gate, and the enabled cases run on the host
and all three QEMU CPU profiles. They cover a direct i64 result, inline
parameters with an indirect result, a 17-element indirect parameter,
and rejection of a mismatched length. Running the two components
independently fits LP's 16 KiB layout. The combined diagnostic exceeded
that budget. The host suite also tests Canonical ABI lowering across a
component boundary, invalid alignment, byte-size overflow and transfer
quota failures. The mixed upstream size-boundary component still
includes stream and future types. The local suite covers its synchronous
boundary cases.

| Fixed-length list QEMU profile | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 13,032 bytes | 4,120 bytes |
| D0 | 49,512 bytes | 7,232 bytes |
| LP | 7,432 bytes | 3,828 bytes |

For the build-only native probes, add `-d:wasmComponentFixedLists` and
`-d:wasmComponentFixedListFirmware` to the firmware command below. The
direct probe uses status prefix `0x57464C00`. Add
`-d:wasmComponentFixedListIndirectFirmware` to build the indirect probe,
which uses `0x57464900`. The LP probes cross-link with
`-d:WasmLpNativeStackBytes=4608` and
`--passL:-Wl,--defsym=__bl808_lp_stack_bytes=4608`. Physical validation
remains pending.

## Canonical context storage

`-d:wasmComponentContext` enables the base `canon context.get` and
`canon context.set` built-ins with an i32 cell at slot zero. Each
synchronous entry and core start gets a zeroed cell. Post-return shares
its entry's cell. Realloc and resource destructor calls get independent
zeroed cells and restore any active caller's context when they return.
The cell is private to the active synchronous call. Async suspension,
explicit threads, and the optional i64 and second-slot extensions remain
outside this execution profile. [Pinned Canonical ABI](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#-canon-contextget)
[Pinned concurrency model](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/Concurrency.md#thread-local-storage)

The host specification gate runs the upstream post-return context case
and the synchronous recursive destructor case. Local tests also check
cross-component calls, realloc while the caller is active, direct lifts
of the built-ins, and invalid types or slots.

`python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-context`
checks the default feature gate and runs start, realloc, post-return
and repeated-entry cases on all three QEMU profiles. M0 and D0 use a
combined fixture. LP runs start and realloc separately from the
upstream post-return fixture within its 16 KiB writable layout.

| Context QEMU profile | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 14,960 bytes | 4,208 bytes |
| D0 | 52,728 bytes | 7,216 bytes |
| LP | 8,592 bytes | 4,236 bytes |

The native probe uses `-d:wasmComponentContext` and
`-d:wasmComponentContextFirmware` with the firmware command below.
Its success status is `0x57435400`. For the LP post-return probe also
add `-d:wasmComponentContextPostReturnFirmware` and expect
`0x57435000`. LP builds use `-d:WasmLpNativeStackBytes=4608` and
`--passL:-Wl,--defsym=__bl808_lp_stack_bytes=4608`. The native LP probes
reserve 8,684 heap bytes, 92 more than the QEMU peak. Actual
heap and stack margins still need to be measured on the Ox64.

## Async callback lifts

`-d:wasmComponentAsyncCallbacks` enables `async` function types, Canonical
ABI callback lifts, `task.return`, and the context built-ins. Async function
types retain their effect through typed linking. An async-typed function
using the synchronous Canonical ABI can still complete in an ordinary call.
[Pinned function types](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/Binary.md#type-definitions)

`beginCallback` prepares a root export or a named interface method for
polling. Each `pollCallback` executes the entry or one callback turn. `YIELD`
releases control with the guest stack unwound, and the invocation retains
its own context for the next poll. `callbackResultReady` and
`takeCallbackResult` expose `task.return` once, including when the callback
thread continues after resolving. `EXIT` before resolution leaves the call
unresolved. The callback entry and its callback function are checked against
their core signatures before instantiation. Runtime return validation checks
the result type, memory instance, and string encoding.
[Pinned Canonical ABI](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#canon-lift)

The current host-polling profile runs each guest turn to completion. Async
callback turns have no instruction budget, so this profile stays outside hard
slots. `pollComponentTasks` advances one runnable guest subtask, including a
callback that continues after returning its result.

```sh
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-callbacks
for core in m0 d0 lp; do
  nim c -d:bl808"$core" -d:bl808kernel -d:bl808WasmFull \
    -d:wasmComponentAsyncCallbacks -d:wasmComponentCallbackFirmware \
    --nimcache:build/wasm-component/callback/"$core"-cache \
    --out:build/wasm-component/callback/"$core".elf \
    examples/wasm_component_scalar_build_test.nim
done
```

The runner builds the interleaving fixture from WIT with `wasm-tools
component embed` and `component new`, validates the binaries, and tests the
opt-in gate. The host tests cover inline and indirect result tuples, a
string result, an owned resource result with destructor dispatch, nested
interface targeting, duplicate return, mismatched return type or options,
invalid callback flags, and an unresolved exit. The pinned upstream cases
cover async option validation and rejection of borrowed return types.

| QEMU callback profile | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 14,752 bytes | 3,768 bytes |
| D0 | 52,104 bytes | 6,608 bytes |
| LP | 9,248 bytes | 3,372 bytes |

The native LP probe reserves 392 bytes of `.data`, 2,212 bytes of `.bss`,
9,684 bytes of heap, and a 4,096-byte stack. The probe publishes `0x57434100`
at the scalar firmware status address on success. Physical Ox64 testing
and native high-water measurements remain pending.

### Guest subtasks and waitable sets

The async option also enables async lowering, explicit backpressure,
waitable-set new, poll and drop, waitable join, subtask drop, and callback
`WAIT`. Before a callee starts, `STARTING` tells the caller to keep its
argument area alive. The callee captures arguments when it starts and writes
the canonical result area before announcing `RETURNED`. An immediate result
uses the packed status directly. A suspended subtask uses the same handle
namespace as resources and waitable sets. Guest subtasks are capped at four
per LP component store and 32 per M0 or D0 store.
[Pinned async lowering and subtask state](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#canon-lower)

The host suite tests the one-, 16-, and 17-lane result layouts and the
4-, 5-, and 17-lane argument layouts in the upstream cross-ABI fixture.
Two upstream assertions at lines 491 and 495 expect a return even though
the lift specifies memory and `task.return` omits it. The gate excludes
those assertions and retains the pinned `LiftOptions.equal` check.
[Pinned ABI options](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#canonical-abi-options)

The M0 and D0 QEMU probes exercise result-buffer visibility, progress
events, backpressure, handle reuse, and a callback that exits after returning
a result. The LP QEMU probes use `--qemu-lp-subtasks-diagnostic` and 32 KiB
of writable RAM. Both LP fixtures exceeded the standard 16 KiB layout. The
same-component probe timed out during instantiation at 16 KiB. The separate
WIT callback probe still passes on LP at 16 KiB.

| QEMU subtask probe | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 cross-component | 37,864 bytes | 6,308 bytes |
| D0 cross-component | 116,904 bytes | 9,168 bytes |
| LP same-component, 32 KiB diagnostic | 11,040 bytes | 3,424 bytes |
| LP cross-component, 32 KiB diagnostic | 15,208 bytes | 4,384 bytes |

The LP native probe uses a memoryless same-component subtask. Use
`-d:wasmComponentSubtasksFirmware` in the native build command above. It
publishes `0x57535400` at the scalar firmware status address on success.
Its 16 KiB link reserves 9,572 bytes of heap and 4,096 bytes of stack.
LP subtask admission within that layout and physical Ox64 runs remain pending.

### Callback subtask cancellation

`subtask.cancel` releases a backpressured subtask without entering the callee
or reading its arguments, returning `CANCELLED_BEFORE_STARTED`. A started
callback receives `TASK_CANCELLED` once, ahead of any queued wait-set event.
It can acknowledge with `task.cancel` or write a normal result with
`task.return`. An async request that has not resolved returns `BLOCKED`.
The caller can join the handle to a waitable set and collect its final status
there. A subtask can be dropped after its terminal status has been delivered.
[Pinned subtask cancellation](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#canon-subtaskcancel)
[Pinned cancellation acknowledgement](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#canon-taskcancel)

`tools/wasm_component_cancellation.wast` isolates these cases from APIs that
require stackful execution. It covers queue reuse within a single guest
turn, waking an empty wait set, delayed acknowledgement, targeted resumption,
returning a value, a completed subtask whose result has yet to be delivered,
and invalid cancellation. The runner assembles and validates the fixture with
`wasm-tools --features=cm-more-async-builtins` and executes it with the
project's interpreter. The QEMU options above also exercise cancellation.
The LP diagnostic fixture tests both cancellation before start and
delivery to a running callback.

| QEMU cancellation probe | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 43,952 bytes | 6,372 bytes |
| D0 | 124,304 bytes | 9,216 bytes |
| LP, 32 KiB diagnostic | 17,656 bytes | 4,540 bytes |

The LP cancellation probe exceeds the standard 16 KiB writable layout.
Blocking `subtask.cancel` requires the stackful option below.

### Stackful async lifts

Enable `-d:wasmComponentAsyncCallbacks -d:wasmComponentStackful` for
callback-free async lifts, blocking `waitable-set.wait`, `thread.yield`,
and synchronous `subtask.cancel` that waits for acknowledgement. Drive the
exports with `beginCallback` and `pollCallback`. A `ccsCoreWaiting` state
keeps the thread's guest operands, frames, and locals in its arena. A
completed host import supplies its return lanes exactly once. Multiple
guest threads in one instance share the store while retaining their own
stacks and context cells. A callback that blocks inside a core turn retains
its exclusive reservation until the turn exits. Portable migration rejects
continuations waiting on a host import.
[Pinned Canonical ABI async lift](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#canon-lift)

```sh
python3 tools/run_wasm_component_spec.py build/wasm-component/spec \
  --stackful --qemu-callbacks --qemu-lp-subtasks-diagnostic
wasm-tools parse tools/wasm_host_suspend.wat -o build/wasm-component/host-suspend.wasm
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on -d:wasmSuspendableHostCalls \
  --out:build/wasm-component/host-suspend tools/test_wasm_host_suspend.nim \
  build/wasm-component/host-suspend.wasm
```

The upstream startup cases verify the trap when a synchronous core start
function tries to block. The M0 and D0 QEMU fixture drives two subtasks in a
shared callee, waits for both sets of results, and waits for a cancellation
acknowledgement after the target yields. The compact LP fixture suspends and
resumes two calls with distinct locals and context cells in 16 KiB of writable
RAM.

| QEMU stackful probe | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 39,264 bytes | 7,512 bytes |
| D0 | 118,616 bytes | 11,048 bytes |
| LP, compact fixture | 7,824 bytes | 3,424 bytes |

The native probe uses the compact fixture and reports `0x57534600` at the
scalar build test's per-core status address. To build it after generating the
fixtures above:

```sh
for core in m0 lp d0; do
  link_flags=()
  if [ "$core" = d0 ]; then link_flags=(-d:bl808D0Xip); fi
  nim c -d:bl808"$core" -d:bl808kernel -d:bl808WasmFull \
    -d:wasmComponentAsyncCallbacks -d:wasmComponentStackful \
    -d:wasmComponentStackfulFirmware "${link_flags[@]}" \
    --nimcache:build/wasm-component/stackful/"$core"-cache \
    --out:build/wasm-component/stackful/"$core".elf \
    examples/wasm_component_scalar_build_test.nim
done
nim c -d:bl808d0 -d:bl808kernel -d:bl808WasmFull \
  -d:wasmComponentAsyncCallbacks -d:wasmComponentStackful \
  -d:wasmComponentStackfulFirmware --passC:-flto \
  '--passL:-flto -Wl,--undefined=trap_entry,--undefined=main,--undefined=memcpy' \
  --nimcache:build/wasm-component/stackful/d0-lto-cache \
  --out:build/wasm-component/stackful/d0-lto.elf \
  examples/wasm_component_scalar_build_test.nim
```

The D0 DRAM probe links with LTO and reserves 92,392 bytes of heap and
an 8 KiB stack. The larger QEMU test exceeds both reservations. The native
LP image reserves 560 bytes of `.data`, 2,212 bytes of `.bss`,
9,516 bytes of heap, and 4,096 bytes of stack. These are build results.
Ox64 execution and D0's concurrent XIP mapping still need bench validation.

### Synchronous lowering of async functions

The stackful profile supports synchronous `canon lower` calls to async
functions. The caller uses the synchronous ABI for its arguments and
results. Backpressure delays lifting the caller's arguments until the
callee starts. If the callee suspends, the caller waits on its own guest
continuation. The callee publishes flat lanes or writes the caller's
indirect result area as soon as it resolves. A synchronous lift runs
`post-return` after writing the result. A callback can continue running
after the caller has resumed. The synchronous caller receives no
guest-visible subtask handle.
[Pinned Canonical ABI lowering](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#canon-lower)

Async-typed exports using the synchronous lift ABI can be driven through
`beginCallback` and `pollCallback`. The existing synchronous invocation API
still requires the call to return directly. The upstream startup traps
cover attempts to block during instantiation. The upstream subtask
drop tests cover waiting inside an async-typed synchronous lift and
rejecting premature drops.

```sh
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-sync-lower
```

The M0 and D0 fixtures cover flat results, indirect strings, deferred
argument lifting, and `post-return` ordering. They also exercise a callback
that waits on a stackful callee while an earlier queue entry needs the
callback's exclusive lock. The memoryless LP fixture
lifts the generated core import directly and checks suspension and flat
result delivery in the standard 16 KiB writable layout. Smaller initial
LP arenas grow on demand and let the fixture reserve a 5,120-byte stack.

| QEMU synchronous lower probe | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 49,096 bytes | 7,584 bytes |
| D0 | 133,272 bytes | 11,280 bytes |
| LP, compact fixture | 8,096 bytes | 4,872 bytes |

For the native probe, use `-d:wasmComponentSyncLowerFirmware` in place of
`-d:wasmComponentStackfulFirmware` in the commands above. Add
`-d:wasmComponentLocalReentry --passL:-Wl,--defsym=__bl808_lp_stack_bytes=5120`
for LP. The compact probe links on M0, LP, D0 XIP and D0 DRAM with LTO.
It reports `0x57534C00` at the scalar build test's status address.
The LP link reserves 8,464 bytes of heap and a 5,120-byte stack. The larger
D0 fixture exceeds the DRAM probe's heap and stack reservations in QEMU.

### Borrowed resources across async calls

Async calls use the existing nominal resource table and attach foreign
borrow handles to the receiving task's scope. The scope survives callback
turns and stackful waits. A borrowed handle may be dropped from another
task in the same instance. A task traps if it tries to return or
acknowledge cancellation while handles from its scope remain live.
Reborrowing retains the source scope until the nested result is delivered.
[Pinned Canonical ABI resource lifting](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#lifting)

The caller starts lending when the callee reads the arguments. The loan
stays active until terminal status is delivered through the packed
return, the waitable event, or cancellation. A synchronous lower keeps
the loan active through result delivery on its continuation. Cancelling
before start leaves the arguments unread. Host-owned values borrowed
through `beginCallback` stay pinned until the result is taken. The
ARC lifetime test also covers callback abandonment with an outstanding
reborrow, delivery by a separate task, and graph cleanup with pending
internal loans.
[Pinned subtask resolution](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#subtask-state)

```sh
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-async-borrows
```

The M0 and D0 fixtures cover transitive loans, concurrent scopes, borrow
delivery, and cancellation. LP's standard 16 KiB probe borrows a
host-owned resource in its defining component. LP's cross-component
fixture uses a 32 KiB diagnostic layout to exercise a foreign borrow
handle and cancellation.

| QEMU async borrow probe | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 67,328 bytes | 11,392 bytes |
| D0 | 159,816 bytes | 16,848 bytes |
| LP, resource in its defining component | 8,808 bytes | 3,424 bytes |
| LP, cross-component, 32 KiB diagnostic | 19,424 bytes | 4,516 bytes |

The compact native fixture links for M0, LP, D0 DRAM, and D0 XIP. Build the
scalar probe with `-d:wasmComponentAsyncCallbacks -d:wasmComponentAsyncBorrowsFirmware`
after running the fixture command above. It reports `0x57414200` at the
per-core status address. The LP link reserves 9,572 bytes of heap and a
4,096-byte stack. Ox64 execution remains pending.

### Canonical ABI futures

`-d:wasmComponentFutures` enables the pinned Canonical ABI's typed pairs,
read and write, cancellation, drop, forwarding, and waitable delivery.
Lifting moves an idle, unjoined reader out of its guest handle table.
Lowering consumes the lifted value and installs a handle in the receiving
guest. These moves work through synchronous calls, async task results,
and compound values. Copies of a consumed host value stay invalid.
Embeddings can release a lifted reader with `dropComponentFuture`.
A same-instance rendezvous accepts unit and numeric payloads.
Cross-instance delivery uses each endpoint's memory, encoding, realloc,
and nominal resource bindings. Synchronous read and write require
`-d:wasmComponentStackful`.
[Pinned Canonical ABI](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#canon-streamfuturereadwrite)

```sh
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-futures
```

The host gate includes all ten assertions in upstream
`future-completion-order.wast`, `futures-must-write.wast`, and
`cross-task-future.wast`. Local tests cover blocking, forwarding,
buffer and transfer-state validation, UTF-8 to UTF-16 delivery in both
arrival orders, and an owned resource whose destructor runs in its
defining component once the receiver drops it. The ARC test uses a
WIT-generated component to check direct and tuple returns, consumed
values, reader abandonment, and peer closure.

The QEMU fixture parks a guest continuation on a synchronous future read.
M0 and D0 start the producer via an asynchronous lowering. The LP probe
starts it as a second callback to fit the standard 16 KiB budget.

| QEMU future wait probe | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 19,504 bytes | 7,592 bytes |
| D0 | 59,360 bytes | 11,240 bytes |
| LP | 9,480 bytes | 3,488 bytes |

The cross-component string transfer probe also runs on M0 and D0 QEMU.
It measured 34,864 bytes peak heap and 9,408 bytes of native stack on
M0, and 112,712 bytes of heap and 13,680 bytes of native stack on D0.
The LP transfer probe moves a memoryless reader through the embedding
and back into its guest with a write pending. It measured 9,168 bytes
of heap and 3,688 bytes of native stack in the 16 KiB layout.

Build the native scalar probe after generating both fixtures. Success
reports `0x57465700` at the per-core status address.

```sh
for profile in m0 lp d0-dram d0-xip; do
  core="${profile%%-*}"
  link_flags=()
  case "$profile" in
    lp) link_flags=(-d:WasmLpNativeStackBytes=3968
      --passL:-Wl,--defsym=__bl808_lp_stack_bytes=3968) ;;
    d0-dram) link_flags=(--passC:-flto
      '--passL:-flto -Wl,--undefined=trap_entry,--undefined=main,--undefined=memcpy,--defsym=__bl808_d0_stack_bytes=16384') ;;
    d0-xip) link_flags=(-d:bl808D0Xip
      --passL:-Wl,--defsym=__bl808_d0_stack_bytes=16384) ;;
  esac
  nim c -d:bl808"$core" -d:bl808kernel -d:bl808WasmFull \
    -d:wasmComponentAsyncCallbacks -d:wasmComponentStackful \
    -d:wasmComponentFutures -d:wasmComponentFutureWaitFirmware "${link_flags[@]}" \
    --nimcache:build/wasm-component/future-wait/"$profile"-cache \
    --out:build/wasm-component/future-wait/"$profile".elf \
    examples/wasm_component_scalar_build_test.nim
done
```

All four firmware profiles cross-link. The LP link reserves 644 bytes of
`.data`, 2,212 bytes of `.bss`, 9,560 bytes of heap, and 3,968 bytes of
stack. D0 uses a 16 KiB stack reservation for this probe. Ox64 execution
and concurrent XIP validation remain pending.

### Canonical ABI streams

`-d:wasmComponentStreams` enables the stream builtins and readable
stream values independently of the future flag. Both use the same
endpoint table, ownership transfers, and waitable sets. Stream events
pack the total copied element count with the status. Several calls can
drain a pending buffer before its owner takes the event. Taking the
event releases the pending region. A peer drop takes precedence over
cancellation and completion, while preserving any elements already
copied. Zero-length readiness follows the Canonical ABI writer-first
rule. Synchronous copies require `-d:wasmComponentStackful`.
[Pinned stream and future state](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#stream-and-future-state)

```sh
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-streams --qemu-futures
```

The stream gate runs the upstream partial copy, cancellation, closure,
forwarding, ready-state, and transfer cases. Local tests cover the
28-bit buffer count and status encoding. The WIT-generated fixture
passes a lifted reader through direct and tuple results and checks
stale handle rejection. The M0 and D0 QEMU probes verify byte order and
waitable progress on a partially drained buffer. The LP fixture uses
a unit stream and cancels a partially drained write.

| QEMU stream probe | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 24,760 bytes | 4,416 bytes |
| D0 | 66,992 bytes | 7,408 bytes |
| LP | 8,712 bytes | 3,488 bytes |

Unit and numeric buffers support the Canonical ABI count encoding.
Compound transfers use the existing canonical value and byte budgets,
and overlapping same-instance numeric copies preserve source order.
The runtime rejects same-instance nonnumeric rendezvous and
`stream<char>` under the pinned revision's restrictions.

Build the native scalar probe after generating the fixtures with the
suite above. The unit-stream success code is `0x57535200`.

```sh
for profile in m0 lp d0-dram d0-xip; do
  core="${profile%%-*}"
  link_flags=()
  case "$profile" in
    lp) link_flags=(-d:WasmLpNativeStackBytes=3968
      --passL:-Wl,--defsym=__bl808_lp_stack_bytes=3968) ;;
    d0-dram) link_flags=(--passC:-flto
      '--passL:-flto -Wl,--undefined=trap_entry,--undefined=main,--undefined=memcpy') ;;
    d0-xip) link_flags=(-d:bl808D0Xip) ;;
  esac
  nim c -d:bl808"$core" -d:bl808kernel -d:bl808WasmFull \
    -d:wasmComponentAsyncCallbacks -d:wasmComponentStreams \
    -d:wasmComponentStreamFirmware "${link_flags[@]}" \
    --nimcache:build/wasm-component/stream/"$profile"-cache \
    --out:build/wasm-component/stream/"$profile".elf \
    examples/wasm_component_scalar_build_test.nim
done
```

The four firmware profiles cross-link. The LP image reserves
532 bytes of `.data`, 2,212 bytes of `.bss`, 9,672 bytes of
heap, and 3,968 bytes of native stack. Ox64 execution is pending.

### Host-owned endpoints

`-d:wasmComponentHostEndpoints` adds an embedding API for the enabled
future and stream types. `newComponentEndpointPair` creates a readable
value and a host writer. The embedding can declare a unit or primitive
payload or derive the full payload type from an export parameter or
result. `hostEndpoint` exposes a readable value to the same host API,
including values lifted from guest functions. The writer stays with the
embedding. Passing the reader to a guest consumes the host handle.

Host reads and writes use the same rendezvous, cancellation, and
waitable rules as guest copies. `readComponentEndpoint`,
`writeComponentEndpoint`, and `writeComponentUnits` return immediately
and share the component store's cooperative execution thread. A pending
copy holds its buffer until `pollComponentEndpoint` delivers its event
or `cancelComponentEndpoint` cancels it.
Write results return the unused suffix after partial completion,
cancellation, or a peer drop. Submitting owned payloads consumes their
original handles. If guest lowering traps, the runtime locks the guest
store and rolls back the handles allocated by that copy so the
embedding can recover its unsent values. The guest memory in that
store may contain partial writes.
[Pinned Canonical ABI buffer state](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#buffer-state)

```sh
python3 tools/run_wasm_component_spec.py build/wasm-component/spec --qemu-host-endpoints
```

The host suite checks typed delivery in both directions, a guest
continuation resumed by a host write, waitable events, zero-length
readiness, cancellation and retry of resource payloads, nested
endpoint ownership, and recovery after a guest realloc trap. The QEMU
probe starts a host-owned unit write and drains it with two guest
reads. It uses the standard LP RAM layout.

| QEMU host-owned unit stream | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 11,840 bytes | 4,104 bytes |
| D0 | 48,008 bytes | 7,280 bytes |
| LP | 6,152 bytes | 3,488 bytes |

The same probe can be cross-linked with the native scalar fixture.
It reports `0x57484500` on success.

```sh
for profile in m0 lp d0-dram d0-xip; do
  core="${profile%%-*}"
  link_flags=()
  case "$profile" in
    lp) link_flags=(-d:WasmLpNativeStackBytes=3968
      --passL:-Wl,--defsym=__bl808_lp_stack_bytes=3968) ;;
    d0-dram) link_flags=(--passC:-flto
      '--passL:-flto -Wl,--undefined=trap_entry,--undefined=main,--undefined=memcpy') ;;
    d0-xip) link_flags=(-d:bl808D0Xip) ;;
  esac
  nim c -d:bl808"$core" -d:bl808kernel -d:bl808WasmFull \
    -d:wasmComponentAsyncCallbacks -d:wasmComponentStreams \
    -d:wasmComponentHostEndpoints -d:wasmComponentHostEndpointFirmware "${link_flags[@]}" \
    --nimcache:build/wasm-component/host-endpoint/"$profile"-cache \
    --out:build/wasm-component/host-endpoint/"$profile".elf \
    examples/wasm_component_scalar_build_test.nim
done
```

The M0, LP, D0 DRAM, and D0 XIP firmware profiles cross-link.
The LP image reserves 532 bytes of `.data`, 2,212 bytes of `.bss`,
9,672 bytes of heap, and 3,968 bytes of native stack. Ox64 execution
remains pending.

### Cooperative guest threads

`-d:wasmComponentThreads` extends the stackful profile with
`thread.index`, `thread.new-indirect`, `thread.resume-later`, and
the suspend, resume, and promote operations for guest continuations.
Each explicit thread starts suspended and uses a private interpreter
arena on its component's core. The scheduler runs an immediate switch
after saving the current guest frames. A thread may resolve its task
after the implicit entry has exited. The i32 context slots are private
to each thread.
[Pinned Canonical ABI threads](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#threads)

The thread registry is bounded to 3 entries on LP and 32 elsewhere.
Indices belong to the current component instance. An exhausted
explicit creation returns `-1`. Invalid table entries, unassigned
indices, and attempts to switch to the current thread trap. The local fixture
tests both a parent-child handoff and task resolution by a queued
worker. The upstream selection covers ready-callback promotion and
cancellation during a switch.

A synchronous lift drives ready threads in its own component instance
until its implicit thread returns. The lift traps if it is still waiting
and that instance has no ready threads. The worker's continuation can
complete a nested synchronous lower, waitable, future, stream, or subtask
cancellation. Guest resource destructors use the same scheduling rule
with a fresh thread and zeroed context slots. The pinned tests exercise
these operations, callback-exclusive resumption, and sibling isolation.
[Pinned Canonical ABI synchronous lift](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#canon-lift)

```sh
python3 tools/run_wasm_component_spec.py build/wasm-component/spec \
  --qemu-guest-threads --host-endpoints
```

The run passes 1,196 host checks from the pinned corpus and local fixtures.
The memoryless target probes run sequentially. One exits its implicit
thread and uses `pollComponentTasks` to deliver the queued worker's result.
The other yields from a synchronous export and returns the value written
by its worker. Each probe loads a separate module to fit LP's decode budget.

| QEMU guest thread probe | Peak heap | Peak native stack |
| --- | ---: | ---: |
| M0 | 14,776 bytes | 4,308 bytes |
| D0 | 52,712 bytes | 6,720 bytes |
| LP | 9,232 bytes | 3,476 bytes |

The corresponding firmware probe reports `0x57544800` on success.

```sh
for profile in m0 lp d0-dram d0-xip; do
  core="${profile%%-*}"
  link_flags=()
  case "$profile" in
    d0-dram) link_flags=(--passC:-flto
      '--passL:-flto -Wl,--undefined=trap_entry,--undefined=main,--undefined=memcpy') ;;
    d0-xip) link_flags=(-d:bl808D0Xip) ;;
  esac
  nim c -d:bl808"$core" -d:bl808kernel -d:bl808WasmFull \
    -d:wasmComponentAsyncCallbacks -d:wasmComponentStackful \
    -d:wasmComponentThreads -d:wasmComponentGuestThreadsFirmware "${link_flags[@]}" \
    --nimcache:build/wasm-component/guest-threads/"$profile"-cache \
    --out:build/wasm-component/guest-threads/"$profile".elf \
    examples/wasm_component_scalar_build_test.nim
done
```

The M0, LP, D0 DRAM, and D0 XIP profiles cross-link. The LP firmware
reserves 644 bytes of `.data`, 2,212 bytes of `.bss`, 9,432 bytes of
heap, and 4,096 bytes of native stack. Ox64 execution remains pending.

### Cooperative phase-two spawning

`-d:wasmComponentThreadSpawn` adds cooperative `thread.spawn-ref` and
`thread.available-parallelism` to the existing guest-thread scheduler. It
requires `-d:wasmFunctionReferences` and the guest-thread flags above.
The spawn import has a nullable reference to the declared core entry type.
It queues the worker on the current component's core and passes it the
i32 closure argument. The registry traps on spawn capacity exhaustion.
`thread.available-parallelism` returns one for this cooperative profile.
[Pinned Canonical ABI](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#-canon-threadspawn-ref)

```sh
python3 tools/run_wasm_component_spec.py build/wasm-component/spec \
  --qemu-thread-spawn --error-context --host-endpoints
```

The fixture uses toolchain-generated core and component sections and emits
the pinned sharedness immediates in the canonical section. `wasm-tools
1.263.0` uses an earlier spelling and binary encoding for these operations.
The runner validates the embedded core module with that tool before
running the pinned component. The tests cover deferred execution, closure
delivery, null and capacity traps, and rejection of a legacy encoding,
invalid sharedness, an unknown type, and an erased `funcref` import.
[Pinned binary format](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/Binary.md)

Both fixtures run sequentially on each QEMU profile. The combined fixture
exceeded the LP heap, so spawning and parallelism use separate component
instances within the same 16 KiB writable layout.

| QEMU profile | Peak heap | Native stack used |
| --- | ---: | ---: |
| M0 RV32 | 13,632 B | 4,456 B |
| D0 RV64 | 50,904 B | 7,408 B |
| LP RV32E | 8,128 B | 3,792 B |

`thread.spawn-indirect` requires a shared core table. Its cooperative form
also requires an unshared element heap type, while the pinned core draft
requires a shared heap type in a shared table. The preemptive form requires
a preemptive execution backend. The interpreter gates both forms and
shared `thread.spawn-ref`. The host fixture exercises rejection of an
ordinary `funcref` table.
[Pinned table requirement](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#-canon-threadspawn-indirect)

The opt-in core interpreter supports shared function types, tables, and
globals. The Component Model host gate checks a core module type ascription,
links an explicitly initialized shared table and typed shared globals to
a second core module, and calls both references through a Canonical ABI lift.
The lifted call also updates an imported shared integer with an atomic add
and atomically loads a provider-initialized byte from an imported shared memory.
Enable this check with
`--shared-core-types` on `tools/run_wasm_component_spec.py`.
[Shared core function types, tables, and globals](wasm_full_baseline.md#shared-core-function-types-tables-and-globals)

The `--atomic-wait` baseline gate validates a component that imports shared
core memory and starts a sibling with `canon thread.new-indirect` and
`canon thread.resume-later`. The first guest thread parks in
`memory.atomic.wait32`. The sibling writes a result and notifies the waiter
through that memory. The lifted call returns 42 after the first guest
resumes. Both threads execute in the existing cooperative component
scheduler.
[Atomic wait gate](wasm_full_baseline.md#cooperative-atomic-wait-and-notify)

For the native probe, add `-d:wasmFunctionReferences
-d:wasmComponentThreadSpawn` to the guest-thread build commands and use
`-d:wasmComponentThreadSpawnFirmware` in place of
`-d:wasmComponentGuestThreadsFirmware`. The probe reports `0x57535000` on
success at the existing Component Model status address. D0 DRAM uses the
link-time optimization flags above and reserves 62,432 bytes of heap.
The LP image reserves 644 bytes of `.data`, 2,212 bytes of `.bss`,
9,432 bytes of heap, and 4,096 bytes of stack. Physical Ox64 execution
remains pending.

Native stacks and host wait closures are
core-local. Live Component Model migration needs a portable representation
of the guest continuations and their resources.
[Pinned binary format](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/Binary.md)

## Error contexts

`-d:wasmComponentErrorContext` enables the `error-context` WIT type and the
three canonical builtins. The guest sees a bounded i32 handle in the
instance's canonical handle table. Lifting an error context preserves the
source handle. Lowering creates a handle in the destination that refers to
the same immutable value. Resource, waitable, and error-context handle kinds
are checked independently. Closing an instance releases its handles.

The default error-context policy discards guest debug messages at creation,
as permitted by the pinned Canonical ABI. With
`-d:wasmComponentErrorContextMessages`, the VM reads, validates, and retains
the guest message using the selected canonical string encoding and the
existing string limits. Host code can construct an error context with
`componentErrorContext` and inspect it with `componentErrorContextMessage`.
The debug-message builtin validates its memory32 return area before calling
canonical `realloc` to write the encoded string.
[Pinned error-context ABI](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md#-canon-error-contextnew)

```sh
python3 tools/run_wasm_component_spec.py build/wasm-component/spec \
  --qemu-error-context --guest-threads --host-endpoints
```

The command checks feature gating and invalid canonical options,
builds a component from WIT, and checks host values, records, inter-component
calls, typed futures, invalid handles, and handle capacity. The QEMU fixture
runs all three builtins as directly lifted exports using one resident
512-byte memory chunk. Its LP profile reserves 4,608 bytes of native stack
within the 16 KiB writable layout.

| QEMU CPU profile | Peak heap | Native stack used |
| --- | ---: | ---: |
| M0 | 14,232 bytes | 4,496 bytes |
| D0 | 51,392 bytes | 7,744 bytes |
| LP | 8,752 bytes | 4,536 bytes |

The native probe is `examples/wasm_component_scalar_build_test.nim` with
`-d:bl808kernel -d:bl808WasmFull -d:wasmChunkedMemory
-d:WasmMemoryChunkBytesConfig=512 -d:wasmComponentErrorContext
-d:wasmComponentErrorContextFirmware`. For LP use
`-d:WasmLpNativeStackBytes=4608` and
`--passL:-Wl,--defsym=__bl808_lp_stack_bytes=4608`. It cross-links
with 364 bytes of `.data`, 2,212 bytes of `.bss`, and 9,200 bytes
of heap on LP. The probe reports `0x57454300` on success. Device
execution and device high-water measurements remain pending.

## WIT-generated fixtures and target coverage

```sh
python3 tools/run_wasm_component.py --qemu --qemu-string --qemu-record \
  --qemu-variant --qemu-words --qemu-qwords --qemu-option-string
python3 tools/run_wasm_component.py --qemu-core-graph
python3 tools/run_wasm_component.py --qemu-core-module
python3 tools/run_wasm_component.py --qemu-definition-relay
python3 tools/run_wasm_component.py --qemu-outer-capture
python3 tools/run_wasm_component.py --qemu-nested-instance
python3 tools/run_wasm_component.py --qemu-interface
python3 tools/run_wasm_component.py --qemu-typed-imports
python3 tools/run_wasm_component.py --qemu-resource
python3 tools/run_wasm_component.py --qemu-foreign-borrow
python3 tools/run_wasm_component.py --qemu-resource-bundle
python3 tools/run_wasm_component.py --qemu-indirect
python3 tools/run_wasm_component.py --qemu-flat-aggregates
python3 tools/run_wasm_component.py --qemu-nested-list
python3 tools/run_wasm_component.py --qemu-nested-value
nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --path:src \
  --checks:on --assertions:on tools/test_wasm_component_resources.nim
```

The host suite uses `wasm-tools component embed` and `component new` for WIT
fixtures and `wasm-tools validate` to check the binaries. It covers typed
memory-backed imports and string results through the generated shim and fixup
modules. Other cases exercise large integer and mixed scalar layouts, post-return,
and the three string encodings, including tagged length, UTF-16 surrogate pairs,
and invalid alignment. A separate regression reenters the interpreter from a
host call and forces both the value and locals arenas to grow before returning.
The component graph test shares a memory, a global, a table and functions on
the host and the M0 and D0 QEMU targets. The LP fixture links two modules
that use the same memory instance, using the same linker and interpreter. This
smaller fixture passed in QEMU within LP's 16 KiB writable budget.

The core-module gate executes a host-supplied module on all three QEMU
profiles. M0 and D0 execute both typed component relays. LP aliases a module
exported through an annotated instance in a child component and runs it on
the same interpreter. The LP QEMU layout reserves 5,120 bytes for the stack
within its 16 KiB writable region. Its `.data`, `.bss` and available heap
are 392, 2,004 and 8,832 bytes. The D0 suite uses a 16 KiB QEMU stack, and its
measured use exceeds the 8 KiB D0 firmware default.

| Core-module QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0, host module and both typed relays | 31,488 | 5,568 |
| D0, host module and both typed relays | 79,848 | 9,168 |
| LP, host module and child instance module | 7,968 | 4,832 |

The definition relay gate runs the forwarding and independent-state
fixtures for component and instance members on M0 and D0 with 16 KiB of
reserved native stack. LP runs two smaller fixtures that instantiate and
call an annotated definition export, including one carried by an instance.
The LP case stays within the 16 KiB writable layout with a 4,928-byte stack
reservation. The D0 relay and LP export exceed the current firmware stack
reservations of 8,192 and 4,096 bytes, respectively.

| Component definition QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0, both definition relays | 44,104 | 5,760 |
| D0, both definition relays | 159,256 | 9,360 |
| LP, both annotated definition exports | 7,616 | 4,400 |

The outer-capture gate runs two sets of captured imports through a
two-scope relay on M0 and D0. LP runs separate one-scope captures of a
component definition and a core module within the 16 KiB layout, with
a 4,096-byte stack. A combined LP graph used 13,720 bytes of heap and
3,948 bytes of stack in an expanded-RAM diagnostic, so that graph
exceeds LP's writable budget before static data. D0's two-scope relay
uses an emulator reservation of 16 KiB for its stack.

| Outer capture QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0, two-scope relay | 52,872 | 6,544 |
| D0, two-scope relay | 203,192 | 10,880 |
| LP, separate component and module captures | 9,168 | 3,812 |

The nested instance gate runs resource aliases, typed substitution, and the
lexically captured resource fixture on M0 and D0. LP runs the smaller
annotated nested export and calls its core-backed function through the nested
host API. The LP test reserves a 4,096-byte stack within 16 KiB of writable
memory.

| Nested instance QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0, three nested fixtures | 54,520 | 5,952 |
| D0, three nested fixtures | 174,744 | 9,576 |
| LP, annotated nested export | 4,144 | 3,304 |

The D0 QEMU suite reserves 16 KiB of stack. Its observed stack use exceeds
the default 8 KiB D0 firmware stack.

The named interface fixture uses `wasm-tools component embed`, `component new`
and `compose --no-imports` to connect a WIT consumer to a separate provider.
The host gate exercises the composed component and the consumer with an
explicit host provider. It also checks that a standalone callback cannot
fulfill an instance import and that a method with a mismatched type is
rejected. M0 and D0 run the composed consumer and provider. LP runs the same
generated consumer with its explicit host provider within 16 KiB.
The host also invokes a named WIT record through its generated export shim and
rejects an instance whose required record has a different field name.

| Named interface QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0, composed | 29,848 | 5,616 |
| D0, composed | 105,584 | 8,384 |
| LP, consumer with host binding | 9,696 | 3,436 |

The LP named-interface QEMU runner reserves 3,712 stack bytes within its
16 KiB test layout. Firmware stack defaults are unchanged.

The typed import gate runs the same host consumer and provider on M0, D0, and
the expanded LP diagnostic. M0 and D0 also execute nominal resource fixtures
and link the WIT-generated arithmetic provider through a contract that
imports `bias` and exports `arithmetic`. The M0 and D0 emulator builds
reserve 16 KiB of native stack.

| Typed import QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0, host-supplied definition | 28,976 | 4,536 |
| D0, host-supplied definition | 104,704 | 7,456 |
| LP, host-supplied definition, 32 KiB diagnostic | 18,000 | 4,624 |
| M0, typed resource and interface imports | 54,616 | 5,344 |
| D0, typed resource and interface imports | 174,688 | 8,384 |

The LP host-definition heap peak alone exceeds its 16 KiB firmware RAM.
The diagnostic uses a 6,144-byte stack reservation. Admission of typed
definitions under the physical LP budget remains open.

The resource fixture uses the WIT-generated `counters` interface and
exercises construction, a borrowed method, and the guest destructor. The
host gate also checks rejection of resources from a second instance and
rejection of a stale borrow. M0 and D0 run the generated component. An LP
diagnostic run of a compact named resource interface used 13,448 bytes of
peak heap and 3,216 bytes of stack before static data. That exceeds the
16 KiB layout even with no destructor callback in the fixture.
The LP regression uses a direct resource export. It constructs a resource
through a local nominal alias, returns the owner through an aliased handle
type, checks borrowed access, and rejects the borrow after dropping its owner.

| Resource QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0, WIT-generated interface | 24,160 | 3,808 |
| D0, WIT-generated interface | 66,784 | 6,464 |
| LP, direct resource export | 7,160 | 3,356 |

The cross-guest borrow fixture lends the same resource twice, checks reuse
of the receiver's handle slot, and verifies that the lender still owns the
resource. A host test also leaves the receiver's borrow live and verifies
that the return traps and locks the component graph.

| Cross-guest borrow QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0 | 29,768 | 5,400 |
| D0 | 104,984 | 9,200 |
| LP, expanded 32 KiB run | 18,760 | 5,024 |

The 582-byte fixture exceeds LP's 16 KiB writable budget. A 313-byte
two-component test also exceeded the budget during LP diagnostics. The
`--qemu-foreign-borrow` option uses the same full fixture on each CPU and
expands the LP QEMU layout for semantics testing. Other LP component fixtures
retain the 16 KiB gate.

The WIT resource bundle passes a record containing `list<own<ticket>>` and
an `option<borrow<ticket>>`. It checks that the original owners are consumed
and that dropping the returned owners invokes the ticket destructor. Host
checks reject a repeated owner and a ticket from another instance. A linked
guest fixture moves a list of owners across two separate memories and back,
then passes and releases a scoped optional borrow. Reusing the same guest
owner in two list elements traps.

| Resource bundle QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0, WIT-generated | 40,384 | 5,280 |
| D0, WIT-generated | 91,672 | 7,904 |
| M0, linked guests | 36,144 | 6,848 |
| D0, linked guests | 114,752 | 10,080 |

The M0 and D0 QEMU images use one 512-byte resident chunk per memory and
reserve 16 KiB of stack for these fixtures. The
1,712-byte WIT-generated fixture and linked guest fixture exceed the 768-byte
LP component admission limit. The LP resource checks use the direct-resource
fixture and the separate foreign-borrow diagnostic.

The indirect fixture is built from a WIT signature with a 17-element
mixed-width tuple parameter and a two-element tuple result. On M0 and D0
QEMU the parameter allocation straddles a 512-byte chunk boundary, and a
lowered import reads the parameters and writes into a caller-provided return
area. The LP fixture invokes a lifted function with the same WIT signature
and a single resident chunk. The host also verifies an out-of-bounds
parameter area traps before the callback runs. Target admission limits are
32 declared parameters, 32 record or tuple fields, and a 4 KiB indirect
parameter area.

| Indirect Canonical ABI QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0, lift and lower | 18,032 | 4,056 |
| D0, lift and lower | 57,248 | 7,072 |
| LP, lift | 7,320 | 3,536 |

The flat-call WIT fixture checks a mixed-width tuple and both cases of a
`result<f32, u64>`. M0 and D0 also pass `option<string>` and `list<u32>`
through the guest's memory. The host checks that an invalid discriminant
traps before the callback is invoked. The LP fixture uses the same flat
tuple and variant conventions with four core parameter lanes.

| Flat aggregate QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0, mixed aggregate parameters | 20,512 | 4,228 |
| D0, mixed aggregate parameters | 60,616 | 7,040 |
| LP, tuple and variant parameters | 8,632 | 4,064 |

String and list copies are capped at 4 KiB. The component binary cap is 768 bytes
on LP, 4 KiB on M0 and 64 KiB on D0. LP also limits the supported graph to four
core module definitions and eight type and function indices. Those caps are
profile admission limits and do not by themselves establish that a module fits
the heap. The larger memory, table and global graph exceeded LP's isolated
16 KiB test budget.

Historical QEMU measurements from 2026-11-22:

| Core | Scalar heap/stack | String input heap/stack | String result heap/stack | Byte list heap/stack | Record heap/stack |
| --- | ---: | ---: | ---: | ---: | ---: |
| M0 | 15,160 / 3,608 | 12,656 / 3,360 | 14,152 / 3,504 | 14,584 / 3,512 | 15,008 / 3,960 |
| D0 | 52,984 / 6,592 | 48,912 / 6,112 | 51,256 / 6,368 | 51,760 / 6,368 | 52,464 / 7,056 |
| LP | 9,656 / 3,460 | 7,168 / 3,244 | 8,664 / 3,372 | 9,104 / 3,400 | 9,480 / 3,840 |

The mixed-width record case used heap/stack bytes of 12,248/3,696 on M0,
48,376/6,640 on D0, and 6,760/3,580 on LP.

The integer-list cases encode each element as little-endian, request four- or
eight-byte alignment from canonical realloc, reject misaligned pointers and
oversized results, and cap the payload at 4 KiB (1,024 `u32` or 512 `u64`
elements). The 2026-11-23 QEMU `list<u32>` heap/stack observations were M0
12,864/3,424, D0 49,064/5,424, and LP 7,376/3,368 bytes. For `list<u64>`,
they were M0 12,864/3,440, D0 49,064/5,424, and LP 7,376/3,376 bytes.

The WIT-generated nested-list case round-trips `list<list<string>>`,
including empty lists, empty strings, and multi-byte Unicode. Host checks
cover an unaligned inner pointer, an excessive element count, an
out-of-bounds inner payload, and a second call after each lift trap. The
typed linking checks also reject a mismatched list element type and accept a
list declared with an externally visible named record.

| Nested-list QEMU fixture | Peak heap | Peak stack |
| --- | ---: | ---: |
| M0 | 13,312 | 4,464 |
| D0 | 49,696 | 6,864 |
| LP | 7,824 | 4,220 |

The LP fixture uses one 512-byte resident chunk and reserves 4,352 stack
bytes. Its writable sections and alignment padding fit within 16 KiB.

The nested-value WIT fixture passes a record containing an
`option<tuple<string, u64>>` and a trailing `u8`. It checks that lowering
uses five flat lanes and zero-fills the absent payload, and that lifting
reads the return area with eight-byte alignment. A separate WIT-generated
host import fixture reads the same flat argument, returns it through the
caller's return area, and lifts that result in the guest export.

| Nested-value QEMU fixture | Peak heap | Peak stack | Stack reserved |
| --- | ---: | ---: | ---: |
| M0 | 13,872 | 5,536 | 8,192 |
| D0 | 50,808 | 8,256 | 12,288 |
| LP | 8,376 | 4,948 | 4,960 |

The `option<string>` case lowers a present string to discriminant, pointer,
and length, returns an option through a bounds-checked 12-byte canonical
result area, and rejects a result whose string points beyond guest memory.
The latest LP QEMU fixtures measured these heap and stack peaks within the
16 KiB layout:

| LP QEMU fixture | Peak heap | Peak stack | Stack reserved |
| --- | ---: | ---: | ---: |
| `option<string>` | 9,080 | 4,148 | 4,224 |
| Two core modules using one memory instance | 6,864 | 3,624 | 4,096 |
| Scalar record | 9,104 | 3,732 | 4,096 |

The M0 and D0 QEMU tests run the pinned upstream nested Boolean case. The
smaller LP fixture runs a parent and child VM and checks the same nonzero
Boolean normalization at the guest-to-guest boundary. The upstream fixture
used 15,168 bytes of LP heap and 4,640 bytes of LP stack in a diagnostic run
with an expanded RAM layout, so it exceeds the physical layout before static
data. These are emulator measurements for isolated fixtures.

| Nested Boolean QEMU fixture | Peak heap | Peak stack | Stack reserved |
| --- | ---: | ---: | ---: |
| M0, pinned upstream | 25,104 | 4,960 | 16,384 |
| D0, pinned upstream | 98,112 | 8,272 | 16,384 |
| LP, reduced fixture | 8,776 | 4,656 | 4,928 |

D0's 8 KiB firmware stack and the 4 KiB LP component examples require
different stack reservations for the tested nested workloads. The QEMU
stack allocations do not change firmware defaults.

`python3 tools/run_wasm_component.py --qemu-function-equality` exercises
equality-bound function types. M0 and D0 run a component that aliases a
function type referencing a named record, passes it through a typed component
argument, and calls the linked guest method. LP runs a scalar instance alias
and direct type argument with an explicit export ascription. Host fixtures also
reject a hidden record type, a mismatched parameter name, an unrelated nominal
resource, and an incompatible export ascription.

| Function type equality QEMU fixture | Peak heap | Peak stack | Stack reserved |
| --- | ---: | ---: | ---: |
| M0 | 43,576 | 5,360 | 16,384 |
| D0 | 157,256 | 9,232 | 16,384 |
| LP, scalar fixture | 5,240 | 3,924 | 4,096 |

`python3 tools/run_wasm_component.py --qemu-contract-equality` exercises
equality-bound component types. The M0 and D0 fixture supplies a component
type with extra exports, forwards it through a typed relay and instance alias,
imports a definition under the resulting type, and invokes the linked method.
The LP fixture exercises an explicit export ascription and type argument with
the same linker. Host cases also check that the ascription hides extra members,
that two aliases of a freshly declared resource preserve its identity, and
that a contract cannot use an outer record name without naming it locally.

| Component type equality QEMU fixture | Peak heap | Peak stack | Stack reserved |
| --- | ---: | ---: | ---: |
| M0, typed relay | 21,424 | 4,752 | 16,384 |
| D0, typed relay | 64,760 | 8,192 | 16,384 |
| LP, type argument | 6,608 | 3,984 | 4,096 |

The LP fixture fit within 16 KiB and used all but 112 bytes of its stack
reservation. Device stack and heap high-water measurements are still pending.

`python3 tools/run_wasm_component.py --qemu-instance-equality` exercises
equality-bound instance types. The M0 and D0 fixture forwards an instance
type through a typed component relay, uses an alias of that type to link an
instance import, and calls the imported method. LP uses an explicit export
ascription and supplies an aliased instance type as a type argument. Host
cases exercise nested captures rebased through a typed component relay and
reject incompatible signatures, unrelated abstract resources, and captured
local resources without an actual resource export.

| Instance type equality QEMU fixture | Peak heap | Peak stack | Stack reserved |
| --- | ---: | ---: | ---: |
| M0, typed relay | 22,920 | 5,128 | 16,384 |
| D0, typed relay | 67,440 | 8,784 | 16,384 |
| LP, type argument | 6,896 | 4,080 | 4,608 |

The LP fixture stayed within the 16 KiB layout with 528 bytes of stack
headroom. The D0 fixture exceeded the default firmware stack size in
QEMU, which reserved 16 KiB for this run.

`python3 tools/run_wasm_component.py --qemu-contract-capture` tests a typed
component bound to an enclosing resource. M0 and D0 run a guest borrow,
release the borrow in the provider, and drop the owner in the caller. The LP
fixture passes an equality-bound resource into the provider and invokes its
scalar export. Host fixtures also check two nested contract scopes and reject
a mismatched provider, a mismatched type argument, an unnamed resource in a
signature, and a missing export of the enclosing resource.

| Contract resource capture QEMU fixture | Peak heap | Peak stack | Stack reserved |
| --- | ---: | ---: | ---: |
| M0, guest borrow | 29,576 | 5,312 | 16,384 |
| D0, guest borrow | 105,352 | 8,176 | 16,384 |
| LP, type binding | 8,376 | 3,896 | 4,096 |

The LP fixture fit within 16 KiB, with 200 stack bytes available at the
observed high-water mark. The D0 run used nearly the entire default 8 KiB
firmware stack reservation. Both figures are emulator observations.

`python3 tools/run_wasm_component.py --qemu-lexical-resource-value` runs
outer component values that capture an enclosing nominal resource. The M0
and D0 fixture instantiates the same owner definition twice, forwards each
provider through an ascribed relay, and checks the two destructor counters.
The LP fixture instantiates a forwarded component with its captured resource
argument before running the root scalar export. The host gate also tests
relaying an earlier child's resource across two levels, a private capture
inside an externally closed component, and rejection of a resource supplied
by the wrong owner.

| Outer component value resource QEMU fixture | Peak heap | Peak stack | Stack reserved |
| --- | ---: | ---: | ---: |
| M0, two resource owners | 83,872 | 5,664 | 16,384 |
| D0, two resource owners | 279,056 | 9,856 | 16,384 |
| LP, captured type argument | 10,736 | 3,048 | 3,136 |

D0 needed a 288 KiB QEMU heap reservation for this fixture. The two-owner
fixture exceeds the heap in the default M0 and D0 example firmware builds.
LP's fixture used the existing 16 KiB total with an 80-byte heap margin
and 88 bytes of stack headroom. These are QEMU settings and measurements.

The remaining synchronous upstream cases and LP admission for larger typed
definitions and cross-guest resource calls within 16 KiB remain open.
Keep the path opt-in until hardware validation covers the firmware and its
RAM margins.

The string-result, record, nested-list, and nested-value entries cross-link
as separate M0, D0, and LP firmware images with the same decoder and interpreter. Add
`-d:wasmComponentRecordFirmware` to select the record fixture and status
prefix `0x57524300`, `-d:wasmComponentNestedListFirmware` for the nested-list
fixture and status prefix `0x574E4C00`, or `-d:wasmComponentNestedValueFirmware`
for the nested-value fixture and status prefix `0x574E5600`. On M0 and D0,
`-d:wasmComponentResourceBundleFirmware` builds the WIT-generated resource
bundle with status prefix `0x57524200`.

```sh
for core in m0 d0 lp; do
  nim c -d:bl808$core -d:bl808kernel -d:bl808WasmFull \
    -d:wasmChunkedMemory -d:WasmMemoryChunkBytesConfig=512 \
    --nimcache:build/wasm-component/firmware-$core-cache \
    --out:build/wasm-component/firmware-$core.elf \
    examples/wasm_component_string_result_build_test.nim
done
```

The latest LP string-result firmware link has 336 bytes `.data`, 2,728 bytes
`.bss`, 9,224 bytes of heap and a 4,096-byte stack in its 16 KiB writable
region. The string
firmware entry writes status `0x57435200` after both greetings. The record
entry writes `0x57524300` after both exports.

Add `--passL:-Wl,--defsym=__bl808_lp_stack_bytes=4960` to the LP nested-value
build. It links with 280 bytes `.data`, 2,728 bytes `.bss`, 8,416 bytes of heap
and a 4,960-byte stack. The opt-in D0 nested-value entry reserves 12,288 stack
bytes. Device measurements are pending for all these entries.
