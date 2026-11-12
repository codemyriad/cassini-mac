// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the real allow-list and strict CLI parser without root or event posting.
#define CASSINI_KEY_POLICY_TEST
#include "keys.c"
#include <assert.h>

int main(void) {
    CGEventFlags command = kCGEventFlagMaskCommand, shift = kCGEventFlagMaskShift;
    assert(allowed_key(0x2B, command));
    assert(!allowed_key(0x2B, 0));
    assert(!allowed_key(0x2B, shift));
    assert(!allowed_key(0x2B, command | shift));
    unsigned long long prior[] = {0x25, 0x09, 0x24, 0x05};
    for (int i = 0; i < 4; i++) {
        assert(allowed_key(prior[i], 0));
        assert(allowed_key(prior[i], command));
        assert(allowed_key(prior[i], shift));
        assert(allowed_key(prior[i], command | shift));
        assert(!allowed_key(prior[i], kCGEventFlagMaskControl));
    }
    assert(!allowed_key(0x00, command));
    assert(!allowed_key(0x01, command));

    unsigned long long parsed = 99;
    assert(parse_u64("0", &parsed) && parsed == 0);
    assert(parse_u64("43", &parsed) && parsed == 0x2B);
    assert(parse_u64("1048576", &parsed) && parsed == 1048576ULL);
    const char *bad[] = {NULL, "", " ", " 37", "+37", "-1", "37xyz", "0x2B", "184467440737095516160"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        assert(!parse_u64(bad[i], &parsed));
    }
    puts("PASS Cmd-comma only, existing keys preserved, malformed CLI inputs rejected; no HID events posted");
    return 0;
}
