## The About page's data (upstream `src/about.rs`): the repository, the
## licence, and the open source list, one `name|author|licence` line each.
## Shown by the settings menu and served at `GET /licenses`.

import std/strutils

const
  Repo* = "https://github.com/alexhorner/freenetradio"
  License* = "MIT"
  LicensesText* = staticRead("licenses.txt")
  Entries = block:
    var rows: seq[array[3, string]]
    for line in LicensesText.splitLines:
      if line.len > 0:
        let f = line.split('|')
        rows.add [f[0], (if f.len > 1: f[1] else: ""), (if f.len > 2: f[2] else: "")]
    rows

func count*(): int = Entries.len

func entry*(i: int): tuple[name, author, license: string] =
  ## Library `i` as (name, author, licence); empty past the end.
  if i >= 0 and i < Entries.len:
    (Entries[i][0], Entries[i][1], Entries[i][2])
  else:
    ("", "", "")
