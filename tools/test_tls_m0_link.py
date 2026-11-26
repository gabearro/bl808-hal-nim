"""Cross-build the M0 images that carry src/bl808/kernel/tls.nim and inspect
what was linked. Nothing is flashed or run: these are link and layout checks
for the vendored Mbed TLS, its hardware providers and the Wi-Fi firmware
sharing one copy of it."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tools/test_tls_m0_link.nim"
GCC = shutil.which("riscv64-unknown-elf-gcc")
NM = shutil.which("riscv64-unknown-elf-nm")
NIM = shutil.which("nim")
SDK = ROOT / "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant"

pytestmark = pytest.mark.skipif(not GCC or not NM or not NIM,
                                reason="needs Nim and the RISC-V toolchain")

# m0_wifi_http_server as tools/hardware_validation.json builds it, with
# placeholder credentials.
WIFI_HTTP_SERVER = [
    "-d:tlsLinkWithWifi", "-d:WifiSsid=placeholder-ssid", "-d:WifiPassword=placeholder-password",
    "-d:bl808WifiHttpServer=1", "-d:bl808WifiNimFw=1", "-d:bl808WifiUseBl808Rf=1",
    "-d:bl808WifiNativeWlanCalibration=1", "-d:bl808WifiRealLwip=1", "-d:bl808WifiRealLwipTcp=1",
    "-d:bl808WifiRxPbufInput=1", "-d:HwValidationLogExternalBuffer=1",
    "-d:HwValidationLogSection=.psrambss.jtaglog",
]


def link(tmp_path: Path, *defines: str) -> dict[str, list[tuple[int, str]]]:
    """Build the image; return its symbols as name -> [(address, kind)]."""
    elf = tmp_path / "image.elf"
    result = subprocess.run(
        [NIM, "c", "-d:bl808m0", "-d:bl808kernel", "--hints:off", "--warnings:off", *defines,
         f"--nimcache:{tmp_path / 'cache'}", f"--out:{elf}", str(SOURCE)],
        cwd=ROOT, capture_output=True, text=True, timeout=900)
    assert result.returncode == 0, (result.stdout + result.stderr)[-4000:]
    symbols: dict[str, list[tuple[int, str]]] = {}
    for line in subprocess.run([NM, str(elf)], capture_output=True, text=True, check=True).stdout.splitlines():
        match = re.fullmatch(r"([0-9a-f]+) (\w) (\S+)", line)
        if match:
            # Nim mangles module-level names; keep the readable prefix.
            name = match[3].split("__")[0]
            symbols.setdefault(name, []).append((int(match[1], 16), match[2]))
    return symbols


HARDWARE = ["bl808_mbedtls_sha256_process", "bl808_software_sha256_process",
            "bl808_mbedtls_sha512_process", "bl808_software_sha512_process",
            "bl808_mbedtls_aes_encrypt", "bl808_software_aes_encrypt",
            "bl808_mbedtls_p256_mul", "bl808_software_ecp_mul_restartable",
            "bl808_software_ecp_muladd_restartable", "bflb_sec_ecdh_get_encrypt_key",
            "bl808_mbedtls_rsa_exp_mod", "bl808_software_mpi_exp_mod_unsafe", "bflb_pka_mexp"]
CLIENT = ["mbedtls_ssl_handshake", "mbedtls_ssl_read", "mbedtls_ssl_write", "psa_crypto_init",
          "mbedtls_x509_crt_parse_der", "mbedtls_gcm_crypt_and_tag", "mbedtls_ecp_mul",
          "mbedtls_internal_sha256_process", "mbedtls_internal_sha512_process",
          "mbedtls_internal_aes_encrypt", "mbedtls_ecp_muladd_restartable",
          "mbedtls_mpi_exp_mod_unsafe",
          "mbedtls_hardware_poll"]           # the TRNG is the entropy source either way


def test_tls_client_links_with_the_hardware_providers(tmp_path: Path) -> None:
    symbols = link(tmp_path)
    for name in CLIENT + HARDWARE:
        assert name in symbols, name
    assert "mbedtls_platform_entropy_poll" not in symbols   # no OS entropy on the chip


def test_tls_client_links_in_software_only(tmp_path: Path) -> None:
    symbols = link(tmp_path, "-d:bl808MbedTlsSoftware")
    for name in CLIENT:
        assert name in symbols, name
    for name in HARDWARE:
        assert name not in symbols, name


@pytest.mark.skipif(not SDK.is_dir(), reason="needs the pinned BL808 SDK cache for the Wi-Fi host")
def test_wifi_and_tls_share_one_mbedtls(tmp_path: Path) -> None:
    symbols = link(tmp_path, *WIFI_HTTP_SERVER)
    for name in CLIENT + HARDWARE + ["wifi_mgmr_sta_connect", "mbedtls_pkcs5_pbkdf2_hmac",
                                     "mbedtls_sha1_update", "mbedtls_md5_update"]:
        assert name in symbols, name
    # One definition of every library function: the supplicant and the TLS
    # client call the same code.
    duplicated = [name for name, entries in symbols.items()
                  if name.startswith(("mbedtls_", "psa_")) and
                  sum(1 for _, kind in entries if kind == "T") > 1]
    assert not duplicated, duplicated
    # The engines' DMA descriptors and blocks sit in uncached WRAM.
    for name in ["sha256Descriptor", "sha256Words", "sha512Descriptor", "sha512Words",
                 "aesDescriptor", "aesSource", "aesDestination"]:
        (address, _), = symbols[name]
        assert 0x2203_0000 <= address < 0x2205_8000, (name, hex(address))
    # Software AES keeps its tables in flash once the engine does the work.
    assert all(0x5800_0000 <= address < 0x5810_0000 for address, _ in symbols["FSb"])
