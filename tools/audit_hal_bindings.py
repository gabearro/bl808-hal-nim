#!/usr/bin/env python3
"""Audit exported BL808 Nim bindings against validation entry sources.

This is intentionally stricter than module reachability. It inventories
top-level exported bindings under src/bl808 and reports whether validation
entry examples mention each binding directly. eFuse programming bindings are
classified separately because they are intentionally not run on hardware.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, NamedTuple


REPO_ROOT = Path(__file__).resolve().parents[1]
SRC_ROOT = REPO_ROOT / "src"
BL808_ROOT = SRC_ROOT / "bl808"
EXAMPLES_ROOT = REPO_ROOT / "examples"
DEFAULT_MANIFESTS = (
    REPO_ROOT / "tools" / "kernel_validation.json",
    REPO_ROOT / "tools" / "hardware_validation.json",
)

CALLABLE_RE = re.compile(
    r"^\s*(proc|template|macro|iterator|converter)\s+([A-Za-z_][A-Za-z0-9_]*)\*"
)
BLOCK_RE = re.compile(r"^(\s*)(const|type|var|let)\s*$")
BLOCK_ITEM_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\*(?:\[[^\]]+\])?\s*(?:\{|:|=)")
IMPORT_START_RE = re.compile(r"^\s*(import|include)\s+(.+)$")
FROM_IMPORT_RE = re.compile(r"^\s*from\s+([^\s]+)\s+import\s+")
EFUSE_PROGRAM_NAMES = {
    "EfPgmCmd",
    "EfPgmEn",
    "efuseProgramWord",
}
FIRMWARE_REIMPL_MODULES = {
    "bl808/blecontroller",
    "bl808/wifi_fw",
}
CORE_DEFINES = ("bl808m0", "bl808d0", "bl808lp")


@dataclass(frozen=True)
class Binding:
    module: str
    path: Path
    line_no: int
    kind: str
    name: str
    text: str
    condition: tuple[str, ...] | None = None

    @property
    def key(self) -> str:
        return f"{self.module}.{self.name}"

    @property
    def category(self) -> str:
        if self.module == "bl808/efuse" and self.name in EFUSE_PROGRAM_NAMES:
            return "efuse-programming"
        if self.module in FIRMWARE_REIMPL_MODULES:
            return "firmware-reimpl"
        if "{.importc" in self.text or " importc" in self.text:
            return "external-c"
        return "ordinary"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        action="append",
        type=Path,
        default=[],
        help="Validation manifest to include. Defaults to kernel and hardware manifests.",
    )
    parser.add_argument(
        "--source-set",
        choices=("validation", "validation-closure", "all-examples"),
        default="validation",
        help=(
            "Scan manifest validation entry examples, those examples plus their "
            "transitive src/bl808 Nim imports, or every examples/*.nim file."
        ),
    )
    parser.add_argument(
        "--kind",
        choices=("all", "callable", "data"),
        default="callable",
        help="Which binding kind to report.",
    )
    parser.add_argument(
        "--include-category",
        action="append",
        default=[],
        help="Only include this category. Repeatable. Categories: ordinary, external-c, firmware-reimpl, efuse-programming.",
    )
    parser.add_argument(
        "--fail-on-uncovered",
        action="store_true",
        help="Return non-zero when any included non-excluded binding lacks a direct validation reference.",
    )
    parser.add_argument(
        "--declared-check",
        action="store_true",
        help="Generate and compile a temporary Nim file that references every included binding visible for --core.",
    )
    parser.add_argument(
        "--core",
        choices=CORE_DEFINES,
        default="bl808m0",
        help="Target core define used by --declared-check.",
    )
    parser.add_argument(
        "--nim",
        default="nim",
        help="Nim compiler executable used by --declared-check.",
    )
    parser.add_argument(
        "--nim-define",
        action="append",
        default=[],
        metavar="NAME[=VALUE]",
        help="Extra -d define passed to Nim during --declared-check.",
    )
    parser.add_argument(
        "--markdown",
        action="store_true",
        help="Emit Markdown.",
    )
    parser.add_argument(
        "--show-covered",
        action="store_true",
        help="Include covered bindings in Markdown output.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=200,
        help="Maximum uncovered bindings to print in terse output.",
    )
    return parser.parse_args()


def strip_comment(line: str) -> str:
    in_string = False
    escaped = False
    for idx, ch in enumerate(line):
        if escaped:
            escaped = False
            continue
        if ch == "\\":
            escaped = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if ch == "#" and not in_string:
            return line[:idx]
    return line


def module_label(path: Path) -> str:
    return path.relative_to(SRC_ROOT).with_suffix("").as_posix()


def bindings_in_file(path: Path) -> list[Binding]:
    module = module_label(path)
    out: list[Binding] = []
    block_kind: str | None = None
    block_indent = 0
    block_item_indent: int | None = None
    condition_stack: list[tuple[int, tuple[str, ...]]] = []

    def active_condition() -> tuple[str, ...] | None:
        if not condition_stack:
            return None
        active = set(CORE_DEFINES)
        for _, cond in condition_stack:
            active &= set(cond)
        return tuple(core for core in CORE_DEFINES if core in active)

    for line_no, raw in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
        text = strip_comment(raw).rstrip()
        if not text.strip():
            continue
        indent = len(text) - len(text.lstrip())
        stripped = text.strip()

        if stripped.startswith("elif ") and condition_stack and condition_stack[-1][0] == indent:
            cores = tuple(re.findall(r"defined\((bl808m0|bl808d0|bl808lp)\)", stripped))
            condition_stack[-1] = (indent, cores or CORE_DEFINES)
            continue
        if stripped.startswith("else:") and condition_stack and condition_stack[-1][0] == indent:
            condition_stack[-1] = (indent, CORE_DEFINES)
            continue
        while condition_stack and indent <= condition_stack[-1][0]:
            condition_stack.pop()

        if stripped.startswith("when "):
            cores = tuple(re.findall(r"defined\((bl808m0|bl808d0|bl808lp)\)", stripped))
            if cores:
                condition_stack.append((indent, cores))
            continue

        callable_match = CALLABLE_RE.match(text)
        if callable_match:
            out.append(Binding(module, path, line_no, callable_match.group(1),
                               callable_match.group(2), raw.strip(),
                               active_condition()))
            block_kind = None
            continue

        block_match = BLOCK_RE.match(text)
        if block_match:
            block_kind = block_match.group(2)
            block_indent = len(block_match.group(1))
            block_item_indent = None
            continue

        if block_kind is not None:
            if indent <= block_indent:
                block_kind = None
                block_item_indent = None
            else:
                item_match = BLOCK_ITEM_RE.match(text)
                if item_match and (block_item_indent is None or indent == block_item_indent):
                    block_item_indent = indent
                    out.append(Binding(module, path, line_no, block_kind,
                                       item_match.group(1), raw.strip(),
                                       active_condition()))

    return out


def all_bindings() -> list[Binding]:
    result: list[Binding] = []
    for path in sorted(BL808_ROOT.rglob("*.nim")):
        result.extend(bindings_in_file(path))
    return result


def manifest_sources(manifests: Iterable[Path]) -> set[Path]:
    sources: set[Path] = set()
    for manifest in manifests:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        for test in data.get("tests", []):
            for build in test.get("build", []):
                source = build.get("source")
                if source:
                    path = (REPO_ROOT / source).resolve()
                    if path.exists():
                        sources.add(path)
    return sources


def split_import_specs(text: str) -> list[str]:
    specs: list[str] = []
    for part in text.split(","):
        spec = part.strip()
        if not spec:
            continue
        spec = re.split(r"\s+as\s+", spec, maxsplit=1)[0].strip()
        spec = spec.split()[0] if spec.split() else spec
        spec = spec.strip('"')
        if spec:
            specs.append(spec)
    return specs


def nim_module_path(spec: str, importer: Path) -> Path | None:
    if spec.startswith("std/") or spec in {"system", "strutils", "macros", "volatile"}:
        return None
    if spec.startswith("bl808/"):
        candidate = SRC_ROOT / f"{spec}.nim"
    elif importer.is_relative_to(SRC_ROOT):
        candidate = importer.parent / f"{spec}.nim"
    else:
        candidate = SRC_ROOT / f"{spec}.nim"
    if candidate.exists() and candidate.is_relative_to(BL808_ROOT):
        return candidate.resolve()
    return None


def imported_nim_modules(path: Path) -> set[Path]:
    imports: set[Path] = set()
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    in_import_block = False
    block_indent = 0
    for raw in lines:
        text = strip_comment(raw).rstrip()
        if not text.strip():
            continue
        indent = len(text) - len(text.lstrip())
        stripped = text.strip()

        from_match = FROM_IMPORT_RE.match(stripped)
        if from_match:
            module_path = nim_module_path(from_match.group(1), path)
            if module_path is not None:
                imports.add(module_path)
            in_import_block = False
            continue

        inline_match = IMPORT_START_RE.match(stripped)
        if inline_match:
            keyword, rest = inline_match.groups()
            if rest.strip():
                for spec in split_import_specs(rest):
                    module_path = nim_module_path(spec, path)
                    if module_path is not None:
                        imports.add(module_path)
                in_import_block = False
            else:
                in_import_block = True
                block_indent = indent
            continue

        if in_import_block:
            if indent <= block_indent:
                in_import_block = False
            else:
                for spec in split_import_specs(stripped):
                    module_path = nim_module_path(spec, path)
                    if module_path is not None:
                        imports.add(module_path)
                continue

    return imports


def transitive_import_closure(entries: Iterable[Path]) -> set[Path]:
    seen = {path.resolve() for path in entries}
    queue = list(seen)
    while queue:
        current = queue.pop()
        for imported in imported_nim_modules(current):
            if imported not in seen:
                seen.add(imported)
                queue.append(imported)
    return seen


def source_paths(args: argparse.Namespace) -> list[Path]:
    if args.source_set == "all-examples":
        return sorted(EXAMPLES_ROOT.glob("*.nim"))
    manifests = tuple(args.manifest) if args.manifest else DEFAULT_MANIFESTS
    entries = manifest_sources(manifests)
    if args.source_set == "validation-closure":
        return sorted(transitive_import_closure(entries))
    return sorted(entries)



def strip_exported_declarations(text: str) -> str:
    lines: list[str] = []
    block_kind: str | None = None
    block_indent = 0
    block_item_indent: int | None = None
    for raw in text.splitlines():
        stripped_line = strip_comment(raw).rstrip()
        if not stripped_line.strip():
            lines.append(raw)
            continue
        indent = len(stripped_line) - len(stripped_line.lstrip())

        if CALLABLE_RE.match(stripped_line):
            lines.append("")
            block_kind = None
            block_item_indent = None
            continue

        block_match = BLOCK_RE.match(stripped_line)
        if block_match:
            block_kind = block_match.group(2)
            block_indent = len(block_match.group(1))
            block_item_indent = None
            lines.append(raw)
            continue

        if block_kind is not None:
            if indent <= block_indent:
                block_kind = None
                block_item_indent = None
            else:
                item_match = BLOCK_ITEM_RE.match(stripped_line)
                if item_match and (block_item_indent is None or indent == block_item_indent):
                    block_item_indent = indent
                    lines.append("")
                    continue

        lines.append(raw)
    return "\n".join(lines)


def source_text(paths: Iterable[Path]) -> str:
    chunks: list[str] = []
    for path in paths:
        chunks.append(strip_exported_declarations(path.read_text(encoding="utf-8", errors="replace")))
    return "\n".join(chunks)


def kind_included(binding: Binding, wanted: str) -> bool:
    if wanted == "all":
        return True
    is_callable = binding.kind in {"proc", "template", "macro", "iterator", "converter"}
    return is_callable if wanted == "callable" else not is_callable


def binding_visible_on_core(binding: Binding, core: str) -> bool:
    return binding.condition is None or core in binding.condition


class ReferenceIndex(NamedTuple):
    bare_names: set[str]
    dotted_names: set[str]
    qualified_names: set[tuple[str, str]]


def build_reference_index(text: str) -> ReferenceIndex:
    bare_names = set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", text))
    dotted_names = set(re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*)\b", text))
    qualified_names = {
        (module, name)
        for module, name in re.findall(
            r"\b([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\b",
            text,
        )
    }
    return ReferenceIndex(bare_names, dotted_names, qualified_names)


def direct_reference(binding: Binding, refs: ReferenceIndex, duplicate_names: set[str]) -> str | None:
    module_short = binding.module.rsplit("/", 1)[-1]
    if (module_short, binding.name) in refs.qualified_names:
        return "qualified"
    if (binding.module.replace("/", "_"), binding.name) in refs.qualified_names:
        return "qualified"

    if binding.name in refs.dotted_names and binding.name not in duplicate_names:
        return "method"

    if binding.name in refs.bare_names:
        return "ambiguous" if binding.name in duplicate_names else "bare"
    return None


def summarize(bindings: list[Binding], source: str, args: argparse.Namespace) -> tuple[dict[str, int], list[tuple[Binding, str]], list[Binding]]:
    include_categories = set(args.include_category)
    filtered = [
        b for b in bindings
        if kind_included(b, args.kind)
        and (not include_categories or b.category in include_categories)
    ]
    name_counts: dict[str, int] = {}
    for binding in filtered:
        name_counts[binding.name] = name_counts.get(binding.name, 0) + 1
    duplicate_names = {name for name, count in name_counts.items() if count > 1}

    refs = build_reference_index(source)
    covered: list[tuple[Binding, str]] = []
    uncovered: list[Binding] = []
    for binding in filtered:
        evidence = direct_reference(binding, refs, duplicate_names)
        if evidence is None:
            uncovered.append(binding)
        else:
            covered.append((binding, evidence))

    stats: dict[str, int] = {
        "total": len(filtered),
        "covered": len(covered),
        "uncovered": len(uncovered),
    }
    for binding in filtered:
        stats[f"category:{binding.category}"] = stats.get(f"category:{binding.category}", 0) + 1
    for binding, _ in covered:
        stats[f"covered:{binding.category}"] = stats.get(f"covered:{binding.category}", 0) + 1
    return stats, covered, uncovered


def nim_alias(module: str) -> str:
    return "m_" + re.sub(r"[^A-Za-z0-9_]", "_", module)


def compile_declared_check(bindings: list[Binding], args: argparse.Namespace) -> int:
    include_categories = set(args.include_category)
    filtered = [
        b for b in bindings
        if kind_included(b, args.kind)
        and (not include_categories or b.category in include_categories)
        and binding_visible_on_core(b, args.core)
    ]
    modules = sorted({b.module for b in filtered})
    lines: list[str] = [
        "## Generated by tools/audit_hal_bindings.py --declared-check",
        "## This file is temporary; do not edit.",
        "",
    ]
    for module in modules:
        lines.append(f"import {module} as {nim_alias(module)}")
    lines.append("")
    lines.append("template requireDeclared(x: untyped, label: static[string]) =")
    lines.append("  static:")
    lines.append("    doAssert declared(x), label")
    lines.append("")

    for idx, binding in enumerate(filtered):
        alias = nim_alias(binding.module)
        label = f"{binding.key} at {binding.path.relative_to(REPO_ROOT)}:{binding.line_no}"
        if binding.kind == "type":
            lines.append(f"requireDeclared({alias}.{binding.name}, \"missing {label}\")")
        elif binding.kind in {"const", "let", "var"}:
            lines.append(f"requireDeclared({alias}.{binding.name}, \"missing {label}\")")
        else:
            lines.append(f"requireDeclared({alias}.{binding.name}, \"missing {label}\")")

    with tempfile.TemporaryDirectory(prefix="bl808-binding-check-") as tmp:
        check_path = Path(tmp) / "binding_declared_check.nim"
        check_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        cmd = [
            args.nim,
            "c",
            "--compileOnly",
            f"-d:{args.core}",
            "-d:bl808kernel",
            f"--path:{SRC_ROOT}",
            f"--nimcache:{Path(tmp) / 'nimcache'}",
            str(check_path),
        ]
        for define in args.nim_define:
            cmd.insert(4, f"-d:{define}")
        proc = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        print(f"declared-check core={args.core} bindings={len(filtered)} modules={len(modules)}")
        if proc.returncode == 0:
            print("PASS declared-check")
            return 0
        print(proc.stdout)
        print("FAIL declared-check")
        return proc.returncode


def print_markdown(stats: dict[str, int], covered: list[tuple[Binding, str]], uncovered: list[Binding], args: argparse.Namespace) -> None:
    print("# BL808 Binding Audit")
    print()
    print(f"- Source set: `{args.source_set}`")
    print(f"- Binding kind: `{args.kind}`")
    if args.include_category:
        print(f"- Included categories: `{', '.join(args.include_category)}`")
    print(f"- Bindings considered: {stats['total']}")
    print(f"- Directly referenced by validation source: {stats['covered']}")
    print(f"- Not directly referenced by validation source: {stats['uncovered']}")
    print()
    print("## Categories")
    print()
    for key in sorted(k for k in stats if k.startswith("category:")):
        category = key.split(":", 1)[1]
        print(f"- `{category}`: {stats[key]} total, {stats.get(f'covered:{category}', 0)} referenced")
    print()
    print("## Uncovered Bindings")
    print()
    if uncovered:
        for binding in uncovered:
            rel = binding.path.relative_to(REPO_ROOT)
            print(f"- `{binding.key}` ({binding.kind}, {binding.category}) at `{rel}:{binding.line_no}`")
    else:
        print("- None")
    if args.show_covered:
        print()
        print("## Covered Bindings")
        print()
        for binding, evidence in covered:
            rel = binding.path.relative_to(REPO_ROOT)
            print(f"- `{binding.key}` ({binding.kind}, {binding.category}, {evidence}) at `{rel}:{binding.line_no}`")


def print_terse(stats: dict[str, int], uncovered: list[Binding], args: argparse.Namespace) -> None:
    print(f"source set: {args.source_set}")
    print(f"binding kind: {args.kind}")
    print(f"bindings considered: {stats['total']}")
    print(f"direct references: {stats['covered']}")
    print(f"uncovered: {stats['uncovered']}")
    for key in sorted(k for k in stats if k.startswith("category:")):
        category = key.split(":", 1)[1]
        print(f"category {category}: {stats[key]} total, {stats.get(f'covered:{category}', 0)} referenced")
    for binding in uncovered[:args.limit]:
        rel = binding.path.relative_to(REPO_ROOT)
        print(f"UNCOVERED {binding.key} {binding.kind} {binding.category} {rel}:{binding.line_no}")
    if len(uncovered) > args.limit:
        print(f"... {len(uncovered) - args.limit} more uncovered")


def main() -> int:
    args = parse_args()
    bindings = all_bindings()
    if args.declared_check:
        return compile_declared_check(bindings, args)
    text = source_text(source_paths(args))
    stats, covered, uncovered = summarize(bindings, text, args)
    if args.markdown:
        print_markdown(stats, covered, uncovered, args)
    else:
        print_terse(stats, uncovered, args)
    return 1 if args.fail_on_uncovered and uncovered else 0


if __name__ == "__main__":
    raise SystemExit(main())
