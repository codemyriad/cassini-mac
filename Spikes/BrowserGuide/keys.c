// SPDX-License-Identifier: GPL-3.0-or-later
// Disposable hosted test-person keyboard. Never bundled with Cassini.
#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 3 || geteuid() != 0) return 64;
    unsigned long key = strtoul(argv[1], NULL, 10);
    if (key != 0x25 && key != 0x09 && key != 0x24 && key != 0x05) return 64;
    CGEventFlags flags = strtoull(argv[2], NULL, 10);
    if (flags & ~(kCGEventFlagMaskCommand | kCGEventFlagMaskShift)) return 64;
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
