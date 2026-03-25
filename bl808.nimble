# Package
version       = "0.1.0"
author        = "Gabriel"
description   = "Hardware Abstraction Layer for Bouffalo Labs BL808 (Pine64 Ox64)"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

# Tasks
task m0, "Build for M0 core (E907, RV32IMAFC)":
  exec "nim c -d:bl808m0 src/bl808.nim"

task d0, "Build for D0 core (C906, RV64IMAFDC)":
  exec "nim c -d:bl808d0 src/bl808.nim"

task lp, "Build for LP core (E902, RV32EMC)":
  exec "nim c -d:bl808lp src/bl808.nim"
