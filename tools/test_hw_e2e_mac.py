"""Tests for tools/hw_e2e_mac.py."""
from __future__ import annotations

import subprocess
from unittest.mock import patch

from hw_e2e_mac import wifi_passive_check, MacAdapterResult


def test_wifi_passive_check_returns_ok_on_zero_exit():
    fake = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
    with patch("hw_e2e_mac.subprocess.run", return_value=fake) as mock_run:
        r = wifi_passive_check(target_host="192.168.1.1", count=2, timeout_s=2)
        assert isinstance(r, MacAdapterResult)
        assert r.ok is True
        assert r.detail == ""
        # Confirm we actually called ping with -c 2 -W <timeout> <host>.
        cmd = mock_run.call_args.args[0]
        assert cmd[0] == "ping"
        assert "-c" in cmd and "2" in cmd
        assert "192.168.1.1" in cmd


def test_wifi_passive_check_returns_fail_on_nonzero_exit():
    fake = subprocess.CompletedProcess(
        args=[], returncode=2, stdout="", stderr="cannot resolve")
    with patch("hw_e2e_mac.subprocess.run", return_value=fake):
        r = wifi_passive_check(target_host="bogus.local", count=1, timeout_s=1)
        assert r.ok is False
        assert "cannot resolve" in r.detail or "exit=2" in r.detail


def test_wifi_passive_check_returns_fail_on_timeout():
    def boom(*args, **kwargs):
        raise subprocess.TimeoutExpired(cmd=args[0], timeout=1.0)
    with patch("hw_e2e_mac.subprocess.run", side_effect=boom):
        r = wifi_passive_check(target_host="192.168.1.1", count=1, timeout_s=1)
        assert r.ok is False
        assert "timeout" in r.detail.lower()
