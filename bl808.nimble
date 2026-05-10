# Package
version       = "0.1.0"
author        = "Gabriel"
description   = "Hardware Abstraction Layer for Bouffalo Labs BL808 (Pine64 Ox64)"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

# Tasks
task m0, "Compile-check the aggregate HAL for M0 core (E907, RV32IMAFC)":
  exec "nim c --compileOnly -d:bl808m0 -d:bl808kernel src/bl808.nim"

task d0, "Compile-check the aggregate HAL for D0 core (C906, RV64IMAFDC)":
  exec "nim c --compileOnly -d:bl808d0 -d:bl808kernel src/bl808.nim"

task lp, "Compile-check the aggregate HAL for LP core (E902, RV32EMC)":
  exec "nim c --compileOnly -d:bl808lp -d:bl808kernel src/bl808.nim"
