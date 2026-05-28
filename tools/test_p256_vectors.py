"""Native vector checks for the pure Nim P-256 implementation."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


def test_p256_debug_key_vectors(tmp_path):
    nim = shutil.which("nim")
    assert nim is not None

    source = tmp_path / "p256_vector_test.nim"
    source.write_text(
        """
import bl808/p256
import bl808/blep256

proc anyNonZero(data: openArray[uint8]): bool =
  for b in data:
    if b != 0'u8:
      return true
  false

var secret = P256DebugPrivateKeyLe
var expectedX = P256DebugPublicKeyXLe
var expectedY = P256DebugPublicKeyYLe
var x: array[32, uint8]
var y: array[32, uint8]

doAssert p256IsValidScalarLe(addr secret[0])
doAssert p256ScalarBaseMultLe(addr secret[0], addr x[0], addr y[0])
doAssert x == expectedX
doAssert y == expectedY
doAssert p256IsValidPublicKeyLe(addr x[0], addr y[0])

x = default(array[32, uint8])
y = default(array[32, uint8])
doAssert bleP256IsValidScalarLe(addr secret[0])
doAssert bleP256ScalarBaseMultLe(addr secret[0], addr x[0], addr y[0])
doAssert x == expectedX
doAssert y == expectedY
doAssert bleP256IsValidPublicKeyLe(addr x[0], addr y[0])

var zero: array[32, uint8]
doAssert not p256IsValidScalarLe(addr zero[0])
doAssert not p256IsValidPublicKeyLe(addr zero[0], addr zero[0])

var sharedX: array[32, uint8]
var sharedY: array[32, uint8]
doAssert p256ScalarMultLe(addr secret[0], addr expectedX[0], addr expectedY[0],
                          addr sharedX[0], addr sharedY[0])
doAssert anyNonZero(sharedX)
doAssert p256IsValidPublicKeyLe(addr sharedX[0], addr sharedY[0])
""",
        encoding="utf-8",
    )

    subprocess.run(
        [
            nim,
            "c",
            "-r",
            "--skipParentCfg:on",
            "--skipProjCfg:on",
            "--path:src",
            "--nimcache:" + str(tmp_path / "nimcache"),
            str(source),
        ],
        check=True,
        cwd=Path(__file__).resolve().parents[1],
    )
