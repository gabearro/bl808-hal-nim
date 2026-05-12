#!/usr/bin/env python3
"""Report BL808 HAL/kernel source reachability from validation examples."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
SRC_ROOT = REPO_ROOT / "src"
BL808_ROOT = SRC_ROOT / "bl808"
KERNEL_ROOT = BL808_ROOT / "kernel"
EXAMPLES_ROOT = REPO_ROOT / "examples"
DEFAULT_MANIFESTS = (
    REPO_ROOT / "tools" / "kernel_validation.json",
    REPO_ROOT / "tools" / "hardware_validation.json",
)
EFUSE_PROGRAM_RE = re.compile(r"\b(efuseProgramWord|EfPgmEn|EfPgmCmd)\b")


IMPORT_START_RE = re.compile(r"^\s*(import|include)\s+(.+)$")
FROM_IMPORT_RE = re.compile(r"^\s*from\s+([^\s]+)\s+import\s+")


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
        "--markdown",
        action="store_true",
        help="Emit a Markdown report instead of terse text.",
    )
    parser.add_argument(
        "--fail-on-uncovered",
        action="store_true",
        help="Return non-zero if any selected non-empty module is not reached by validation examples.",
    )
    parser.add_argument(
        "--scope",
        choices=("hal", "src"),
        default="hal",
        help="Audit root HAL modules only, or every Nim module under src/bl808.",
    )
    parser.add_argument(
        "--forbid-efuse-programming",
        action="store_true",
        help="Return non-zero if a validation entry example calls eFuse programming APIs/registers.",
    )
    return parser.parse_args()


def source_index() -> dict[str, Path]:
    paths = sorted(BL808_ROOT.rglob("*.nim"))
    index: dict[str, Path] = {}
    for path in paths:
        rel = path.relative_to(SRC_ROOT).with_suffix("")
        index[rel.as_posix()] = path
    return index


def target_modules(scope: str, index: dict[str, Path]) -> list[Path]:
    if scope == "hal":
        paths = sorted(BL808_ROOT.glob("*.nim"))
    else:
        paths = sorted(index.values())
    return [
        path for path in paths
        if path.read_text(encoding="utf-8", errors="replace").strip()
    ]


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


def import_specs(path: Path) -> list[str]:
    specs: list[str] = []
    continued = ""
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = strip_comment(raw_line).strip()
        if not line:
            continue
        if continued:
            line = continued + " " + line
        if line.endswith(","):
            continued = line[:-1]
            continue
        continued = ""

        match = FROM_IMPORT_RE.match(line)
        if match:
            specs.append(match.group(1).strip())
            continue

        match = IMPORT_START_RE.match(line)
        if not match:
            continue
        body = match.group(2)
        body = body.replace("(", " ").replace(")", " ")
        for token in re.split(r"[,\s]+", body):
            token = token.strip()
            if not token or token in {"except", "as"}:
                continue
            if "=" in token or token.startswith("{"):
                continue
            specs.append(token)
    return specs


def resolve_import(spec: str, importer: Path, index: dict[str, Path]) -> Path | None:
    spec = spec.strip("\"'")
    if not (spec.startswith("./") or spec.startswith("../")):
        spec = spec.split(".", 1)[0]
    if not spec:
        return None

    candidates: list[Path] = []
    if spec.startswith("."):
        candidates.append((importer.parent / spec).resolve())
    elif spec.startswith("../") or spec.startswith("./"):
        candidates.append((importer.parent / spec).resolve())
    else:
        normalized = spec.replace("\\", "/")
        if normalized in index:
            return index[normalized]
        if not normalized.startswith("bl808/"):
            prefixed = f"bl808/{normalized}"
            if prefixed in index:
                return index[prefixed]
        candidates.append((SRC_ROOT / normalized).resolve())

    for candidate in candidates:
        if candidate.suffix != ".nim":
            candidate = candidate.with_suffix(".nim")
        try:
            rel = candidate.relative_to(SRC_ROOT)
        except ValueError:
            continue
        found = index.get(rel.with_suffix("").as_posix())
        if found is not None:
            return found
    return None


def reachable_from(start: Path, index: dict[str, Path]) -> set[Path]:
    seen: set[Path] = set()
    stack = [start]
    while stack:
        path = stack.pop()
        if path in seen:
            continue
        seen.add(path)
        for spec in import_specs(path):
            resolved = resolve_import(spec, path, index)
            if resolved is not None and resolved not in seen:
                stack.append(resolved)
    return seen


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


def efuse_programming_sites(paths: Iterable[Path]) -> list[tuple[Path, int, str]]:
    sites: list[tuple[Path, int, str]] = []
    for path in sorted(paths):
        for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
            text = strip_comment(line)
            if EFUSE_PROGRAM_RE.search(text):
                sites.append((path, line_no, line.strip()))
    return sites


def module_label(path: Path) -> str:
    return path.relative_to(SRC_ROOT).with_suffix("").as_posix()


def main() -> int:
    args = parse_args()
    manifests = tuple(args.manifest) if args.manifest else DEFAULT_MANIFESTS
    index = source_index()
    modules = target_modules(args.scope, index)
    module_kind = "HAL" if args.scope == "hal" else "source"
    examples = sorted(EXAMPLES_ROOT.glob("*.nim"))
    validation_starts = manifest_sources(manifests)
    efuse_sites = efuse_programming_sites(validation_starts) if args.forbid_efuse_programming else []

    all_reachable: set[Path] = set()
    validation_reachable: set[Path] = set()
    reached_by: dict[Path, list[Path]] = {path: [] for path in modules}
    validation_reached_by: dict[Path, list[Path]] = {path: [] for path in modules}

    for example in examples:
        reachable = reachable_from(example, index)
        all_reachable.update(reachable)
        for module in modules:
            if module in reachable:
                reached_by[module].append(example)
        if example.resolve() in validation_starts:
            validation_reachable.update(reachable)
            for module in modules:
                if module in reachable:
                    validation_reached_by[module].append(example)

    uncovered = [path for path in modules if path not in validation_reachable]
    compile_only = [
        path for path in modules
        if path in all_reachable and path not in validation_reachable
    ]

    if args.markdown:
        title_scope = "HAL" if args.scope == "hal" else "Source"
        print(f"# BL808 {title_scope} Coverage Audit")
        print()
        print(f"- {module_kind.capitalize()} modules: {len(modules)} non-empty files")
        print(f"- Examples: {len(examples)}")
        print(f"- Validation entry examples: {len(validation_starts)}")
        print(f"- {module_kind.capitalize()} modules reached by validation examples: {len(modules) - len(uncovered)}")
        print(f"- {module_kind.capitalize()} modules not reached by validation examples: {len(uncovered)}")
        if args.forbid_efuse_programming:
            print(f"- eFuse programming sites in validation entries: {len(efuse_sites)}")
        print()
        print(f"## Uncovered {module_kind.capitalize()} Modules")
        print()
        if uncovered:
            for path in uncovered:
                status = "compile-only" if path in compile_only else "no example reachability"
                print(f"- `{module_label(path)}` ({status})")
        else:
            print("- None")
        if args.forbid_efuse_programming:
            print()
            print("## eFuse Programming Guard")
            print()
            if efuse_sites:
                for path, line_no, line in efuse_sites:
                    rel = path.relative_to(REPO_ROOT)
                    print(f"- `{rel}:{line_no}` `{line}`")
            else:
                print("- No validation entry example calls eFuse programming APIs/registers.")
        print()
        print(f"## Covered {module_kind.capitalize()} Modules")
        print()
        for path in modules:
            if path in validation_reachable:
                examples_text = ", ".join(e.stem for e in validation_reached_by[path][:4])
                more = "" if len(validation_reached_by[path]) <= 4 else f", +{len(validation_reached_by[path]) - 4} more"
                print(f"- `{module_label(path)}` via {examples_text}{more}")
    else:
        print(f"{module_kind.capitalize()} modules: {len(modules)}")
        print(f"examples: {len(examples)}")
        print(f"validation entry examples: {len(validation_starts)}")
        print(f"covered by validation examples: {len(modules) - len(uncovered)}")
        print(f"uncovered by validation examples: {len(uncovered)}")
        if args.forbid_efuse_programming:
            print(f"efuse programming sites in validation entries: {len(efuse_sites)}")
        for path in uncovered:
            status = "compile-only" if path in compile_only else "no example reachability"
            print(f"UNCOVERED {module_label(path)} {status}")
        for path, line_no, line in efuse_sites:
            rel = path.relative_to(REPO_ROOT)
            print(f"EFUSE_PROGRAMMING {rel}:{line_no} {line}")

    failed = (args.fail_on_uncovered and uncovered) or (args.forbid_efuse_programming and efuse_sites)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
