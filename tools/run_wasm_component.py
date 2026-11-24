#!/usr/bin/env python3
"""Build a real WIT-derived component and exercise the shared VM's scalar path."""

import argparse
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "wasm-component"


CORES = {
    "m0": ("riscv32", "rv32imafc", "ilp32f", "rv32,m=true,f=true,c=true"),
    "d0": ("riscv64", "rv64imafdc", "lp64d", "rv64,m=true,a=true,f=true,d=true,c=true"),
    "lp": ("riscv32", "rv32emc_zicsr", "ilp32e", "rv32e,m=true,c=true,zicsr=true"),
}


def run(*args, timeout=None):
    try:
        return subprocess.run(args, cwd=ROOT, check=True, text=True,
                              capture_output=True, timeout=timeout).stdout
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"command failed: {' '.join(map(str, args))}\n"
                           f"{exc.stdout[-2000:]}\n{exc.stderr[-4000:]}") from exc


def check_qemu(core, cpu, march, abi, model, string=False, string_result=False,
               bytes_case=False, words_case=False, record_case=False, mixed_case=False,
               option_case=False, variant_case=False, enum_case=False,
               result_case=False, tuple_case=False, flags_case=False,
               char_case=False, qwords_case=False,
               option_string_case=False, core_graph_case=False, nested_case=False,
               interface_case=False, resource_case=False, indirect_case=False,
               flat_case=False, nested_list_case=False, nested_value_case=False,
               foreign_borrow_case=False, resource_bundle_case=False,
               linked_resource_bundle_case=False, typed_import_case=False,
               host_definition_case=False, core_module_case=False,
               definition_relay_case=False, nested_instance_case=False, outer_capture_case=False,
               function_equality_case=False, contract_equality_case=False,
               instance_equality_case=False, contract_capture_case=False,
               lexical_resource_value_case=False, local_lower_case=False,
               generated_core_case=False, cross_post_return_case=False, tag_case=False):
    linker = "tools/wasm_full_qemu.ld" if core == "lp" else "tools/wasm_full_qemu_large.ld"
    label = "core-graph" if core_graph_case else "option-string" if option_string_case else "qwords" if qwords_case else "words" if words_case else "char" if char_case else "flags" if flags_case else "tuple" if tuple_case else "result" if result_case else "enum" if enum_case else "variant" if variant_case else "option" if option_case else "record-mixed" if mixed_case else "record" if record_case else "bytes" if bytes_case else "string-result" if string_result else "string" if string else "scalar"
    if nested_case:
        label = "nested-bool"
    if interface_case:
        label = "named-interface"
    if resource_case:
        label = "resource"
    if indirect_case:
        label = "indirect"
    if flat_case:
        label = "flat-aggregates"
    if nested_list_case:
        label = "nested-list"
    if nested_value_case:
        label = "nested-value"
    if foreign_borrow_case:
        label = "foreign-borrow"
    if resource_bundle_case:
        label = "resource-bundle"
    if linked_resource_bundle_case:
        label = "linked-resource-bundle"
    if typed_import_case:
        label = "typed-import"
    if host_definition_case:
        label = "host-definition"
    if core_module_case:
        label = "core-module"
    if definition_relay_case:
        label = "definition-relay"
    if nested_instance_case:
        label = "nested-instance"
    if outer_capture_case:
        label = "outer-capture"
    if function_equality_case:
        label = "function-equality"
    if contract_equality_case:
        label = "contract-equality"
    if instance_equality_case:
        label = "instance-equality"
    if contract_capture_case:
        label = "contract-capture"
    if lexical_resource_value_case:
        label = "lexical-resource-value"
    if local_lower_case:
        label = "local-lower"
    if generated_core_case:
        label = "generated-core"
    if cross_post_return_case:
        label = "cross-post-return"
    if tag_case:
        label = "tag-link"
    elf = OUT / f"component-{label}-qemu-{core}.elf"
    memory_flags = ""
    lp_ram_bytes = 32768 if foreign_borrow_case or host_definition_case or cross_post_return_case else 16384
    if core == "lp":
        if nested_case or definition_relay_case:
            stack = 4928
        elif interface_case:
            stack = 3712
        elif core_module_case:
            stack = 5120
        elif nested_value_case:
            stack = 4960
        elif foreign_borrow_case:
            stack = 6656
        elif host_definition_case:
            stack = 6144
        elif option_string_case:
            stack = 4224
        elif nested_list_case:
            stack = 4352
        elif lexical_resource_value_case:
            stack = 3136
        elif local_lower_case:
            stack = 6400
        elif cross_post_return_case:
            stack = 8192
        else:
            stack = 4096
        memory_flags = f"-Wl,--defsym=__qemu_lp_stack_override={stack} "
        if lp_ram_bytes != 16384:
            memory_flags += f"-Wl,--defsym=__qemu_lp_ram_override={lp_ram_bytes} "
    elif core == "d0" and nested_value_case:
        memory_flags = "-Wl,--defsym=__qemu_stack_override=12288 "
    elif (nested_case or interface_case or resource_case or foreign_borrow_case or
          resource_bundle_case or linked_resource_bundle_case or typed_import_case or
          host_definition_case or core_module_case or definition_relay_case or nested_instance_case or
          outer_capture_case or function_equality_case or contract_equality_case or instance_equality_case or
          contract_capture_case or lexical_resource_value_case or cross_post_return_case):
        memory_flags = "-Wl,--defsym=__qemu_stack_override=16384 "
    if core == "d0" and lexical_resource_value_case:
        memory_flags += "-Wl,--defsym=__qemu_heap_override=294912 "
    run("nim", "c", "-d:release", "--skipUserCfg", "--skipParentCfg",
        "--skipProjCfg", f"--path:{ROOT / 'src'}", "--os:any", f"--cpu:{cpu}",
        "--cc:gcc", "--gcc.exe:riscv64-unknown-elf-gcc",
        "--gcc.linkerexe:riscv64-unknown-elf-gcc", "--mm:arc",
        "-d:useMalloc", "-d:nimNoLibc", "-d:noSignalHandler",
        f"-d:bl808{core}", "-d:bl808WasmFull",
        *(["-d:wasmComponentLocalReentry"] if core == "lp" and local_lower_case else []),
        "-d:wasmComponentLinkedResourceBundleQemu" if linked_resource_bundle_case else
        "-d:wasmComponentResourceBundleQemu" if resource_bundle_case else
        "-d:wasmComponentTypedImportQemu" if typed_import_case else
        "-d:wasmComponentHostDefinitionQemu" if host_definition_case else
        "-d:wasmComponentCoreModuleQemu" if core_module_case else
        "-d:wasmComponentDefinitionRelayQemu" if definition_relay_case else
        "-d:wasmComponentNestedInstanceQemu" if nested_instance_case else
        "-d:wasmComponentOuterCaptureQemu" if outer_capture_case else
        "-d:wasmComponentFunctionEqualityQemu" if function_equality_case else
        "-d:wasmComponentContractEqualityQemu" if contract_equality_case else
        "-d:wasmComponentInstanceEqualityQemu" if instance_equality_case else
        "-d:wasmComponentContractCaptureQemu" if contract_capture_case else
        "-d:wasmComponentLexicalResourceValueQemu" if lexical_resource_value_case else
        "-d:wasmComponentLocalLowerQemu" if local_lower_case else
        "-d:wasmComponentGeneratedCoreQemu" if generated_core_case else
        "-d:wasmComponentCrossPostReturnQemu" if cross_post_return_case else
        "-d:wasmComponentTagLinkQemu" if tag_case else
        "-d:wasmComponentForeignBorrowQemu" if foreign_borrow_case else
        "-d:wasmComponentNestedValueQemu" if nested_value_case else
        "-d:wasmComponentNestedListQemu" if nested_list_case else
        "-d:wasmComponentFlatQemu" if flat_case else
        "-d:wasmComponentIndirectQemu" if indirect_case else
        "-d:wasmComponentResourceQemu" if resource_case else
        "-d:wasmComponentInterfaceQemu" if interface_case else
        "-d:wasmComponentNestedQemu" if nested_case else
        "-d:wasmComponentCoreGraphQemu" if core_graph_case else
        "-d:wasmComponentCharQemu" if char_case else
        "-d:wasmComponentFlagsQemu" if flags_case else
        "-d:wasmComponentTupleQemu" if tuple_case else
        "-d:wasmComponentResultQemu" if result_case else
        "-d:wasmComponentEnumQemu" if enum_case else
        "-d:wasmComponentVariantQemu" if variant_case else
        "-d:wasmComponentOptionQemu" if option_case else
        "-d:wasmComponentRecordMixedQemu" if mixed_case else
        "-d:wasmComponentRecordQemu" if record_case else
        "-d:wasmComponentBytesQemu" if bytes_case else
        "-d:wasmComponentOptionStringQemu" if option_string_case else
        "-d:wasmComponentQwordsQemu" if qwords_case else
        "-d:wasmComponentWordsQemu" if words_case else
        "-d:wasmComponentStringResultQemu" if string_result else
        "-d:wasmComponentStringQemu" if string else "-d:wasmComponentQemu",
        *(["-d:wasmChunkedMemory", "-d:WasmMemoryChunkBytesConfig=512"]
          if label not in ("scalar", "nested-bool", "named-interface", "resource", "foreign-borrow",
                           "typed-import", "host-definition", "core-module", "definition-relay",
                           "nested-instance", "outer-capture", "function-equality",
                           "contract-equality", "instance-equality", "contract-capture",
                           "lexical-resource-value", "tag-link") else []),
        "--noMain:on", "--threads:off", "--checks:off", "--assertions:off",
        "--stackTrace:off", "--lineTrace:off", "--panics:on",
        f"--passC:-march={march} -mabi={abi} -mcmodel=medany -ffunction-sections -fdata-sections -fno-builtin",
        f"--passL:-march={march} -mabi={abi} -mcmodel=medany -nostdlib -nostartfiles -static -Wl,--gc-sections -T {linker} "
        + memory_flags + "-lgcc",
        f"--nimcache:{OUT / f'component-{label}-qemu-{core}-cache'}",
        f"--out:{elf}", "tools/wasm_full_qemu.nim")
    executable = "qemu-system-riscv64" if core == "d0" else "qemu-system-riscv32"
    try:
        output = run(executable, "-machine", "virt", "-cpu", model, "-m", "32M",
                     "-bios", "none", "-nographic", "-no-reboot", "-kernel", str(elf),
                     timeout=30)
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(f"{core} component {label} QEMU timed out:\n{exc.stdout}") from exc
    marker = f"[PASS] {core.upper()} " + ("RV64" if core == "d0" else "RV32E" if core == "lp" else "RV32") + f" component {label}"
    if marker not in output or "[FAIL]" in output:
        raise AssertionError(f"{core} component QEMU failed:\n{output}")
    peak = int(re.search(r"component heap peak bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    stack = int(re.search(r"component native stack used bytes=0x\n([0-9a-f]+)", output).group(1), 16)
    sections = run("riscv64-unknown-elf-size", "-A", str(elf))
    sizes = {name: int(size) for name, size in re.findall(
        r"^(\.[a-z]+)\s+(\d+)\s+\d+", sections, re.M)}
    assert peak < sizes[".heap"] and stack < sizes[".stack"], (core, peak, stack, sizes)
    if core == "lp":
        assert sum(sizes[name] for name in (".data", ".bss", ".heap", ".stack")) <= lp_ram_bytes
    layout = " (32 KiB diagnostic)" if core == "lp" and lp_ram_bytes == 32768 else ""
    print(f"{core} QEMU component {label}{layout}: heap peak={peak}, native stack used={stack}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu", action="store_true")
    parser.add_argument("--qemu-string", action="store_true")
    parser.add_argument("--qemu-record", action="store_true")
    parser.add_argument("--qemu-variant", action="store_true")
    parser.add_argument("--qemu-words", action="store_true")
    parser.add_argument("--qemu-qwords", action="store_true")
    parser.add_argument("--qemu-option-string", action="store_true")
    parser.add_argument("--qemu-core-graph", action="store_true")
    parser.add_argument("--qemu-core-module", action="store_true")
    parser.add_argument("--qemu-definition-relay", action="store_true")
    parser.add_argument("--qemu-nested-instance", action="store_true")
    parser.add_argument("--qemu-outer-capture", action="store_true")
    parser.add_argument("--qemu-function-equality", action="store_true")
    parser.add_argument("--qemu-contract-equality", action="store_true")
    parser.add_argument("--qemu-instance-equality", action="store_true")
    parser.add_argument("--qemu-contract-capture", action="store_true")
    parser.add_argument("--qemu-lexical-resource-value", action="store_true")
    parser.add_argument("--qemu-local-lower", action="store_true")
    parser.add_argument("--qemu-generated-core", action="store_true")
    parser.add_argument("--qemu-cross-post-return", action="store_true")
    parser.add_argument("--qemu-interface", action="store_true")
    parser.add_argument("--qemu-resource", action="store_true")
    parser.add_argument("--qemu-indirect", action="store_true")
    parser.add_argument("--qemu-flat-aggregates", action="store_true")
    parser.add_argument("--qemu-nested-list", action="store_true")
    parser.add_argument("--qemu-nested-value", action="store_true")
    parser.add_argument("--qemu-foreign-borrow", action="store_true",
                        help="run cross-guest borrows, with an expanded LP diagnostic layout")
    parser.add_argument("--qemu-resource-bundle", action="store_true",
                        help="run WIT resource aggregates on the M0 and D0 CPU profiles")
    parser.add_argument("--qemu-typed-imports", action="store_true",
                        help="run typed imports on M0/D0 and a host definition in an expanded LP layout")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    components = []
    for stem in ("arithmetic", "import", "multi_import", "string", "bad_realloc", "string_result", "string_result_oob", "bytes", "record", "record_oob", "record_mixed", "resource", "post_import", "option", "variant", "enum", "result", "tuple", "flags", "variant_invalid", "char", "words", "words_unaligned", "qwords", "qwords_unaligned", "option_string", "option_string_oob"):
        embedded = OUT / f"{stem}.embedded.wasm"
        component = OUT / f"{stem}.component.wasm"
        wit = "string" if stem == "bad_realloc" else "string_result" if stem == "string_result_oob" else "record" if stem == "record_oob" else "words" if stem == "words_unaligned" else "qwords" if stem == "qwords_unaligned" else "option_string" if stem == "option_string_oob" else stem
        run("wasm-tools", "component", "embed",
            f"tools/wasm_component_{wit}.wit",
            f"tools/wasm_component_{stem}.wat", "-o", str(embedded))
        run("wasm-tools", "component", "new", str(embedded), "-o", str(component))
        run("wasm-tools", "validate", str(component))
        components.append(component)
    graph = OUT / "core_graph.component.wasm"
    run("wasm-tools", "strip", "--all", "tools/wasm_component_core_graph.wat",
        "-o", str(graph))
    run("wasm-tools", "validate", str(graph))
    components.append(graph)
    graph_lp = OUT / "core_graph_lp.component.wasm"
    run("wasm-tools", "strip", "--all", "tools/wasm_component_core_graph_lp.wat",
        "-o", str(graph_lp))
    run("wasm-tools", "validate", str(graph_lp))
    wrong_limit = OUT / "core_graph_wrong_limit.component.wasm"
    wrong_limit_wat = OUT / "core_graph_wrong_limit.wat"
    fixture = (ROOT / "tools/wasm_component_core_graph.wat").read_text()
    wrong_limit_wat.write_text(fixture.replace(
        '(import "env" "memory" (memory 1 2))',
        '(import "env" "memory" (memory 2 2))'))
    run("wasm-tools", "parse", str(wrong_limit_wat), "-o", str(wrong_limit))
    verdict = subprocess.run(("wasm-tools", "validate", str(wrong_limit)),
                             cwd=ROOT, capture_output=True)
    assert verdict.returncode != 0, "type mismatch accepted by wasm-tools"
    components.append(wrong_limit)
    for stem in ("import_string", "import_string_result", "single_tuple"):
        embedded = OUT / f"{stem}.embedded.wasm"
        component = OUT / f"{stem}.component.wasm"
        run("wasm-tools", "component", "embed", f"tools/wasm_component_{stem}.wit",
            f"tools/wasm_component_{stem}.wat", "-o", str(embedded))
        run("wasm-tools", "component", "new", str(embedded), "-o", str(component))
        run("wasm-tools", "validate", str(component))
        components.append(component)
    for encoding in ("utf16", "compact-utf16"):
        stem = "import_string_result"
        embedded = OUT / f"{stem}_{encoding}.embedded.wasm"
        component = OUT / f"{stem}_{encoding}.component.wasm"
        run("wasm-tools", "component", "embed", "--encoding", encoding,
            f"tools/wasm_component_{stem}.wit", f"tools/wasm_component_{stem}.wat",
            "-o", str(embedded))
        run("wasm-tools", "component", "new", str(embedded), "-o", str(component))
        run("wasm-tools", "validate", str(component))
        components.append(component)
    local_resources = OUT / "local_resources.component.wasm"
    run("wasm-tools", "parse", "tools/wasm_component_local_resources.wat",
        "-o", str(local_resources))
    run("wasm-tools", "validate", str(local_resources))
    components.append(local_resources)
    named_components = {}
    for world, stem in (("demo", "named_interface"), ("provider", "named_provider")):
        embedded = OUT / f"{stem}.embedded.wasm"
        component = OUT / f"{stem.replace('_', '-')}.wasm"
        run("wasm-tools", "component", "embed", "--world", world,
            "tools/wasm_component_named_interface.wit", f"tools/wasm_component_{stem}.wat",
            "-o", str(embedded))
        run("wasm-tools", "component", "new", str(embedded), "-o", str(component))
        run("wasm-tools", "validate", str(component))
        named_components[world] = component
    composed = OUT / "named_composed.component.wasm"
    run("wasm-tools", "compose", "--quiet", "--no-imports", "--definitions",
        str(named_components["provider"]), str(named_components["demo"]), "-o", str(composed))
    named_fixture = OUT / "named_interface.stripped.wasm"
    run("wasm-tools", "strip", "--all", str(named_components["demo"]), "-o", str(named_fixture))
    run("wasm-tools", "validate", str(named_fixture))
    run("wasm-tools", "validate", str(composed))
    components.extend((named_fixture, composed))
    for world, stem in (("direct", "indirect"), ("linked", "indirect_linked")):
        embedded = OUT / f"{stem}.embedded.wasm"
        component = OUT / f"{stem}.component.wasm"
        stripped = OUT / f"{stem}.stripped.wasm"
        run("wasm-tools", "component", "embed", "--world", world,
            "tools/wasm_component_indirect.wit", f"tools/wasm_component_{stem}.wat",
            "-o", str(embedded))
        run("wasm-tools", "component", "new", str(embedded), "-o", str(component))
        run("wasm-tools", "strip", "--all", str(component), "-o", str(stripped))
        run("wasm-tools", "validate", str(stripped))
        components.append(stripped)
    for world, stem in (("flat-demo", "flat"), ("flat-lp", "flat_lp"),
                        ("named-record", "named_record")):
        flat_embedded = OUT / f"{stem}.embedded.wasm"
        flat_fixture = OUT / f"{stem}.stripped.wasm"
        run("wasm-tools", "component", "embed", "--world", world,
            "tools/wasm_component_flat.wit", f"tools/wasm_component_{stem}.wat",
            "-o", str(flat_embedded))
        run("wasm-tools", "component", "new", str(flat_embedded), "-o", str(flat_fixture))
        run("wasm-tools", "strip", "--all", str(flat_fixture), "-o", str(flat_fixture))
        run("wasm-tools", "validate", str(flat_fixture))
        if world != "flat-lp":
            components.append(flat_fixture)
    for stem, supplied, expected, diagnostic in (
        ("wrong_instance_type", '(record (field "left" u32))',
         '(record (field "right" u32))', "field name"),
        ("wrong_list_type", "(list string)", "(list s32)", "expected primitive `s32`"),
    ):
        wrong_type = OUT / f"{stem}.wat"
        wrong_type.write_text(f"""(component
          (component $provider
            (type $value {supplied})
            (export "value" (type $value)))
          (instance $provider-instance (instantiate $provider))
          (component $consumer
            (import "types" (instance
              (type $value {expected})
              (export "value" (type (eq $value))))))
          (instance (instantiate $consumer
            (with "types" (instance $provider-instance)))))
        """)
        wrong_binary = wrong_type.with_suffix(".wasm")
        run("wasm-tools", "parse", str(wrong_type), "-o", str(wrong_binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(wrong_binary)),
                                 cwd=ROOT, capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(wrong_binary)
    visible_list = OUT / "visible_list_element.wat"
    visible_list.write_text("""(component
      (type $row (record (field "x" u32)))
      (export $named-row "row" (type $row))
      (type $rows (list $named-row))
      (export "rows" (type $rows)))
    """)
    visible_list_binary = visible_list.with_suffix(".wasm")
    run("wasm-tools", "parse", str(visible_list), "-o", str(visible_list_binary))
    run("wasm-tools", "validate", str(visible_list_binary))
    components.append(visible_list_binary)
    for stem in ("nested_list", "nested_value", "nested_bridge", "resource_bundle"):
        embedded = OUT / f"{stem}.embedded.wasm"
        component = OUT / f"{stem}.component.wasm"
        stripped = OUT / f"{stem}.stripped.wasm"
        run("wasm-tools", "component", "embed", f"tools/wasm_component_{stem}.wit",
            f"tools/wasm_component_{stem}.wat", "-o", str(embedded))
        run("wasm-tools", "component", "new", str(embedded), "-o", str(component))
        run("wasm-tools", "strip", "--all", str(component), "-o", str(stripped))
        run("wasm-tools", "validate", str(stripped))
        components.append(stripped)
    for stem in ("foreign_borrow", "foreign_borrow_lp", "resource_bundle_linked", "resource_annotation"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    annotation = (ROOT / "tools" / "wasm_component_resource_annotation.wat").read_text()
    for stem, original, changed in (
        ("wrong_resource_annotation", '(export "ticket-alias" (type $ticket))',
         '(export "ticket-alias" (type $other))'),
        ("wrong_value_annotation", '(export "bundle" (type $bundle))',
         '(export "bundle" (type $other-bundle))'),
        ("wrong_function_annotation", '(export "get" (func $read))',
         '(export "get" (func $read-other))'),
        ("abstract_resource_annotation", '(type $R (eq $source))',
         '(type $R (sub resource))'),
    ):
        assert annotation.count(original) == 1
        invalid_wat = OUT / f"{stem}.wat"
        invalid_wat.write_text(annotation.replace(original, changed))
        invalid_binary = invalid_wat.with_suffix(".wasm")
        run("wasm-tools", "parse", str(invalid_wat), "-o", str(invalid_binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(invalid_binary)),
                                 cwd=ROOT, capture_output=True, text=True)
        assert verdict.returncode != 0 and "resource types are not the same" in verdict.stderr, verdict.stderr
        components.append(invalid_binary)
    typed_import = ROOT / "tools" / "wasm_component_typed_import.wat"
    typed_binary = OUT / "typed_import.wasm"
    run("wasm-tools", "strip", "--all", str(typed_import), "-o", str(typed_binary))
    run("wasm-tools", "validate", str(typed_binary))
    components.append(typed_binary)
    typed_source = typed_import.read_text()
    for stem, original, changed, diagnostic in (
        ("typed_import_wrong_resource", '(export "get" (func $read))',
         '(export "get" (func $read-other))', "resource types are not the same"),
        ("typed_import_extra_import", "(component $provider\n",
         '(component $provider\n    (import "required" (func (result u32)))\n',
         "missing import named `required`"),
    ):
        assert typed_source.count(original) == 1
        invalid_wat = OUT / f"{stem}.wat"
        invalid_wat.write_text(typed_source.replace(original, changed))
        invalid_binary = invalid_wat.with_suffix(".wasm")
        run("wasm-tools", "parse", str(invalid_wat), "-o", str(invalid_binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(invalid_binary)),
                                 cwd=ROOT, capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(invalid_binary)
    for stem in ("host_consumer", "host_provider"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    unused = OUT / "host_unused.wat"
    consumer_source = (ROOT / "tools" / "wasm_component_host_consumer.wat").read_text()
    prefix, tail = consumer_source.split('  (instance $api (instantiate $factory')
    assert '(alias export $api "apply")' in tail
    unused.write_text(prefix + ")\n")
    unused_binary = unused.with_suffix(".wasm")
    run("wasm-tools", "strip", "--all", str(unused), "-o", str(unused_binary))
    run("wasm-tools", "validate", str(unused_binary))
    components.append(unused_binary)
    for stem in ("typed_reexport", "typed_interface", "typed_interface_resource"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    source = (ROOT / "tools" / "wasm_component_typed_interface_resource.wat").read_text()
    for stem, original, changed, diagnostic in (
        ("typed_interface_wrong_resource", '(export "ticket" (type $Input))',
         '(export "ticket" (type $wrong))', "resource types are not the same"),
        ("typed_interface_missing_method", '(export "forward" (func $forward)))\n',
         '(export "another" (func $forward)))\n', 'missing expected export `forward`'),
    ):
        assert source.count(original) == 1
        invalid_wat = OUT / f"{stem}.wat"
        invalid_wat.write_text(source.replace(original, changed))
        invalid_binary = invalid_wat.with_suffix(".wasm")
        run("wasm-tools", "parse", str(invalid_wat), "-o", str(invalid_binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(invalid_binary)),
                                 cwd=ROOT, capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(invalid_binary)
    for stem in ("core_module_link", "core_module_host", "core_module_provider", "core_module_limits"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    source = (ROOT / "tools" / "wasm_component_core_module_link.wat").read_text()
    for stem, original, changed, diagnostic in (
        ("core_module_wrong_variance", '(export "runtime" (core module (type $R)))',
         '(export "runtime" (core module (type $M)))', 'missing expected import `inputs::unused`'),
        ("core_module_hidden_export", '(import "" "calc" (func $calc',
         '(import "" "decoy" (func $calc', 'does not export an item named `decoy`'),
    ):
        assert source.count(original) == 1
        invalid_wat = OUT / f"{stem}.wat"
        invalid_wat.write_text(source.replace(original, changed))
        invalid_binary = invalid_wat.with_suffix(".wasm")
        run("wasm-tools", "parse", str(invalid_wat), "-o", str(invalid_binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(invalid_binary)),
                                 cwd=ROOT, capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(invalid_binary)
    for stem in ("definition_relay", "definition_export_lp"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    source = (ROOT / "tools" / "wasm_component_definition_relay.wat").read_text()
    for stem, original, changed, diagnostic in (
        ("definition_requires_extra", '(import "task" (component $task (export "run" (func (result u32)))))',
         '(import "task" (component $task (export "run" (func (result u32))) (export "missing" (func))))',
         'missing export named `missing`'),
        ("definition_missing_output", '(export "selected" (component (export "run" (func (result u32)))))))',
         '(export "selected" (component (export "run" (func (result u32))) (export "extra" (func (result u32)))))))',
         'missing export named `extra`'),
        ("definition_hidden_export", '(alias export $result "run")',
         '(alias export $result "extra")', 'has no export named `extra`'),
    ):
        assert source.count(original) == 1
        invalid_wat = OUT / f"{stem}.wat"
        invalid_wat.write_text(source.replace(original, changed))
        invalid_binary = invalid_wat.with_suffix(".wasm")
        run("wasm-tools", "parse", str(invalid_wat), "-o", str(invalid_binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(invalid_binary)),
                                 cwd=ROOT, capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(invalid_binary)
    deep_type = "(component)"
    for _ in range(8):
        deep_type = f'(component (export "next" {deep_type}))'
    too_deep = OUT / "definition_too_deep.wat"
    too_deep.write_text(f"(component (type {deep_type}))\n")
    too_deep_binary = too_deep.with_suffix(".wasm")
    run("wasm-tools", "parse", str(too_deep), "-o", str(too_deep_binary))
    run("wasm-tools", "validate", str(too_deep_binary))
    components.append(too_deep_binary)
    for stem in ("nested_instance", "nested_instance_typed", "nested_instance_lp"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    resource_source = (ROOT / "tools" / "wasm_component_nested_instance.wat").read_text()
    wrong_identity = resource_source.replace("    (instance $outer", (
        '    (type $wrong (resource (rep i32)))\n'
        '    (instance $wrong-api (export "ticket" (type $wrong)))\n'
        '    (instance $outer'
    )).replace('(export "mirror" (instance $inner))', '(export "mirror" (instance $wrong-api))')
    typed_source = (ROOT / "tools" / "wasm_component_nested_instance_typed.wat").read_text()
    missing_export = typed_source.replace('(export "methods" (instance $methods))',
                                          '(export "renamed" (instance $methods))')
    beta = '(export "beta" (instance (export "get" (func (result u32)))))'
    wrong_import = typed_source.replace(beta, beta.replace("u32", "s32"), 1)
    for stem, source, diagnostic in (
        ("nested_instance_wrong_identity", wrong_identity, "resource types are not the same"),
        ("nested_instance_missing_export", missing_export, 'missing expected export `methods`'),
        ("nested_instance_wrong_import", wrong_import, 'expected primitive `s32`'),
    ):
        fixture = OUT / f"{stem}.wat"
        fixture.write_text(source)
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(binary)), cwd=ROOT,
                                 capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(binary)
    nested_host = OUT / "nested_instance_host.wat"
    nested_host.write_text("""
      (component
        (import "services" (instance $services
          (export "clock" (instance (export "read" (func (result u32)))))))
        (alias export $services "clock" (instance $clock))
        (func (export "run") (alias export $clock "read")))
    """)
    nested_host_binary = nested_host.with_suffix(".wasm")
    run("wasm-tools", "strip", "--all", str(nested_host), "-o", str(nested_host_binary))
    run("wasm-tools", "validate", str(nested_host_binary))
    components.append(nested_host_binary)
    large_instance = OUT / "nested_instance_large.wat"
    items = " ".join(f'(export "item-{i}" (instance (type $empty)))' for i in range(16))
    groups = " ".join(f'(export "group-{i}" (instance (type $group)))' for i in range(16))
    large_instance.write_text(f"""
      (component
        (import "api" (instance
          (type $group (instance (type $empty (instance)) {items}))
          {groups})))
    """)
    large_instance_binary = large_instance.with_suffix(".wasm")
    run("wasm-tools", "strip", "--all", str(large_instance), "-o", str(large_instance_binary))
    run("wasm-tools", "validate", str(large_instance_binary))
    components.append(large_instance_binary)
    lexical_resource = OUT / "lexical_resource.wasm"
    run("wasm-tools", "strip", "--all", "tools/wasm_component_lexical_resource.wat",
        "-o", str(lexical_resource))
    run("wasm-tools", "validate", str(lexical_resource))
    components.append(lexical_resource)
    lexical_source = (ROOT / "tools" / "wasm_component_lexical_resource.wat").read_text()
    private_type = lexical_source.replace(
        "(type $maybe (option $public-request))", "(type $maybe (option $request))")
    unrelated_type = lexical_source.replace(
        '    (instance $details\n      (export "ticket" (type $public))',
        '    (type $unrelated (resource (rep i32)))\n'
        '    (export $other "unrelated" (type $unrelated))\n'
        '    (instance $details\n'
        '      (export "ticket" (type $other))\n'
        '      (export "underlying" (type $public))')
    for stem, source, diagnostic in (
        ("lexical_resource_private", private_type, "instance not valid to be used as import"),
        ("lexical_resource_unrelated", unrelated_type, "resource types are not the same"),
        ("outer_function_resource", """
            (component
              (type $ticket (resource (rep i32)))
              (type $read (func (param "ticket" (borrow $ticket))))
              (component (alias outer 1 $read (type $copy))))
        """, "transitively refers to resources"),
        ("outer_instance_resource", """
            (component
              (type $ticket (resource (rep i32)))
              (type $api (instance
                (alias outer 1 $ticket (type $ticket))
                (export "ticket" (type (eq $ticket)))))
              (component (alias outer 1 $api (type $copy))))
        """, "transitively refers to resources"),
        ("outer_function_private_name", """
            (component
              (type $data (record (field "value" u32)))
              (import "shape" (type $shape (eq $data)))
              (type $read (func (param "value" $shape)))
              (component
                (alias outer 1 $read (type $copy))
                (import "read" (func (type $copy)))))
        """, "func not valid to be used as import"),
        ("outer_instance_private_name", """
            (component
              (type $data (record (field "value" u32)))
              (import "shape" (type $shape (eq $data)))
              (type $api (instance
                (alias outer 1 $shape (type $local))
                (export "read" (func (param "value" $local)))))
              (component
                (alias outer 1 $api (type $copy))
                (import "api" (instance (type $copy)))))
        """, "instance not valid to be used as import"),
        ("outer_function_depends_on_export", """
            (component
              (type $data (record (field "value" u32)))
              (export $shape "shape" (type $data))
              (type $read (func (param "value" $shape)))
              (import "api" (instance
                (alias outer 1 $read (type $copy))
                (export "read" (func (type $copy))))))
        """, "instance not valid to be used as import"),
    ):
        fixture = OUT / f"{stem}.wat"
        fixture.write_text(source)
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(binary)), cwd=ROOT,
                                 capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(binary)
    for stem in ("interface_module_link", "interface_module_lp", "interface_module_host"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    for stem, value in (("interface_module_direct", 13), ("interface_module_nested", 16)):
        fixture = OUT / f"{stem}.wat"
        fixture.write_text(f'(module (func (export "run") (result i32) (i32.const {value})))')
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        run("wasm-tools", "validate", str(binary))
        components.append(binary)
    interface_link = (ROOT / "tools" / "wasm_component_interface_module_link.wat").read_text()
    interface_lp = (ROOT / "tools" / "wasm_component_interface_module_lp.wat").read_text()
    wide_imports = ('(import "inputs" "unused" (func (result i32)))\n'
                    '    (import "inputs" "value" (func (result i32)))')
    for stem, source, old, new, diagnostic in (
        ("interface_module_wrong_variance", interface_link, wide_imports,
         wide_imports + '\n    (export "decoy" (func (result i32)))',
         'missing expected export `decoy`'),
        ("interface_module_hidden_member", interface_lp, '"engine" (core module $selected)',
         '"decoy" (core module $selected)', 'instance 1 has no export named `decoy`'),
        ("interface_module_hidden_export", interface_lp, '$selected "run"', '$selected "decoy"',
         'core instance 0 has no export named `decoy`'),
        ("interface_module_missing_projection", interface_link,
         '(instance $published-right (export "engine"',
         '(instance $published-right (export "renamed"', 'missing expected export `engine`'),
    ):
        fixture = OUT / f"{stem}.wat"
        fixture.write_text(source.replace(old, new, 1))
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(binary)), cwd=ROOT,
                                 capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(binary)
    for stem in ("interface_component_link", "interface_component_lp", "interface_component_host"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    for stem, value in (("interface_component_direct", 21), ("interface_component_nested", 42)):
        fixture = OUT / f"{stem}.wat"
        fixture.write_text(f"""
            (component
              (core module $code (func (export "run") (result i32) (i32.const {value})))
              (core instance $code (instantiate $code))
              (func (export "run") (result u32) (canon lift (core func $code "run"))))
        """)
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        run("wasm-tools", "validate", str(binary))
        components.append(binary)
    component_link = (ROOT / "tools" / "wasm_component_interface_component_link.wat").read_text()
    component_lp = (ROOT / "tools" / "wasm_component_interface_component_lp.wat").read_text()
    right = '(export "right" (instance (export "task" (component (type $Narrow)))))'
    for stem, source, old, new, diagnostic in (
        ("interface_component_wrong_variance", component_link, right,
         right.replace("$Narrow", "$Wide"), 'missing export named `extra`'),
        ("interface_component_hidden_member", component_lp, '$visible "task"', '$visible "hidden"',
         'instance 1 has no export named `hidden`'),
        ("interface_component_hidden_export", component_lp, '$result "run"', '$result "extra"',
         'instance 2 has no export named `extra`'),
        ("interface_component_missing_projection", component_link,
         '(instance $published-right (export "task"',
         '(instance $published-right (export "renamed"', 'missing expected export `task`'),
    ):
        fixture = OUT / f"{stem}.wat"
        fixture.write_text(source.replace(old, new, 1))
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(binary)), cwd=ROOT,
                                 capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(binary)
    deep = "(component)"
    for _ in range(8):
        deep = f'(component (export "path" (instance (export "task" {deep}))))'
    fixture = OUT / "interface_component_too_deep.wat"
    fixture.write_text(f"(component (type {deep}))")
    binary = fixture.with_suffix(".wasm")
    run("wasm-tools", "parse", str(fixture), "-o", str(binary))
    run("wasm-tools", "validate", str(binary))
    components.append(binary)
    for stem in ("outer_capture", "outer_capture_lp"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    for flavor, engine, start in (("a", 20, 21), ("b", 50, 34)):
        samples = {
            f"outer_capture_engine_{flavor}":
                f'(module (func (export "run") (result i32) (i32.const {engine})))',
            f"outer_capture_worker_{flavor}": f"""
              (component
                (core module $code
                  (global $calls (mut i32) (i32.const {start}))
                  (func (export "run") (result i32)
                    (global.set $calls (i32.add (global.get $calls) (i32.const 1)))
                    (global.get $calls)))
                (core instance $code (instantiate $code))
                (func (export "run") (result u32) (canon lift (core func $code "run"))))
            """,
        }
        for stem, source in samples.items():
            fixture = OUT / f"{stem}.wat"
            fixture.write_text(source)
            binary = fixture.with_suffix(".wasm")
            run("wasm-tools", "strip", "--all", str(fixture), "-o", str(binary))
            run("wasm-tools", "validate", str(binary))
            components.append(binary)
    capture_source = (ROOT / "tools" / "wasm_component_outer_capture.wat").read_text()
    for name, invalid in (("engine", "$source-engine"), ("worker", "$source-worker")):
        fixture = OUT / f"outer_capture_missing_{name}.wat"
        fixture.write_text(capture_source.replace(f"outer 2 {invalid}", "outer 2 99", 1))
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(binary)), cwd=ROOT,
                                 capture_output=True, text=True)
        assert verdict.returncode != 0 and "index out of bounds" in verdict.stderr, verdict.stderr
        components.append(binary)
    lp_module = OUT / "outer_capture_lp_module.wasm"
    run("wasm-tools", "strip", "--all", "tools/wasm_component_outer_capture_lp_module.wat",
        "-o", str(lp_module))
    run("wasm-tools", "validate", str(lp_module))
    components.append(lp_module)
    for stem in ("function_equality", "function_equality_lp", "function_equality_resources"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    structural = (ROOT / "tools" / "wasm_component_function_equality.wat").read_text()
    nominal = (ROOT / "tools" / "wasm_component_function_equality_resources.wat").read_text()
    small = (ROOT / "tools" / "wasm_component_function_equality_lp.wat").read_text()
    hidden = structural.replace('  (export $public-schema "schema" (instance $schema))\n', "")
    hidden = hidden.replace('$public-schema "signature"', '$schema "signature"')
    before, marker, consumer = structural.partition("(component $consumer")
    wrong_label = before + marker + consumer.replace('param "arg"', 'param "other"', 1)
    wrong_resource = nominal.replace('(with "signature" (type $FA))', '(with "signature" (type $FB))', 1)
    annotation = small.replace("  (export $published",
                               "  (type $Wrong (func (result s32)))\n  (export $published", 1)
    annotation = annotation.replace("(type $Read) (type (eq $Read))",
                                    "(type $Read) (type (eq $Wrong))", 1)
    for stem, source, diagnostic in (
        ("function_equality_hidden", hidden, "func not valid to be used as export"),
        ("function_equality_wrong_argument", wrong_label, "expected parameter named"),
        ("function_equality_nominal", wrong_resource, "resource types are not the same"),
        ("function_equality_annotation", annotation, "ascribed type of export is not compatible"),
    ):
        fixture = OUT / f"{stem}.wat"
        fixture.write_text(source)
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(binary)), cwd=ROOT,
                                 capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(binary)
    for stem in ("contract_equality", "contract_equality_lp"):
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat",
            "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    contract = (ROOT / "tools" / "wasm_component_contract_equality.wat").read_text()
    small_contract = (ROOT / "tools" / "wasm_component_contract_equality_lp.wat").read_text()
    wrong_argument = contract.replace('  (instance $run (instantiate $consumer',
        '  (type $Wrong (component (export "run" (func (result s32)))))\n'
        '  (instance $run (instantiate $consumer', 1).replace('(with "shape" (type $Rich))',
                                                             '(with "shape" (type $Wrong))')
    for stem, source, diagnostic in (
        ("contract_equality_argument", wrong_argument, "type mismatch for import `shape`"),
        ("contract_equality_annotation", small_contract.replace('(type $Rich) (type (eq $Thin))',
            '(type $Thin) (type (eq $Rich))', 1), "ascribed type of export is not compatible"),
        ("contract_equality_sort", contract.replace('(with "shape" (type $Rich))',
            '(with "shape" (component $provider))', 1), "expected type, found component"),
        ("contract_equality_hidden", contract.replace('(alias export $product "run")',
            '(alias export $product "extra")', 1), "has no export named `extra`"),
    ):
        fixture = OUT / f"{stem}.wat"
        fixture.write_text(source)
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(binary)), cwd=ROOT,
                                 capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(binary)
    resource_contract = "tools/wasm_component_contract_equality_resources.wat"
    resource_contract_wasm = OUT / "contract_equality_resources.wasm"
    run("wasm-tools", "strip", "--all", resource_contract, "-o", str(resource_contract_wasm))
    run("wasm-tools", "validate", str(resource_contract_wasm))
    components.append(resource_contract_wasm)
    distinct = OUT / "contract_equality_distinct_resources.wat"
    distinct.write_text((ROOT / resource_contract).read_text().replace(
        '(export "second" (type (eq $R)))', '(export "second" (type (sub resource)))', 1))
    distinct_wasm = distinct.with_suffix(".wasm")
    run("wasm-tools", "parse", str(distinct), "-o", str(distinct_wasm))
    verdict = subprocess.run(("wasm-tools", "validate", str(distinct_wasm)), cwd=ROOT,
                             capture_output=True, text=True)
    assert verdict.returncode != 0 and "resource types are not the same" in verdict.stderr, verdict.stderr
    components.append(distinct_wasm)
    visibility_source = ROOT / "tools" / "wasm_component_contract_equality_visibility.wat"
    visible_contract = OUT / "contract_equality_visibility.wasm"
    run("wasm-tools", "strip", "--all", str(visibility_source), "-o", str(visible_contract))
    run("wasm-tools", "validate", str(visible_contract))
    components.append(visible_contract)
    unnamed = OUT / "contract_equality_unnamed.wat"
    unnamed.write_text(visibility_source.read_text().replace(
        '    (export "record" (type $Inside (eq $Captured)))\n', '').replace('$Inside', '$Captured'))
    unnamed_wasm = unnamed.with_suffix(".wasm")
    run("wasm-tools", "parse", str(unnamed), "-o", str(unnamed_wasm))
    verdict = subprocess.run(("wasm-tools", "validate", str(unnamed_wasm)), cwd=ROOT,
                             capture_output=True, text=True)
    assert verdict.returncode != 0 and "func not valid to be used as export" in verdict.stderr, verdict.stderr
    components.append(unnamed_wasm)
    instance_sources = {}
    for stem in ("instance_equality", "instance_equality_lp", "instance_equality_resources",
                 "instance_equality_fresh"):
        source = ROOT / "tools" / f"wasm_component_{stem}.wat"
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", str(source), "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
        instance_sources[stem] = source.read_text()
    instance = instance_sources["instance_equality"]
    small_instance = instance_sources["instance_equality_lp"]
    resources = instance_sources["instance_equality_resources"]
    fresh = instance_sources["instance_equality_fresh"]
    first, marker, second = fresh.partition("(type $Expected")
    bad_instance_argument = instance.replace('  (instance $run (instantiate $consumer',
        '  (type $Wrong (instance (export "read" (func (result s32)))))\n'
        '  (instance $run (instantiate $consumer', 1)
    for suffix, source, diagnostic in (
        ("width", small_instance.replace("(type $Rich) (type (eq $Narrow))",
            "(type $Narrow) (type (eq $Rich))", 1), "missing expected export `extra`"),
        ("argument", bad_instance_argument.replace('(with "shape" (type $Rich))',
            '(with "shape" (type $Wrong))', 1), "type mismatch for import `shape`"),
        ("nominal", resources.replace('(with "shape" (type $Declared))',
            '(with "shape" (type $Unrelated))', 1), "resource types are not the same"),
        ("capture", resources.replace('(with "shape" (type $Shape)) (with "token" (type $Token))',
            '(with "shape" (type $Shape)) (with "token" (type $Other))', 1), "resource types are not the same"),
        ("anchor", resources.replace('(export $Token "token" (type $token))',
            '(alias outer 0 $token (type $Token))', 1), "local resource type found in export"),
        ("fresh", first + marker + second.replace("outer 1 $First", "outer 1 $Second", 1),
            "resource types are not the same"),
        ("nested_resource", fresh.replace('(type $Nested) (type (eq $Nested))',
            '(type $Nested) (type (eq $OtherNested))', 1), "resource types are not the same"),
    ):
        fixture = OUT / f"instance_equality_{suffix}_invalid.wat"
        fixture.write_text(source)
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(binary)), cwd=ROOT,
                                 capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(binary)
    capture_sources = {}
    for stem in ("contract_capture", "contract_capture_lp", "contract_capture_nested"):
        source = ROOT / "tools" / f"wasm_component_{stem}.wat"
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", str(source), "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
        capture_sources[stem] = source.read_text()
    capture = capture_sources["contract_capture"]
    first, marker, second = capture_sources["contract_capture_nested"].partition("(type $Required")
    for suffix, source, diagnostic in (
        ("provider", capture.replace('(import "ticket" (type $Local (sub resource)))',
            '(type $Local (resource (rep i32)))', 1), "resource types are not the same"),
        ("argument", capture.replace('(with "ticket" (type $Ticket))',
            '(with "ticket" (type $unused))', 1), "resource types are not the same"),
        ("visibility", capture.replace('(borrow $Out)', '(borrow $Captured)', 1),
            "func not valid to be used as export"),
        ("anchor", capture.replace('(export $Ticket "ticket" (type $ticket))',
            '(alias outer 0 $ticket (type $Ticket))', 1), "local resource type found in export"),
        ("nested", first + marker + second.replace("outer 2 $Left", "outer 2 $Right", 1),
            "resource types are not the same"),
        ("nested_argument", capture_sources["contract_capture_nested"].replace(
            '(with "choice" (type $Left))', '(with "choice" (type $Right))', 1),
            "resource types are not the same"),
    ):
        fixture = OUT / f"contract_capture_{suffix}_invalid.wat"
        fixture.write_text(source)
        binary = fixture.with_suffix(".wasm")
        run("wasm-tools", "parse", str(fixture), "-o", str(binary))
        verdict = subprocess.run(("wasm-tools", "validate", str(binary)), cwd=ROOT,
                                 capture_output=True, text=True)
        assert verdict.returncode != 0 and diagnostic in verdict.stderr, verdict.stderr
        components.append(binary)
    for stem in ("lexical_resource_value", "lexical_resource_value_lp", "lexical_resource_value_deep",
                 "lexical_resource_value_private"):
        source = ROOT / "tools" / f"wasm_component_{stem}.wat"
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", str(source), "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    resource_value = (ROOT / "tools" / "wasm_component_lexical_resource_value.wat").read_text()
    wrong_owner = OUT / "lexical_resource_value_wrong_owner.wat"
    wrong_owner.write_text(resource_value.replace('(instantiate $B (with "ticket" (type $Second)))',
        '(instantiate $B (with "ticket" (type $First)))', 1))
    wrong_owner_wasm = wrong_owner.with_suffix(".wasm")
    run("wasm-tools", "parse", str(wrong_owner), "-o", str(wrong_owner_wasm))
    verdict = subprocess.run(("wasm-tools", "validate", str(wrong_owner_wasm)), cwd=ROOT,
                             capture_output=True, text=True)
    assert verdict.returncode != 0 and "resource types are not the same" in verdict.stderr, verdict.stderr
    components.append(wrong_owner_wasm)
    for stem in ("local_lower", "local_post_return", "local_lower_resource", "local_lower_lp",
                 "generated_core_host", "generated_core_children", "generated_core_lifecycle",
                 "generated_core_realloc"):
        source = ROOT / "tools" / f"wasm_component_{stem}.wat"
        fixture = OUT / f"{stem}.wasm"
        run("wasm-tools", "strip", "--all", str(source), "-o", str(fixture))
        run("wasm-tools", "validate", str(fixture))
        components.append(fixture)
    generated_core = ROOT / "tools" / "wasm_component_generated_core_host.wat"
    mismatched_lift = OUT / "generated_core_wrong_lift.wat"
    mismatched_lift.write_text(generated_core.read_text().replace(
        '(param "enabled" u32) (result u32)', '(param "enabled" u32) (result u64)'))
    mismatched_lift_wasm = mismatched_lift.with_suffix(".wasm")
    run("wasm-tools", "parse", str(mismatched_lift), "-o", str(mismatched_lift_wasm))
    verdict = subprocess.run(("wasm-tools", "validate", str(mismatched_lift_wasm)),
                             cwd=ROOT, capture_output=True, text=True)
    assert verdict.returncode != 0 and "lowered result types" in verdict.stderr, verdict.stderr
    components.append(mismatched_lift_wasm)
    cross_post_return = ROOT / "tools" / "wasm_component_cross_post_return.wat"
    cross_post_trap = cross_post_return.read_text().replace(
        "(i32.store8 (i32.const 32) (i32.const 0))", "unreachable")
    for stem, source_text in (
        ("cross_post_return", cross_post_return.read_text()),
        ("cross_post_trap", cross_post_trap),
        ("cross_post_realloc_trap", cross_post_trap.replace("i32.const 64", "i32.const 65536")),
    ):
        source = OUT / f"{stem}.wat"
        binary = OUT / f"{stem}.wasm"
        source.write_text(source_text)
        run("wasm-tools", "strip", "--all", str(source), "-o", str(binary))
        run("wasm-tools", "validate", str(binary))
        components.append(binary)
    typed_tag = ROOT / "tools" / "wasm_component_typed_tag.wat"
    tag_binary = OUT / "typed_tag.wasm"
    run("wasm-tools", "strip", "--all", str(typed_tag), "-o", str(tag_binary))
    run("wasm-tools", "validate", str(tag_binary))
    components.append(tag_binary)
    tag_source = OUT / "typed_tag_wrong_payload.wat"
    tag_source.write_text(typed_tag.read_text().replace(
        '(type $t (func (param i32)))', '(type $t (func (param i64)))', 1))
    tag_binary = tag_source.with_suffix(".wasm")
    run("wasm-tools", "parse", str(tag_source), "-o", str(tag_binary))
    verdict = subprocess.run(("wasm-tools", "validate", str(tag_binary)),
                             cwd=ROOT, capture_output=True, text=True)
    assert verdict.returncode != 0 and "type mismatch" in verdict.stderr, verdict.stderr
    components.append(tag_binary)
    output = run("nim", "c", "-r", "--skipUserCfg", "--skipParentCfg",
        "--skipProjCfg", "--path:src", "--checks:on", "--assertions:on",
        "--nimcache:" + str(OUT / "nimcache"), "--out:" + str(OUT / "test"),
        "tools/test_wasm_component.nim", *map(str, components))
    assert "component scalar ABI:ok" in output, output
    print("host toolchain-built components: canonical ABI subset PASS")
    reentry = OUT / "reentry.wat"
    reentry.write_text(
        '(module (import "env" "call-guest" (func $call-guest (result i32)))'
        '(func (export "trap") unreachable)'
        '(func (export "nested") (result i32) (local ' + "i32 " * 257 + ") "
        + "i32.const 1 " * 1025 + "i32.add " * 1024 + ") "
        '(func (export "run") (param i32) (result i32) i32.const 10 '
        'call $call-guest local.get 0 i32.add i32.add))')
    reentry_wasm = reentry.with_suffix(".wasm")
    run("wasm-tools", "parse", str(reentry), "-o", str(reentry_wasm))
    print(run("nim", "c", "-r", "--skipUserCfg", "--skipParentCfg",
              "--skipProjCfg", "--path:src", "--checks:on", "--assertions:on",
              f"--nimcache:{OUT / 'reentry-cache'}", f"--out:{OUT / 'reentry-test'}",
              "tools/test_wasm_component_reentry.nim", str(reentry_wasm)).strip())
    if args.qemu:
        for core, target in CORES.items():
            check_qemu(core, *target)
    if args.qemu_string:
        for core, target in CORES.items():
            check_qemu(core, *target, string=True)
            check_qemu(core, *target, string_result=True)
            check_qemu(core, *target, bytes_case=True)
    if args.qemu_words:
        for core, target in CORES.items():
            check_qemu(core, *target, words_case=True)
    if args.qemu_qwords:
        for core, target in CORES.items():
            check_qemu(core, *target, qwords_case=True)
    if args.qemu_option_string:
        for core, target in CORES.items():
            check_qemu(core, *target, option_string_case=True)
    if args.qemu_core_graph:
        for core, target in CORES.items():
            check_qemu(core, *target, core_graph_case=True)
    if args.qemu_core_module:
        for core, target in CORES.items():
            check_qemu(core, *target, core_module_case=True)
    if args.qemu_definition_relay:
        for core, target in CORES.items():
            check_qemu(core, *target, definition_relay_case=True)
    if args.qemu_nested_instance:
        for core, target in CORES.items():
            check_qemu(core, *target, nested_instance_case=True)
    if args.qemu_outer_capture:
        for core, target in CORES.items():
            check_qemu(core, *target, outer_capture_case=True)
    if args.qemu_function_equality:
        for core, target in CORES.items():
            check_qemu(core, *target, function_equality_case=True)
    if args.qemu_contract_equality:
        for core, target in CORES.items():
            check_qemu(core, *target, contract_equality_case=True)
    if args.qemu_instance_equality:
        for core, target in CORES.items():
            check_qemu(core, *target, instance_equality_case=True)
    if args.qemu_contract_capture:
        for core, target in CORES.items():
            check_qemu(core, *target, contract_capture_case=True)
    if args.qemu_lexical_resource_value:
        for core, target in CORES.items():
            check_qemu(core, *target, lexical_resource_value_case=True)
    if args.qemu_local_lower:
        for core, target in CORES.items():
            check_qemu(core, *target, local_lower_case=True)
    if args.qemu_generated_core:
        for core, target in CORES.items():
            check_qemu(core, *target, generated_core_case=True)
    if args.qemu_cross_post_return:
        for core, target in CORES.items():
            check_qemu(core, *target, cross_post_return_case=True)
    if args.qemu_interface:
        for core, target in CORES.items():
            check_qemu(core, *target, interface_case=True)
    if args.qemu_typed_imports:
        for core, target in CORES.items():
            check_qemu(core, *target, host_definition_case=True)
            if core != "lp":
                check_qemu(core, *target, typed_import_case=True)
    if args.qemu_resource:
        resource = OUT / "resource.stripped.wasm"
        lp_resource = OUT / "resource-lp.wasm"
        run("wasm-tools", "strip", "--all", str(OUT / "resource.component.wasm"),
            "-o", str(resource))
        run("wasm-tools", "strip", "--all", "tools/wasm_component_resource_lp.wat",
            "-o", str(lp_resource))
        run("wasm-tools", "validate", str(resource))
        run("wasm-tools", "validate", str(lp_resource))
        for core, target in CORES.items():
            check_qemu(core, *target, resource_case=True)
    if args.qemu_indirect:
        for core, target in CORES.items():
            check_qemu(core, *target, indirect_case=True)
    if args.qemu_flat_aggregates:
        for core, target in CORES.items():
            check_qemu(core, *target, flat_case=True)
    if args.qemu_nested_list:
        for core, target in CORES.items():
            check_qemu(core, *target, nested_list_case=True)
    if args.qemu_nested_value:
        for core, target in CORES.items():
            check_qemu(core, *target, nested_value_case=True)
    if args.qemu_foreign_borrow:
        for core, target in CORES.items():
            check_qemu(core, *target, foreign_borrow_case=True)
    if args.qemu_resource_bundle:
        for core in ("m0", "d0"):
            check_qemu(core, *CORES[core], resource_bundle_case=True)
            check_qemu(core, *CORES[core], linked_resource_bundle_case=True)
    if args.qemu_record:
        for core, target in CORES.items():
            check_qemu(core, *target, record_case=True)
            check_qemu(core, *target, mixed_case=True)
    if args.qemu_variant:
        for core, target in CORES.items():
            check_qemu(core, *target, option_case=True)
            check_qemu(core, *target, variant_case=True)
            check_qemu(core, *target, enum_case=True)
            check_qemu(core, *target, result_case=True)
            check_qemu(core, *target, tuple_case=True)
            check_qemu(core, *target, flags_case=True)
            check_qemu(core, *target, char_case=True)


if __name__ == "__main__":
    main()
