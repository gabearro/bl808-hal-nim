"""Native vector checks for pure Nim BLE AES/CMAC helpers."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from cryptography.hazmat.primitives.cmac import CMAC
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESCCM


def _cmac(key: bytes, msg: bytes) -> bytes:
    c = CMAC(algorithms.AES(key))
    c.update(msg)
    return c.finalize()


def _aes_block(key: bytes, block: bytes) -> bytes:
    encryptor = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return encryptor.update(block) + encryptor.finalize()


def _xor(a: bytes, b: bytes) -> bytes:
    return bytes(x ^ y for x, y in zip(a, b, strict=True))


def _addr_param(addr: bytes) -> bytes:
    assert len(addr) == 7
    return addr[:1] + addr[1:][::-1]


def _k1(n: bytes, salt: bytes, p: bytes) -> bytes:
    t = _cmac(salt, n)
    return _cmac(t, p)


def _k2(n: bytes, p: bytes) -> bytes:
    salt = bytes.fromhex("b1108d4d1f9716fdbfbf71180c48904f")
    t = _cmac(salt, n)
    t1 = _cmac(t, p + b"\x01")
    t2 = _cmac(t, t1 + p + b"\x02")
    t3 = _cmac(t, t2 + p + b"\x03")
    return bytes([t1[15] & 0x7F]) + t2 + t3


def _k3(n: bytes) -> bytes:
    salt = bytes.fromhex("02c39162136e718acc95f10335443600")
    return _cmac(_cmac(salt, n), b"id64\x01")[8:]


def _k4(n: bytes) -> int:
    salt = bytes.fromhex("be495fac54ee974c8766faceb7c19a0e")
    return _cmac(_cmac(salt, n), b"id6\x01")[15] & 0x3F


def _h8(k: bytes, s: bytes, key_id: bytes) -> bytes:
    return _cmac(_cmac(k, s), key_id)


def _h9(k: bytes, key_id: bytes) -> bytes:
    return _cmac(_cmac(k, b"ISOC"), key_id)


def _c1(key: bytes, r: bytes, p1: bytes, p2: bytes) -> bytes:
    return _aes_block(key, _xor(_aes_block(key, _xor(r, p1)), p2))


def _s1(msg: bytes) -> bytes:
    return _cmac(bytes(16), msg)


def _f4(u: bytes, v: bytes, x: bytes, z: int) -> bytes:
    return _cmac(x[::-1], u[::-1] + v[::-1] + bytes([z]))[::-1]


def _f5(w: bytes, n1: bytes, n2: bytes, a1: bytes, a2: bytes) -> bytes:
    salt = bytes.fromhex("6c888391aaf5a53860370bdb5a6083be")
    t = _cmac(salt, w[::-1])
    body = b"btle" + n1[::-1] + n2[::-1] + _addr_param(a1) + _addr_param(a2) + b"\x01\x00"
    return _cmac(t, b"\x00" + body)[::-1] + _cmac(t, b"\x01" + body)[::-1]


def _f6(w: bytes, n1: bytes, n2: bytes, r: bytes, iocap: bytes, a1: bytes, a2: bytes) -> bytes:
    msg = n1[::-1] + n2[::-1] + r[::-1] + iocap[::-1] + _addr_param(a1) + _addr_param(a2)
    return _cmac(w[::-1], msg)[::-1]


def _g2_raw(u: bytes, v: bytes, x: bytes, y: bytes) -> bytes:
    return _cmac(x[::-1], u[::-1] + v[::-1] + y[::-1])


def _g2(u: bytes, v: bytes, x: bytes, y: bytes) -> int:
    raw = _g2_raw(u, v, x, y)
    return int.from_bytes(raw[12:16], "big") % 1_000_000


def _h6(w: bytes, key_id: bytes) -> bytes:
    return _cmac(w[::-1], key_id[::-1])[::-1]


def _h7(salt: bytes, w: bytes) -> bytes:
    return _cmac(salt[::-1], w[::-1])[::-1]


def _nim_array(values: bytes) -> str:
    return "[" + ", ".join(f"0x{b:02x}'u8" for b in values) + "]"


def test_blecrypto_vectors(tmp_path):
    nim = shutil.which("nim")
    assert nim is not None

    aes_key = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
    aes_plain = bytes.fromhex("00112233445566778899aabbccddeeff")
    aes_cipher = bytes.fromhex("69c4e0d86a7b0430d8cdb78070b4c55a")

    cmac_key = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")
    cmac_msg = bytes.fromhex("6bc1bee22e409f96e93d7e117393172a")
    cmac_empty = bytes.fromhex("bb1d6929e95937287fa37d129b756746")
    cmac_one_block = bytes.fromhex("070a16b46b4d4144f79bdd9dd04a287c")

    n = bytes.fromhex("00112233445566778899aabbccddeeff")
    salt = bytes.fromhex("0f0e0d0c0b0a09080706050403020100")
    p = bytes.fromhex("010203040506")
    h8_s = bytes.fromhex("101112131415161718191a1b1c1d1e1f")
    key_id = bytes.fromhex("20212223")
    u = bytes.fromhex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
    v = bytes.fromhex("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")
    w = bytes.fromhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    n1 = bytes.fromhex("00112233445566778899aabbccddeeff")
    n2 = bytes.fromhex("102132435465768798a9babbdcddfeef")
    r = bytes.fromhex("8899aabbccddeeff0011223344556677")
    iocap = bytes.fromhex("010203")
    addr1 = bytes.fromhex("00a1a2a3a4a5a6")
    addr2 = bytes.fromhex("01b1b2b3b4b5b6")
    c1_p1 = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
    c1_p2 = bytes.fromhex("101112131415161718191a1b1c1d1e1f")
    ccm_key = bytes.fromhex("404142434445464748494a4b4c4d4e4f")
    ccm_nonce = bytes.fromhex("101112131415161718191a1b1c")
    ccm_plain = bytes.fromhex("202122232425262728292a2b2c2d2e")
    ccm_payload = AESCCM(ccm_key, tag_length=4).encrypt(ccm_nonce, ccm_plain, None)

    source = tmp_path / "blecrypto_vector_test.nim"
    source.write_text(
        f"""
import bl808/blecrypto

proc checkBytes(name: string, actual: openArray[uint8], expected: openArray[uint8]) =
  doAssert actual.len == expected.len, name & " length"
  for i in 0 ..< actual.len:
    doAssert actual[i] == expected[i], name & " byte " & $i

var aesKey: array[16, uint8] = {_nim_array(aes_key)}
var aesPlain: array[16, uint8] = {_nim_array(aes_plain)}
var aesExpected: array[16, uint8] = {_nim_array(aes_cipher)}
var blockOut: array[16, uint8]
bleAesEncryptBlock(addr aesKey[0], addr aesPlain[0], addr blockOut[0])
checkBytes("aes block", blockOut, aesExpected)

var cmacKey: array[16, uint8] = {_nim_array(cmac_key)}
var cmacMsg: array[16, uint8] = {_nim_array(cmac_msg)}
var cmacExpectedEmpty: array[16, uint8] = {_nim_array(cmac_empty)}
var cmacExpectedOneBlock: array[16, uint8] = {_nim_array(cmac_one_block)}
var cmacOut: array[16, uint8]
bleAesCmac(addr cmacKey[0], nil, 0, addr cmacOut[0])
checkBytes("cmac empty", cmacOut, cmacExpectedEmpty)
bleAesCmac(addr cmacKey[0], addr cmacMsg[0], cmacMsg.len.uint16, addr cmacOut[0])
checkBytes("cmac one block", cmacOut, cmacExpectedOneBlock)

var n: array[16, uint8] = {_nim_array(n)}
var salt: array[16, uint8] = {_nim_array(salt)}
var p: array[{len(p)}, uint8] = {_nim_array(p)}
var k1Expected: array[16, uint8] = {_nim_array(_k1(n, salt, p))}
var k1Out: array[16, uint8]
bleAesK1(addr n[0], addr salt[0], addr p[0], p.len.uint16, addr k1Out[0])
checkBytes("k1", k1Out, k1Expected)

var k2Expected: array[33, uint8] = {_nim_array(_k2(n, p))}
var k2Out: array[33, uint8]
bleAesK2(addr n[0], addr p[0], p.len.uint16, addr k2Out[0])
checkBytes("k2", k2Out, k2Expected)

var k3Expected: array[8, uint8] = {_nim_array(_k3(n))}
var k3Out: array[8, uint8]
bleAesK3(addr n[0], addr k3Out[0])
checkBytes("k3", k3Out, k3Expected)

doAssert bleAesK4(addr n[0]) == {_k4(n)}

var h8S: array[16, uint8] = {_nim_array(h8_s)}
var keyId: array[4, uint8] = {_nim_array(key_id)}
var h8Expected: array[16, uint8] = {_nim_array(_h8(n, h8_s, key_id))}
var h9Expected: array[16, uint8] = {_nim_array(_h9(n, key_id))}
var hOut: array[16, uint8]
bleAesH8(addr n[0], addr h8S[0], addr keyId[0], addr hOut[0])
checkBytes("h8", hOut, h8Expected)
bleAesH9(addr n[0], addr keyId[0], addr hOut[0])
checkBytes("h9", hOut, h9Expected)

var c1P1: array[16, uint8] = {_nim_array(c1_p1)}
var c1P2: array[16, uint8] = {_nim_array(c1_p2)}
var c1R: array[16, uint8] = {_nim_array(n2)}
var c1Expected: array[16, uint8] = {_nim_array(_c1(n, n2, c1_p1, c1_p2))}
bleAesC1(addr n[0], addr c1R[0], addr c1P1[0], addr c1P2[0], addr hOut[0])
checkBytes("c1", hOut, c1Expected)

var s1Expected: array[16, uint8] = {_nim_array(_s1(p))}
bleAesS1(addr p[0], p.len.uint16, addr hOut[0])
checkBytes("s1", hOut, s1Expected)

var u: array[32, uint8] = {_nim_array(u)}
var v: array[32, uint8] = {_nim_array(v)}
var w: array[32, uint8] = {_nim_array(w)}
var n1: array[16, uint8] = {_nim_array(n1)}
var n2: array[16, uint8] = {_nim_array(n2)}
var r: array[16, uint8] = {_nim_array(r)}
var iocap: array[3, uint8] = {_nim_array(iocap)}
var addr1: array[7, uint8] = {_nim_array(addr1)}
var addr2: array[7, uint8] = {_nim_array(addr2)}

var f4Expected: array[16, uint8] = {_nim_array(_f4(u, v, n1, 0x42))}
bleAesF4(addr u[0], addr v[0], addr n1[0], 0x42'u8, addr hOut[0])
checkBytes("f4", hOut, f4Expected)

var f5Expected: array[32, uint8] = {_nim_array(_f5(w, n1, n2, addr1, addr2))}
var f5Out: array[32, uint8]
bleAesF5(addr w[0], addr n1[0], addr n2[0], addr addr1[0], addr addr2[0], addr f5Out[0])
checkBytes("f5", f5Out, f5Expected)

var f6Expected: array[16, uint8] = {_nim_array(_f6(n, n1, n2, r, iocap, addr1, addr2))}
bleAesF6(addr n[0], addr n1[0], addr n2[0], addr r[0], addr iocap[0], addr addr1[0],
         addr addr2[0], addr hOut[0])
checkBytes("f6", hOut, f6Expected)

var g2ExpectedRaw: array[16, uint8] = {_nim_array(_g2_raw(u, v, n1, n2))}
bleAesG2Raw(addr u[0], addr v[0], addr n1[0], addr n2[0], addr hOut[0])
checkBytes("g2 raw", hOut, g2ExpectedRaw)
doAssert bleAesG2(addr u[0], addr v[0], addr n1[0], addr n2[0]) == {_g2(u, v, n1, n2)}'u32

var h6Expected: array[16, uint8] = {_nim_array(_h6(n, key_id))}
var h7Expected: array[16, uint8] = {_nim_array(_h7(n, n1))}
bleAesH6(addr n[0], addr keyId[0], addr hOut[0])
checkBytes("h6", hOut, h6Expected)
bleAesH7(addr n[0], addr n1[0], addr hOut[0])
checkBytes("h7", hOut, h7Expected)

var ccmKey: array[16, uint8] = {_nim_array(ccm_key)}
var ccmNonce: array[13, uint8] = {_nim_array(ccm_nonce)}
var ccmPlain: array[{len(ccm_plain)}, uint8] = {_nim_array(ccm_plain)}
var ccmExpectedCipher: array[{len(ccm_plain)}, uint8] = {_nim_array(ccm_payload[:-4])}
var ccmExpectedMic: array[4, uint8] = {_nim_array(ccm_payload[-4:])}
var ccmCipher: array[{len(ccm_plain)}, uint8]
var ccmMic: array[4, uint8]
doAssert bleAesCcm(addr ccmKey[0], addr ccmNonce[0], addr ccmPlain[0], addr ccmCipher[0],
                   ccmPlain.len.uint16, addr ccmMic[0], ccmMic.len.uint8, true)
checkBytes("ccm cipher", ccmCipher, ccmExpectedCipher)
checkBytes("ccm mic", ccmMic, ccmExpectedMic)
var ccmDecoded: array[{len(ccm_plain)}, uint8]
doAssert bleAesCcm(addr ccmKey[0], addr ccmNonce[0], addr ccmCipher[0], addr ccmDecoded[0],
                   ccmCipher.len.uint16, addr ccmMic[0], ccmMic.len.uint8, false)
checkBytes("ccm decoded", ccmDecoded, ccmPlain)
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
