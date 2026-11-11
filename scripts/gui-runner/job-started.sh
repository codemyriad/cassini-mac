#!/bin/bash
set -euo pipefail
[[ $(id -u) == 503 && $(stat -f %u /dev/console) == 503 ]]
launchctl print gui/503 >/dev/null
/usr/bin/osascript -e 'set volume output muted true'
# One registered GUI listener owns this desktop. Do not add the headless label.
