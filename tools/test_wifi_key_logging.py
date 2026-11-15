"""Check key-install log formats through the real C variadic convention."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_key_ingress import PLATFORM
from test_wifi_message_allocation import run_program


def source() -> str:
    platform = PLATFORM.replace(procedure(PLATFORM, "getLogFunc"), r'''
proc getLogFunc(offset: int): PlatformLogFunc =
  doAssert offset == 204
  if logging: cast[PlatformLogFunc](recordLog) else: nil
''', 1)
    firmware = (FW / "platform_bl.nim").read_text()
    owner = re.search(r"(?ms)^type\n  SupplicantKeyOwner = object.*?(?=^proc captureSupplicantKeyOwner)",
                      firmware).group(0)
    code = layouts("SupplicantKeyParamView", "SupplicantTkipKeyDataView", "MachwKeyWriteParamView")
    code += owner + r'''
proc recordLog(level: uint32; tag, file: cstring; line: cint;
               format: cstring) {.cdecl, varargs.}
''' + platform + r'''
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
var formatted: seq[string]
var logLines: seq[cint]
proc recordLog(level: uint32; tag, file: cstring; line: cint;
               format: cstring) {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil and not irq
  doAssert cast[uint](format) > 4096, "log format is not a string"
  doAssert file == cstring("supplicant_api.c")
  var output: array[512, char]
  var written: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           written, " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
           format, ", args); va_end(args);"].}
  doAssert written >= 0 and written < output.len.cint
  formatted.add($cast[cstring](addr output[0]))
  logLines.add(line)
  fire("log" & $line)
'''
    for name in ["captureSupplicantKeyOwner", "supplicantKeyOwnerCurrent", "supplicantKeyLengthValid",
                 "setKey", "bl_wifi_set_ap_key_internal", "bl_wifi_set_sta_key_internal",
                 "bl_wifi_set_igtk_internal"]:
        code += procedure(firmware, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_key_install_log_arguments(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for incoming in [false, true]:
    setup(VIF_TYPE_AP, 1, incoming)
    logging = enabled
    formatted.setLen(0)
    logLines.setLen(0)
    doAssert ingress_call_ap(addr sourceKey[0], 16) == 0
    doAssert formatted == (if enabled:
      @["bl_wifi_set_ap_key_internal: vif_idx 1, sta_idx 2, alg 3, key_idx 1, key_len 16, pairwise 1\r\n"]
      else: newSeq[string]())
    doAssert logLines == (if enabled: @[192.cint] else: newSeq[cint]())
    doAssert irq == incoming and writes == 1 and maps == 0

    setup(VIF_TYPE_STA, 1, incoming)
    logging = enabled
    formatted.setLen(0)
    logLines.setLen(0)
    doAssert ingress_call_sta(addr sourcePn[0], addr sourceKey[0]) == 0
    doAssert formatted == (if enabled:
      @["bl_wifi_set_sta_key_internal: vif_idx 1, sta_idx 2\r\n",
        "\t alg 3, key_idx 2, set_tx 1, key_len 16, pairwise 1\r\n",
        "hw_key_idx: 13\r\n"] else: newSeq[string]())
    doAssert logLines == (if enabled: @[211.cint, 212, 213] else: newSeq[cint]())
    doAssert irq == incoming and writes == 1 and maps == 1 and mapping[1][0] == 13

    setup(VIF_TYPE_STA, 1, incoming)
    logging = enabled
    formatted.setLen(0)
    logLines.setLen(0)
    doAssert ingress_call_igtk(addr sourcePn[0], addr sourceKey[0]) == 0
    doAssert formatted == (if enabled:
      @["bl_wifi_set_igtk_internal: vif_idx 1, sta_idx 2, key_idx 5, hw_key_idx 13\r\n"]
      else: newSeq[string]())
    doAssert logLines == (if enabled: @[237.cint] else: newSeq[cint]())
    doAssert irq == incoming and writes == 1 and maps == 1 and mapping[1][2] == 13
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_key_log_numeric_types(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(VIF_TYPE_AP, 1)
formatted.setLen(0)
doAssert bl_wifi_set_ap_key_internal(1, 2, 0, -1, nil, 0, false) == 0
doAssert formatted == @[
  "bl_wifi_set_ap_key_internal: vif_idx 1, sta_idx 2, alg 0, key_idx 4294967295, key_len 0, pairwise 0\r\n"]
doAssert deleted == @[10'u8] and writes == 0 and maps == 0

setup(VIF_TYPE_STA, 1)
formatted.setLen(0)
doAssert bl_wifi_set_sta_key_internal(1, 2, 3, 3, -7,
  addr sourcePn[0], 6, addr sourceKey[0], 16, false) == 0
doAssert formatted == @[
  "bl_wifi_set_sta_key_internal: vif_idx 1, sta_idx 2\r\n",
  "\t alg 3, key_idx 3, set_tx -7, key_len 16, pairwise 0\r\n",
  "hw_key_idx: 13\r\n"]
doAssert mapping[1][1] == 13 and writes == 1 and maps == 1
''')
