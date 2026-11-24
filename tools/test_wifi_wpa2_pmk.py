"""Compare the optimized WPA2 derivation with an independent PBKDF2."""

import hashlib
from pathlib import Path
import random
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT


def literal(data: bytes) -> str:
    return "@[" + ", ".join(f"{byte}'u8" for byte in data) + "]" if data else "newSeq[uint8]()"


@pytest.mark.parametrize("flags", [[], ["-d:release"], ["--passC:-fsanitize=address",
                                                          "--passL:-fsanitize=address"]])
def test_wpa2_pmk_matches_reference(tmp_path: Path, flags: list[str]) -> None:
    sdk = ROOT / "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls"
    nim = shutil.which("nim")
    if not nim or not (sdk / "library/sha1.c").is_file():
        pytest.skip("WPA2 derivation vectors require Nim and the pinned BL808 SDK")
    rng = random.Random(808)
    cases = [(b"password", b"IEEE"), (b"12345678", b""), (b"P" * 63, bytes(range(32)))]
    for length, ssid_len in [(8, 1), (9, 3), (11, 4), (12, 5), (31, 19), (48, 20), (63, 31)]:
        cases.append((bytes(rng.randrange(32, 127) for _ in range(length)),
                      rng.randbytes(ssid_len)))
    code = [
        "import bl808/wifi/wpa2_pmk",
        f'{{.compile: "{sdk}/library/sha1.c".}}',
        f'{{.compile: "{sdk}/library/platform_util.c".}}',
        "var pmk: Wpa2Pmk",
    ]
    for passphrase, ssid in cases:
        expected = hashlib.pbkdf2_hmac("sha1", passphrase, ssid, 4096, dklen=32)
        code.append(f"doAssert deriveWpa2Pmk({literal(passphrase)}, {literal(ssid)}, pmk)")
        code.append(f"doAssert @pmk == {literal(expected)}")
    for length, ssid_len in [(7, 4), (64, 4), (8, 33)]:
        code.append(f"doAssert not deriveWpa2Pmk({literal(b'P' * length)}, "
                    f"{literal(b'S' * ssid_len)}, pmk)")
    source = tmp_path / "pmk_vectors.nim"
    source.write_text("\n".join(code) + "\n")
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg", "--skipProjCfg", "--skipUserCfg",
         "--assertions:on", f"--path:{ROOT / 'src'}", f"--passC:-I{sdk / 'include'}",
         f"--nimcache:{tmp_path / 'cache'}", *flags, str(source)],
        capture_output=True, text=True, timeout=60, cwd=ROOT,
    )
    assert result.returncode == 0, result.stdout + result.stderr
