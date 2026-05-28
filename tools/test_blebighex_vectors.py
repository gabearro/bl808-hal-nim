"""Native vector checks for BLE BigHex P-256 compatibility helpers."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


def test_blebighex_field_and_jacobian_vectors(tmp_path):
    nim = shutil.which("nim")
    assert nim is not None

    source = tmp_path / "blebighex_vector_test.nim"
    source.write_text(
        """
import bl808/blebighex
import bl808/p256
import bl808/pka

type Field = array[32, uint8]

proc beWordsToLe(words: openArray[uint32]): Field =
  var be: Field
  for i in 0 ..< 8:
    let w = words[i]
    let off = i * 4
    be[off] = w.uint8
    be[off + 1] = (w shr 8).uint8
    be[off + 2] = (w shr 16).uint8
    be[off + 3] = (w shr 24).uint8
  for i in 0 ..< 32:
    result[i] = be[31 - i]

proc storePoint(point: var array[33, uint32], x, y: var Field) =
  var one: Field
  one[0] = 1
  doAssert bleBigHexFromFieldLe(addr point[0], addr x[0])
  doAssert bleBigHexFromFieldLe(addr point[11], addr y[0])
  doAssert bleBigHexFromFieldLe(addr point[22], addr one[0])

var gx = beWordsToLe(secp256r1Gx)
var gy = beWordsToLe(secp256r1Gy)
var twoGx = beWordsToLe([
  0x187BF27C'u32, 0x7E4F038D'u32, 0x0338528A'u32, 0xC31AB504'u32,
  0xE26989C0'u32, 0x351BF277'u32, 0xFC480BA6'u32, 0x78996647'u32
])
var twoGy = beWordsToLe([
  0x10557707'u32, 0x40D08EDB'u32, 0xC69A3D29'u32, 0xDB30749F'u32,
  0xE6AD7DBA'u32, 0x2982E93C'u32, 0x9DB7049E'u32, 0xD1737822'u32
])

var hx: array[11, uint32]
var hy: array[11, uint32]
var got: Field
doAssert bleBigHexFromFieldLe(addr hx[0], addr gx[0])
doAssert bleBigHexToFieldLe(addr hx[0], addr got[0])
doAssert got == gx

doAssert bleBigHexFromFieldLe(addr hy[0], addr gy[0])
var sumHex: array[11, uint32]
var expected: Field
doAssert p256FieldAddLe(addr gx[0], addr gy[0], addr expected[0])
bleBigHexAddModP256(addr hx[0], addr hy[0], addr sumHex[0])
doAssert bleBigHexToFieldLe(addr sumHex[0], addr got[0])
doAssert got == expected

doAssert p256FieldSubLe(addr gx[0], addr gy[0], addr expected[0])
bleBigHexSubtractModP256(addr hx[0], addr hy[0], addr sumHex[0])
doAssert bleBigHexToFieldLe(addr sumHex[0], addr got[0])
doAssert got == expected

doAssert p256FieldMulLe(addr gx[0], addr gy[0], addr expected[0])
bleBigHexMultiplyModP256(addr hx[0], addr hy[0], addr sumHex[0])
doAssert bleBigHexToFieldLe(addr sumHex[0], addr got[0])
doAssert got == expected

var point: array[33, uint32]
var doubled: array[33, uint32]
var added: array[33, uint32]
storePoint(point, gx, gy)
bleP256JacobianDouble(addr point[0], addr doubled[0])
doAssert bleBigHexToFieldLe(addr doubled[0], addr got[0])
doAssert got == twoGx
doAssert bleBigHexToFieldLe(addr doubled[11], addr got[0])
doAssert got == twoGy

bleP256JacobianAdd(addr point[0], addr point[0], addr added[0])
doAssert bleBigHexToFieldLe(addr added[0], addr got[0])
doAssert got == twoGx
doAssert bleBigHexToFieldLe(addr added[11], addr got[0])
doAssert got == twoGy
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
