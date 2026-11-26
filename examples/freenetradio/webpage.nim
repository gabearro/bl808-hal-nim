## The web page, gzip-compressed at compile time (upstream's `build.rs`) and
## served with `Content-Encoding: gzip`.
##
## `staticExec` reads a child's output as text lines, which is not safe for
## binary data, so the compressed bytes cross as a hex dump. Needs POSIX
## `gzip` and `od` on the build machine (the target has no shell of its own,
## hence `quoteShellPosix`); `-n` keeps the result reproducible.

import std/[os, strutils]

func fromHexDump(dump: string): string =
  for token in dump.splitWhitespace:
    result.add char(parseHexInt(token))

const
  PagePath = currentSourcePath().parentDir / "index.html"
  PageGz*: string = fromHexDump(
    staticExec("gzip -9 -n -c " & quoteShellPosix(PagePath) & " | od -An -v -tx1"))

static:
  doAssert PageGz.len > 18 and PageGz[0] == '\x1f' and PageGz[1] == '\x8b',
    "gzip of index.html failed: " & PageGz
