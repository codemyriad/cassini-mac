// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the real allow-list without root or event posting.
#define CASSINI_KEY_POLICY_TEST
#include "keys.c"
#include <assert.h>
int main(void) {
    CGEventFlags command = kCGEventFlagMaskCommand, shift = kCGEventFlagMaskShift;
    assert(allowed_key(0x2B, command));
    assert(!allowed_key(0x2B, 0));
    assert(!allowed_key(0x2B, shift));
    assert(!allowed_key(0x2B, command | shift));
    unsigned long prior[] = {0x25, 0x09, 0x24, 0x05};
    for (int i = 0; i < 4; i++) {
        assert(allowed_key(prior[i], 0));
        assert(allowed_key(prior[i], command));
        assert(allowed_key(prior[i], shift));
        assert(allowed_key(prior[i], command | shift));
        assert(!allowed_key(prior[i], kCGEventFlagMaskControl));
    }
    assert(!allowed_key(0x00, command));
    assert(!allowed_key(0x01, command));
    puts("PASS Cmd-comma only, existing keys preserved, other inputs rejected; no HID events posted");
    return 0;
}
