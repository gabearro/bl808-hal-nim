from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_ram_anchor_drains_response_before_reboot():
    source = (ROOT / "tools" / "uart_flash_anchor.c").read_text()
    wait_body = source.split("static void uart_wait_tx_complete(void)", 1)[1].split(
        "static void delay_cycles", 1
    )[0]
    reboot_branch = source.split("if (reboot_after_response != 0u)", 1)[1].split(
        "reboot_chip();", 1
    )[0]

    assert "uart_tx_free() < UART_TX_FIFO_SIZE" in wait_body
    assert "UART_STATUS) & UART_TX_BUSY" in wait_body
    assert "uart_wait_tx_complete();" in reboot_branch
    assert "delay_cycles(100000000u)" not in reboot_branch


def test_nim_anchor_drains_response_before_reboot():
    source = (ROOT / "examples" / "m0_uart_flash_anchor.nim").read_text()
    reboot_branch = source.split("if rebootAfterResponse:", 1)[1].split(
        "rebootChip()", 1
    )[0]

    assert "console.txFifoEmpty()" in reboot_branch
    assert "console.txBusy()" in reboot_branch
    assert "delayCycles(100_000_000)" not in reboot_branch


def test_ram_anchor_verifies_each_byte_with_one_buffer_read_per_word():
    source = (ROOT / "tools" / "uart_flash_anchor.c").read_text()
    compare_body = source.split("static int flash_read_compare", 1)[1].split(
        "static int flash_program_verify", 1
    )[0]

    assert "i += 4u" in compare_body
    assert "read32(SF_CTRL_BUF + i)" in compare_body
    assert "j < bytes" in compare_body
    assert "got != expected[base + i + j]" in compare_body
