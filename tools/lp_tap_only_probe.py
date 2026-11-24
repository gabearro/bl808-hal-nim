#!/usr/bin/env python3
"""Tap-only LP JTAG probe for use while firmware samples LP-visible pins.

This intentionally does not take the hardware validation lock; it is designed
to run as a host action inside tools/hw_validate.py after that harness has
loaded the diagnostic image and closed its own OpenOCD session.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def default_openocd() -> str:
    for candidate in (
        os.environ.get("OPENOCD"),
        "/opt/homebrew/bin/openocd",
        "openocd",
    ):
        if candidate and (Path(candidate).exists() or shutil.which(candidate)):
            return candidate
    return "openocd"


def default_interface() -> str:
    for candidate in (
        os.environ.get("OPENOCD_INTERFACE"),
        "/opt/homebrew/share/openocd/scripts/interface/cklink.cfg",
        str(REPO_ROOT / "pine64jtag_slow.cfg"),
    ):
        if candidate and Path(candidate).exists():
            return candidate
    return "/opt/homebrew/share/openocd/scripts/interface/cklink.cfg"


def parse_word(text: str, label: str) -> int | None:
    match = re.search(rf"{re.escape(label)}=(0x[0-9a-fA-F]+|[0-9a-fA-F]+)", text)
    return int(match.group(1), 16) if match else None


def classify(text: str) -> str:
    idcode = parse_word(text, "LP_IDCODE_IR01_DR32")
    dtmcs = parse_word(text, "LP_DTMCS_IR10_DR32")
    if idcode is None:
        return "LP TAP IDCODE was not reported"
    if idcode == 0xFFFF_FFFF:
        return "LP TAP reads all ones: TDO is not being driven by the selected chain"
    if idcode == 0:
        return "LP TAP reads zero: selected chain is not responding or is held low/reset"
    if idcode != 0x18005B31:
        return f"LP TAP IDCODE mismatch: 0x{idcode:08x}"
    if dtmcs is None:
        return "LP TAP IDCODE is visible, but DTMCS was not reported"
    if dtmcs == 0xFFFF_FFFF:
        return "LP TAP is visible, but DTMCS reads all ones"
    if dtmcs == 0:
        return "LP TAP is visible, but DTMCS reads zero"
    version = dtmcs & 0xF
    abits = (dtmcs >> 4) & 0x3F
    return f"LP TAP DTMCS observed: idcode=0x{idcode:08x} dtmcs=0x{dtmcs:08x} version={version} abits={abits}"


def make_target_cfg() -> str:
    ir_values = " ".join(f"0x{ir:02x}" for ir in range(32))
    return f"""
adapter speed 100
set _CHIPNAME bl808lp
jtag newtap $_CHIPNAME cpu -irlen 5

init
echo "BL808_LP_TAP_PROBE begin"
scan_chain

irscan bl808lp.cpu 0x01
set lp_idcode [drscan bl808lp.cpu 32 0x00000000]
echo "LP_IDCODE_IR01_DR32=$lp_idcode"

irscan bl808lp.cpu 0x10
set lp_dtmcs [drscan bl808lp.cpu 32 0x00000000]
echo "LP_DTMCS_IR10_DR32=$lp_dtmcs"

irscan bl808lp.cpu 0x11
set lp_dmi_lo [drscan bl808lp.cpu 32 0x00000000]
echo "LP_DMI_IR11_DR32=$lp_dmi_lo"

foreach ir {{{ir_values}}} {{
    irscan bl808lp.cpu $ir
    set dr [drscan bl808lp.cpu 32 0x00000000]
    echo [format "LP_IR%02x_DR32=%s" $ir $dr]
}}

echo "BL808_LP_TAP_PROBE end"
shutdown
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--openocd", default=default_openocd())
    parser.add_argument("--interface", default=default_interface())
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="bl808-lp-tap-") as tmp:
        cfg = Path(tmp) / "lp-tap-only.cfg"
        cfg.write_text(make_target_cfg().lstrip(), encoding="utf-8")
        cmd = [args.openocd, "-f", args.interface, "-f", str(cfg)]
        print("$ " + " ".join(cmd), flush=True)
        try:
            proc = subprocess.run(
                cmd,
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=args.timeout,
            )
            output = proc.stdout
        except subprocess.TimeoutExpired as exc:
            output = exc.stdout or ""
            print(output, end="" if output.endswith("\n") else "\n")
            print(f"BL808_LP_TAP_PROBE timed out after {args.timeout:.1f}s")
            print("BL808_LP_TAP_PROBE done")
            return 0

    print(output, end="" if output.endswith("\n") else "\n")
    print(classify(output))
    print(f"BL808_LP_TAP_PROBE openocd_exit={proc.returncode}")
    print("BL808_LP_TAP_PROBE done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
