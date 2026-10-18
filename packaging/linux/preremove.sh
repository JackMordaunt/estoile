#!/bin/sh
# Before the files go: a removal (deb "remove", rpm's count of what stays,
# 0) stops and disables the recorder, which would otherwise point at a
# binary about to vanish. An upgrade leaves it running; postinstall
# restarts it.
set -e
case "$1" in
remove | 0)
    if [ -d /run/systemd/system ]; then
        systemctl disable --now leita-journal.service || true
    fi
    ;;
esac
