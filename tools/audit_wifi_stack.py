#!/usr/bin/env python3
"""Combine linked call edges with GCC stack usage; incomplete evidence fails closed."""

import argparse
from bisect import bisect_right
from dataclasses import dataclass, field
import hashlib
import json
from pathlib import Path
import re


@dataclass
class Function:
    address: int
    size: int
    names: set[str] = field(default_factory=set)
    callees: set[int] = field(default_factory=set)
    issues: set[str] = field(default_factory=set)
    frame: int = 0
    observed_frame: int = 0
    instructions: set[int] = field(default_factory=set)

    @property
    def name(self):
        return min(self.names, key=lambda name: (name.startswith("$"), len(name), name))


def stack_usage(paths):
    records = {}
    for path in paths:
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            location, amount, kind = line.rsplit("\t", 2)
            match = re.fullmatch(r"(.*):(\d+):(\d+):(.+)", location)
            if match is None or int(amount) < 0:
                raise ValueError(f"invalid stack-usage record: {path}: {line}")
            records.setdefault(match[4], []).append((int(amount), kind))
    return records


def linked_functions(symbols):
    functions, names = {}, {}
    for symbol in symbols["symbols"]:
        if symbol["type"] != "FUNC" or not symbol["size"] or symbol.get("is_imported"):
            continue
        address = symbol["vaddr"]
        function = functions.setdefault(address, Function(address, symbol["size"]))
        function.size = max(function.size, symbol["size"])
        function.names.add(symbol["name"])
        names[symbol["name"]] = address
    return functions, names


def prepare_graph(symbols, r2_functions, r2_graph, usage, disassembly, overrides=None,
                  indirect_calls=None):
    functions, names = linked_functions(symbols)
    overrides = overrides or {}
    for name in overrides:
        if name not in names:
            raise ValueError(f"frame override is not a linked function: {name}")
    addresses = sorted(functions)

    def containing(address):
        index = bisect_right(addresses, address) - 1
        if index >= 0:
            function = functions[addresses[index]]
            if address < function.address + function.size:
                return function
        return None

    bindings, local_bindings = {}, {}
    for record in indirect_calls or []:
        if not isinstance(record, dict):
            raise ValueError("indirect call must be an object")
        caller_name = record.get("caller")
        address = record.get("address")
        evidence = record.get("evidence")
        if not isinstance(caller_name, str) or caller_name not in names:
            raise ValueError(f"indirect caller is not a linked function: {caller_name}")
        if type(address) is not int or containing(address) is not functions[names[caller_name]]:
            raise ValueError(f"indirect call address is outside {caller_name}: {address}")
        if address in bindings or address in local_bindings:
            raise ValueError(f"duplicate indirect call address: 0x{address:x}")
        if not isinstance(evidence, str) or not evidence.strip():
            raise ValueError(f"indirect call needs evidence: 0x{address:x}")
        if ("targets" in record) == ("local_targets" in record):
            raise ValueError("declare either function targets or local jump targets")
        if "local_targets" in record:
            targets = record["local_targets"]
            caller = functions[names[caller_name]]
            if not isinstance(targets, list) or not targets or any(
                    type(target) is not int or target <= caller.address or
                    containing(target) is not caller for target in targets):
                raise ValueError(f"local targets must be inside {caller_name}: {targets}")
            local_bindings[address] = set(targets)
        else:
            targets = record["targets"]
            if not isinstance(targets, list) or not targets or any(
                    not isinstance(target, str) or target not in names for target in targets):
                raise ValueError(f"indirect targets must name linked functions: {targets}")
            bindings[address] = {names[target] for target in targets}
    bound_calls = set()

    r2_names = {item["name"]: item["addr"] for item in r2_functions}
    for node in r2_graph:
        caller = containing(r2_names.get(node["name"], -1))
        if caller is None:
            continue
        for target in node["imports"]:
            address = r2_names.get(target)
            if address is None and target.startswith("sym."):
                address = names.get(target[4:])
            callee = containing(address) if address is not None else None
            if callee is None:
                caller.issues.add(f"unresolved radare2 target: {target}")
            elif callee.address != caller.address:
                # radare2 can report local assembly jumps as self-call edges.
                # Actual self calls are recovered from the instructions below.
                caller.callees.add(callee.address)

    for line in disassembly.splitlines():
        instruction = re.match(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
        if instruction is None:
            continue
        address, opcode, operands = int(instruction[1], 16), instruction[2], instruction[3]
        caller = containing(address)
        if caller is None:
            continue
        caller.instructions.add(address)
        if opcode in ("jalr", "jr"):
            if address in local_bindings:
                if opcode != "jr" or operands.strip() == "ra":
                    raise ValueError(f"local targets require a non-return jr: 0x{address:x}")
                bound_calls.add(address)
            elif not (opcode == "jr" and operands.strip() == "ra"):
                if address in bindings:
                    caller.callees.update(bindings[address])
                    bound_calls.add(address)
                else:
                    caller.issues.add(f"indirect {opcode} at 0x{address:x}")
        elif opcode in ("jal", "call", "j", "tail"):
            target = re.search(r"\b0x([0-9a-f]+)\b", operands)
            if target is None:
                caller.issues.add(f"unresolved {opcode} at 0x{address:x}")
                continue
            callee = containing(int(target[1], 16))
            if callee is None:
                caller.issues.add(f"unmapped call/jump at 0x{address:x}")
            elif opcode in ("jal", "call") or callee.address != caller.address:
                caller.callees.add(callee.address)
        if opcode in ("addi", "addiw"):
            decrement = re.fullmatch(r"sp,\s*sp,\s*-(0x[0-9a-f]+|\d+)", operands)
            if decrement:
                caller.observed_frame = max(caller.observed_frame, int(decrement[1], 0))
        elif (operands.split(",", 1)[0].strip() == "sp" and
              opcode not in ("sb", "sh", "sw", "sd", "fsw", "fsd", "beq", "bne",
                             "blt", "bge", "bltu", "bgeu", "jr")):
            caller.issues.add(f"unmodeled stack-pointer write at 0x{address:x}")
        if opcode == "<unknown>":
            caller.issues.add(f"undecoded instruction at 0x{address:x}")

    unused_bindings = (bindings.keys() | local_bindings.keys()) - bound_calls
    if unused_bindings:
        addresses = ", ".join(f"0x{address:x}" for address in sorted(unused_bindings))
        raise ValueError(f"declared address is not an indirect call: {addresses}")

    for address, targets in local_bindings.items():
        if not targets <= containing(address).instructions:
            raise ValueError(f"local jump target is not a decoded instruction: 0x{address:x}")

    for function in functions.values():
        instructions = sorted(function.instructions)
        if (not instructions or instructions[0] != function.address or
                function.address + function.size - instructions[-1] not in (2, 4) or
                any(right - left not in (2, 4) for left, right in zip(instructions, instructions[1:]))):
            function.issues.add("incomplete instruction coverage")
        matches = [record for name in function.names for record in usage.get(name, [])]
        if not matches:
            # GCC sometimes omits the numeric suffix of an IPA clone in .su.
            for name in function.names:
                shortened = re.sub(r"\.(isra|constprop)\.\d+$", r".\1", name)
                matches.extend(usage.get(shortened, []))
        manual = [overrides[name] for name in function.names if name in overrides]
        if manual:
            function.frame = max(manual)
        elif matches:
            function.frame = max(amount for amount, _ in matches)
            if any(kind != "static" for _, kind in matches):
                function.issues.add("non-static compiler stack usage")
        else:
            function.issues.add("missing compiler stack usage")
        if function.observed_frame > function.frame:
            function.issues.add("assembly stack decrement exceeds recorded frame")
            function.frame = function.observed_frame
    return functions, names


def audit_roots(functions, names, roots, limit, reserve=0):
    if reserve < 0 or reserve >= limit:
        raise ValueError("reserve must be nonnegative and smaller than the stack limit")
    # Collapse recursive components before the longest-path pass. A recursive
    # component is counted once for the estimate, never reported as bounded.
    reverse = {address: set() for address in functions}
    for address, node in functions.items():
        for callee in node.callees:
            reverse[callee].add(address)
    seen, finished = set(), []
    for address in sorted(functions):
        stack = [(address, False)]
        while stack:
            current, expanded = stack.pop()
            if expanded:
                finished.append(current)
            elif current not in seen:
                seen.add(current)
                stack.append((current, True))
                stack.extend((callee, False) for callee in sorted(functions[current].callees, reverse=True))
    components, component_of = [], {}
    for address in reversed(finished):
        if address in component_of:
            continue
        members, stack = [], [address]
        while stack:
            current = stack.pop()
            if current in component_of:
                continue
            component_of[current] = len(components)
            members.append(current)
            stack.extend(reverse[current])
        components.append(sorted(members))
    cache = {}
    for index in reversed(range(len(components))):
        members = components[index]
        issues = {f"{functions[address].name}: {issue}"
                  for address in members for issue in functions[address].issues}
        if len(members) > 1 or members[0] in functions[members[0]].callees:
            issues.update(f"recursive call through {functions[address].name}" for address in members)
        children = {component_of[callee] for address in members
                    for callee in functions[address].callees if component_of[callee] != index}
        longest, chain = 0, []
        for child in sorted(children):
            amount, route, problems = cache[child]
            issues.update(problems)
            if amount > longest:
                longest, chain = amount, route
        cache[index] = (sum(functions[address].frame for address in members) + longest,
                        [functions[address].name for address in members] + chain, issues)

    reports = []
    for root in roots:
        if root not in names:
            raise ValueError(f"root is not a linked function: {root}")
        amount, chain, issues = cache[component_of[names[root]]]
        reports.append({"root": root, "direct_chain_estimate": amount, "chain": chain,
                        "complete": not issues, "issues": sorted(issues),
                        "exceeds_usable_stack": amount > limit - reserve})
    return {"limit": limit, "reserve": reserve, "usable": limit - reserve,
            "complete": all(report["complete"] for report in reports), "roots": reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--symbols", type=Path, required=True, help="rabin2 -sj JSON")
    parser.add_argument("--r2-functions", type=Path, required=True, help="radare2 aa;aflj JSON")
    parser.add_argument("--r2-callgraph", type=Path, required=True, help="radare2 aa;agCj JSON")
    parser.add_argument("--disassembly", type=Path, required=True,
                        help="LLVM disassembly with --no-show-raw-insn")
    parser.add_argument("--stack-usage", type=Path, required=True, help="directory containing .su files")
    parser.add_argument("--root", action="append", required=True)
    parser.add_argument("--frame", action="append", default=[], metavar="NAME=BYTES",
                        help="manually verified frame size for assembly functions")
    parser.add_argument("--indirect-calls", type=Path,
                        help="ELF-hash-pinned JSON with function or intra-function jump targets")
    parser.add_argument("--limit", type=int, default=8192)
    parser.add_argument("--reserve", type=int, default=0)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        overrides = {}
        for entry in args.frame:
            name, amount = entry.rsplit("=", 1)
            amount = int(amount, 0)
            if amount < 0:
                raise ValueError("frame sizes must be nonnegative")
            overrides[name] = amount
        indirect_calls = []
        if args.indirect_calls is not None:
            bindings = json.loads(args.indirect_calls.read_text())
            if not isinstance(bindings, dict) or not isinstance(bindings.get("calls"), list):
                raise ValueError("indirect calls file must contain a calls list")
            elf_hash = hashlib.sha256(args.elf.read_bytes()).hexdigest()
            if bindings.get("elf_sha256") != elf_hash:
                raise ValueError("indirect calls file does not match the ELF hash")
            indirect_calls = bindings["calls"]
        usage_files = sorted(args.stack_usage.rglob("*.su"))
        if not usage_files:
            raise ValueError("no .su files found")
        functions, names = prepare_graph(
            json.loads(args.symbols.read_text()), json.loads(args.r2_functions.read_text()),
            json.loads(args.r2_callgraph.read_text()), stack_usage(usage_files),
            args.disassembly.read_text(), overrides, indirect_calls)
        report = audit_roots(functions, names, args.root, args.limit, args.reserve)
        report["frame_overrides"] = overrides
        report["indirect_calls"] = indirect_calls
        input_paths = [args.elf, args.symbols, args.r2_functions, args.r2_callgraph,
                       args.disassembly, *usage_files]
        if args.indirect_calls is not None:
            input_paths.append(args.indirect_calls)
        report["inputs"] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in input_paths}
        report["largest_linked_frames"] = sorted(
            ({"name": node.name, "bytes": node.frame} for node in functions.values()),
            key=lambda item: (-item["bytes"], item["name"]))[:20]
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        for root in report["roots"]:
            status = "complete" if root["complete"] else "incomplete"
            if root["complete"] and indirect_calls:
                status += " under declared targets"
            print(f"{root['root']}: {root['direct_chain_estimate']} bytes, {status}, "
                  f"{len(root['issues'])} unresolved conditions")
        if not report["complete"]:
            return 2
        return int(any(root["exceeds_usable_stack"] for root in report["roots"]))
    except (ValueError, KeyError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
