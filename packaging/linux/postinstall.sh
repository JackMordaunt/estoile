#!/bin/sh
# After install or upgrade, .deb and .rpm alike: systemd rereads the unit
# this package carries, and a recorder already running restarts on the new
# binary. Installing never enables the recorder; leita journal on does.
set -e
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
    systemctl try-restart leita-journal.service || true
fi
