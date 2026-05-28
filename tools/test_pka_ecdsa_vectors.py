"""Native vector checks for PKA ECDSA verification helpers."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


def test_pka_ecdsa_fixed_signature_vector(tmp_path):
    nim = shutil.which("nim")
    assert nim is not None

    source = tmp_path / "pka_ecdsa_vector_test.nim"
    source.write_text(
        """
import bl808/pka

var handle: BflbEcdsa
doAssert bflb_sec_ecdsa_init(addr handle, EcpSecp256r1) == 0

var pubX = secp256r1Gx
var pubY = secp256r1Gy
handle.publicKeyx = addr pubX[0]
handle.publicKeyy = addr pubY[0]

var hash = [0'u32, 0, 0, 0, 0, 0, 0, 0x01000000'u32]
var r = [
  0x187BF27C'u32, 0x7E4F038D'u32, 0x0338528A'u32, 0xC31AB504'u32,
  0xE26989C0'u32, 0x351BF277'u32, 0xFC480BA6'u32, 0x78996647'u32
]
var s = [
  0x8B3D79BE'u32, 0xBFA781C6'u32, 0x011C29C5'u32, 0x618D5A82'u32,
  0x4832B8BE'u32, 0xDDDC840F'u32, 0xDF89E24C'u32, 0x65DFE4A1'u32
]

doAssert bflb_sec_ecdsa_verify(addr handle, addr hash[0], 8,
                               addr r[0], addr s[0]) == 0
doAssert bflb_sec_ecdsa_verify_384(addr handle, addr hash[0], 8,
                                   addr r[0], addr s[0]) == 0

s[0] = s[0] xor 1'u32
doAssert bflb_sec_ecdsa_verify(addr handle, addr hash[0], 8,
                               addr r[0], addr s[0]) != 0
s[0] = s[0] xor 1'u32

pubY[0] = pubY[0] xor 1'u32
doAssert bflb_sec_ecdsa_verify(addr handle, addr hash[0], 8,
                               addr r[0], addr s[0]) != 0
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


def test_pka_high_level_rejects_invalid_inputs_before_hardware(tmp_path):
    nim = shutil.which("nim")
    assert nim is not None

    source = tmp_path / "pka_invalid_input_test.nim"
    source.write_text(
        """
import bl808/pka

var ecdsa: BflbEcdsa
doAssert bflb_sec_ecdsa_init(addr ecdsa, EcpSecp256r1) == 0

var zero = [0'u32, 0, 0, 0, 0, 0, 0, 0]
var one = [0'u32, 0, 0, 0, 0, 0, 0, 0x01000000'u32]
var outX: array[8, uint32]
var outY: array[8, uint32]

doAssert bflb_sec_ecdsa_get_public_key(addr ecdsa, addr zero[0],
                                       addr outX[0], addr outY[0]) != 0

ecdsa.privateKey = addr zero[0]
var hash = one
var sigR: array[8, uint32]
var sigS: array[8, uint32]
doAssert bflb_sec_ecdsa_sign(addr ecdsa, addr one[0], addr hash[0], 8,
                             addr sigR[0], addr sigS[0]) != 0

var ecdh: BflbEcdh
doAssert bflb_sec_ecdh_init(addr ecdh, EcpSecp256r1) == 0
doAssert bflb_sec_ecdh_get_public_key(addr ecdh, addr zero[0],
                                      addr outX[0], addr outY[0]) != 0
doAssert bflb_sec_ecdh_get_encrypt_key(addr ecdh, addr zero[0], addr zero[0],
                                       addr one[0], addr outX[0],
                                       addr outY[0]) != 0

var dsa: BflbDsa
doAssert bflb_sec_dsa_init(addr dsa, 2048) == 0
doAssert bflb_sec_dsa_init(addr dsa, 0) != 0
doAssert bflb_sec_dsa_init(cast[ptr BflbDsa](0), 32) != 0
doAssert bflb_sec_dsa_sign(cast[ptr BflbDsa](0), addr one[0], 1,
                           addr sigR[0]) != 0
doAssert bflb_sec_dsa_verify(cast[ptr BflbDsa](0), addr one[0], 1,
                             addr sigR[0]) != 0
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


def test_pka_polling_driver_matches_sdk_interrupt_clear_contract():
    source = Path(__file__).resolve().parents[1] / "src/bl808/pka.nim"
    irq_source = Path(__file__).resolve().parents[1] / "src/bl808/irq.nim"
    text = source.read_text(encoding="utf-8")
    irq_text = irq_source.read_text(encoding="utf-8")

    init_body = text.split("proc bflb_pka_init*", 1)[1].split(
        "proc bflb_pka_deinit*", 1
    )[0]
    assert "PkaCtrlIntMask" in init_body
    assert "regWrite(base + PkaCtrl0Offset, 0)" in init_body
    assert "pkaClearInt(base)" in init_body

    deinit_body = text.split("proc bflb_pka_deinit*", 1)[1].split(
        "proc bflb_pka_write*", 1
    )[0]
    assert "PkaCtrlIntMask" in deinit_body
    assert deinit_body.count("pkaClearInt(base)") >= 2
    assert "regWrite(dev.regBase + PkaCtrl0Offset, 0)" not in deinit_body

    clear_body = text.split("proc pkaClearInt", 1)[1].split(
        "proc pkaReadMtimeUs", 1
    )[0]
    assert "PkaCtrlIntClear" in clear_body
    assert "PkaCtrlDoneClear" not in clear_body
    wait_body = text.split("proc pkaWaitIsr", 1)[1].split(
        "proc pkaWaitAndClear", 1
    )[0]
    assert "PkaCtrlIntStatus" in wait_body
    assert "PkaCtrlDoneStatus" not in wait_body
    irq_clear_body = irq_text.split("proc clicClearPending*", 1)[1].split(
        "proc clicSetAttr*", 1
    )[0]
    assert "m0McuIntClearSource(irq)" in irq_clear_body


def test_pka_ecc_random_trng_is_polling_safe():
    source = Path(__file__).resolve().parents[1] / "src/bl808/pka.nim"
    text = source.read_text(encoding="utf-8")

    read_block = text.split("proc eccTrngReadBlock", 1)[1].split(
        "proc bflb_sec_ecc_get_random_value*", 1
    )[0]
    assert "EccTrngIntMask" in read_block
    assert "eccTrngClearInterrupt()" in read_block

    random_body = text.split("proc bflb_sec_ecc_get_random_value*", 1)[1].split(
        "proc bflb_sec_ecc_cmp*", 1
    )[0]
    assert "eccRequestTrngGroup0" in random_body
    assert "eccReleaseTrngGroup0" in random_body


def test_generic_sec_trng_masks_done_interrupt():
    source = Path(__file__).resolve().parents[1] / "src/bl808/sec.nim"
    text = source.read_text(encoding="utf-8")

    enable_body = text.split("proc trngEnable*", 1)[1].split(
        "proc trngDisable*", 1
    )[0]
    assert "TrngIntMask" in enable_body
    assert "trngClearInt()" in enable_body

    finish_body = text.split("proc trngFinish", 1)[1].split(
        "proc trngReadAll*", 1
    )[0]
    assert "TrngIntMask" in finish_body
    assert "trngClearInt()" in finish_body
