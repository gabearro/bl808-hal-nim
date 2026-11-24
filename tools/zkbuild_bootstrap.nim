## Fetch a pinned Nim-only cryptographic dependency into ignored build output.
import std/[os, osproc, strutils]

const revision = "502a868ba2862f2b267120989f035757cc8d5ea5"
let root = currentSourcePath().parentDir.parentDir
let dest = root / "build/zkbuild-deps/constantine"
let portable = root / "build/zkbuild-deps/portable"
createDir(dest.parentDir)
if not dirExists(dest / ".git"):
  let rc = execCmd("git clone " &
    quoteShell("https://github.com/mratsim/constantine.git") & " " & quoteShell(dest))
  if rc != 0: quit(rc)
let check = execCmdEx("git -C " & quoteShell(dest) & " rev-parse HEAD")
let dirty = execCmdEx("git -C " & quoteShell(dest) & " status --porcelain")
if dirty.exitCode != 0 or dirty.output.strip().len != 0:
  quit("Pinned Constantine dependency has local modifications", 1)
if check.exitCode != 0 or check.output.strip() != revision:
  if execCmd("git -C " & quoteShell(dest) & " checkout --detach " & revision) != 0:
    quit("Unable to checkout pinned Constantine revision", 1)
createDir(portable)
copyDir(dest / "constantine", portable / "constantine")
let patched = execCmdEx("patch --batch -p1 -i " &
  quoteShell(root / "tools/zkbuild_constantine.patch"), workingDir = portable)
if patched.exitCode != 0: quit("Failed to apply RV32 portability patch: " & patched.output, 1)
echo "Constantine ", revision
