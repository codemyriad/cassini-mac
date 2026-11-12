// SPDX-License-Identifier: GPL-3.0-or-later
// Disposable hosted test-person keyboard. Never bundled with Cassini.
#include <ApplicationServices/ApplicationServices.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int parse_u64(const char *raw, unsigned long long *out) {
    if (!raw || raw[0] < '0' || raw[0] > '9') return 0;
    for (const char *p = raw; *p; ++p) {
        if (*p < '0' || *p > '9') return 0;
    }
    errno = 0;
    char *end = NULL;
    unsigned long long value = strtoull(raw, &end, 10);
    if (errno != 0 || !end || *end != '\0') return 0;
    *out = value;
    return 1;
}

static int allowed_key(unsigned long long key, CGEventFlags flags) {
    if (flags & ~(kCGEventFlagMaskCommand | kCGEventFlagMaskShift)) return 0;
    if (key == 0x2B) return flags == kCGEventFlagMaskCommand;
    return key == 0x25 || key == 0x09 || key == 0x24 || key == 0x05;
}

#ifndef CASSINI_KEY_POLICY_TEST
int main(int argc, char **argv) {
    if (argc != 3 || geteuid() != 0) return 64;
    unsigned long long key = 0, raw_flags = 0;
    if (!parse_u64(argv[1], &key) || !parse_u64(argv[2], &raw_flags)) return 64;
    CGEventFlags flags = (CGEventFlags)raw_flags;
    if ((unsigned long long)flags != raw_flags || !allowed_key(key, flags)) return 64;
    fprintf(stderr, "Hosted keyboard post access: %d\n", CGPreflightPostEventAccess());
    for (int down = 1; down >= 0; --down) {
        CGEventRef event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key, down);
        if (!event) return 70;
        CGEventSetFlags(event, flags);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        usleep(25000);
    }
    return 0;
}
#endif
