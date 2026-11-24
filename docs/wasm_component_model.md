# Component Model implementation status

The target is the synchronous [Component Model 0.2 MVP binary format](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/Binary.md) and [Canonical ABI](https://github.com/WebAssembly/component-model/blob/585526aa1f2c7f76f07557d16e265dede38b3acb/design/mvp/CanonicalABI.md) at spec revision `585526aa1f2c7f76f07557d16e265dede38b3acb`, with `wasm-tools 1.263.0` generating and validating the test components. The decoder accepts the component binary header `00 61 73 6d 0d 00 01 00`. `ComponentVersion` and `ComponentSpecRevision` in `src/cps/wasm/component.nim` name this target. This is an incremental implementation, not yet full conformance to the proposal.

`src/cps/wasm/component.nim` validates and links multiple embedded core modules
within one component using the full interpreter's store. Core functions, tables,
memories, globals and exception tags link by identity. A module importing mutable state sees
changes made by the other module. The linker validates the full core graph before
running guest start functions. The decoder accepts valid empty components and
checks kebab-case labels, name collisions, and qualified interface name syntax.

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
The pinned revision passed 465 checks across 35 instantiations, 37
definition validations, 258 rejections, 100 return assertions and 35 trap
assertions. The 35 selected `values/concat.wast` returns cover the upstream
aggregate fixture. The second fixture, which uses maps, is excluded.
The generated core function cases exercise lifting `resource.drop` through
resource visibility and identity rules.
The `resources/borrows.wast`, `resources/multiple-resources.wast`, and
`resources/handle-table.wast` runtime files run in full. All 11 cases in
`validation/core-modules.wast` run. The runner also covers the full
`linking/tags.wast` and `validation/defined-types.wast` files.
The core memory variance case in
`validation/instantiation.wast` that declares two memories remains outside
the interpreter's single-memory profile.
The runner prints the number of excluded cases per selected WAST file.

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
```

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
around one shared linear memory, using the same linker and interpreter. This
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
| Two core modules with shared linear memory | 6,864 | 3,624 | 4,096 |
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
| M0, typed relay | 22,296 | 4,752 | 16,384 |
| D0, typed relay | 65,944 | 8,192 | 16,384 |
| LP, type argument | 6,880 | 3,984 | 4,096 |

The LP fixture stayed within the 16 KiB layout with 112 bytes of stack
headroom. The D0 fixture reached the size of the default firmware stack in
the emulator, which reserved 16 KiB for this run.

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

The latest LP string-result firmware link has 392 bytes `.data`, 2,728 bytes
`.bss`, 9,168 bytes of heap and a 4,096-byte stack in its 16 KiB writable
region. The string
firmware entry writes status `0x57435200` after both greetings. The record
entry writes `0x57524300` after both exports.

Add `--passL:-Wl,--defsym=__bl808_lp_stack_bytes=4960` to the LP nested-value
build. It links with 280 bytes `.data`, 2,728 bytes `.bss`, 8,416 bytes of heap
and a 4,960-byte stack. The opt-in D0 nested-value entry reserves 12,288 stack
bytes. Device measurements are pending for all these entries.
