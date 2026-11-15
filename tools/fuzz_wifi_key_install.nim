## Exhaustive checks for the VIF key-install classification helpers.
## Production lifecycle coverage lives in test_wifi_vif_keys.py.

import ../src/bl808/wifi/fw/key_install_policy

var cases = 0
for cipher in 0'u16 .. 255'u16:
  doAssert wifiCipherIsBip(cipher.uint8) == (cipher == 5)
  for pairwise in 0'u16 .. 255'u16:
    let direct = pairwise == 0 or cipher == 5
    doAssert wifiKeyUsesDirectReplayPn(cipher.uint8, pairwise.uint8) == direct
    inc cases

echo "fuzz_wifi_key_install: ", cases, " classification cases"
echo "PASS"
