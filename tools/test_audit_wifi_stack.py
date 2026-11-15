import json
import hashlib

import pytest

from audit_wifi_stack import Function, audit_roots, main, prepare_graph, stack_usage


def fixture(names):
    return {"symbols": [{"name": name, "type": "FUNC", "size": 32, "vaddr": address}
                         for name, address in names.items()]}


def assembly(symbols, overrides=""):
    rows = {int(line.split(":", 1)[0], 16): line for line in overrides.splitlines()}
    for symbol in symbols["symbols"]:
        for address in range(symbol["vaddr"], symbol["vaddr"] + symbol["size"], 4):
            rows.setdefault(address, f"{address:x}: nop")
    return "\n".join(rows[address] for address in sorted(rows))


def test_parses_compiler_records_and_paths(tmp_path):
    path = tmp_path / "unit.su"
    path.write_text("/path with spaces/source.c:10:2:worker\t80\tstatic\n"
                    "source.c:21:3:variable\t32\tdynamic,bounded\n")
    assert stack_usage([path]) == {"worker": [(80, "static")],
                                 "variable": [(32, "dynamic,bounded")]}


def test_radare_aliases_and_compiler_frames():
    symbols = fixture({"root": 0x100, "leaf": 0x200})
    functions, names = prepare_graph(symbols, [{"name": "loc.a", "addr": 0x100},
                                              {"name": "loc.b", "addr": 0x200}],
                                     [{"name": "loc.a", "imports": ["loc.b"]}],
                                     {"root": [(80, "static")], "leaf": [(32, "static")]}, assembly(symbols))
    result = audit_roots(functions, names, ["root"], 8192, 128)
    assert result["complete"] and result["usable"] == 8064
    assert result["roots"][0]["direct_chain_estimate"] == 112


def test_disassembly_fills_missed_edges_and_marks_indirect_calls():
    symbols = fixture({"root": 0x100, "leaf": 0x200})
    functions, names = prepare_graph(symbols, [], [],
        {"root": [(16, "static")], "leaf": [(32, "static")]},
        assembly(symbols, "100: jal 0x200 <leaf>\n104: jalr a5\n108: ret\n"))
    result = audit_roots(functions, names, ["root"], 1024)
    assert result["roots"][0]["direct_chain_estimate"] == 48
    assert not result["complete"]
    assert result["roots"][0]["issues"] == ["root: indirect jalr at 0x104"]


@pytest.mark.parametrize("encoding", ["word", "bytes", "halfwords"])
def test_raw_encoding_columns_keep_calls_and_stack_writes_visible(encoding):
    symbols = fixture({"root": 0x100, "leaf": 0x200})
    words = {"word": ["fe010113", "000780e7", "000000ef"],
             "bytes": ["13 01 01 fe", "e7 80 07 00", "ef 00 00 00"],
             "halfwords": ["fe01 0113", "0007 80e7", "0000 00ef"]}[encoding]
    code = assembly(symbols, f"100: {words[0]}\taddi sp, sp, -0x20\n"
                    f"104: {words[1]}\tjalr a5\n108: {words[2]}\tjal 0x200 <leaf>\n")
    functions, names = prepare_graph(symbols, [], [],
        {"root": [(16, "static")], "leaf": [(8, "static")]}, code)
    report = audit_roots(functions, names, ["root"], 1024)
    assert report["roots"][0]["direct_chain_estimate"] == 40
    assert report["roots"][0]["issues"] == [
        "root: assembly stack decrement exceeds recorded frame",
        "root: indirect jalr at 0x104",
    ]


@pytest.mark.parametrize("raw", ["00000013", "13 00 00 00", "0000 0013"])
def test_raw_encoding_without_a_mnemonic_is_incomplete(raw):
    symbols = fixture({"root": 0x100})
    functions, names = prepare_graph(symbols, [], [], {"root": [(0, "static")]},
                                     assembly(symbols, f"100: {raw}\n"))
    report = audit_roots(functions, names, ["root"], 1024)
    assert not report["complete"]
    assert report["roots"][0]["issues"] == ["root: missing instruction mnemonic at 0x100"]


def test_raw_compressed_indirect_call_uses_declared_targets():
    symbols = fixture({"root": 0x100, "leaf": 0x200})
    symbols["symbols"][0]["size"] = 6
    code = assembly(symbols).replace("100: nop\n104: nop", "100: 0001 nop\n102: 9782 jalr a5\n104: 8082 ret")
    bindings = [{"caller": "root", "address": 0x102, "targets": ["leaf"],
                 "evidence": "test callback"}]
    functions, names = prepare_graph(symbols, [], [],
        {"root": [(16, "static")], "leaf": [(8, "static")]}, code, indirect_calls=bindings)
    report = audit_roots(functions, names, ["root"], 1024)
    assert report["complete"] and report["roots"][0]["direct_chain_estimate"] == 24


def test_declared_indirect_targets_keep_other_calls_unresolved():
    symbols = fixture({"root": 0x100, "small": 0x200, "large": 0x300})
    code = assembly(symbols, "100: jalr a5\n104: jr t1\n")
    usage = {"root": [(16, "static")], "small": [(32, "static")], "large": [(80, "static")]}
    bindings = [{"caller": "root", "address": 0x100, "targets": ["small", "large"],
                 "evidence": "test callback table"}]
    functions, names = prepare_graph(symbols, [], [], usage, code, indirect_calls=bindings)
    report = audit_roots(functions, names, ["root"], 1024)
    assert report["roots"][0]["direct_chain_estimate"] == 96
    assert report["roots"][0]["issues"] == ["root: indirect jr at 0x104"]
    bindings.append({"caller": "root", "address": 0x104, "targets": ["small"],
                     "evidence": "test tail callback"})
    functions, names = prepare_graph(symbols, [], [], usage, code, indirect_calls=bindings)
    report = audit_roots(functions, names, ["root"], 1024)
    assert report["complete"] and report["roots"][0]["direct_chain_estimate"] == 96


def test_local_jump_targets_keep_calls_without_recursive_edges():
    symbols = fixture({"root": 0x100, "leaf": 0x200})
    code = assembly(symbols, "100: jr a5\n108: jal 0x200 <leaf>\n10c: jr t1\n")
    usage = {"root": [(16, "static")], "leaf": [(32, "static")]}
    bindings = [{"caller": "root", "address": 0x100, "local_targets": [0x108, 0x114],
                 "evidence": "bounded switch table"}]
    functions, names = prepare_graph(symbols, [], [], usage, code, indirect_calls=bindings)
    report = audit_roots(functions, names, ["root"], 1024)
    assert functions[0x100].callees == {0x200}
    assert report["roots"][0]["direct_chain_estimate"] == 48
    assert report["roots"][0]["issues"] == ["root: indirect jr at 0x10c"]


@pytest.mark.parametrize("change", ["both", "neither", "empty", "foreign", "entry",
                                    "middle", "bool", "call", "return", "direct",
                                    "duplicate", "missing_instruction"])
def test_bad_local_jump_bindings_fail_closed(change):
    symbols = fixture({"root": 0x100, "leaf": 0x200})
    record = {"caller": "root", "address": 0x100, "local_targets": [0x108],
              "evidence": "switch table"}
    bindings = [record]
    code = assembly(symbols, "100: jr a5\n")
    if change == "both": record["targets"] = ["leaf"]
    elif change == "neither": del record["local_targets"]
    elif change == "empty": record["local_targets"] = []
    elif change == "foreign": record["local_targets"] = [0x200]
    elif change == "entry": record["local_targets"] = [0x100]
    elif change == "middle": record["local_targets"] = [0x109]
    elif change == "bool": record["local_targets"] = [True]
    elif change == "call": code = assembly(symbols, "100: jalr a5\n")
    elif change == "return": code = assembly(symbols, "100: jr ra\n")
    elif change == "direct": code = assembly(symbols, "100: j 0x108 <root+8>\n")
    elif change == "duplicate":
        bindings.append({"caller": "root", "address": 0x100, "targets": ["leaf"],
                         "evidence": "callback"})
    else: code = code.replace("108: nop\n", "")
    with pytest.raises(ValueError):
        prepare_graph(symbols, [], [], {}, code, indirect_calls=bindings)


def test_local_jump_targets_do_not_hide_missing_frames_or_instructions():
    symbols = fixture({"root": 0x100})
    bindings = [{"caller": "root", "address": 0x100, "local_targets": [0x108],
                 "evidence": "switch table"}]
    code = assembly(symbols, "100: jr a5\n").replace("110: nop\n", "")
    functions, names = prepare_graph(symbols, [], [], {}, code, indirect_calls=bindings)
    report = audit_roots(functions, names, ["root"], 1024)
    assert not report["complete"]
    assert "root: missing compiler stack usage" in report["roots"][0]["issues"]
    assert "root: incomplete instruction coverage" in report["roots"][0]["issues"]


@pytest.mark.parametrize("change", ["caller", "outside", "unaligned", "direct", "return",
                                    "empty", "unlinked", "duplicate", "evidence"])
def test_bad_indirect_bindings_fail_closed(change):
    symbols = fixture({"root": 0x100, "leaf": 0x200})
    record = {"caller": "root", "address": 0x100, "targets": ["leaf"], "evidence": "table"}
    bindings = [record]
    code = assembly(symbols, "100: jalr a5\n104: jal 0x200 <leaf>\n108: jr ra\n")
    if change == "caller": record["caller"] = "missing"
    elif change == "outside": record["address"] = 0x200
    elif change == "unaligned": record["address"] = 0x101
    elif change == "direct": record["address"] = 0x104
    elif change == "return": record["address"] = 0x108
    elif change == "empty": record["targets"] = []
    elif change == "unlinked": record["targets"] = ["missing"]
    elif change == "duplicate": bindings.append(dict(record))
    else: record["evidence"] = " "
    with pytest.raises(ValueError):
        prepare_graph(symbols, [], [], {}, code, indirect_calls=bindings)


def test_indirect_target_missing_frames_and_recursion_stay_incomplete():
    symbols = fixture({"root": 0x100, "leaf": 0x200})
    bindings = [{"caller": "root", "address": 0x100, "targets": ["leaf"], "evidence": "table"}]
    functions, names = prepare_graph(symbols, [], [], {"root": [(16, "static")]},
        assembly(symbols, "100: jalr a5\n200: jal 0x100 <root>"), indirect_calls=bindings)
    report = audit_roots(functions, names, ["root"], 1024)
    assert not report["complete"]
    assert "leaf: missing compiler stack usage" in report["roots"][0]["issues"]
    assert "recursive call through root" in report["roots"][0]["issues"]


def test_missing_dynamic_and_recursive_evidence_is_incomplete():
    symbols = fixture({"root": 0x100, "variable": 0x200, "missing": 0x300})
    functions, names = prepare_graph(symbols,
        [], [], {"root": [(16, "static")], "variable": [(32, "dynamic,bounded")]},
        assembly(symbols, "100: jal 0x200 <variable>\n104: jal 0x300 <missing>\n200: jal 0x100 <root>\n"))
    result = audit_roots(functions, names, ["root"], 1024)
    assert not result["complete"]
    issues = result["roots"][0]["issues"]
    assert "recursive call through root" in issues
    assert "variable: non-static compiler stack usage" in issues
    assert "missing: missing compiler stack usage" in issues


def test_naked_frame_needs_verified_override():
    symbols = fixture({"irq": 0x100})
    usage = {"irq": [(0, "static")]}
    code = assembly(symbols, "100: addi sp, sp, -0xa0\n")
    functions, names = prepare_graph(symbols, [], [], usage, code)
    assert not audit_roots(functions, names, ["irq"], 1024)["complete"]
    functions, names = prepare_graph(symbols, [], [], usage, code,
                                     {"irq": 160})
    report = audit_roots(functions, names, ["irq"], 128)
    assert report["complete"] and report["roots"][0]["exceeds_usable_stack"]


def test_unlinked_frames_do_not_inflate_estimates():
    symbols = fixture({"root": 0x100})
    functions, names = prepare_graph(symbols, [], [],
                                     {"root": [(16, "static")], "unused": [(9000, "static")]}, assembly(symbols))
    report = audit_roots(functions, names, ["root"], 1024)
    assert report["complete"] and report["roots"][0]["direct_chain_estimate"] == 16


def test_tail_jumps_are_conservative_and_internal_jumps_are_not_recursion():
    symbols = fixture({"root": 0x100, "leaf": 0x200})
    functions, names = prepare_graph(symbols, [], [],
        {"root": [(16, "static")], "leaf": [(32, "static")]},
        assembly(symbols, "100: j 0x110 <root+0x10>\n110: j 0x200 <leaf>\n"))
    report = audit_roots(functions, names, ["root"], 1024)
    assert report["complete"] and report["roots"][0]["direct_chain_estimate"] == 48


def test_radare_self_edge_needs_an_actual_self_call():
    symbols = fixture({"root": 0x100})
    r2_functions = [{"name": "sym.root", "addr": 0x100}]
    graph = [{"name": "sym.root", "imports": ["sym.root"]}]
    for opcode, recursive in [("j", False), ("jal", True)]:
        functions, names = prepare_graph(symbols, r2_functions, graph, {"root": [(16, "static")]},
                                         assembly(symbols, f"100: {opcode} 0x100 <root>"))
        assert audit_roots(functions, names, ["root"], 1024)["complete"] is not recursive


def test_missing_or_incomplete_instruction_coverage_fails_closed():
    symbols = fixture({"root": 0x100})
    for code in ("", "100: ret\n", "100: nop\n11c: ret\n"):
        functions, names = prepare_graph(symbols, [], [], {"root": [(0, "static")]}, code)
        report = audit_roots(functions, names, ["root"], 1024)
        assert not report["complete"]
        assert "root: incomplete instruction coverage" in report["roots"][0]["issues"]


def test_unmodeled_stack_pointer_write_is_not_treated_as_zero_frame():
    symbols = fixture({"root": 0x100})
    functions, names = prepare_graph(symbols, [], [], {"root": [(0, "static")]},
                                     assembly(symbols, "100: sub sp, sp, a0"))
    report = audit_roots(functions, names, ["root"], 1024)
    assert not report["complete"]
    assert "root: unmodeled stack-pointer write at 0x100" in report["roots"][0]["issues"]


def test_storing_stack_pointer_does_not_change_stack_depth():
    symbols = fixture({"root": 0x100})
    functions, names = prepare_graph(symbols, [], [], {"root": [(0, "static")]},
                                     assembly(symbols, "100: sw sp, 0(a0)"))
    assert audit_roots(functions, names, ["root"], 1024)["complete"]


def test_deep_call_graph_is_iterative():
    nodes = {i: Function(i, 4, {f"function_{i}"}, frame=16) for i in range(2000)}
    for i in range(1999):
        nodes[i].callees.add(i + 1)
    result = audit_roots(nodes, {"root": 0}, ["root"], 8192)
    assert result["complete"]
    assert result["roots"][0]["direct_chain_estimate"] == 32000
    assert result["roots"][0]["exceeds_usable_stack"]


@pytest.mark.parametrize("indirect", [False, True])
def test_cli_exit_status_marks_incomplete_evidence(tmp_path, monkeypatch, indirect):
    symbols = fixture({"root": 0x100})
    files = {"symbols.json": json.dumps(symbols), "functions.json": "[]", "graph.json": "[]",
             "instructions.txt": assembly(symbols, "100: jalr a5" if indirect else ""),
             "unit.su": "source.c:1:1:root\t16\tstatic\n", "firmware.elf": "test fixture"}
    for name, content in files.items():
        (tmp_path / name).write_text(content)
    output = tmp_path / "report.json"
    monkeypatch.setattr("sys.argv", ["audit_wifi_stack.py", "--elf", str(tmp_path / "firmware.elf"),
        "--symbols", str(tmp_path / "symbols.json"), "--r2-functions", str(tmp_path / "functions.json"),
        "--r2-callgraph", str(tmp_path / "graph.json"), "--disassembly", str(tmp_path / "instructions.txt"),
        "--stack-usage", str(tmp_path), "--root", "root", "--output", str(output)])
    assert main() == (2 if indirect else 0)
    assert json.loads(output.read_text())["complete"] is not indirect


@pytest.mark.parametrize("matching", [False, True])
@pytest.mark.parametrize("local", [False, True])
def test_cli_indirect_bindings_are_elf_pinned_and_recorded(tmp_path, monkeypatch, capsys, matching, local):
    symbols = fixture({"root": 0x100, "leaf": 0x200})
    files = {"symbols.json": json.dumps(symbols), "functions.json": "[]", "graph.json": "[]",
             "instructions.txt": assembly(symbols, "100: jr a5" if local else "100: jalr a5"),
             "unit.su": "source.c:1:1:root\t16\tstatic\nsource.c:2:1:leaf\t32\tstatic\n",
             "firmware.elf": "test fixture"}
    for name, content in files.items():
        (tmp_path / name).write_text(content)
    bindings = {"elf_sha256": hashlib.sha256(b"test fixture").hexdigest() if matching else "stale",
                "calls": [{"caller": "root", "address": 0x100,
                           ("local_targets" if local else "targets"): [0x108] if local else ["leaf"],
                           "evidence": "test callback table"}]}
    path = tmp_path / "indirect.json"
    path.write_text(json.dumps(bindings))
    output = tmp_path / "report.json"
    monkeypatch.setattr("sys.argv", ["audit_wifi_stack.py", "--elf", str(tmp_path / "firmware.elf"),
        "--symbols", str(tmp_path / "symbols.json"), "--r2-functions", str(tmp_path / "functions.json"),
        "--r2-callgraph", str(tmp_path / "graph.json"), "--disassembly", str(tmp_path / "instructions.txt"),
        "--stack-usage", str(tmp_path), "--root", "root", "--indirect-calls", str(path),
        "--output", str(output)])
    if matching:
        assert main() == 0
        assert "complete under declared targets" in capsys.readouterr().out
        report = json.loads(output.read_text())
        assert report["indirect_calls"] == bindings["calls"]
        assert report["inputs"][str(path)] == hashlib.sha256(path.read_bytes()).hexdigest()
        assert report["roots"][0]["direct_chain_estimate"] == (16 if local else 48)
    else:
        with pytest.raises(SystemExit) as error:
            main()
        assert error.value.code == 2
        assert not output.exists()
