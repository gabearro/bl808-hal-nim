"""Run the production BL808 WPA TX-completion path with host driver faults."""

import os
from pathlib import Path
import shlex
import subprocess
import sys
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]
SDK = ROOT / "build/bl_iot_sdk_b773b3f/components"
SUPPLICANT = SDK / "security/wpa_supplicant"


def main() -> int:
    if not (SUPPLICANT / "src/rsn_supp/wpa.c").is_file():
        print(f"Missing BL808 supplicant sources: {SUPPLICANT}", file=sys.stderr)
        return 2

    compiler = shlex.split(os.environ.get("CC", "cc"))
    dead_strip = "-Wl,-dead_strip" if sys.platform == "darwin" else "-Wl,--gc-sections"
    includes = (
        SDK / "network/lwip/lwip-port",
        SDK / "network/lwip/src/include",
        SDK / "network/wifi/include",
        SUPPLICANT / "include",
        SUPPLICANT / "port/include",
        SUPPLICANT / "src",
        ROOT / "src/bl808/kernel/lwip_wifi_smoke",
    )
    with TemporaryDirectory(prefix="bl808-wpa-key-completion-") as scratch:
        binary = str(Path(scratch) / "oracle")
        subprocess.run(
            [
                *compiler, "-fcommon", "-fshort-enums", "-ffunction-sections", "-fdata-sections",
                "-Wno-incompatible-pointer-types", "-Wno-int-conversion",
                "-Wno-implicit-function-declaration", "-include", "sys/types.h",
                *(f"-I{path}" for path in includes), dead_strip, "-o", binary,
                str(ROOT / "tools/wifi_wpa_key_completion_oracle.c"),
                str(ROOT / "src/bl808/wifi_supplicant_wpa_overlay.c"),
                str(SUPPLICANT / "src/bl_supplicant/bl_wpa_main.c"),
                str(SUPPLICANT / "src/bl_supplicant/bl_wpas_glue.c"),
                str(SUPPLICANT / "src/utils/common.c"),
            ],
            check=True,
            timeout=60,
        )
        return subprocess.run([binary], timeout=10).returncode


if __name__ == "__main__":
    sys.exit(main())
