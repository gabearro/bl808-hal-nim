#!/usr/bin/env python3
"""
BL808 qtest regression checks.

Runs a small set of MMIO-level validations against the BL808 machine model:
  - CLINT mtime read/write semantics
  - D0 PLIC fan-out for shared PWM/EMAC interrupts
  - Register-backed stand-ins for LZ4 and MM multimedia accelerators
  - SEC_ENG reset/TRNG/SHA256/AES-128 ECB
  - USB reset values and VDMA FIFO round-trip
"""

from __future__ import annotations

import argparse
import hashlib
import json
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path
from typing import Any


class QTestSession:
    def __init__(
        self,
        qemu_binary: Path,
        machine: str = "bl808,accel=qtest",
        extra_args: list[str] | None = None,
    ) -> None:
        self._irq_events: list[str] = []
        self._qmp_dir = tempfile.TemporaryDirectory(prefix="bl808-qtest-")
        self._qmp_path = Path(self._qmp_dir.name) / "qmp.sock"
        cmd = [
            str(qemu_binary),
            "-M",
            machine,
            "-display",
            "none",
            "-serial",
            "none",
            "-monitor",
            "none",
            "-qmp",
            f"unix:{self._qmp_path},server=on,wait=off",
            "-qtest",
            "stdio",
        ]
        if extra_args is not None:
            cmd.extend(extra_args)
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self._qmp_socket = self._connect_qmp()
        self._qmp_reader = self._qmp_socket.makefile("r", encoding="utf-8")
        self._qmp_writer = self._qmp_socket.makefile("w", encoding="utf-8")
        self._qmp_read_message()  # Greeting
        self.qmp_command("qmp_capabilities")

    def close(self) -> None:
        self._qmp_reader.close()
        self._qmp_writer.close()
        self._qmp_socket.close()
        self._qmp_dir.cleanup()
        if self.proc.poll() is not None:
            return
        self.proc.terminate()
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()

    def command(self, line: str) -> str:
        assert self.proc.stdin is not None
        assert self.proc.stdout is not None
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()
        while True:
            resp = self.proc.stdout.readline()
            if not resp:
                raise RuntimeError(f"{line!r} -> unexpected EOF")
            resp = resp.strip()
            if resp.startswith("IRQ "):
                self._irq_events.append(resp)
                continue
            if not resp.startswith("OK"):
                raise RuntimeError(f"{line!r} -> {resp!r}")
            return resp

    def _connect_qmp(self) -> socket.socket:
        deadline = time.monotonic() + 5.0
        while True:
            try:
                qmp_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                qmp_socket.connect(str(self._qmp_path))
                return qmp_socket
            except FileNotFoundError:
                pass
            except ConnectionRefusedError:
                pass

            qmp_socket.close()
            if self.proc.poll() is not None:
                raise RuntimeError("QEMU exited before QMP became available")
            if time.monotonic() >= deadline:
                raise RuntimeError("Timed out waiting for QMP socket")
            time.sleep(0.05)

    def _qmp_read_message(self) -> dict[str, Any]:
        line = self._qmp_reader.readline()
        if not line:
            raise RuntimeError("Unexpected EOF from QMP")
        return json.loads(line)

    def qmp_command(
        self, execute: str, arguments: dict[str, Any] | None = None
    ) -> Any:
        payload: dict[str, Any] = {"execute": execute}
        if arguments is not None:
            payload["arguments"] = arguments

        self._qmp_writer.write(json.dumps(payload) + "\n")
        self._qmp_writer.flush()

        while True:
            resp = self._qmp_read_message()
            if "return" in resp:
                return resp["return"]
            if "error" in resp:
                raise RuntimeError(f"QMP {execute!r} failed: {resp['error']!r}")

    def hmp_command(self, command: str) -> str:
        return self.qmp_command(
            "human-monitor-command", {"command-line": command}
        )

    def qom_set(self, path: str, property_name: str, value: Any) -> None:
        self.qmp_command(
            "qom-set",
            {"path": path, "property": property_name, "value": value},
        )

    def find_qom_path_by_type(self, type_name: str, root: str = "/machine") -> str:
        matches = self.find_qom_paths_by_type(type_name, root)
        if len(matches) != 1:
            raise AssertionError(
                f"Expected exactly one QOM object of type {type_name!r}, got {matches!r}"
            )
        return matches[0]

    def find_qom_paths_by_type(
        self, type_name: str, root: str = "/machine"
    ) -> list[str]:
        matches: list[str] = []
        pending = [root]
        visited: set[str] = set()

        while pending:
            path = pending.pop()
            if path in visited:
                continue
            visited.add(path)
            for entry in self.qmp_command("qom-list", {"path": path}):
                entry_type = entry.get("type", "")
                child_path = f"{path}/{entry['name']}"
                if entry_type == f"child<{type_name}>":
                    matches.append(child_path)
                if entry_type.startswith("child<"):
                    pending.append(child_path)
        return matches

    def readl(self, addr: int) -> int:
        return int(self.command(f"readl 0x{addr:x}").split()[1], 16)

    def writel(self, addr: int, value: int) -> None:
        self.command(f"writel 0x{addr:x} 0x{value:x}")

    def memset(self, addr: int, size: int, value: int) -> None:
        self.command(f"memset 0x{addr:x} 0x{size:x} 0x{value:02x}")

    def clock_step(self, ns: int) -> None:
        self.command(f"clock_step {ns}")

    def irq_intercept_in(self, path: str) -> None:
        self.command(f"irq_intercept_in {path}")

    def take_irq_events(self) -> list[str]:
        events = list(self._irq_events)
        self._irq_events.clear()
        return events

    def write(self, addr: int, data: bytes) -> None:
        self.command(f"write 0x{addr:x} 0x{len(data):x} 0x{data.hex()}")

    def read(self, addr: int, size: int) -> bytes:
        resp = self.command(f"read 0x{addr:x} 0x{size:x}")
        return bytes.fromhex(resp.split()[1][2:])


def check_equal(label: str, actual, expected) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def check_range(label: str, actual: int, start: int, end: int) -> None:
    if not (start <= actual <= end):
        raise AssertionError(
            f"{label}: expected {actual!r} to be in range [{start!r}, {end!r}]"
        )


def check_contains(label: str, actual: list[str], expected: str) -> None:
    if expected not in actual:
        raise AssertionError(
            f"{label}: expected {expected!r} in {actual!r}"
        )


def check_not_contains(label: str, actual: list[str], unexpected: str) -> None:
    if unexpected in actual:
        raise AssertionError(
            f"{label}: did not expect {unexpected!r} in {actual!r}"
        )


def mmio_words_to_bytes(words: list[int]) -> bytes:
    return b"".join(word.to_bytes(4, "little") for word in words)


def timer_wdt_unlock(qtest: QTestSession, base: int) -> None:
    qtest.writel(base + TIMER_WFAR, TIMER_WFAR_MAGIC)
    qtest.writel(base + TIMER_WSAR, TIMER_WSAR_MAGIC)


I2C_CONFIG = 0x00
I2C_INT_STS = 0x04
I2C_SUB_ADDR = 0x08
I2C_FIFO_CONFIG0 = 0x80
I2C_FIFO_CONFIG1 = 0x84
I2C_FIFO_WDATA = 0x88
I2C_FIFO_RDATA = 0x8C

I2C_MASTER_EN = 1 << 0
I2C_PKT_DIR = 1 << 1
I2C_SUB_ADDR_EN = 1 << 4
I2C_SUB_ADDR_BC_MASK = 0x3 << 5
I2C_SLV_ADDR_SHIFT = 8
I2C_SLV_ADDR_MASK = 0x7F << I2C_SLV_ADDR_SHIFT
I2C_PKT_LEN_SHIFT = 16
I2C_PKT_LEN_MASK = 0xFF << I2C_PKT_LEN_SHIFT

I2C_INT_END = 1 << 0
I2C_INT_NAK = 1 << 3
I2C_INT_ARB = 1 << 4
I2C_INT_FIFO_ERR = 1 << 5
I2C_INT_CLEAR = (
    1 << 16
    | 1 << 19
    | 1 << 20
    | 1 << 21
)

I2C_FIFO_TX_FREE_MASK = 0x3
I2C_FIFO_RX_COUNT_MASK = 0x3 << 8
I2C_FIFO_RX_COUNT_SHIFT = 8
I2C_FIFO_TX_CLR = 1 << 2
I2C_FIFO_RX_CLR = 1 << 3
I2C_FIFO_DEPTH = 2

PDS_BASE = 0x2000E000
PDS_CTL = PDS_BASE + 0x00
PDS_TIME1 = PDS_BASE + 0x04
PDS_INT = PDS_BASE + 0x0C
PDS_CTL2 = PDS_BASE + 0x10
PDS_STAT = PDS_BASE + 0x1C
PDS_CPU_CORE_CFG0 = PDS_BASE + 0x110
PDS_CPU_CORE_CFG1 = PDS_BASE + 0x114
PDS_CPU_CORE_CFG13 = PDS_BASE + 0x144
PDS_GPIO_I_SET = PDS_BASE + 0x30
PDS_GPIO_PD_SET = PDS_BASE + 0x34
PDS_GPIO_INT = PDS_BASE + 0x40
PDS_GPIO_STAT = PDS_BASE + 0x44

PDS_CTL_START_PS = 1 << 0
PDS_CTL_SLEEP_FOREVER = 1 << 1
PDS_INT_WAKEUP = 1 << 0
PDS_INT_CLEAR = 1 << 8
PDS_WAKEUP_SRC_TIMER = 1 << 10
PDS_WAKEUP_SRC_HBN_IRQ = 1 << 11
PDS_WAKEUP_SRC_GLB_GPIO = 1 << 12
PDS_WAKEUP_SRC_PDS_GPIO = 1 << 13
PDS_WAKEUP_EVENT_TIMER = 1 << 21
PDS_WAKEUP_EVENT_HBN_IRQ = 1 << 22
PDS_WAKEUP_EVENT_GLB_GPIO = 1 << 23
PDS_WAKEUP_EVENT_PDS_GPIO = 1 << 24
PDS_STAT_BUSY = 1 << 0
PDS_MM_FORCE_MASK = 0x00022222
PDS_PICO_CLK_EN = 1 << 28

PDS_GPIO_GROUP_16_TO_23_IE = 1 << 1
PDS_GPIO_SET2_CLR = 1 << 10
PDS_GPIO_SET2_MODE_SHIFT = 12
PDS_GPIO_ASYNC_RISING = 9
PDS_GPIO_GPIO16_STAT = 1 << 9

HBN_BASE = 0x2000F000
HBN_CTL = HBN_BASE + 0x00
HBN_TIML = HBN_BASE + 0x04
HBN_TIMH = HBN_BASE + 0x08
HBN_RTC_TIML = HBN_BASE + 0x0C
HBN_RTC_TIMH = HBN_BASE + 0x10
HBN_IRQ_MODE = HBN_BASE + 0x14
HBN_IRQ_STAT = HBN_BASE + 0x18
HBN_IRQ_CLR = HBN_BASE + 0x1C
HBN_PAD_CTRL_0 = HBN_BASE + 0x38
HBN_PAD_CTRL_1 = HBN_BASE + 0x3C
HBN_RSV0 = HBN_BASE + 0x100
HBN_RSV1 = HBN_BASE + 0x104
HBN_RSV3 = HBN_BASE + 0x10C

HBN_CTL_MODE = 1 << 7
HBN_RTC_LATCH = 1 << 31
HBN_IRQ_RTC_STAT = 1 << 16
HBN_IRQ_BOD_STAT = 1 << 18
HBN_IRQ_BOD_EN = 1 << 18
HBN_PAD_OE_SHIFT = 0
HBN_PAD_CTRL_SHIFT = 20
HBN_PAD_PU_SHIFT = 20
HBN_PAD_ISO_MODE = 1 << 31
HBN_GLB = HBN_BASE + 0x30

GLB_BASE = 0x20000000
GLB_SYS_CFG0 = GLB_BASE + 0x90
GLB_SYS_CFG1 = GLB_BASE + 0x94
GLB_SWRST_CFG2 = GLB_BASE + 0x548
GLB_DIG_CLK_CFG1 = GLB_BASE + 0x254
GLB_WIFI_PLL_CFG0 = GLB_BASE + 0x810
GLB_WIFI_PLL_CFG1 = GLB_BASE + 0x814
GLB_WIFI_PLL_CFG5 = GLB_BASE + 0x824
GLB_WIFI_PLL_CFG6 = GLB_BASE + 0x828
GLB_WIFI_PLL_CFG8 = GLB_BASE + 0x830
GLB_GPIO_CFG_BASE = GLB_BASE + 0x8C4
GLB_GPIO_CFG_SWGPIO_FUNC = 11
GLB_GPIO_CFG_FUNC_SHIFT = 8
GLB_GPIO_CFG_INT_MODE_SHIFT = 16
GLB_GPIO_CFG_IE = 1 << 0
GLB_GPIO_CFG_INT_CLR = 1 << 20
GLB_GPIO_CFG_INT_STAT = 1 << 21
GLB_GPIO_CFG_I = 1 << 28
GLB_GPIO_CFG_ASYNC_RISING = 6
GLB_SWRST_CFG2_PICO_RESET = 1 << 3

MM_GLB_BASE = 0x30007000
MM_GLB_MM_CLK_CTRL_CPU = MM_GLB_BASE + 0x00
MM_GLB_MM_CLK_CPU = MM_GLB_BASE + 0x04
MM_GLB_MM_SW_SYS_RESET = MM_GLB_BASE + 0x40
MM_GLB_MM_SW_RESET_CODEC = MM_GLB_BASE + 0x4C
MM_GLB_CNN_CLK_DIV_EN = 1 << 8
MM_GLB_SWRST_CNN = 1 << 4

CCI_BASE = 0x20008000
CCI_AUDIO_PLL_CFG0 = CCI_BASE + 0x750
CCI_AUDIO_PLL_CFG1 = CCI_BASE + 0x754
CCI_AUDIO_PLL_CFG6 = CCI_BASE + 0x768
CCI_AUDIO_PLL_CFG8 = CCI_BASE + 0x770
CCI_CPU_PLL_CFG0 = CCI_BASE + 0x7D0
CCI_CPU_PLL_CFG1 = CCI_BASE + 0x7D4
CCI_CPU_PLL_CFG6 = CCI_BASE + 0x7E8
CCI_CPU_PLL_CFG8 = CCI_BASE + 0x7F0

MM_MISC_MISC_DUMMY = 0x300000FC
MM_MISC_MISC_DUMMY_RESET = 0xFFF00000
MM_MISC_VRAM_CTRL = 0x30000050
MM_MISC_SYSRAM_SET = 1 << 0
MM_MISC_BLAI_SRAM_REL = 1 << 7

LZ4D_BASE = 0x2000AD00
DVP0_BASE = 0x30012000
OSD_A_BASE = 0x30013000
OSD_DP_BASE = 0x30015000
DBI_BASE = 0x3001B000
MJPEG_BASE = 0x30021000
H264_BASE = 0x30022000

DMA2D_BASE = 0x30006000
DMA2D_INTSTATUS = 0x000
DMA2D_INTTCCLEAR = 0x008
DMA2D_CONFIG = 0x010
DMA2D_CH0_SRCADDR = 0x100
DMA2D_CH0_DSTADDR = 0x104
DMA2D_CH0_BUS = 0x10C
DMA2D_CH0_CFG = 0x17C

DMA2D_E = 1 << 0
DMA2D_SI = 1 << 26
DMA2D_DI = 1 << 27
DMA2D_I = 1 << 31
DMA2D_CH_EN = 1 << 0

IPC_TRI = 0x00
IPC_STS = 0x04
IPC_ACK = 0x08
IPC_IEN = 0x0C
IPC_IDIS = 0x10
IPC_ISTS = 0x14
IPC0_BASE = 0x2000A800
IPC1_BASE = 0x2000A840
IPC2_BASE = 0x30005000

I2C0_BASE = 0x2000A300
I2C2_BASE = 0x30003000

TIMER0_BASE = 0x2000A500
TIMER1_BASE = 0x30009000
TIMER_TCCR = 0x00
TIMER_TMR2_0 = 0x10
TIMER_TMR2_1 = 0x14
TIMER_TMR2_2 = 0x18
TIMER_TMR3_0 = 0x1C
TIMER_TMR3_1 = 0x20
TIMER_TMR3_2 = 0x24
TIMER_TCR2 = 0x2C
TIMER_TCR3 = 0x30
TIMER_TSR2 = 0x38
TIMER_TSR3 = 0x3C
TIMER_TIER2 = 0x44
TIMER_TIER3 = 0x48
TIMER_TPLVR2 = 0x50
TIMER_TPLVR3 = 0x54
TIMER_TPLCR2 = 0x5C
TIMER_TPLCR3 = 0x60
TIMER_TILR2 = 0x90
TIMER_TILR3 = 0x94
TIMER_WMER = 0x64
TIMER_WMR = 0x68
TIMER_WVR = 0x6C
TIMER_WSR = 0x70
TIMER_TICR2 = 0x78
TIMER_WICR = 0x80
TIMER_TCER = 0x84
TIMER_TCMR = 0x88
TIMER_WCR = 0x98
TIMER_WFAR = 0x9C
TIMER_WSAR = 0xA0
TIMER_TCVWR2 = 0xA8
TIMER_TCVWR3 = 0xAC
TIMER_TCVSYN2 = 0xB4
TIMER_TCVSYN3 = 0xB8
TIMER_TCDR = 0xBC
TIMER_TCDR_FORCE = 0xCC

TIMER_TCCR_ID = 0xA5000000
TIMER_TCCR_RESET = TIMER_TCCR_ID | 0x00000155
TIMER_TMR_RESET = 0xFFFFFFFF
GLB_SYS_CFG_PLL_EN = 1 << 0
GLB_SYS_CFG_BCLK_EN = 1 << 3
GLB_BCLK_DIV_ACT_PULSE = 1 << 0
GLB_STS_BCLK_PROT_DONE = 1 << 2
MM_GLB_CLK_CTRL_PLL_EN = 1 << 0
MM_GLB_CLK_CTRL_BCLK_EN = 1 << 2
MM_GLB_CLK_CTRL_MMCPU0_EN = 1 << 12
MM_GLB_SW_SYS_RESET_MMCPU0 = 1 << 8
HBN_ROOT_CLK_XCLK_RC32M = 0x0
HBN_ROOT_CLK_XCLK_XTAL = 0x1
HBN_ROOT_CLK_PLL = 0x2
PDS_PLL_SEL_CPUPLL_400M = 0x0 << 4
PDS_PLL_SEL_AUPLL_DIV1 = 0x1 << 4
PDS_PLL_SEL_WIFIPLL_240M = 0x2 << 4
PDS_PLL_SEL_WIFIPLL_320M = 0x3 << 4

CCI_AUPLL_SDMIN_442P368M = 0x161E5
CCI_AUPLL_SDMIN_451P584M = 0x16944
CCI_AUPLL_SDMIN_442P368M_32M = 0x1BA5E
CCI_CPUPLL_SDMIN_400M = 0x14000
CCI_CPUPLL_SDMIN_480M = 0x18000
CCI_CPUPLL_SDMIN_400M_32M = 0x19000
CCI_AUPLL_CFG0_ON = 0x00000FFF
CCI_AUPLL_CFG1_XTAL = 0x01100412
CCI_AUPLL_CFG1_RC32M = 0x01130412
CCI_AUPLL_CFG8_DEFAULT = 0x00000067
CCI_CPUPLL_CFG0_ON = 0x00000FFF
CCI_CPUPLL_CFG1_XTAL = 0x01100400
CCI_CPUPLL_CFG1_RC32M = 0x01130400
CCI_CPUPLL_CFG8_DEFAULT = 0x00000037
GLB_WIFIPLL_SDMIN_960M_40M = 0x1800000
GLB_WIFIPLL_SDMIN_960M_32M = 0x1E00000
GLB_WIFIPLL_CFG0_ON = 0x00000FFF
GLB_WIFIPLL_CFG1_XTAL = 0x00010200
GLB_WIFIPLL_CFG1_RC32M = 0x00030200
GLB_WIFIPLL_CFG5_DEFAULT = 0x00001005
GLB_WIFIPLL_CFG8_DEFAULT = 0x800000AE
GLB_MM_MUXPLL_240M_SEL_AUPLL = 0x1 << 1
MM_GLB_BCLK1X_SEL_XCLK = 0x0 << 13
MM_GLB_BCLK1X_SEL_160M = 0x2 << 13
MM_GLB_BCLK1X_SEL_240M = 0x3 << 13
TIMER_CLK2_SRC_BCLK = 0x0
TIMER_CLK2_SRC_1KHZ = 0x2
TIMER_CLK2_SRC_XTAL = 0x3
TIMER_CLK3_SRC_1KHZ = 0x2 << 4
TIMER_WDT_CLK_SRC_1KHZ = 0x2 << 8
TIMER_TIMER2_EN = 1 << 1
TIMER_TIMER3_EN = 1 << 2
TIMER_TCMR_TIMER2_MODE = 1 << 1
TIMER_TCMR_TIMER3_MODE = 1 << 2
TIMER_TCMR_TIMER2_ALIGN = 1 << 5
TIMER_WDT_EN = 1 << 0
TIMER_WDT_RST = 1 << 1
TIMER_WMR_ALIGN = 1 << 16
TIMER_WDT_MATCH_MASK = 0xFFFF
TIMER_TCDR_TIMER2_DIV2 = 0x1 << 8
TIMER_TCDR_FORCE_TIMER2 = 1 << 1
TIMER_WFAR_MAGIC = 0x0000BABA
TIMER_WSAR_MAGIC = 0x0000EB10

BLE_BASE = 0x28000000
BLE_INTCNTL = BLE_BASE + 0x0C
BLE_INTSTAT = BLE_BASE + 0x10
BLE_INTRAWSTAT = BLE_BASE + 0x14
BLE_INTACK = BLE_BASE + 0x18
BLE_BASETIMECNT = BLE_BASE + 0x1C
BLE_FINETIMECNT = BLE_BASE + 0x20
BLE_FINE_TIMER_IRQ = 0x00000001
BLE_BASETIME_LATCH = 0x80000000

WIFI_MAC_PL_IRQ_STATUS0 = 0x44910000
WIFI_MAC_PL_IRQ_HANDLER = 0x44910040
WIFI_MACHW_INTC_STATUS_RAW = 0x44B0806C
WIFI_MACHW_INTC_STATUS_ACK = 0x44B08070
WIFI_MACHW_INTC_UNMASK = 0x44B08074
WIFI_MACHW_INTC_GEN_STATUS = 0x44B08080
WIFI_MACHW_INTC_GEN_RAW = 0x44B08084
WIFI_MACHW_INTC_IRQ_SET = 0x44B08088
WIFI_MACHW_INTC_IRQ_STAT = 0x44B0808C
WIFI_MACHW_IRQ_GLOBAL_EN = 0x80000000
WIFI_MACHW_IRQ_GEN = 0x00000008
WIFI_MACHW_GEN_GLOBAL_EN = 0x80000000
WIFI_MACHW_GEN_RX_COMPLETE = 0x00000080
WIFI_MAC_GEN_HANDLER = 61

WIFI_IPC_BASE = 0x44800000
WIFI_IPC_STATUS = WIFI_IPC_BASE + 0x100
WIFI_IPC_UNMASK_SET = WIFI_IPC_BASE + 0x10C
WIFI_IPC_ACK = WIFI_IPC_BASE + 0x118
WIFI_IPC_STATUS2 = WIFI_IPC_BASE + 0x11C
WIFI_IPC_MAGIC = WIFI_IPC_BASE + 0x140
WIFI_IPC_MAGIC_VALUE = 0x49504332
WIFI_IPC_MSG_BIT = 0x00000002

BOOTROM_BASE = 0x90000000
BOOTROM_PC = 0xFFFFFFFF90000000
BOOTROM_SIZE = 0x20000
FLASH_XIP_BASE = 0x58000000
LP_FLASH_XIP_BASE = 0x58020000
FLASH_OFFSET_LP = 0x020000
FLASH_OFFSET_D0 = 0x100000
FLASH_OFFSET_D0_IMAGE = FLASH_OFFSET_D0 + 0x1000
PT_TABLE0_OFFSET = 0x00E000
PT_TABLE1_OFFSET = 0x00F000
PT_TABLE_SIZE = 596
WRAM_CACHED = 0x62030000
BOOT2_PASS_PARAM_ADDR = WRAM_CACHED + 0x27C00
DRAM_BASE = 0x3EF80000
XRAM_BASE = 0x40000000
SF_CTRL_BASE = 0x2000B000
SF_CTRL_ID0_OFFSET = SF_CTRL_BASE + 0x0A0
SF_CTRL_ID1_OFFSET = SF_CTRL_BASE + 0x0A4
MM_MISC_CPU0_BOOT_RESET = 0x3EFF0000

M0_EMAC_IRQ = 40
M0_IPC_IRQ = 19
M0_PWM_IRQ = 49
M0_TIMER0_CH0_IRQ = 52
M0_TIMER0_WDT_IRQ = 54
M0_PDS_WAKEUP_IRQ = 66
M0_HBN_OUT0_IRQ = 67
M0_HBN_OUT1_IRQ = 68
M0_WIFI_IRQ = 70
M0_BLE_IRQ = 72
M0_WIFI_IPC_PUB_IRQ = 79
LP_IPC_IRQ = 19
D0_WL_ALL_IRQ = 81


def i2c_clear_state(qtest: QTestSession, base: int) -> None:
    qtest.writel(base + I2C_FIFO_CONFIG0, I2C_FIFO_TX_CLR | I2C_FIFO_RX_CLR)
    qtest.writel(base + I2C_INT_STS, I2C_INT_CLEAR)


def i2c_wait_complete(qtest: QTestSession, base: int) -> str:
    for _ in range(1000):
        sts = qtest.readl(base + I2C_INT_STS)
        if sts & I2C_INT_END:
            qtest.writel(base + I2C_INT_STS, 1 << 16)
            if sts & I2C_INT_NAK:
                qtest.writel(base + I2C_INT_STS, 1 << 19)
                return "nak"
            if sts & I2C_INT_ARB:
                qtest.writel(base + I2C_INT_STS, 1 << 20)
                return "arb"
            if sts & I2C_INT_FIFO_ERR:
                qtest.writel(base + I2C_INT_STS, 1 << 21)
                return "fifo"
            return "ok"
    raise AssertionError("I2C transfer timed out")


def i2c_write_reg(qtest: QTestSession, base: int, address: int, reg: int, data: bytes) -> str:
    cfg = qtest.readl(base + I2C_CONFIG)
    i2c_clear_state(qtest, base)

    for byte in data[:I2C_FIFO_DEPTH]:
        qtest.writel(base + I2C_FIFO_WDATA, byte)

    cfg = (cfg & ~I2C_SLV_ADDR_MASK) | ((address & 0x7F) << I2C_SLV_ADDR_SHIFT)
    cfg &= ~I2C_PKT_DIR
    cfg = (cfg & ~I2C_PKT_LEN_MASK) | (((len(data) - 1) & 0xFF) << I2C_PKT_LEN_SHIFT)
    cfg |= I2C_SUB_ADDR_EN
    cfg &= ~I2C_SUB_ADDR_BC_MASK

    qtest.writel(base + I2C_SUB_ADDR, reg & 0xFF)
    qtest.writel(base + I2C_CONFIG, cfg)
    qtest.writel(base + I2C_CONFIG, cfg | I2C_MASTER_EN)

    next_index = I2C_FIFO_DEPTH
    while next_index < len(data):
        tx_free = qtest.readl(base + I2C_FIFO_CONFIG1) & I2C_FIFO_TX_FREE_MASK
        if tx_free > 0:
            qtest.writel(base + I2C_FIFO_WDATA, data[next_index])
            next_index += 1

    status = i2c_wait_complete(qtest, base)
    qtest.writel(base + I2C_CONFIG, qtest.readl(base + I2C_CONFIG) & ~I2C_MASTER_EN)
    return status


def i2c_read_reg(qtest: QTestSession, base: int, address: int, reg: int, length: int) -> tuple[str, bytes]:
    cfg = qtest.readl(base + I2C_CONFIG)
    i2c_clear_state(qtest, base)

    cfg = (cfg & ~I2C_SLV_ADDR_MASK) | ((address & 0x7F) << I2C_SLV_ADDR_SHIFT)
    cfg |= I2C_PKT_DIR
    cfg = (cfg & ~I2C_PKT_LEN_MASK) | (((length - 1) & 0xFF) << I2C_PKT_LEN_SHIFT)
    cfg |= I2C_SUB_ADDR_EN
    cfg &= ~I2C_SUB_ADDR_BC_MASK

    qtest.writel(base + I2C_SUB_ADDR, reg & 0xFF)
    qtest.writel(base + I2C_CONFIG, cfg)
    qtest.writel(base + I2C_CONFIG, cfg | I2C_MASTER_EN)

    data = bytearray()
    for _ in range(1000):
        rx_count = (
            qtest.readl(base + I2C_FIFO_CONFIG1) & I2C_FIFO_RX_COUNT_MASK
        ) >> I2C_FIFO_RX_COUNT_SHIFT
        while rx_count > 0 and len(data) < length:
            data.append(qtest.readl(base + I2C_FIFO_RDATA) & 0xFF)
            rx_count -= 1
        if len(data) == length:
            break
    else:
        raise AssertionError("I2C RX FIFO did not fill")

    status = i2c_wait_complete(qtest, base)
    qtest.writel(base + I2C_CONFIG, qtest.readl(base + I2C_CONFIG) & ~I2C_MASTER_EN)
    return status, bytes(data)


def mm_domain_set_power(qtest: QTestSession, powered_on: bool) -> None:
    qtest.writel(PDS_CTL2, 0 if powered_on else PDS_MM_FORCE_MASK)


def check_regbank_readback(qtest: QTestSession, name: str, addr: int, value: int) -> None:
    qtest.writel(addr, value)
    check_equal(name, qtest.readl(addr), value)


def hbn_read_rtc(qtest: QTestSession) -> int:
    qtest.writel(HBN_RTC_TIMH, HBN_RTC_LATCH)
    lo = qtest.readl(HBN_RTC_TIML)
    hi = qtest.readl(HBN_RTC_TIMH) & 0xFF
    qtest.writel(HBN_RTC_TIMH, 0x0)
    return (hi << 32) | lo


def riscv_encode_lui(rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | 0x37


def riscv_encode_jalr(rd: int, rs1: int, imm12: int) -> int:
    return (((imm12 & 0xFFF) << 20)
            | ((rs1 & 0x1F) << 15)
            | ((rd & 0x1F) << 7)
            | 0x67)


def synthetic_bootrom_jump(target: int) -> bytes:
    hi20 = (target + 0x800) >> 12
    lo12 = target - (hi20 << 12)
    return mmio_words_to_bytes(
        [
            riscv_encode_lui(5, hi20),
            riscv_encode_jalr(0, 5, lo12),
            0x00000013,
        ]
    )


def build_bl808_boot_header(
    *,
    group_image_offset: int,
    power_on_mm: bool,
    cpu_offsets: tuple[int, int, int],
    cpu_enable: tuple[bool, bool, bool],
    cpu_halt: tuple[bool, bool, bool] = (False, False, False),
    deadbeef_crc: bool = False,
) -> bytes:
    header = bytearray(352)
    struct.pack_into("<I", header, 0x00, 0x504E4642)  # BFNP
    struct.pack_into("<I", header, 0x04, 0x00000001)
    struct.pack_into("<I", header, 0x08, 0x47464346)  # FCFG
    struct.pack_into("<I", header, 0x64, 0x47464350)  # PCFG

    flags = 1 << 8  # no_segment
    if power_on_mm:
        flags |= 1 << 18
    struct.pack_into("<I", header, 0x80, flags)
    struct.pack_into("<I", header, 0x84, group_image_offset)

    for cpu, image_offset in enumerate(cpu_offsets):
        base = 0x0B0 + cpu * 24
        header[base] = 1 if cpu_enable[cpu] else 0
        header[base + 1] = 1 if cpu_halt[cpu] else 0
        struct.pack_into("<I", header, base + 12, image_offset)
        struct.pack_into("<I", header, base + 16, FLASH_XIP_BASE + image_offset)

    crc = 0xDEADBEEF if deadbeef_crc else (zlib.crc32(header[:0x15C]) & 0xFFFFFFFF)
    struct.pack_into("<I", header, 0x15C, crc)
    return bytes(header)


def build_bflb_partition_table(
    *,
    age: int,
    entries: list[dict[str, Any]],
) -> bytes:
    table = bytearray(b"\xFF" * PT_TABLE_SIZE)
    struct.pack_into("<IHHI", table, 0x00, 0x54504642, 0, len(entries), age)

    for index, entry in enumerate(entries):
        base = 0x10 + index * 36
        name = entry["name"].encode("ascii")
        table[base + 0] = entry.get("type", 0)
        table[base + 1] = entry.get("device", 0)
        table[base + 2] = entry.get("active_index", 0)
        table[base + 3:base + 12] = name[:9].ljust(9, b"\x00")
        struct.pack_into("<II", table, base + 12, *entry["start_address"])
        struct.pack_into("<II", table, base + 20, *entry.get("max_len", (0, 0)))
        struct.pack_into("<II", table, base + 28,
                         entry.get("len", 0), entry.get("entry_age", 0))

    struct.pack_into("<I", table, 0x0C, zlib.crc32(table[:0x0C]) & 0xFFFFFFFF)
    entries_end = 0x10 + len(entries) * 36
    struct.pack_into("<I", table, entries_end,
                     zlib.crc32(table[0x10:entries_end]) & 0xFFFFFFFF)
    return bytes(table)


def synthetic_riscv64_elf(entry: int, code: bytes) -> bytes:
    phoff = 64
    phentsize = 56
    segment_offset = 0x1000
    ident = bytes([0x7F, ord("E"), ord("L"), ord("F"),
                   2, 1, 1, 0, 0]) + bytes(7)
    ehdr = struct.pack(
        "<16sHHIQQQIHHHHHH",
        ident,
        2,
        243,
        1,
        entry,
        phoff,
        0,
        0,
        64,
        phentsize,
        1,
        0,
        0,
        0,
    )
    phdr = struct.pack(
        "<IIQQQQQQ",
        1,
        0x7,
        segment_offset,
        entry,
        entry,
        len(code),
        len(code),
        0x1000,
    )
    padding = bytes(segment_offset - len(ehdr) - len(phdr))
    return ehdr + phdr + padding + code


def synthetic_riscv32_elf(entry: int, code: bytes) -> bytes:
    phoff = 52
    phentsize = 32
    segment_offset = 0x1000
    ident = bytes([0x7F, ord("E"), ord("L"), ord("F"),
                   1, 1, 1, 0, 0]) + bytes(7)
    ehdr = struct.pack(
        "<16sHHIIIIIHHHHHH",
        ident,
        2,
        243,
        1,
        entry,
        phoff,
        0,
        0,
        52,
        phentsize,
        1,
        0,
        0,
        0,
    )
    phdr = struct.pack(
        "<IIIIIIII",
        1,
        segment_offset,
        entry,
        entry,
        len(code),
        len(code),
        0x7,
        0x1000,
    )
    padding = bytes(segment_offset - len(ehdr) - len(phdr))
    return ehdr + phdr + padding + code


def read_cpu_pcs(qtest: QTestSession) -> dict[int, int]:
    cpu_pcs: dict[int, int] = {}
    current_cpu: int | None = None

    for raw_line in qtest.hmp_command("info registers -a").splitlines():
        line = raw_line.strip()
        if line.startswith("CPU#"):
            current_cpu = int(line[4:])
            continue
        if current_cpu is None or not line.startswith("pc"):
            continue
        cpu_pcs[current_cpu] = int(line.split()[1], 16)

    return cpu_pcs


def dma2d_linear_copy(
    qtest: QTestSession, src: int, dst: int, data: bytes
) -> tuple[int, bytes, list[str]]:
    qtest.take_irq_events()
    qtest.write(src, data)
    qtest.memset(dst, len(data), 0x00)
    qtest.writel(DMA2D_BASE + DMA2D_INTTCCLEAR, 0x3)
    qtest.writel(DMA2D_BASE + DMA2D_CH0_SRCADDR, src)
    qtest.writel(DMA2D_BASE + DMA2D_CH0_DSTADDR, dst)
    qtest.writel(
        DMA2D_BASE + DMA2D_CH0_BUS,
        len(data) | DMA2D_SI | DMA2D_DI | DMA2D_I,
    )
    qtest.writel(DMA2D_BASE + DMA2D_CH0_CFG, DMA2D_CH_EN)
    qtest.writel(DMA2D_BASE + DMA2D_CONFIG, DMA2D_E)
    qtest.clock_step(1)
    return (
        qtest.readl(DMA2D_BASE + DMA2D_INTSTATUS),
        qtest.read(dst, len(data)),
        qtest.take_irq_events(),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--qemu",
        default="/Users/gabriel/Documents/nimlang/qemu-bl808/build/qemu-system-riscv64",
        help="Path to qemu-system-riscv64 with the BL808 machine installed",
    )
    args = parser.parse_args()

    qemu_binary = Path(args.qemu)
    if not qemu_binary.is_file():
        print(f"QEMU binary not found: {qemu_binary}", file=sys.stderr)
        return 2

    qtest = QTestSession(qemu_binary)
    try:
        mtree = qtest.hmp_command("info mtree")
        if "bl808.coreid" not in mtree:
            raise AssertionError("Default machine should expose BL808 core-id MMIO")
        check_equal("Core ID MMIO", qtest.readl(0xF0000000), 0xE9070000)
        check_equal(
            "I2C0 default EEPROM disabled",
            i2c_write_reg(qtest, 0x2000A300, 0x50, 0x00, b"\x5a"),
            "nak",
        )

        # CLINT: qtest virtual time is deterministic, so mtime writes should
        # read back exactly.
        qtest.writel(0xE000BFFC, 0x1)
        qtest.writel(0xE000BFF8, 0x23456789)
        check_range("mtime lo", qtest.readl(0xE000BFF8), 0x23456789, 0x23456889)
        check_equal("mtime hi", qtest.readl(0xE000BFFC), 0x00000001)
        check_equal("Timer0 TCCR reset", qtest.readl(TIMER0_BASE + TIMER_TCCR),
                    TIMER_TCCR_RESET)
        check_equal("Timer0 match0 reset", qtest.readl(TIMER0_BASE + TIMER_TMR2_0),
                    TIMER_TMR_RESET)

        # RM Table 1.6 exposes the shared EMAC and PWM blocks as D0 PLIC
        # sources EMAC2 (IRQ 52) and PWM1 (IRQ 64). The D0 PLIC sits on the
        # D0 private bus, so qtest observes it by intercepting the PLIC GPIO
        # inputs rather than by reading a shared MMIO alias.
        d0_plic_path = qtest.find_qom_path_by_type("riscv.sifive.plic")
        qtest.irq_intercept_in(d0_plic_path)
        qtest.take_irq_events()

        check_equal("MM_MISC reset while MM off", qtest.readl(MM_MISC_MISC_DUMMY),
                    MM_MISC_MISC_DUMMY_RESET)
        qtest.writel(MM_MISC_MISC_DUMMY, 0x12345678)
        check_equal("MM_MISC write ignored while MM off",
                    qtest.readl(MM_MISC_MISC_DUMMY), MM_MISC_MISC_DUMMY_RESET)
        qtest.writel(IPC2_BASE + IPC_IEN, 0x0001)
        qtest.writel(IPC2_BASE + IPC_TRI, 0x0001)
        check_equal("IPC2 MM-off raw status", qtest.readl(IPC2_BASE + IPC_STS), 0)
        check_equal("IPC2 MM-off masked status", qtest.readl(IPC2_BASE + IPC_ISTS), 0)
        check_not_contains("IPC2 MM-off IRQ blocked", qtest.take_irq_events(),
                           "IRQ raise 54")

        dma2d_src = 0x22031300
        dma2d_dst = 0x22031340
        dma2d_payload = bytes.fromhex("00112233445566778899aabbccddeeff")
        dma2d_status, dma2d_result, dma2d_events = dma2d_linear_copy(
            qtest, dma2d_src, dma2d_dst, dma2d_payload
        )
        check_equal("DMA2D MM-off intstatus", dma2d_status, 0)
        check_equal("DMA2D MM-off transfer blocked", dma2d_result,
                    bytes(len(dma2d_payload)))
        check_not_contains("DMA2D MM-off IRQ blocked", dma2d_events,
                           "IRQ raise 61")

        mm_domain_set_power(qtest, True)
        qtest.writel(MM_MISC_MISC_DUMMY, 0x12345678)
        check_equal("MM_MISC write sticks while MM on",
                    qtest.readl(MM_MISC_MISC_DUMMY), 0x12345678)
        check_regbank_readback(qtest, "LZ4D register bank",
                               LZ4D_BASE + 0x10, 0x22031000)
        check_regbank_readback(qtest, "DVP0 register bank",
                               DVP0_BASE + 0x04, 0x3EF80000)
        check_regbank_readback(qtest, "OSD A register bank",
                               OSD_A_BASE + 0x00, 0x00440005)
        check_regbank_readback(qtest, "OSD DP register bank",
                               OSD_DP_BASE + 0x04, 0x00112233)
        check_regbank_readback(qtest, "DBI register bank",
                               DBI_BASE + 0x0C, 0x80000000)
        check_regbank_readback(qtest, "MJPEG register bank",
                               MJPEG_BASE + 0x24, 0x00020004)
        check_regbank_readback(qtest, "H264 register bank",
                               H264_BASE + 0x04, 0x00200040)
        qtest.writel(MM_GLB_MM_CLK_CPU, MM_GLB_CNN_CLK_DIV_EN)
        check_equal("BLAI CNN clock enable",
                    qtest.readl(MM_GLB_MM_CLK_CPU) & MM_GLB_CNN_CLK_DIV_EN,
                    MM_GLB_CNN_CLK_DIV_EN)
        qtest.writel(MM_GLB_MM_SW_RESET_CODEC, MM_GLB_SWRST_CNN)
        check_equal("BLAI CNN reset assert",
                    qtest.readl(MM_GLB_MM_SW_RESET_CODEC) & MM_GLB_SWRST_CNN,
                    MM_GLB_SWRST_CNN)
        qtest.writel(MM_GLB_MM_SW_RESET_CODEC, 0)
        check_equal("BLAI CNN reset release",
                    qtest.readl(MM_GLB_MM_SW_RESET_CODEC) & MM_GLB_SWRST_CNN,
                    0)
        qtest.writel(MM_MISC_VRAM_CTRL, MM_MISC_BLAI_SRAM_REL | MM_MISC_SYSRAM_SET)
        check_equal("BLAI SRAM release",
                    qtest.readl(MM_MISC_VRAM_CTRL) & MM_MISC_BLAI_SRAM_REL,
                    MM_MISC_BLAI_SRAM_REL)
        check_equal("BLAI SRAM latch self-clears",
                    qtest.readl(MM_MISC_VRAM_CTRL) & MM_MISC_SYSRAM_SET,
                    0)
        qtest.writel(IPC2_BASE + IPC_IEN, 0x0001)
        qtest.writel(IPC2_BASE + IPC_TRI, 0x0001)
        check_equal("IPC2 MM-on raw status", qtest.readl(IPC2_BASE + IPC_STS), 0x0001)
        check_equal("IPC2 MM-on masked status", qtest.readl(IPC2_BASE + IPC_ISTS), 0x0001)
        check_contains("D0 PLIC IPC2 IRQ", qtest.take_irq_events(), "IRQ raise 54")

        dma2d_status, dma2d_result, dma2d_events = dma2d_linear_copy(
            qtest, dma2d_src, dma2d_dst, dma2d_payload
        )
        check_equal("DMA2D MM-on intstatus", dma2d_status, 0x1)
        check_equal("DMA2D MM-on transfer", dma2d_result, dma2d_payload)
        check_contains("D0 PLIC DMA2D IRQ", dma2d_events, "IRQ raise 61")

        mm_domain_set_power(qtest, False)
        check_equal("MM_MISC resets on MM power-off",
                    qtest.readl(MM_MISC_MISC_DUMMY), MM_MISC_MISC_DUMMY_RESET)
        check_equal("IPC2 reset on MM power-off raw", qtest.readl(IPC2_BASE + IPC_STS), 0)
        check_equal("IPC2 reset on MM power-off mask", qtest.readl(IPC2_BASE + IPC_ISTS), 0)

        dma2d_status, dma2d_result, dma2d_events = dma2d_linear_copy(
            qtest, dma2d_src, dma2d_dst, dma2d_payload
        )
        check_equal("DMA2D MM-poweroff intstatus reset", dma2d_status, 0)
        check_equal("DMA2D MM-poweroff transfer blocked", dma2d_result,
                    bytes(len(dma2d_payload)))
        check_not_contains("DMA2D MM-poweroff IRQ blocked", dma2d_events,
                           "IRQ raise 61")

        mm_domain_set_power(qtest, True)
        check_equal("MM_MISC reset after MM power cycle",
                    qtest.readl(MM_MISC_MISC_DUMMY), MM_MISC_MISC_DUMMY_RESET)
        check_equal("IPC2 reset after MM power cycle raw", qtest.readl(IPC2_BASE + IPC_STS), 0)
        check_equal("IPC2 reset after MM power cycle mask", qtest.readl(IPC2_BASE + IPC_ISTS), 0)
        qtest.take_irq_events()

        emac_base = 0x20070000
        emac_src = 0x22030A00
        qtest.write(emac_src, bytes.fromhex("00112233"))
        qtest.writel(emac_base + 0x08, 0x00000000)
        qtest.writel(emac_base + 0x20, 0x00000001)
        qtest.writel(emac_base + 0x404, emac_src)
        qtest.writel(emac_base + 0x400, (4 << 16) | 0x4000 | 0x8000)
        qtest.writel(emac_base + 0x00, 0x00000002)
        emac_events = qtest.take_irq_events()
        check_contains("D0 PLIC EMAC2 IRQ", emac_events, "IRQ raise 52")

        pwm_base = 0x2000A400
        qtest.writel(pwm_base + 0x68, 0x000007FF)
        qtest.writel(pwm_base + 0x64, 0x000007FF)
        qtest.writel(pwm_base + 0x6C, 0x00000100)
        qtest.writel(pwm_base + 0x64, 0x00000000)
        qtest.writel(pwm_base + 0x48, 0x00000000)
        qtest.writel(pwm_base + 0x40, 0x00000000)
        qtest.clock_step(100)
        pwm_events = qtest.take_irq_events()
        check_contains("D0 PLIC PWM1 IRQ", pwm_events, "IRQ raise 64")

        # SEC_ENG reset protection state and TRNG.
        check_equal("SEC_ENG ctrl_prot_rd", qtest.readl(0x20004F00), 0x00000FFF)
        check_equal("SEC_ENG SHA status reset", qtest.readl(0x20004008), 0x00000041)
        check_equal("SEC_ENG SHA endian reset", qtest.readl(0x2000400C), 0x00000001)
        check_equal("SEC_ENG AES endian reset", qtest.readl(0x20004148), 0x0000001F)
        check_equal("SEC_ENG AES sboot reset", qtest.readl(0x2000414C), 0x00020000)
        qtest.writel(0x20004200, 0x00000006)
        check_equal("SEC_ENG TRNG ctrl", qtest.readl(0x20004200), 0x00000104)
        check_equal("SEC_ENG TRNG status", qtest.readl(0x20004204), 0x00000001)
        if qtest.readl(0x20004208) == 0:
            raise AssertionError("SEC_ENG TRNG dout0 should not stay zero")

        # SHA256 of one 64-byte zero block.
        sha_src = 0x22030000
        qtest.memset(sha_src, 0x40, 0x00)
        qtest.writel(0x20004004, sha_src)
        qtest.writel(0x20004000, 0x00010022)
        check_equal(
            "SEC_ENG SHA256",
            qtest.read(0x20004010, 32).hex(),
            "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b",
        )

        qtest.writel(0x20004004, sha_src)
        qtest.writel(0x20004000, 0x00011022)
        check_equal(
            "SEC_ENG MD5",
            qtest.read(0x20004010, 16).hex(),
            "3b5d3c7d207e37dceeedd301e35e2e58",
        )

        qtest.writel(0x20004004, sha_src)
        qtest.writel(0x20004000, 0x0001002E)
        check_equal(
            "SEC_ENG SHA1 mode3",
            qtest.read(0x20004010, 20).hex(),
            hashlib.sha1(bytes(64)).hexdigest(),
        )

        # CRC32 link mode shares the SHA engine on BL808 and writes the
        # rolling result back to link_addr + 0x10.
        crc_src = 0x22030800
        crc_link = 0x22030880
        qtest.write(crc_src, bytes.fromhex("00010203"))
        qtest.memset(crc_link, 0x14, 0x00)
        qtest.writel(crc_link + 0x00, 0x00013000)
        qtest.writel(crc_link + 0x04, crc_src)
        qtest.writel(crc_link + 0x08, 0x04C11DB7)
        qtest.writel(crc_link + 0x0C, 0x00000007)
        qtest.writel(crc_link + 0x10, 0xFFFFFFFF)
        qtest.writel(0x20004050, crc_link)
        qtest.writel(0x20004000, 0x00008022)
        check_equal("SEC_ENG CRC32 reflected", qtest.read(crc_link + 0x10, 4).hex(), "1386b98b")

        qtest.writel(crc_link + 0x0C, 0x00000000)
        qtest.writel(crc_link + 0x10, 0xFFFFFFFF)
        qtest.writel(0x20004050, crc_link)
        qtest.writel(0x20004000, 0x00008022)
        check_equal("SEC_ENG CRC32 straight", qtest.read(crc_link + 0x10, 4).hex(), "2ac96d6b")

        crc_src2 = 0x22030900
        crc_link2 = 0x22030980
        qtest.write(crc_src2, bytes(range(8)))
        qtest.memset(crc_link2, 0x14, 0x00)
        qtest.writel(crc_link2 + 0x00, 0x00013000)
        qtest.writel(crc_link2 + 0x04, crc_src2)
        qtest.writel(crc_link2 + 0x08, 0x04C11DB7)
        qtest.writel(crc_link2 + 0x0C, 0x00000007)
        qtest.writel(crc_link2 + 0x10, 0xFFFFFFFF)
        qtest.writel(0x20004050, crc_link2)
        qtest.writel(0x20004000, 0x00008022)
        check_equal("SEC_ENG CRC32 block0", qtest.read(crc_link2 + 0x10, 4).hex(), "1386b98b")
        qtest.writel(crc_link2 + 0x00, 0x00013040)
        qtest.writel(crc_link2 + 0x04, crc_src2 + 4)
        qtest.writel(0x20004050, crc_link2)
        qtest.writel(0x20004000, 0x00008022)
        check_equal("SEC_ENG CRC32 accumulate", qtest.read(crc_link2 + 0x10, 4).hex(), "9f68aa88")

        # Direct CRC mode uses the SHA registers directly, with HASH_SEL
        # accumulating from the previous hash register contents.
        crc_direct_src = 0x22030940
        qtest.write(crc_direct_src, bytes(range(8)))
        qtest.writel(0x20004004, crc_direct_src)
        qtest.writel(0x20004000, 0x00013022)
        check_equal("SEC_ENG CRC32 direct", qtest.readl(0x20004010), 0x8BB98613)
        qtest.writel(0x20004004, crc_direct_src + 4)
        qtest.writel(0x20004000, 0x00013062)
        check_equal("SEC_ENG CRC32 direct accumulate", qtest.readl(0x20004010), 0x88AA689F)

        qtest.writel(0x20004004, crc_direct_src)
        qtest.writel(0x20004000, 0x00012022)
        check_equal("SEC_ENG CRC16 direct", qtest.readl(0x20004010), 0x00008510)
        qtest.writel(0x20004004, crc_direct_src + 4)
        qtest.writel(0x20004000, 0x00012062)
        check_equal("SEC_ENG CRC16 direct accumulate", qtest.readl(0x20004010), 0x00007A46)

        # SHA512 and SHA384 use the BL808 H/L interleaved output register layout.
        sha512_src = 0x22030080
        qtest.memset(sha512_src, 0x80, 0x00)
        qtest.writel(0x20004004, sha512_src)
        qtest.writel(0x20004000, 0x00010032)
        sha512_regs = [
            qtest.readl(0x20004030),
            qtest.readl(0x20004010),
            qtest.readl(0x20004034),
            qtest.readl(0x20004014),
            qtest.readl(0x20004038),
            qtest.readl(0x20004018),
            qtest.readl(0x2000403C),
            qtest.readl(0x2000401C),
            qtest.readl(0x20004040),
            qtest.readl(0x20004020),
            qtest.readl(0x20004044),
            qtest.readl(0x20004024),
            qtest.readl(0x20004048),
            qtest.readl(0x20004028),
            qtest.readl(0x2000404C),
            qtest.readl(0x2000402C),
        ]
        check_equal(
            "SEC_ENG SHA512",
            mmio_words_to_bytes(sha512_regs).hex(),
            hashlib.sha512(bytes(128)).hexdigest(),
        )

        qtest.writel(0x20004004, sha512_src)
        qtest.writel(0x20004000, 0x00010036)
        sha384_regs = [
            qtest.readl(0x20004030),
            qtest.readl(0x20004010),
            qtest.readl(0x20004034),
            qtest.readl(0x20004014),
            qtest.readl(0x20004038),
            qtest.readl(0x20004018),
            qtest.readl(0x2000403C),
            qtest.readl(0x2000401C),
            qtest.readl(0x20004040),
            qtest.readl(0x20004020),
            qtest.readl(0x20004044),
            qtest.readl(0x20004024),
        ]
        check_equal(
            "SEC_ENG SHA384",
            mmio_words_to_bytes(sha384_regs).hex(),
            hashlib.sha384(bytes(128)).hexdigest(),
        )

        qtest.writel(0x20004004, sha512_src)
        qtest.writel(0x20004000, 0x0001003A)
        sha512_224_regs = [
            qtest.readl(0x20004030),
            qtest.readl(0x20004010),
            qtest.readl(0x20004034),
            qtest.readl(0x20004014),
            qtest.readl(0x20004038),
            qtest.readl(0x20004018),
            qtest.readl(0x2000403C),
        ]
        check_equal(
            "SEC_ENG SHA512/224",
            mmio_words_to_bytes(sha512_224_regs).hex(),
            hashlib.new("sha512_224", bytes(128)).hexdigest(),
        )

        qtest.writel(0x20004004, sha512_src)
        qtest.writel(0x20004000, 0x0001003E)
        sha512_256_regs = [
            qtest.readl(0x20004030),
            qtest.readl(0x20004010),
            qtest.readl(0x20004034),
            qtest.readl(0x20004014),
            qtest.readl(0x20004038),
            qtest.readl(0x20004018),
            qtest.readl(0x2000403C),
            qtest.readl(0x2000401C),
        ]
        check_equal(
            "SEC_ENG SHA512/256",
            mmio_words_to_bytes(sha512_256_regs).hex(),
            hashlib.new("sha512_256", bytes(128)).hexdigest(),
        )

        # AES-128 ECB encrypt of one zero block with a zero key.
        aes_src = 0x22030100
        aes_dst = 0x22030200
        qtest.memset(aes_src, 0x10, 0x00)
        qtest.memset(aes_dst, 0x10, 0x00)
        for off in range(0, 0x20, 4):
            qtest.writel(0x20004120 + off, 0)
        qtest.writel(0x20004104, aes_src)
        qtest.writel(0x20004108, aes_dst)
        qtest.writel(0x20004100, 0x00010006)
        check_equal(
            "SEC_ENG AES-128 ECB",
            qtest.read(aes_dst, 16).hex(),
            "66e94bd4ef8a2c3b884cfa59ca342b2e",
        )

        aes_ctr_iv = bytes.fromhex("006cb6dbc0543b590000000000000000")
        aes_ctr_pt = bytes.fromhex(
            "000102030405060708090a0b0c0d0e0f"
            "101112131415161718191a1b1c1d1e1f"
            "202122232425262728292a2b2c2d2e2f"
        )
        aes_ctr_ct = (
            "3a98b6848526185c46527ad934faafcf"
            "825107dc10def523ab4a787f9e5b90e7"
            "4cd2f783122389ee077ac01ed049701b"
        )

        # AES-128 CTR uses a 128-bit counter block on BL808. This path is
        # backend-independent in QEMU, so validate it directly with software
        # key registers before exercising efuse-backed hardware keys.
        aes_ctr_src = 0x220309C0
        aes_ctr_dst = 0x22030900
        aes_ctr_key = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")
        qtest.write(aes_ctr_src, aes_ctr_pt)
        qtest.memset(aes_ctr_dst, len(aes_ctr_pt), 0x00)
        for off in range(0, len(aes_ctr_key), 4):
            qtest.writel(
                0x20004120 + off,
                int.from_bytes(aes_ctr_key[off : off + 4], "little"),
            )
        for off in range(0, len(aes_ctr_iv), 4):
            qtest.writel(
                0x20004110 + off,
                int.from_bytes(aes_ctr_iv[off : off + 4], "little"),
            )
        qtest.writel(0x20004104, aes_ctr_src)
        qtest.writel(0x20004108, aes_ctr_dst)
        qtest.writel(0x20004100, 0x00031006)
        check_equal("SEC_ENG AES-128 CTR", qtest.read(aes_ctr_dst, len(aes_ctr_pt)).hex(), aes_ctr_ct)

        # Hardware AES keys use efuse slot-backed key material. Program BL808
        # Slot2 at EF_CTRL offset 0x3c and select it with key_sel0 = 2.
        hwkey = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")
        for index in range(0, len(hwkey), 4):
            qtest.writel(
                0x2005603C + index,
                int.from_bytes(hwkey[index : index + 4], "little"),
            )
        aes_hw_src = 0x22030A00
        aes_hw_dst = 0x22030B00
        qtest.write(aes_hw_src, aes_ctr_pt)
        qtest.memset(aes_hw_dst, len(aes_ctr_pt), 0x00)
        for off in range(0, 0x20, 4):
            qtest.writel(0x20004120 + off, 0)
        for off in range(0, len(aes_ctr_iv), 4):
            qtest.writel(
                0x20004110 + off,
                int.from_bytes(aes_ctr_iv[off : off + 4], "little"),
            )
        qtest.writel(0x20004140, 0x00000002)
        qtest.writel(0x20004144, 0x00000000)
        qtest.writel(0x2000414C, 0x00000000)
        qtest.writel(0x20004104, aes_hw_src)
        qtest.writel(0x20004108, aes_hw_dst)
        qtest.writel(0x20004100, 0x00031086)
        check_equal(
            "SEC_ENG AES-128 CTR hwkey slot2",
            qtest.read(aes_hw_dst, len(aes_ctr_pt)).hex(),
            aes_ctr_ct,
        )

        # AES-XTS direct mode follows the BL808 SDK conventions:
        # key mode 0 uses two 128-bit halves from KEY0..KEY7,
        # key mode 2 duplicates one 192-bit key from KEY0..KEY5,
        # key mode 1 duplicates one 256-bit key from KEY0..KEY7.
        aes_xts_src = 0x22030500
        aes_xts_dst = 0x22030600
        aes_xts_pt = bytes(range(16))
        qtest.write(aes_xts_src, aes_xts_pt)
        qtest.memset(aes_xts_dst, 0x10, 0x00)
        for off, value in enumerate(
            [
                0x03020100,
                0x07060504,
                0x0B0A0908,
                0x0F0E0D0C,
                0x13121110,
                0x17161514,
                0x1B1A1918,
                0x1F1E1D1C,
            ]
        ):
            qtest.writel(0x20004120 + off * 4, value)
        qtest.writel(0x20004110, 0x0C0D0E0F)
        qtest.writel(0x20004114, 0x08090A0B)
        qtest.writel(0x20004118, 0x04050607)
        qtest.writel(0x2000411C, 0x00010203)
        qtest.writel(0x2000414C, 0x00020000)
        qtest.writel(0x20004104, aes_xts_src)
        qtest.writel(0x20004108, aes_xts_dst)
        qtest.writel(0x20004100, 0x00013006)
        check_equal(
            "SEC_ENG AES-128 XTS",
            qtest.read(aes_xts_dst, 16).hex(),
            "b62412371f8d7cf1e27c05af1a83d9b9",
        )

        aes_xts192_src = 0x22030C00
        aes_xts192_dst = 0x22030D00
        aes_xts192_pt = bytes(64)
        aes_xts192_key = bytes.fromhex(
            "000102030405060708090a0b0c0d0e0f"
            "fffefdfcfbfaf9f8"
        )
        qtest.write(aes_xts192_src, aes_xts192_pt)
        qtest.memset(aes_xts192_dst, len(aes_xts192_pt), 0x00)
        for off in range(0, 0x20, 4):
            qtest.writel(0x20004120 + off, 0x00000000)
        for off in range(0, len(aes_xts192_key), 4):
            qtest.writel(
                0x20004120 + off,
                int.from_bytes(aes_xts192_key[off : off + 4], "little"),
            )
        for off in range(0, 0x10, 4):
            qtest.writel(0x20004110 + off, 0x00000000)
        qtest.writel(0x2000414C, 0x00020000)
        qtest.writel(0x20004104, aes_xts192_src)
        qtest.writel(0x20004108, aes_xts192_dst)
        qtest.writel(0x20004100, 0x00043016)
        check_equal(
            "SEC_ENG AES-192 XTS",
            qtest.read(aes_xts192_dst, len(aes_xts192_pt)).hex(),
            (
                "82ba637ad6fb48e15cc23e8e36f96353"
                "0cd8da208790df038297e565eee254a5"
                "e83d20a123d2cc22e16ec2144919dc09"
                "4c1cdbe1bdc15ba6df7a71c79e1162db"
            ),
        )

        aes_xts256_src = 0x22030E00
        aes_xts256_dst = 0x22030F00
        aes_xts256_pt = bytes(64)
        aes_xts256_key = bytes.fromhex(
            "000102030405060708090a0b0c0d0e0f"
            "fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0"
        )
        qtest.write(aes_xts256_src, aes_xts256_pt)
        qtest.memset(aes_xts256_dst, len(aes_xts256_pt), 0x00)
        for off in range(0, 0x20, 4):
            qtest.writel(
                0x20004120 + off,
                int.from_bytes(aes_xts256_key[off : off + 4], "little"),
            )
        for off in range(0, 0x10, 4):
            qtest.writel(0x20004110 + off, 0x00000000)
        qtest.writel(0x2000414C, 0x00020000)
        qtest.writel(0x20004104, aes_xts256_src)
        qtest.writel(0x20004108, aes_xts256_dst)
        qtest.writel(0x20004100, 0x0004300E)
        check_equal(
            "SEC_ENG AES-256 XTS",
            qtest.read(aes_xts256_dst, len(aes_xts256_pt)).hex(),
            (
                "b5e0204ece33cdc04974a6eb78d1cbad"
                "9c5ebc0a6df254868bb80085691b2f17"
                "c0fa26fe005433335636a692e5656824"
                "748171b68edbaa0d7a4c310fdc2c71a4"
            ),
        )

        # Link mode uses the descriptor-local hwkey bit together with the
        # global key-select registers.
        aes_link_src = 0x22031000
        aes_link_dst = 0x22031100
        aes_link_desc = 0x22031200
        qtest.memset(aes_link_src, 0x10, 0x00)
        qtest.memset(aes_link_dst, 0x10, 0x00)
        qtest.memset(aes_link_desc, 0x50, 0x00)
        qtest.writel(aes_link_desc + 0x00, 0x00010080)
        qtest.writel(aes_link_desc + 0x04, aes_link_src)
        qtest.writel(aes_link_desc + 0x08, aes_link_dst)
        qtest.writel(0x20004140, 0x00000002)
        qtest.writel(0x20004144, 0x00000000)
        qtest.writel(0x2000414C, 0x00000000)
        qtest.writel(0x20004150, aes_link_desc)
        qtest.writel(0x20004100, 0x00018006)
        check_equal(
            "SEC_ENG AES link ECB hwkey slot2",
            qtest.read(aes_link_dst, 16).hex(),
            "7df76b0c1ab899b33e42f047b91b546f",
        )

        # SEC_GMAC uses the BL808 link descriptor format with a fixed-size
        # 128-bit key and a 16-byte tag.
        gmac_src = 0x22030780
        gmac_link = 0x22030700
        qtest.write(gmac_src, bytes(range(16)))
        qtest.memset(gmac_link, 0x28, 0x00)
        qtest.writel(gmac_link + 0x00, 0x00010000)
        qtest.writel(gmac_link + 0x04, gmac_src)
        qtest.writel(gmac_link + 0x08, 0x03020100)
        qtest.writel(gmac_link + 0x0C, 0x07060504)
        qtest.writel(gmac_link + 0x10, 0x0B0A0908)
        qtest.writel(gmac_link + 0x14, 0x0F0E0D0C)
        qtest.writel(0x20004504, gmac_link)
        qtest.writel(0x20004500, 0x00000006)
        check_equal(
            "SEC_ENG GMAC",
            qtest.read(gmac_link + 0x18, 16).hex(),
            "4d1f06b70f92ca320f8d91cee03e379e",
        )

        # USB reset values and VDMA FIFO0 round-trip.
        check_equal("USB HCCAP", qtest.readl(0x20072000), 0x01000010)
        check_equal("USB REVISION", qtest.readl(0x200720E0), 0x00010000)
        usb_src = 0x22030300
        usb_dst = 0x22030400
        usb_data = bytes.fromhex("00112233445566778899aabbccddeeff")
        qtest.write(usb_src, usb_data)
        qtest.memset(usb_dst, len(usb_data), 0x00)
        qtest.writel(0x2007230C, usb_src)
        qtest.writel(0x20072308, 0x00001003)
        check_equal("USB FIFO0 fill", qtest.readl(0x200721B0), len(usb_data))
        qtest.writel(0x2007230C, usb_dst)
        qtest.writel(0x20072308, 0x00001001)
        check_equal("USB FIFO0 drain", qtest.readl(0x200721B0), 0)
        check_equal("USB VDMA round-trip", qtest.read(usb_dst, len(usb_data)), usb_data)

        # SF_CTRL uses IF_SAHB1/2 for the opcode/address stream and the SRAM
        # window at +0x600 for payload/result bytes.
        sf_base = 0x2000B000
        sf_buf = sf_base + 0x600
        sf_xip = 0x58000000

        SAHB_TRIGGER = 1 << 1
        SAHB_DATA_RW = 1 << 23
        SAHB_DATA_EN = 1 << 24
        SAHB_ADDR_EN = 1 << 26
        SAHB_CMD_EN = 1 << 27

        def sf_issue(
            cmd_lo: int,
            cmd_hi: int = 0,
            *,
            data_len: int = 0,
            addr_len: int = 0,
            read: bool = False,
        ) -> None:
            sahb0 = SAHB_CMD_EN | SAHB_TRIGGER
            if data_len:
                sahb0 |= ((data_len - 1) << 2) | SAHB_DATA_EN
                if read:
                    sahb0 |= SAHB_DATA_RW
            if addr_len:
                sahb0 |= ((addr_len - 1) << 17) | SAHB_ADDR_EN
            qtest.writel(sf_base + 0x00C, cmd_lo)
            qtest.writel(sf_base + 0x010, cmd_hi)
            qtest.writel(sf_base + 0x008, sahb0)

        def sf_wren() -> None:
            sf_issue(0x06000000)

        def sf_read(
            cmd_lo: int,
            *,
            data_len: int,
            addr_len: int = 0,
            cmd_hi: int = 0,
        ) -> bytes:
            qtest.memset(sf_buf, data_len, 0x00)
            sf_issue(cmd_lo, cmd_hi, data_len=data_len, addr_len=addr_len, read=True)
            return qtest.read(sf_buf, data_len)

        check_equal("SF_CTRL JEDEC ID", sf_read(0x9F000000, data_len=3).hex(), "ef6018")
        check_equal("SF_CTRL device ID", sf_read(0x90000000, data_len=2, addr_len=3).hex(), "ef17")
        check_equal("SF_CTRL XIP above chip size", qtest.read(sf_xip + 0x01000000, 16).hex(), "ff" * 16)

        sf_issue(0xB9000000)
        qtest.memset(sf_buf, 3, 0x00)
        sf_issue(0x9F000000, data_len=3, read=True)
        check_equal("SF_CTRL power-down blocks reads", qtest.read(sf_buf, 3), bytes(3))
        check_equal("SF_CTRL release power-down", sf_read(0xAB000000, data_len=1).hex(), "17")

        qtest.write(sf_buf, bytes.fromhex("00"))
        sf_issue(0x50000000)
        sf_issue(0x31000000, data_len=1)
        check_equal("SF_CTRL QE fixed high", sf_read(0x35000000, data_len=1).hex(), "02")

        qtest.write(sf_buf, bytes.fromhex("64"))
        sf_issue(0x50000000)
        sf_issue(0x11000000, data_len=1)
        check_equal("SF_CTRL volatile reg write enable", sf_read(0x15000000, data_len=1).hex(), "64")

        qtest.write(sf_buf, bytes.fromhex("00"))
        sf_issue(0x11000000, data_len=1)
        check_equal("SF_CTRL volatile reg write one-shot", sf_read(0x15000000, data_len=1).hex(), "64")

        sf_issue(0x66000000)
        sf_issue(0x06000000)
        sf_issue(0x99000000)
        check_equal("SF_CTRL reset-enable cancellation", sf_read(0x05000000, data_len=1).hex(), "02")

        sf_data = bytes.fromhex("00112233445566778899aabbccddeeff")
        qtest.write(sf_buf, sf_data)
        sf_wren()
        sf_issue(0x02000100, data_len=len(sf_data), addr_len=3)
        check_equal("SF_CTRL IF_SAHB round-trip", sf_read(0x03000100, data_len=len(sf_data), addr_len=3), sf_data)

        sf_wrap = bytes(range(16))
        qtest.write(sf_buf, sf_wrap)
        sf_wren()
        sf_issue(0x020003F8, data_len=len(sf_wrap), addr_len=3)
        check_equal("SF_CTRL page wrap tail", sf_read(0x030003F8, data_len=8, addr_len=3), sf_wrap[:8])
        check_equal("SF_CTRL page wrap head", sf_read(0x03000300, data_len=8, addr_len=3), sf_wrap[8:])

        sf_qpp = bytes.fromhex("8899aabbccddeeff0011223344556677")
        qtest.write(sf_buf, sf_qpp)
        sf_wren()
        sf_issue(0x32000200, data_len=len(sf_qpp), addr_len=3)
        check_equal("SF_CTRL quad page program", sf_read(0x03000200, data_len=len(sf_qpp), addr_len=3), sf_qpp)

        sec_data = bytes.fromhex("deadbeef00112233445566778899aabb")
        qtest.write(sf_buf, sec_data)
        sf_wren()
        sf_issue(0x42001020, data_len=len(sec_data), addr_len=3)
        check_equal("SF_CTRL security register read/write", sf_read(0x48001020, data_len=len(sec_data), addr_len=3), sec_data)
        check_equal("SF_CTRL security register address decode", sf_read(0x48000120, data_len=len(sec_data), addr_len=3).hex(), "ff" * len(sec_data))

        sf_wren()
        sf_issue(0x44001000, addr_len=3)
        check_equal("SF_CTRL security register erase", sf_read(0x48001020, data_len=len(sec_data), addr_len=3).hex(), "ff" * len(sec_data))

        # Each mailbox exposes one documented 32-bit channel bitmap.
        qtest.writel(IPC0_BASE + IPC_IDIS, 0xFFFF_FFFF)
        qtest.writel(IPC0_BASE + IPC_ACK, 0xFFFF_FFFF)
        qtest.writel(IPC0_BASE + IPC_IEN, 0x0000_0003)
        qtest.writel(IPC0_BASE + IPC_TRI, 0x0000_0003)
        check_equal("IPC0 raw status", qtest.readl(IPC0_BASE + IPC_STS), 0x0000_0003)
        check_equal("IPC0 masked status", qtest.readl(IPC0_BASE + IPC_ISTS), 0x0000_0003)
        qtest.writel(IPC0_BASE + IPC_ACK, 0x0000_0001)
        check_equal("IPC0 partial clear", qtest.readl(IPC0_BASE + IPC_STS), 0x0000_0002)

        # D0 firmware examples only depend on the WL_ALL summary line, not on
        # a full wireless backend. Assert that native BLE pending bits still
        # reach the D0 PLIC through that summary interrupt.
        qtest.take_irq_events()
        qtest.qom_set("/machine", "ble-intrawstat-pending", BLE_FINE_TIMER_IRQ)
        check_equal("D0 WL_ALL BLE summary raw",
                    qtest.readl(BLE_INTRAWSTAT), BLE_FINE_TIMER_IRQ)
        check_contains("D0 PLIC WL_ALL summary IRQ",
                       qtest.take_irq_events(),
                       f"IRQ raise {D0_WL_ALL_IRQ}")
        qtest.writel(BLE_INTACK, BLE_FINE_TIMER_IRQ)
        check_equal("D0 WL_ALL BLE summary clear",
                    qtest.readl(BLE_INTRAWSTAT), 0x0)
        check_contains("D0 PLIC WL_ALL summary IRQ clear",
                       qtest.take_irq_events(),
                       f"IRQ lower {D0_WL_ALL_IRQ}")
    finally:
        qtest.close()

    m0_irq_qtest = QTestSession(qemu_binary)
    try:
        m0_clic_path = sorted(
            m0_irq_qtest.find_qom_paths_by_type("csky_xt_clic")
        )[0]
        m0_irq_qtest.irq_intercept_in(m0_clic_path)
        m0_irq_qtest.take_irq_events()

        # RM Table 1.5 routes the shared EMAC and PWM blocks to M0 CLIC
        # sources EMAC (IRQ 40) and PWM (IRQ 49).
        emac_base = 0x20070000
        emac_src = 0x22030A00
        m0_irq_qtest.write(emac_src, bytes.fromhex("00112233"))
        m0_irq_qtest.writel(emac_base + 0x08, 0x00000000)
        m0_irq_qtest.writel(emac_base + 0x20, 0x00000001)
        m0_irq_qtest.writel(emac_base + 0x404, emac_src)
        m0_irq_qtest.writel(emac_base + 0x400, (4 << 16) | 0x4000 | 0x8000)
        m0_irq_qtest.writel(emac_base + 0x00, 0x00000002)
        check_contains("M0 CLIC EMAC IRQ", m0_irq_qtest.take_irq_events(),
                       f"IRQ raise {M0_EMAC_IRQ}")

        pwm_base = 0x2000A400
        m0_irq_qtest.writel(pwm_base + 0x68, 0x000007FF)
        m0_irq_qtest.writel(pwm_base + 0x64, 0x000007FF)
        m0_irq_qtest.writel(pwm_base + 0x6C, 0x00000100)
        m0_irq_qtest.writel(pwm_base + 0x64, 0x00000000)
        m0_irq_qtest.writel(pwm_base + 0x48, 0x00000000)
        m0_irq_qtest.writel(pwm_base + 0x40, 0x00000000)
        m0_irq_qtest.clock_step(100)
        check_contains("M0 CLIC PWM IRQ", m0_irq_qtest.take_irq_events(),
                       f"IRQ raise {M0_PWM_IRQ}")

        m0_irq_qtest.writel(IPC0_BASE + IPC_ACK, 0xFFFF_FFFF)
        m0_irq_qtest.writel(IPC0_BASE + IPC_IDIS, 0xFFFF_FFFF)
        m0_irq_qtest.writel(IPC0_BASE + IPC_IEN, 0x0001)
        m0_irq_qtest.writel(IPC0_BASE + IPC_TRI, 0x0001)
        check_equal("IPC0 M0 raw status",
                    m0_irq_qtest.readl(IPC0_BASE + IPC_STS), 0x0001)
        check_equal("IPC0 M0 masked status",
                    m0_irq_qtest.readl(IPC0_BASE + IPC_ISTS), 0x0001)
        check_contains("M0 CLIC IPC0 IRQ", m0_irq_qtest.take_irq_events(),
                       f"IRQ raise {M0_IPC_IRQ}")
        m0_irq_qtest.writel(IPC0_BASE + IPC_ACK, 0x0001)
        check_equal("IPC0 M0 clear",
                    m0_irq_qtest.readl(IPC0_BASE + IPC_STS), 0x0)
        check_contains("M0 CLIC IPC0 IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_IPC_IRQ}")

        # SDK-backed clock-source mapping: timer0 BCLK follows MCU PBCLK, XTAL
        # follows the HBN XTAL type/fallback, and timer1 BCLK follows MM_GLB.
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 80_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(900_000)
        check_equal("Timer0 CH2 default BCLK rate pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(100_000)
        check_equal("Timer0 CH2 default BCLK rate threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(HBN_RSV3, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_XTAL)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 40_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(900_000)
        check_equal("Timer0 CH2 default XTAL pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(100_000)
        check_equal("Timer0 CH2 default XTAL threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(HBN_RSV3, 0x00005801)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 24_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(900_000)
        check_equal("Timer0 CH2 HBN XTAL type pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(100_000)
        check_equal("Timer0 CH2 HBN XTAL type threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(HBN_RSV3, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_0, 160_000)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(900_000)
        check_equal("Timer1 CH2 default MM BCLK pre-threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(100_000)
        check_equal("Timer1 CH2 default MM BCLK threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)

        # Timer0 BCLK should track the MCU root clock path through HBN/PDS.
        m0_irq_qtest.writel(HBN_RSV3, 0x0)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0000000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, GLB_BCLK_DIV_ACT_PULSE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)

        m0_irq_qtest.writel(HBN_GLB, HBN_ROOT_CLK_XCLK_RC32M)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 32_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(900_000)
        check_equal("Timer0 CH2 MCU XCLK RC32M pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(100_000)
        check_equal("Timer0 CH2 MCU XCLK RC32M threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(HBN_GLB, HBN_ROOT_CLK_XCLK_XTAL)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 40_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(900_000)
        check_equal("Timer0 CH2 MCU XCLK XTAL pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(100_000)
        check_equal("Timer0 CH2 MCU XCLK XTAL threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(HBN_GLB, HBN_ROOT_CLK_PLL)
        m0_irq_qtest.writel(PDS_CPU_CORE_CFG1, PDS_PLL_SEL_WIFIPLL_240M)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 240_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(900_000)
        check_equal("Timer0 CH2 MCU PLL240 pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(100_000)
        check_equal("Timer0 CH2 MCU PLL240 threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(PDS_CPU_CORE_CFG1, PDS_PLL_SEL_WIFIPLL_320M)
        m0_irq_qtest.writel(HBN_GLB, HBN_ROOT_CLK_PLL)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0003000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, GLB_BCLK_DIV_ACT_PULSE)

        # MM timer BCLK should follow GLB_DIG_CLK_CFG1 muxpll selection.
        m0_irq_qtest.writel(HBN_RSV3, 0x0)
        m0_irq_qtest.writel(GLB_DIG_CLK_CFG1, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_240M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CPU, 0x00000000)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_0, 240_000)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(GLB_DIG_CLK_CFG1, GLB_MM_MUXPLL_240M_SEL_AUPLL)
        m0_irq_qtest.clock_step(500_000)
        check_equal("Timer1 CH2 MM muxpll240 AUPLL pre-threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(50_000)
        check_equal("Timer1 CH2 MM muxpll240 AUPLL threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(GLB_DIG_CLK_CFG1, 0x0)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)

        # CCI CPU PLL changes should retime timer0 immediately when the MCU
        # root clock is sourced from CPU PLL.
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0000000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, GLB_BCLK_DIV_ACT_PULSE)
        m0_irq_qtest.writel(CCI_CPU_PLL_CFG0, CCI_CPUPLL_CFG0_ON)
        m0_irq_qtest.writel(CCI_CPU_PLL_CFG1, CCI_CPUPLL_CFG1_XTAL)
        m0_irq_qtest.writel(CCI_CPU_PLL_CFG8, CCI_CPUPLL_CFG8_DEFAULT)
        m0_irq_qtest.writel(CCI_CPU_PLL_CFG6, CCI_CPUPLL_SDMIN_400M)
        m0_irq_qtest.writel(HBN_GLB, HBN_ROOT_CLK_PLL)
        m0_irq_qtest.writel(PDS_CPU_CORE_CFG1, PDS_PLL_SEL_CPUPLL_400M)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 440_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        check_equal("Timer0 CH2 CPU PLL pre-retime",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(CCI_CPU_PLL_CFG6, CCI_CPUPLL_SDMIN_480M)
        m0_irq_qtest.clock_step(490_000)
        check_equal("Timer0 CH2 CPU PLL live retime pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(10_000)
        check_equal("Timer0 CH2 CPU PLL live retime threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(CCI_CPU_PLL_CFG0, CCI_CPUPLL_CFG0_ON)
        m0_irq_qtest.writel(CCI_CPU_PLL_CFG1, CCI_CPUPLL_CFG1_XTAL)
        m0_irq_qtest.writel(CCI_CPU_PLL_CFG8, CCI_CPUPLL_CFG8_DEFAULT)
        m0_irq_qtest.writel(CCI_CPU_PLL_CFG6, CCI_CPUPLL_SDMIN_400M)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 400_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(CCI_CPU_PLL_CFG0, CCI_CPUPLL_CFG0_ON & ~(1 << 10))
        m0_irq_qtest.clock_step(2_000_000)
        check_equal("Timer0 CH2 CPU PLL power gate stalls clock",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(CCI_CPU_PLL_CFG0, CCI_CPUPLL_CFG0_ON)
        m0_irq_qtest.clock_step(490_000)
        check_equal("Timer0 CH2 CPU PLL power restore pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(10_000)
        check_equal("Timer0 CH2 CPU PLL power restore threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(CCI_CPU_PLL_CFG6, 0x0)
        m0_irq_qtest.writel(PDS_CPU_CORE_CFG1, PDS_PLL_SEL_WIFIPLL_320M)
        m0_irq_qtest.writel(HBN_GLB, HBN_ROOT_CLK_PLL)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0003000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, GLB_BCLK_DIV_ACT_PULSE)

        # CCI AUPLL changes should retime timer1 immediately when the MM 1x
        # PB-root is sourced from muxpll240 -> AUPLL_DIV2.
        m0_irq_qtest.writel(GLB_DIG_CLK_CFG1, GLB_MM_MUXPLL_240M_SEL_AUPLL)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG0, CCI_AUPLL_CFG0_ON)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG1, CCI_AUPLL_CFG1_XTAL)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG8, CCI_AUPLL_CFG8_DEFAULT)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG6, CCI_AUPLL_SDMIN_442P368M)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_240M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CPU, 0x00000000)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_0, 223_488)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        check_equal("Timer1 CH2 AUPLL pre-retime",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG6, CCI_AUPLL_SDMIN_451P584M)
        m0_irq_qtest.clock_step(450_000)
        check_equal("Timer1 CH2 AUPLL live retime pre-threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(50_000)
        check_equal("Timer1 CH2 AUPLL live retime threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG0, CCI_AUPLL_CFG0_ON)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG1, CCI_AUPLL_CFG1_XTAL)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG8, CCI_AUPLL_CFG8_DEFAULT)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG6, CCI_AUPLL_SDMIN_442P368M)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_0, 221_184)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG1, CCI_AUPLL_CFG1_RC32M)
        m0_irq_qtest.clock_step(2_000_000)
        check_equal("Timer1 CH2 AUPLL refclk mismatch stalls clock",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG6, CCI_AUPLL_SDMIN_442P368M_32M)
        m0_irq_qtest.clock_step(490_000)
        check_equal("Timer1 CH2 AUPLL refclk restore pre-threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(10_000)
        check_equal("Timer1 CH2 AUPLL refclk restore threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG1, CCI_AUPLL_CFG1_XTAL)
        m0_irq_qtest.writel(CCI_AUDIO_PLL_CFG6, CCI_AUPLL_SDMIN_442P368M)
        m0_irq_qtest.writel(GLB_DIG_CLK_CFG1, 0x0)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)

        # WiFi PLL should no longer behave like a hardcoded 240/320/160 MHz
        # source: invalid SDMIN should stall WiFi-backed timer clocks until the
        # PLL is programmed back to a valid 960 MHz VCO.
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG0, GLB_WIFIPLL_CFG0_ON)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG1, GLB_WIFIPLL_CFG1_XTAL)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG5, GLB_WIFIPLL_CFG5_DEFAULT)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG8, GLB_WIFIPLL_CFG8_DEFAULT)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG6, GLB_WIFIPLL_SDMIN_960M_40M)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0000000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, GLB_BCLK_DIV_ACT_PULSE)
        m0_irq_qtest.writel(HBN_GLB, HBN_ROOT_CLK_PLL)
        m0_irq_qtest.writel(PDS_CPU_CORE_CFG1, PDS_PLL_SEL_WIFIPLL_320M)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 320_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        check_equal("Timer0 CH2 WiFi PLL pre-retime",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG6, 0x0)
        m0_irq_qtest.clock_step(2_000_000)
        check_equal("Timer0 CH2 WiFi PLL invalid SDMIN stalls clock",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG6, GLB_WIFIPLL_SDMIN_960M_40M)
        m0_irq_qtest.clock_step(490_000)
        check_equal("Timer0 CH2 WiFi PLL restored pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(10_000)
        check_equal("Timer0 CH2 WiFi PLL restored threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG0, GLB_WIFIPLL_CFG0_ON)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG1, GLB_WIFIPLL_CFG1_XTAL)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG5, GLB_WIFIPLL_CFG5_DEFAULT)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG8, GLB_WIFIPLL_CFG8_DEFAULT)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG6, GLB_WIFIPLL_SDMIN_960M_40M)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 320_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG1, GLB_WIFIPLL_CFG1_RC32M)
        m0_irq_qtest.clock_step(2_000_000)
        check_equal("Timer0 CH2 WiFi PLL refclk mismatch stalls clock",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG6, GLB_WIFIPLL_SDMIN_960M_32M)
        m0_irq_qtest.clock_step(490_000)
        check_equal("Timer0 CH2 WiFi PLL refclk restore pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(10_000)
        check_equal("Timer0 CH2 WiFi PLL refclk restore threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG1, GLB_WIFIPLL_CFG1_XTAL)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG6, GLB_WIFIPLL_SDMIN_960M_40M)
        m0_irq_qtest.writel(PDS_CPU_CORE_CFG1, PDS_PLL_SEL_WIFIPLL_320M)
        m0_irq_qtest.writel(HBN_GLB, HBN_ROOT_CLK_PLL)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0003000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, GLB_BCLK_DIV_ACT_PULSE)

        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG6, GLB_WIFIPLL_SDMIN_960M_40M)
        m0_irq_qtest.writel(GLB_DIG_CLK_CFG1, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CPU, 0x00000000)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_0, 160_000)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        check_equal("Timer1 CH2 WiFi PLL160 pre-retime",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG6, 0x0)
        m0_irq_qtest.clock_step(2_000_000)
        check_equal("Timer1 CH2 WiFi PLL160 invalid SDMIN stalls clock",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG6, GLB_WIFIPLL_SDMIN_960M_40M)
        m0_irq_qtest.clock_step(490_000)
        check_equal("Timer1 CH2 WiFi PLL160 restored pre-threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(10_000)
        check_equal("Timer1 CH2 WiFi PLL160 restored threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(GLB_WIFI_PLL_CFG6, GLB_WIFIPLL_SDMIN_960M_40M)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)

        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0000000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, GLB_BCLK_DIV_ACT_PULSE)
        m0_irq_qtest.writel(HBN_GLB, HBN_ROOT_CLK_PLL)
        m0_irq_qtest.writel(PDS_CPU_CORE_CFG1, PDS_PLL_SEL_WIFIPLL_320M)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 320_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0000000E)
        m0_irq_qtest.clock_step(2_000_000)
        check_equal("Timer0 CH2 GLB pll_en gate stalls PLL root",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0000000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.clock_step(490_000)
        check_equal("Timer0 CH2 GLB pll_en restore pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(10_000)
        check_equal("Timer0 CH2 GLB pll_en restore threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_0, 160_000)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_BCLK_EN)
        m0_irq_qtest.clock_step(2_000_000)
        check_equal("Timer1 CH2 MM pll_en gate stalls muxpll root",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)
        m0_irq_qtest.clock_step(490_000)
        check_equal("Timer1 CH2 MM pll_en restore pre-threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(10_000)
        check_equal("Timer1 CH2 MM pll_en restore threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0003000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, GLB_BCLK_DIV_ACT_PULSE)

        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 80_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(GLB_SYS_CFG0,
                            (0x0003000E | GLB_SYS_CFG_PLL_EN) &
                            ~GLB_SYS_CFG_BCLK_EN)
        m0_irq_qtest.clock_step(2_000_000)
        check_equal("Timer0 CH2 GLB bclk_en gate stalls PBCLK",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0003000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.clock_step(490_000)
        check_equal("Timer0 CH2 GLB bclk_en restore pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(10_000)
        check_equal("Timer0 CH2 GLB bclk_en restore threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_0, 160_000)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_PLL_EN)
        m0_irq_qtest.clock_step(2_000_000)
        check_equal("Timer1 CH2 MM bclk_en gate stalls PBCLK",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)
        m0_irq_qtest.clock_step(490_000)
        check_equal("Timer1 CH2 MM bclk_en restore pre-threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(10_000)
        check_equal("Timer1 CH2 MM bclk_en restore threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0003000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, GLB_BCLK_DIV_ACT_PULSE)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)

        # MCU PBCLK divider changes should not affect timer0 until the GLB
        # apply pulse is issued, and the protection-done status should latch.
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0003000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 100_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x000F000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.clock_step(600_000)
        check_equal("Timer0 CH2 pending MCU PBCLK change stays old rate",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(150_000)
        check_equal("Timer0 CH2 old MCU PBCLK still reaches threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(GLB_SYS_CFG1, GLB_BCLK_DIV_ACT_PULSE)
        check_equal("MCU PBCLK protection done status",
                    m0_irq_qtest.readl(GLB_SYS_CFG1) & GLB_STS_BCLK_PROT_DONE,
                    GLB_STS_BCLK_PROT_DONE)
        m0_irq_qtest.clock_step(2_900_000)
        check_equal("Timer0 CH2 applied MCU PBCLK divider pre-threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(100_000)
        check_equal("Timer0 CH2 applied MCU PBCLK divider threshold",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        # MM PBCLK retimes immediately through the 1x PB-root selector.
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CPU, 0x00000000)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCCR, TIMER_CLK2_SRC_BCLK)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_0, 200_000)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(500_000)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_XCLK |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)
        m0_irq_qtest.clock_step(900_000)
        check_equal("Timer1 CH2 MM PBCLK source retime pre-threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x0)
        m0_irq_qtest.clock_step(2_900_000)
        check_equal("Timer1 CH2 MM PBCLK source retime threshold",
                    m0_irq_qtest.readl(TIMER1_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER1_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(MM_GLB_MM_CLK_CTRL_CPU,
                            MM_GLB_BCLK1X_SEL_160M |
                            MM_GLB_CLK_CTRL_PLL_EN |
                            MM_GLB_CLK_CTRL_BCLK_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG0, 0x0003000E | GLB_SYS_CFG_PLL_EN)
        m0_irq_qtest.writel(GLB_SYS_CFG1, 0x0)

        m0_irq_qtest.writel(HBN_RSV3, 0x0)

        # Preload mode should honor TPLCR and reload from TPLVR only when the
        # selected comparator matches.
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_1KHZ)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TPLVR2, 10)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 13)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, 16)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TPLCR2, 0x2)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        check_range("Timer0 CH2 preload start",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCR2), 10, 10)
        m0_irq_qtest.clock_step(3_000_000)
        check_equal("Timer0 CH2 compare0 status",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x1)
        m0_irq_qtest.clock_step(3_000_000)
        check_equal("Timer0 CH2 compare1 reload status",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x2, 0x2)
        check_range("Timer0 CH2 reloads on compare1",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCR2), 10, 11)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.clock_step(3_000_000)
        check_equal("Timer0 CH2 compare0 retriggers after reload",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        check_range("Timer0 CH2 sync counter read",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCVSYN2), 13, 16)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        # Timer channel IRQ mode should follow TILR: level mode stays asserted
        # until cleared, while edge mode pulses without holding the line high.
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TIER2, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, 0x2)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TPLCR2, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TIER2, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TILR2, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 2)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(3_000_000)
        check_equal("Timer0 CH2 level IRQ status",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        level_events = m0_irq_qtest.take_irq_events()
        check_contains("M0 CLIC Timer0 CH2 level IRQ raise",
                       level_events, f"IRQ raise {M0_TIMER0_CH0_IRQ}")
        check_not_contains("M0 CLIC Timer0 CH2 level IRQ held high",
                           level_events, f"IRQ lower {M0_TIMER0_CH0_IRQ}")
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x1)
        check_contains("M0 CLIC Timer0 CH2 level IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_TIMER0_CH0_IRQ}")

        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TIER2, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TILR2, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TIER2, 0x1)
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(3_000_000)
        check_equal("Timer0 CH2 edge IRQ status",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        edge_events = m0_irq_qtest.take_irq_events()
        check_contains("M0 CLIC Timer0 CH2 edge IRQ raise",
                       edge_events, f"IRQ raise {M0_TIMER0_CH0_IRQ}")
        check_contains("M0 CLIC Timer0 CH2 edge IRQ pulse low",
                       edge_events, f"IRQ lower {M0_TIMER0_CH0_IRQ}")
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x1)
        check_not_contains("M0 CLIC Timer0 CH2 edge clear stays low",
                           m0_irq_qtest.take_irq_events(),
                           f"IRQ lower {M0_TIMER0_CH0_IRQ}")
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TIER2, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TILR2, 0x0)

        # TCVWR should latch both timer counters on the first read, while
        # TCVSYN remains a continuously readable live counter.
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR,
                            TIMER_TCMR_TIMER2_MODE | TIMER_TCMR_TIMER3_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR,
                            TIMER_CLK2_SRC_1KHZ | TIMER_CLK3_SRC_1KHZ)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(2_000_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER,
                            TIMER_TIMER2_EN | TIMER_TIMER3_EN)
        m0_irq_qtest.clock_step(3_000_000)
        tcvwr2_latched = m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCVWR2)
        m0_irq_qtest.clock_step(3_000_000)
        tcvwr3_latched = m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCVWR3)
        tcvsyn3_live = m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCVSYN3)
        check_range("Timer0 TCVWR2 latched snapshot", tcvwr2_latched, 5, 6)
        check_range("Timer0 TCVWR3 paired latch snapshot", tcvwr3_latched, 3, 4)
        check_range("Timer0 TCVSYN3 live counter", tcvsyn3_live, 6, 7)
        if not tcvwr3_latched < tcvsyn3_live:
            raise AssertionError(
                "Timer0 TCVWR3 should remain latched while TCVSYN3 advances"
            )
        check_range("Timer0 TCVWR latch clears after both reads",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCVWR2), 8, 9)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        # timer2_align should defer match-value updates until the current
        # compare interrupt boundary has completed.
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_1KHZ)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 5)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(2_000_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR,
                            TIMER_TCMR_TIMER2_MODE | TIMER_TCMR_TIMER2_ALIGN)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 10)
        m0_irq_qtest.clock_step(4_000_000)
        check_equal("Timer0 CH2 align old compare fires first",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x1)
        m0_irq_qtest.clock_step(5_000_000)
        check_equal("Timer0 CH2 align new compare fires after boundary",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        check_range("Timer0 CH2 align live counter",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCVSYN2), 10, 11)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)

        # TCDR writes should not retime a running counter unless TCDR_FORCE is
        # asserted; the programmed divider becomes live on the next restart.
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCMR, TIMER_TCMR_TIMER2_MODE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_CLK2_SRC_1KHZ)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_0, 5)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_1, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TMR2_2, TIMER_TMR_RESET)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(2_000_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, TIMER_TCDR_TIMER2_DIV2)
        m0_irq_qtest.clock_step(4_000_000)
        check_equal("Timer0 CH2 divider write without force keeps old timing",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(6_000_000)
        check_equal("Timer0 CH2 divider update applies after restart",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        check_range("Timer0 CH2 restart uses slower divider",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCVSYN2), 2, 3)
        m0_irq_qtest.clock_step(4_000_000)
        check_equal("Timer0 CH2 slower divider eventually reaches compare",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, TIMER_TIMER2_EN)
        m0_irq_qtest.clock_step(2_000_000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, TIMER_TCDR_TIMER2_DIV2)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR_FORCE,
                            TIMER_TCDR_FORCE_TIMER2)
        m0_irq_qtest.clock_step(4_000_000)
        check_equal("Timer0 CH2 forced divider avoids old compare deadline",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x0)
        check_range("Timer0 CH2 forced divider slows live counter",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCVSYN2), 3, 4)
        m0_irq_qtest.clock_step(3_000_000)
        check_equal("Timer0 CH2 forced divider still reaches compare later",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TSR2) & 0x1, 0x1)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TICR2, 0x7)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCER, 0x0)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCDR, 0x0)

        # wdt_align should defer a programmed match update until the running
        # timeout boundary, while the next reset/feed cycle uses the new match.
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_WDT_CLK_SRC_1KHZ)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMR, 0x00000005)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WCR, 0x1)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMER, TIMER_WDT_EN)
        m0_irq_qtest.clock_step(2_000_000)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMR, TIMER_WMR_ALIGN | 10)
        check_equal("Timer0 WDT aligned match readback",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WMR),
                    TIMER_WMR_ALIGN | 10)
        m0_irq_qtest.clock_step(4_000_000)
        check_equal("Timer0 WDT align keeps old timeout in flight",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WSR), 0x1)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WICR, 0x1)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WCR, 0x1)
        m0_irq_qtest.clock_step(6_000_000)
        check_equal("Timer0 WDT align defers new match after feed",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WSR), 0x0)
        m0_irq_qtest.clock_step(5_000_000)
        check_equal("Timer0 WDT align uses new match on next cycle",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WSR), 0x1)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WICR, 0x1)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMER, 0x0)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMR, TIMER_WDT_MATCH_MASK)

        # Timer0 watchdog uses the documented feed sequence and asserts the
        # M0 watchdog interrupt when reset-on-timeout is disabled.
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_WDT_CLK_SRC_1KHZ)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMR, 0x00000005)
        check_equal("Timer0 WDT locked WMR ignored",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WMR),
                    TIMER_WDT_MATCH_MASK)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMR, 0x00000005)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WCR, 0x1)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMER, TIMER_WDT_EN)
        m0_irq_qtest.clock_step(2_000_000)
        check_range("Timer0 WDT counter before feed",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WVR), 1, 3)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WCR, 0x1)
        check_range("Timer0 WDT counter after feed",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WVR), 0, 1)
        m0_irq_qtest.clock_step(6_000_000)
        check_equal("Timer0 WDT timeout status",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WSR), 0x1)
        check_contains("M0 CLIC Timer0 WDT IRQ", m0_irq_qtest.take_irq_events(),
                       f"IRQ raise {M0_TIMER0_WDT_IRQ}")
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WICR, 0x1)
        check_equal("Timer0 WDT locked clear ignored",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WSR), 0x1)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WICR, 0x1)
        check_equal("Timer0 WDT clear status",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WSR), 0x0)
        check_contains("M0 CLIC Timer0 WDT IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_TIMER0_WDT_IRQ}")
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMER, 0x0)

        # Reset-on-timeout should perform a whole-machine reset and restore
        # peripheral reset defaults.
        m0_irq_qtest.writel(PDS_CTL2, 0x00000000)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_TCCR, TIMER_WDT_CLK_SRC_1KHZ)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMR, 0x00000005)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WCR, 0x1)
        timer_wdt_unlock(m0_irq_qtest, TIMER0_BASE)
        m0_irq_qtest.writel(TIMER0_BASE + TIMER_WMER,
                            TIMER_WDT_EN | TIMER_WDT_RST)
        m0_irq_qtest.clock_step(6_000_000)
        check_equal("Timer0 WDT reset clears WMER",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WMER), 0x0)
        check_equal("Timer0 WDT reset restores WMR",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_WMR),
                    TIMER_WDT_MATCH_MASK)
        check_equal("Timer0 WDT reset restores TCCR",
                    m0_irq_qtest.readl(TIMER0_BASE + TIMER_TCCR),
                    TIMER_TCCR_RESET)
        check_equal("Timer0 WDT reset restores PDS_CTL2",
                    m0_irq_qtest.readl(PDS_CTL2), PDS_MM_FORCE_MASK)

        # qtest MMIO writes should be able to exercise the PDS state machine
        # even though there is no guest CPU context attached to the access.
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(PDS_INT, PDS_INT_CLEAR | PDS_WAKEUP_SRC_TIMER)
        m0_irq_qtest.writel(PDS_TIME1, 0x8)
        m0_irq_qtest.writel(PDS_CTL, 0x0)
        m0_irq_qtest.writel(PDS_CTL, PDS_CTL_START_PS)
        check_equal("PDS timed wake enters busy state",
                    m0_irq_qtest.readl(PDS_STAT) & PDS_STAT_BUSY,
                    PDS_STAT_BUSY)
        m0_irq_qtest.clock_step(100_000)
        check_equal("PDS timed wake remains busy before expiry",
                    m0_irq_qtest.readl(PDS_STAT) & PDS_STAT_BUSY,
                    PDS_STAT_BUSY)
        check_equal("PDS timed wake stays idle before expiry",
                    m0_irq_qtest.readl(PDS_INT) &
                    (PDS_INT_WAKEUP | PDS_WAKEUP_EVENT_TIMER),
                    0x0)
        check_not_contains("M0 CLIC timed PDS wake premature IRQ",
                           m0_irq_qtest.take_irq_events(),
                           f"IRQ raise {M0_PDS_WAKEUP_IRQ}")
        m0_irq_qtest.clock_step(200_000)
        check_equal("PDS timed wake event bits",
                    m0_irq_qtest.readl(PDS_INT) &
                    (PDS_INT_WAKEUP | PDS_WAKEUP_EVENT_TIMER),
                    PDS_INT_WAKEUP | PDS_WAKEUP_EVENT_TIMER)
        check_equal("PDS timed wake clears busy state",
                    m0_irq_qtest.readl(PDS_STAT) & PDS_STAT_BUSY,
                    0x0)
        check_contains("M0 CLIC timed PDS wake IRQ",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ raise {M0_PDS_WAKEUP_IRQ}")
        m0_irq_qtest.writel(PDS_INT, PDS_INT_CLEAR | PDS_WAKEUP_SRC_TIMER)
        check_equal("PDS timed wake clears status",
                    m0_irq_qtest.readl(PDS_INT) &
                    (PDS_INT_WAKEUP | PDS_WAKEUP_EVENT_TIMER),
                    0x0)
        check_contains("M0 CLIC timed PDS wake IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_PDS_WAKEUP_IRQ}")

        # GLB AON GPIO wake should latch the pin interrupt and resume PDS.
        gpio10_cfg = GLB_GPIO_CFG_BASE + 10 * 4
        gpio10_mode = (
            GLB_GPIO_CFG_IE
            | (GLB_GPIO_CFG_SWGPIO_FUNC << GLB_GPIO_CFG_FUNC_SHIFT)
            | (GLB_GPIO_CFG_ASYNC_RISING << GLB_GPIO_CFG_INT_MODE_SHIFT)
        )
        m0_irq_qtest.qom_set("/machine", "aon-gpio10-level", False)
        m0_irq_qtest.writel(gpio10_cfg, gpio10_mode | GLB_GPIO_CFG_INT_CLR)
        m0_irq_qtest.writel(PDS_INT, PDS_INT_CLEAR | PDS_WAKEUP_SRC_GLB_GPIO)
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(
            PDS_CTL, PDS_CTL_SLEEP_FOREVER | PDS_CTL_START_PS
        )
        check_equal("GLB wake enters PDS busy state",
                    m0_irq_qtest.readl(PDS_STAT) & PDS_STAT_BUSY,
                    PDS_STAT_BUSY)
        m0_irq_qtest.qom_set("/machine", "aon-gpio10-level", True)
        check_equal("GLB GPIO10 interrupt latched",
                    m0_irq_qtest.readl(gpio10_cfg) &
                    (GLB_GPIO_CFG_INT_STAT | GLB_GPIO_CFG_I),
                    GLB_GPIO_CFG_INT_STAT | GLB_GPIO_CFG_I)
        check_equal("PDS GLB wake event bits",
                    m0_irq_qtest.readl(PDS_INT) &
                    (PDS_INT_WAKEUP | PDS_WAKEUP_EVENT_GLB_GPIO),
                    PDS_INT_WAKEUP | PDS_WAKEUP_EVENT_GLB_GPIO)
        check_equal("GLB wake clears PDS busy state",
                    m0_irq_qtest.readl(PDS_STAT) & PDS_STAT_BUSY,
                    0x0)
        check_contains("M0 CLIC GLB PDS wake IRQ",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ raise {M0_PDS_WAKEUP_IRQ}")
        m0_irq_qtest.writel(gpio10_cfg, gpio10_mode | GLB_GPIO_CFG_INT_CLR)
        check_equal("GLB GPIO10 interrupt clear",
                    m0_irq_qtest.readl(gpio10_cfg) & GLB_GPIO_CFG_INT_STAT,
                    0x0)
        m0_irq_qtest.writel(PDS_INT, PDS_INT_CLEAR | PDS_WAKEUP_SRC_GLB_GPIO)
        check_contains("M0 CLIC GLB PDS wake IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_PDS_WAKEUP_IRQ}")
        m0_irq_qtest.qom_set("/machine", "aon-gpio10-level", False)

        # Native PDS GPIO wake should use the dedicated PDS GPIO status bank.
        pds_gpio16_mode = PDS_GPIO_ASYNC_RISING << PDS_GPIO_SET2_MODE_SHIFT
        m0_irq_qtest.qom_set("/machine", "gpio16-level", False)
        m0_irq_qtest.writel(PDS_GPIO_I_SET, PDS_GPIO_GROUP_16_TO_23_IE)
        m0_irq_qtest.writel(PDS_GPIO_PD_SET, 0x0)
        m0_irq_qtest.writel(PDS_GPIO_INT, pds_gpio16_mode)
        m0_irq_qtest.writel(PDS_INT, PDS_INT_CLEAR | PDS_WAKEUP_SRC_PDS_GPIO)
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(
            PDS_CTL, PDS_CTL_SLEEP_FOREVER | PDS_CTL_START_PS
        )
        check_equal("PDS GPIO wake enters busy state",
                    m0_irq_qtest.readl(PDS_STAT) & PDS_STAT_BUSY,
                    PDS_STAT_BUSY)
        m0_irq_qtest.qom_set("/machine", "gpio16-level", True)
        check_equal("PDS GPIO16 status latched",
                    m0_irq_qtest.readl(PDS_GPIO_STAT) & PDS_GPIO_GPIO16_STAT,
                    PDS_GPIO_GPIO16_STAT)
        check_equal("PDS GPIO wake event bits",
                    m0_irq_qtest.readl(PDS_INT) &
                    (PDS_INT_WAKEUP | PDS_WAKEUP_EVENT_PDS_GPIO),
                    PDS_INT_WAKEUP | PDS_WAKEUP_EVENT_PDS_GPIO)
        check_equal("PDS GPIO wake clears busy state",
                    m0_irq_qtest.readl(PDS_STAT) & PDS_STAT_BUSY,
                    0x0)
        check_contains("M0 CLIC PDS GPIO wake IRQ",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ raise {M0_PDS_WAKEUP_IRQ}")
        m0_irq_qtest.writel(PDS_GPIO_INT, pds_gpio16_mode | PDS_GPIO_SET2_CLR)
        m0_irq_qtest.writel(PDS_GPIO_INT, pds_gpio16_mode)
        check_equal("PDS GPIO16 status clear",
                    m0_irq_qtest.readl(PDS_GPIO_STAT) & PDS_GPIO_GPIO16_STAT,
                    0x0)
        m0_irq_qtest.writel(PDS_INT, PDS_INT_CLEAR | PDS_WAKEUP_SRC_PDS_GPIO)
        check_contains("M0 CLIC PDS GPIO wake IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_PDS_WAKEUP_IRQ}")
        m0_irq_qtest.qom_set("/machine", "gpio16-level", False)

        # HBN live sources should fan into both HBN_OUTx and PDS wake logic.
        m0_irq_qtest.qom_set("/machine", "hbn-bod-level", False)
        m0_irq_qtest.writel(HBN_IRQ_CLR, HBN_IRQ_BOD_STAT)
        m0_irq_qtest.writel(HBN_IRQ_MODE, HBN_IRQ_BOD_EN)
        m0_irq_qtest.writel(PDS_INT, PDS_INT_CLEAR | PDS_WAKEUP_SRC_HBN_IRQ)
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(
            PDS_CTL, PDS_CTL_SLEEP_FOREVER | PDS_CTL_START_PS
        )
        check_equal("HBN BOD wake enters PDS busy state",
                    m0_irq_qtest.readl(PDS_STAT) & PDS_STAT_BUSY,
                    PDS_STAT_BUSY)
        m0_irq_qtest.qom_set("/machine", "hbn-bod-level", True)
        check_equal("HBN BOD status latched",
                    m0_irq_qtest.readl(HBN_IRQ_STAT) & HBN_IRQ_BOD_STAT,
                    HBN_IRQ_BOD_STAT)
        check_equal("PDS HBN wake event bits",
                    m0_irq_qtest.readl(PDS_INT) &
                    (PDS_INT_WAKEUP | PDS_WAKEUP_EVENT_HBN_IRQ),
                    PDS_INT_WAKEUP | PDS_WAKEUP_EVENT_HBN_IRQ)
        check_equal("HBN BOD wake clears PDS busy state",
                    m0_irq_qtest.readl(PDS_STAT) & PDS_STAT_BUSY,
                    0x0)
        bod_events = m0_irq_qtest.take_irq_events()
        check_contains("M0 CLIC HBN OUT1 IRQ",
                       bod_events, f"IRQ raise {M0_HBN_OUT1_IRQ}")
        check_contains("M0 CLIC HBN->PDS wake IRQ",
                       bod_events, f"IRQ raise {M0_PDS_WAKEUP_IRQ}")
        m0_irq_qtest.qom_set("/machine", "hbn-bod-level", False)
        check_equal("HBN BOD status clears with source",
                    m0_irq_qtest.readl(HBN_IRQ_STAT) & HBN_IRQ_BOD_STAT,
                    0x0)
        check_contains("M0 CLIC HBN OUT1 IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_HBN_OUT1_IRQ}")
        m0_irq_qtest.writel(PDS_INT, PDS_INT_CLEAR | PDS_WAKEUP_SRC_HBN_IRQ)
        check_contains("M0 CLIC HBN->PDS wake IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_PDS_WAKEUP_IRQ}")

        # BLE IRQ routing only needs the native controller register slice that
        # the firmware reads: latch current time, expose raw/masked status, and
        # clear on INTACK.
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(BLE_INTACK, 0xFFFF_FFFF)
        m0_irq_qtest.writel(BLE_INTCNTL, BLE_FINE_TIMER_IRQ)
        m0_irq_qtest.writel(BLE_BASETIMECNT, BLE_BASETIME_LATCH)
        ble_basetime = m0_irq_qtest.readl(BLE_BASETIMECNT)
        ble_finetime = m0_irq_qtest.readl(BLE_FINETIMECNT)
        m0_irq_qtest.qom_set("/machine", "ble-intrawstat-pending",
                             BLE_FINE_TIMER_IRQ)
        check_equal("BLE raw status pending",
                    m0_irq_qtest.readl(BLE_INTRAWSTAT), BLE_FINE_TIMER_IRQ)
        check_equal("BLE masked status pending",
                    m0_irq_qtest.readl(BLE_INTSTAT), BLE_FINE_TIMER_IRQ)
        check_equal("BLE basetime latch clears on read",
                    ble_basetime & BLE_BASETIME_LATCH, 0x0)
        check_range("BLE fine timer range", ble_finetime, 0, 624)
        check_contains("M0 CLIC BLE IRQ",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ raise {M0_BLE_IRQ}")
        m0_irq_qtest.writel(BLE_INTACK, BLE_FINE_TIMER_IRQ)
        check_equal("BLE raw status clear",
                    m0_irq_qtest.readl(BLE_INTRAWSTAT), 0x0)
        check_equal("BLE masked status clear",
                    m0_irq_qtest.readl(BLE_INTSTAT), 0x0)
        check_contains("M0 CLIC BLE IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_BLE_IRQ}")

        # Native Wi-Fi MACHW general interrupts are the exact registers the
        # M0 firmware touches for RX-complete notification.
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(WIFI_MACHW_INTC_STATUS_ACK, 0xFFFF_FFFF)
        m0_irq_qtest.writel(WIFI_MACHW_INTC_IRQ_SET, 0xFFFF_FFFF)
        m0_irq_qtest.writel(WIFI_MACHW_INTC_IRQ_STAT, WIFI_MACHW_GEN_RX_COMPLETE)
        m0_irq_qtest.writel(WIFI_MACHW_INTC_GEN_STATUS, WIFI_MACHW_GEN_GLOBAL_EN)
        m0_irq_qtest.writel(WIFI_MACHW_INTC_UNMASK,
                            WIFI_MACHW_IRQ_GLOBAL_EN | WIFI_MACHW_IRQ_GEN)
        m0_irq_qtest.qom_set("/machine", "wifi-mac-gen-rx-complete", True)
        check_equal("Wi-Fi MACHW status0 pending",
                    m0_irq_qtest.readl(WIFI_MAC_PL_IRQ_STATUS0),
                    WIFI_MACHW_IRQ_GEN)
        check_equal("Wi-Fi MACHW handler index",
                    m0_irq_qtest.readl(WIFI_MAC_PL_IRQ_HANDLER),
                    WIFI_MAC_GEN_HANDLER)
        check_equal("Wi-Fi MACHW raw status pending",
                    m0_irq_qtest.readl(WIFI_MACHW_INTC_STATUS_RAW),
                    WIFI_MACHW_IRQ_GEN)
        check_equal("Wi-Fi MACHW gen raw pending",
                    m0_irq_qtest.readl(WIFI_MACHW_INTC_GEN_RAW),
                    WIFI_MACHW_GEN_RX_COMPLETE)
        check_contains("M0 CLIC Wi-Fi MACHW IRQ",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ raise {M0_WIFI_IRQ}")
        m0_irq_qtest.writel(WIFI_MACHW_INTC_STATUS_ACK, WIFI_MACHW_IRQ_GEN)
        m0_irq_qtest.writel(WIFI_MACHW_INTC_IRQ_SET, WIFI_MACHW_GEN_RX_COMPLETE)
        check_equal("Wi-Fi MACHW status0 clear",
                    m0_irq_qtest.readl(WIFI_MAC_PL_IRQ_STATUS0), 0x0)
        check_equal("Wi-Fi MACHW raw status clear",
                    m0_irq_qtest.readl(WIFI_MACHW_INTC_STATUS_RAW), 0x0)
        check_equal("Wi-Fi MACHW gen raw clear",
                    m0_irq_qtest.readl(WIFI_MACHW_INTC_GEN_RAW), 0x0)
        check_contains("M0 CLIC Wi-Fi MACHW IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_WIFI_IRQ}")

        # Native Wi-Fi IPC PUB routing depends on the status2/mask/ack window
        # and the magic register value used by the firmware handshake.
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(WIFI_IPC_ACK, 0xFFFF_FFFF)
        m0_irq_qtest.writel(WIFI_IPC_UNMASK_SET, WIFI_IPC_MSG_BIT)
        m0_irq_qtest.qom_set("/machine", "wifi-ipc-status2-pending",
                             WIFI_IPC_MSG_BIT)
        check_equal("Wi-Fi IPC magic register",
                    m0_irq_qtest.readl(WIFI_IPC_MAGIC), WIFI_IPC_MAGIC_VALUE)
        check_equal("Wi-Fi IPC masked status2 pending",
                    m0_irq_qtest.readl(WIFI_IPC_STATUS2), WIFI_IPC_MSG_BIT)
        check_equal("Wi-Fi IPC status register stays guest-owned",
                    m0_irq_qtest.readl(WIFI_IPC_STATUS), 0x0)
        check_contains("M0 CLIC Wi-Fi IPC PUB IRQ",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ raise {M0_WIFI_IPC_PUB_IRQ}")
        m0_irq_qtest.writel(WIFI_IPC_ACK, WIFI_IPC_MSG_BIT)
        check_equal("Wi-Fi IPC status2 clear",
                    m0_irq_qtest.readl(WIFI_IPC_STATUS2), 0x0)
        check_contains("M0 CLIC Wi-Fi IPC PUB IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_WIFI_IPC_PUB_IRQ}")

        # HBN RTC wake should reset the machine while preserving the retained
        # HBN registers and reasserting HBN_OUT0 on the next boot.
        rtc_rsv0 = 0x11223344
        rtc_rsv1 = 0x55667788
        rtc_pad0 = HBN_PAD_ISO_MODE | (1 << (HBN_PAD_CTRL_SHIFT + 1))
        rtc_pad1 = (1 << (HBN_PAD_OE_SHIFT + 1)) | (1 << (HBN_PAD_PU_SHIFT + 1))
        rtc_alarm = hbn_read_rtc(m0_irq_qtest) + 0x8
        m0_irq_qtest.writel(PDS_CTL2, 0x00000000)
        m0_irq_qtest.writel(HBN_IRQ_MODE, 0x0)
        m0_irq_qtest.writel(HBN_IRQ_CLR, HBN_IRQ_RTC_STAT | HBN_IRQ_BOD_STAT)
        m0_irq_qtest.writel(HBN_RSV0, rtc_rsv0)
        m0_irq_qtest.writel(HBN_RSV1, rtc_rsv1)
        m0_irq_qtest.writel(HBN_PAD_CTRL_0, rtc_pad0)
        m0_irq_qtest.writel(HBN_PAD_CTRL_1, rtc_pad1)
        m0_irq_qtest.writel(HBN_TIML, rtc_alarm & 0xFFFF_FFFF)
        m0_irq_qtest.writel(HBN_TIMH, (rtc_alarm >> 32) & 0xFF)
        m0_irq_qtest.take_irq_events()
        m0_irq_qtest.writel(HBN_CTL, HBN_CTL_MODE)
        m0_irq_qtest.clock_step(300_000)
        rtc_events = m0_irq_qtest.take_irq_events()
        check_equal("HBN RTC reset restores PDS_CTL2",
                    m0_irq_qtest.readl(PDS_CTL2), PDS_MM_FORCE_MASK)
        check_equal("HBN RTC wake status retained",
                    m0_irq_qtest.readl(HBN_IRQ_STAT), HBN_IRQ_RTC_STAT)
        check_equal("HBN RTC retained RSV0",
                    m0_irq_qtest.readl(HBN_RSV0), rtc_rsv0)
        check_equal("HBN RTC retained RSV1",
                    m0_irq_qtest.readl(HBN_RSV1), rtc_rsv1)
        check_equal("HBN RTC retained PAD_CTRL0",
                    m0_irq_qtest.readl(HBN_PAD_CTRL_0), rtc_pad0)
        check_equal("HBN RTC retained PAD_CTRL1",
                    m0_irq_qtest.readl(HBN_PAD_CTRL_1), rtc_pad1)
        check_contains("M0 CLIC HBN OUT0 RTC IRQ",
                       rtc_events, f"IRQ raise {M0_HBN_OUT0_IRQ}")
        m0_irq_qtest.writel(HBN_IRQ_CLR, HBN_IRQ_RTC_STAT)
        check_equal("HBN RTC status clear",
                    m0_irq_qtest.readl(HBN_IRQ_STAT), 0x0)
        check_contains("M0 CLIC HBN OUT0 RTC IRQ clear",
                       m0_irq_qtest.take_irq_events(),
                       f"IRQ lower {M0_HBN_OUT0_IRQ}")
    finally:
        m0_irq_qtest.close()

    lp_irq_qtest = QTestSession(qemu_binary)
    try:
        lp_clic_path = sorted(
            lp_irq_qtest.find_qom_paths_by_type("csky_xt_clic")
        )[1]
        lp_irq_qtest.irq_intercept_in(lp_clic_path)
        lp_irq_qtest.take_irq_events()

        lp_irq_qtest.writel(IPC1_BASE + IPC_ACK, 0xFFFF_FFFF)
        lp_irq_qtest.writel(IPC1_BASE + IPC_IDIS, 0xFFFF_FFFF)
        lp_irq_qtest.writel(IPC1_BASE + IPC_IEN, 0x0002)
        lp_irq_qtest.writel(IPC1_BASE + IPC_TRI, 0x0002)
        check_equal("IPC1 LP raw status",
                    lp_irq_qtest.readl(IPC1_BASE + IPC_STS), 0x0002)
        check_equal("IPC1 LP masked status",
                    lp_irq_qtest.readl(IPC1_BASE + IPC_ISTS), 0x0002)
        check_contains("LP CLIC IPC1 IRQ", lp_irq_qtest.take_irq_events(),
                       f"IRQ raise {LP_IPC_IRQ}")
        lp_irq_qtest.writel(IPC1_BASE + IPC_ACK, 0x0002)
        check_equal("IPC1 LP clear",
                    lp_irq_qtest.readl(IPC1_BASE + IPC_STS), 0x0)
        check_contains("LP CLIC IPC1 IRQ clear",
                       lp_irq_qtest.take_irq_events(),
                       f"IRQ lower {LP_IPC_IRQ}")
    finally:
        lp_irq_qtest.close()

    # Synthetic boot flow should expose the convenience boot ROM jump while
    # still parking the secondary cores at their synthetic entry points.
    boot_qtest = QTestSession(qemu_binary)
    try:
        check_equal("Synthetic boot ROM flash jump",
                    boot_qtest.read(BOOTROM_BASE, 12),
                    synthetic_bootrom_jump(FLASH_XIP_BASE))
        check_equal("Synthetic boot ROM signature",
                    boot_qtest.read(BOOTROM_BASE + BOOTROM_SIZE - 16, 16),
                    b"BL808QEMUBOOT\0\0\0")
        boot_pcs = read_cpu_pcs(boot_qtest)
        check_equal("Default M0 reset PC", boot_pcs[0], BOOTROM_PC)
        check_equal("Default D0 parked PC", boot_pcs[1], FLASH_XIP_BASE)
        check_equal("Default LP synthetic PC", boot_pcs[2], LP_FLASH_XIP_BASE)
    finally:
        boot_qtest.close()

    with tempfile.TemporaryDirectory(prefix="bl808-boot-") as temp_dir:
        flash_path = Path(temp_dir) / "flash.bin"
        bootheader_flash_path = Path(temp_dir) / "flash-bootheader.bin"
        partition_flash_path = Path(temp_dir) / "flash-partition.bin"
        bootrom_path = Path(temp_dir) / "bootrom.bin"

        bootheader_flash = bytearray(b"\xFF" * (FLASH_OFFSET_LP + 0x30000))
        bootheader_flash[:352] = build_bl808_boot_header(
            group_image_offset=0x2000,
            power_on_mm=True,
            cpu_offsets=(0x00000, 0x04000, 0x20000),
            cpu_enable=(True, True, True),
            deadbeef_crc=True,
        )
        bootheader_flash[0x2000:0x2008] = b"BOOT2HDR"
        bootheader_flash[0x6000:0x6007] = b"D0XIP!!"
        bootheader_flash[0x22000:0x22006] = b"LPXIP!"
        bootheader_flash_path.write_bytes(bootheader_flash)

        bootheader_qtest = QTestSession(
            qemu_binary,
            machine=f"bl808,accel=qtest,flash-image={bootheader_flash_path}",
        )
        try:
            check_equal("Boot header remaps M0 XIP window",
                        bootheader_qtest.readl(SF_CTRL_ID0_OFFSET), 0x2000)
            check_equal("Boot header remaps D0 XIP window",
                        bootheader_qtest.readl(SF_CTRL_ID1_OFFSET), 0x2000)
            check_equal("Boot header exposes remapped M0 image",
                        bootheader_qtest.read(FLASH_XIP_BASE, 8), b"BOOT2HDR")
            check_equal("Boot header exposes remapped LP image",
                        bootheader_qtest.read(LP_FLASH_XIP_BASE, 6), b"LPXIP!")
            check_equal("Boot header powers on MM domain",
                        bootheader_qtest.readl(PDS_CTL2), 0x00000000)
            check_equal("Boot header seeds LP boot address",
                        bootheader_qtest.readl(PDS_CPU_CORE_CFG13),
                        LP_FLASH_XIP_BASE)
            bootheader_pcs = read_cpu_pcs(bootheader_qtest)
            check_equal("Boot header parks D0 at remapped image PC",
                        bootheader_pcs[1], FLASH_XIP_BASE + 0x4000)
        finally:
            bootheader_qtest.close()

        partition_flash = bytearray(b"\xFF" * 0x240000)
        partition_flash[:352] = build_bl808_boot_header(
            group_image_offset=0x2000,
            power_on_mm=False,
            cpu_offsets=(0x0000, 0x0000, 0x0000),
            cpu_enable=(True, False, False),
            deadbeef_crc=True,
        )
        partition_flash[0x2000:0x2008] = b"BOOT2BIN"
        partition_flash[PT_TABLE0_OFFSET:PT_TABLE0_OFFSET + PT_TABLE_SIZE] = (
            build_bflb_partition_table(
                age=1,
                entries=[
                    {
                        "name": "FW",
                        "type": 0,
                        "active_index": 0,
                        "start_address": (0x100000, 0x200000),
                        "max_len": (0x80000, 0x80000),
                        "len": 0x80000,
                    }
                ],
            )
        )
        partition_flash[PT_TABLE1_OFFSET:PT_TABLE1_OFFSET + PT_TABLE_SIZE] = (
            build_bflb_partition_table(
                age=2,
                entries=[
                    {
                        "name": "FW",
                        "type": 0,
                        "active_index": 1,
                        "start_address": (0x100000, 0x200000),
                        "max_len": (0x80000, 0x80000),
                        "len": 0x80000,
                    }
                ],
            )
        )
        partition_flash[0x100000:0x100000 + 352] = build_bl808_boot_header(
            group_image_offset=0x1000,
            power_on_mm=True,
            cpu_offsets=(0x0000, 0x04000, 0x20000),
            cpu_enable=(True, True, True),
            deadbeef_crc=True,
        )
        partition_flash[0x101000:0x101008] = b"OLDPART0"
        partition_flash[0x121000:0x121006] = b"OLDLP!"
        partition_flash[0x200000:0x200000 + 352] = build_bl808_boot_header(
            group_image_offset=0x1000,
            power_on_mm=True,
            cpu_offsets=(0x0000, 0x04000, 0x20000),
            cpu_enable=(True, True, True),
            deadbeef_crc=True,
        )
        partition_flash[0x201000:0x201008] = b"NEWPART1"
        partition_flash[0x221000:0x221006] = b"PTLP!!"
        partition_flash_path.write_bytes(partition_flash)

        partition_qtest = QTestSession(
            qemu_binary,
            machine=f"bl808,accel=qtest,flash-image={partition_flash_path}",
        )
        try:
            check_equal("Partition table remaps M0 XIP window",
                        partition_qtest.readl(SF_CTRL_ID0_OFFSET), 0x201000)
            check_equal("Partition table remaps D0 XIP window",
                        partition_qtest.readl(SF_CTRL_ID1_OFFSET), 0x201000)
            check_equal("Partition table selects active FW image",
                        partition_qtest.read(FLASH_XIP_BASE, 8), b"NEWPART1")
            check_equal("Partition table exposes active LP image",
                        partition_qtest.read(LP_FLASH_XIP_BASE, 6), b"PTLP!!")
            check_equal("Partition-selected firmware powers on MM domain",
                        partition_qtest.readl(PDS_CTL2), 0x00000000)
            check_equal("Partition-selected PT copy index in boot2 pass params",
                        partition_qtest.readl(BOOT2_PASS_PARAM_ADDR), 1)
            check_equal("Partition-selected FW entry prefix in boot2 pass params",
                        partition_qtest.read(BOOT2_PASS_PARAM_ADDR + 4, 20),
                        bytes(partition_flash[PT_TABLE1_OFFSET + 0x10:PT_TABLE1_OFFSET + 0x10 + 20]))
            partition_pcs = read_cpu_pcs(partition_qtest)
            check_equal("Partition-selected D0 parked PC",
                        partition_pcs[1], FLASH_XIP_BASE + 0x4000)
        finally:
            partition_qtest.close()

        partition_fallback_flash_path = Path(temp_dir) / "flash-partition-fallback.bin"
        partition_fallback_flash = bytearray(b"\xFF" * 0x240000)
        partition_fallback_flash[:352] = build_bl808_boot_header(
            group_image_offset=0x2000,
            power_on_mm=False,
            cpu_offsets=(0x0000, 0x0000, 0x0000),
            cpu_enable=(True, False, False),
            deadbeef_crc=True,
        )
        partition_fallback_flash[0x2000:0x2008] = b"BOOT2AB!"
        partition_fallback_flash[PT_TABLE0_OFFSET:PT_TABLE0_OFFSET + PT_TABLE_SIZE] = (
            build_bflb_partition_table(
                age=1,
                entries=[
                    {
                        "name": "FW",
                        "type": 0,
                        "active_index": 0,
                        "start_address": (0x100000, 0x200000),
                        "max_len": (0x80000, 0x80000),
                        "len": 0x80000,
                    }
                ],
            )
        )
        partition_fallback_flash[PT_TABLE1_OFFSET:PT_TABLE1_OFFSET + PT_TABLE_SIZE] = (
            build_bflb_partition_table(
                age=2,
                entries=[
                    {
                        "name": "FW",
                        "type": 0,
                        "active_index": 0,
                        "start_address": (0x100000, 0x200000),
                        "max_len": (0x80000, 0x80000),
                        "len": 0x80000,
                    }
                ],
            )
        )
        partition_fallback_flash[0x100000:0x100008] = b"BADHDR!!"
        partition_fallback_flash[0x200000:0x200000 + 352] = build_bl808_boot_header(
            group_image_offset=0x1000,
            power_on_mm=True,
            cpu_offsets=(0x0000, 0x04000, 0x20000),
            cpu_enable=(True, True, True),
            deadbeef_crc=True,
        )
        partition_fallback_flash[0x201000:0x201008] = b"ABFALLBK"
        partition_fallback_flash[0x221000:0x221006] = b"ABLP!!"
        partition_fallback_flash_path.write_bytes(partition_fallback_flash)

        partition_fallback_qtest = QTestSession(
            qemu_binary,
            machine=f"bl808,accel=qtest,flash-image={partition_fallback_flash_path}",
        )
        try:
            check_equal("Partition fallback remaps M0 XIP window",
                        partition_fallback_qtest.readl(SF_CTRL_ID0_OFFSET), 0x201000)
            check_equal("Partition fallback selects inactive FW image",
                        partition_fallback_qtest.read(FLASH_XIP_BASE, 8), b"ABFALLBK")
            check_equal("Partition fallback PT copy index in boot2 pass params",
                        partition_fallback_qtest.readl(BOOT2_PASS_PARAM_ADDR), 0)
            expected_fallback_prefix = bytearray(
                partition_fallback_flash[PT_TABLE1_OFFSET + 0x10:PT_TABLE1_OFFSET + 0x10 + 20]
            )
            expected_fallback_prefix[2] = 1
            check_equal("Partition fallback FW entry prefix in boot2 pass params",
                        partition_fallback_qtest.read(BOOT2_PASS_PARAM_ADDR + 4, 20),
                        bytes(expected_fallback_prefix))
        finally:
            partition_fallback_qtest.close()
        updated_fallback_flash = partition_fallback_flash_path.read_bytes()
        check_equal("Partition fallback rewrites alternate PT active index",
                    updated_fallback_flash[PT_TABLE0_OFFSET + 0x10 + 2:PT_TABLE0_OFFSET + 0x10 + 3],
                    b"\x01")
        check_equal("Partition fallback bumps alternate PT age",
                    struct.unpack_from("<I", updated_fallback_flash, PT_TABLE0_OFFSET + 0x08)[0],
                    3)

        flash_image = bytearray(b"\xFF" * (FLASH_OFFSET_D0_IMAGE + 0x100))
        flash_image[:8] = b"M0FLASH!"
        flash_image[FLASH_OFFSET_LP:FLASH_OFFSET_LP + 4] = b"LP42"
        flash_image[FLASH_OFFSET_D0_IMAGE:FLASH_OFFSET_D0_IMAGE + 8] = b"D0FLASH!"
        flash_path.write_bytes(flash_image)

        flash_qtest = QTestSession(
            qemu_binary,
            machine=f"bl808,accel=qtest,flash-image={flash_path}",
        )
        try:
            check_equal("Flash-backed M0 XIP slot",
                        flash_qtest.read(FLASH_XIP_BASE, 8), b"M0FLASH!")
            check_equal("Flash-backed LP XIP slot",
                        flash_qtest.read(LP_FLASH_XIP_BASE, 4), b"LP42")
            check_equal("Flash-backed D0 SF_CTRL image offset",
                        flash_qtest.readl(SF_CTRL_ID1_OFFSET),
                        FLASH_OFFSET_D0_IMAGE)
            check_equal("Flash-backed D0 is no longer DRAM-staged",
                        flash_qtest.read(DRAM_BASE, 8), bytes(8))
            flash_pcs = read_cpu_pcs(flash_qtest)
            check_equal("Flash-backed D0 parked at XIP",
                        flash_pcs[1], FLASH_XIP_BASE)
            flash_qtest.writel(SF_CTRL_ID1_OFFSET, FLASH_OFFSET_D0)
            check_equal("SF_CTRL group1 offset retarget readback",
                        flash_qtest.readl(SF_CTRL_ID1_OFFSET), FLASH_OFFSET_D0)
        finally:
            flash_qtest.close()

        download_qtest = QTestSession(
            qemu_binary,
            machine=(
                f"bl808,accel=qtest,flash-image={flash_path},"
                "boot-gpio39=on"
            ),
        )
        try:
            check_equal("Boot GPIO39 selects download stub",
                        download_qtest.read(BOOTROM_BASE, 8),
                        bytes.fromhex("6f00000073001000"))
            check_equal("Boot GPIO39 blocks synthetic D0 XIP setup",
                        download_qtest.readl(SF_CTRL_ID1_OFFSET), 0x0)
            download_pcs = read_cpu_pcs(download_qtest)
            check_equal("Boot GPIO39 leaves D0 at reset aperture",
                        download_pcs[1], MM_MISC_CPU0_BOOT_RESET)
        finally:
            download_qtest.close()

        bootrom_image = bytearray(b"Z" * BOOTROM_SIZE)
        bootrom_image[:16] = bytes.fromhex(
            "13000000130000001300000013000000"
        )
        bootrom_path.write_bytes(bootrom_image)
        d0_entry = DRAM_BASE + 0x100
        d0_elf_path = Path(temp_dir) / "d0.elf"
        d0_elf_path.write_bytes(
            synthetic_riscv64_elf(
                d0_entry,
                mmio_words_to_bytes([0x00000013] * 4),
            )
        )
        lp_entry = XRAM_BASE + 0x100
        lp_entry2 = XRAM_BASE + 0x200
        lp_elf_path = Path(temp_dir) / "lp.elf"
        lp_elf_path.write_bytes(
            synthetic_riscv32_elf(
                lp_entry,
                mmio_words_to_bytes([0x0000006F]),
            )
        )

        strict_qtest = QTestSession(
            qemu_binary,
            machine=(
                "bl808,accel=qtest,strict-fidelity=on,"
                f"flash-image={flash_path},bootrom-image={bootrom_path}"
            ),
        )
        try:
            check_equal("Strict fidelity external boot ROM load",
                        strict_qtest.read(BOOTROM_BASE, 16),
                        bytes(bootrom_image[:16]))
            check_equal("Strict fidelity boot ROM tail preserved",
                        strict_qtest.read(BOOTROM_BASE + BOOTROM_SIZE - 16, 16),
                        bytes(bootrom_image[-16:]))
            strict_pcs = read_cpu_pcs(strict_qtest)
            check_equal("Strict fidelity M0 reset PC",
                        strict_pcs[0], BOOTROM_PC)
            check_equal("Strict fidelity D0 parked PC",
                        strict_pcs[1], MM_MISC_CPU0_BOOT_RESET)
            check_equal("Strict fidelity LP reset PC",
                        strict_pcs[2], BOOTROM_PC)
        finally:
            strict_qtest.close()

        d0_release_qtest = QTestSession(
            qemu_binary,
            machine=f"bl808,accel=qtest,d0-firmware={d0_elf_path}",
        )
        try:
            d0_pcs = read_cpu_pcs(d0_release_qtest)
            check_equal("D0 firmware stays parked at reset address with MM off",
                        d0_pcs[1], d0_entry)
            mm_domain_set_power(d0_release_qtest, True)
            d0_pcs = read_cpu_pcs(d0_release_qtest)
            check_equal("D0 waits for MMCPU0 clock enable",
                        d0_pcs[1], d0_entry)
            d0_release_qtest.writel(
                MM_GLB_MM_CLK_CTRL_CPU,
                d0_release_qtest.readl(MM_GLB_MM_CLK_CTRL_CPU)
                | MM_GLB_CLK_CTRL_MMCPU0_EN,
            )
            d0_pcs = read_cpu_pcs(d0_release_qtest)
            check_equal("MMCPU0 clock enable releases D0",
                        d0_pcs[1], d0_entry)
            d0_release_qtest.writel(MM_GLB_MM_SW_SYS_RESET,
                                    MM_GLB_SW_SYS_RESET_MMCPU0)
            d0_pcs = read_cpu_pcs(d0_release_qtest)
            check_equal("MMCPU0 software reset parks D0",
                        d0_pcs[1], d0_entry)
            d0_release_qtest.writel(MM_GLB_MM_SW_SYS_RESET, 0x0)
            d0_pcs = read_cpu_pcs(d0_release_qtest)
            check_equal("MMCPU0 reset release re-enters D0 firmware",
                        d0_pcs[1], d0_entry)
        finally:
            d0_release_qtest.close()

        lp_release_qtest = QTestSession(
            qemu_binary,
            machine=f"bl808,accel=qtest,lp-firmware={lp_elf_path}",
        )
        try:
            lp_pcs = read_cpu_pcs(lp_release_qtest)
            check_equal("LP firmware stays parked with PICO clock off",
                        lp_pcs[2], lp_entry)
            lp_release_qtest.write(lp_entry2, mmio_words_to_bytes([0x0000006F]))
            lp_release_qtest.writel(PDS_CPU_CORE_CFG13, lp_entry2)
            lp_pcs = read_cpu_pcs(lp_release_qtest)
            check_equal("LP reset address retargets parked PC",
                        lp_pcs[2], lp_entry2)
            lp_release_qtest.writel(
                PDS_CPU_CORE_CFG0,
                lp_release_qtest.readl(PDS_CPU_CORE_CFG0) | PDS_PICO_CLK_EN,
            )
            lp_pcs = read_cpu_pcs(lp_release_qtest)
            check_equal("PICO clock enable releases LP",
                        lp_pcs[2], lp_entry2)
            lp_release_qtest.writel(GLB_SWRST_CFG2, GLB_SWRST_CFG2_PICO_RESET)
            lp_pcs = read_cpu_pcs(lp_release_qtest)
            check_equal("LP software reset parks core at reset address",
                        lp_pcs[2], lp_entry2)
            lp_release_qtest.writel(GLB_SWRST_CFG2, 0x0)
            lp_pcs = read_cpu_pcs(lp_release_qtest)
            check_equal("LP reset release re-enters reset address",
                        lp_pcs[2], lp_entry2)
        finally:
            lp_release_qtest.close()

    shortcut_qtest = QTestSession(
        qemu_binary,
        machine=(
            "bl808,accel=qtest,core-id-shortcut=on,"
            "attach-default-eeproms=on"
        ),
    )
    try:
        mtree = shortcut_qtest.hmp_command("info mtree")
        if "bl808.coreid" not in mtree:
            raise AssertionError("Shortcut machine should expose bl808.coreid")
        check_equal("Core ID shortcut", shortcut_qtest.readl(0xF0000000), 0xE9070000)
        check_equal(
            "I2C0 EEPROM write",
            i2c_write_reg(shortcut_qtest, I2C0_BASE, 0x50, 0x00, b"\xa5"),
            "ok",
        )
        read_status, read_back = i2c_read_reg(shortcut_qtest, I2C0_BASE, 0x50, 0x00, 1)
        check_equal("I2C0 EEPROM read", read_status, "ok")
        check_equal("I2C0 EEPROM data", read_back, b"\xa5")

        shortcut_qtest.writel(GLB_SYS_CFG0,
                              shortcut_qtest.readl(GLB_SYS_CFG0) &
                              ~GLB_SYS_CFG_BCLK_EN)
        try:
            i2c_write_reg(shortcut_qtest, I2C0_BASE, 0x50, 0x01, b"\x5a")
        except AssertionError as exc:
            check_equal("I2C0 PBCLK gate timeout",
                        str(exc), "I2C transfer timed out")
        else:
            raise AssertionError("I2C0 should stall when MCU BCLK_EN is cleared")
        shortcut_qtest.writel(GLB_SYS_CFG0,
                              shortcut_qtest.readl(GLB_SYS_CFG0) |
                              GLB_SYS_CFG_BCLK_EN)
        check_equal(
            "I2C0 PBCLK gate restore",
            i2c_write_reg(shortcut_qtest, I2C0_BASE, 0x50, 0x01, b"\x5a"),
            "ok",
        )
        read_status, read_back = i2c_read_reg(shortcut_qtest, I2C0_BASE, 0x50, 0x01, 1)
        check_equal("I2C0 PBCLK gate restore read", read_status, "ok")
        check_equal("I2C0 PBCLK gate restore data", read_back, b"\x5a")

    finally:
        shortcut_qtest.close()

    print("BL808 qtest validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
