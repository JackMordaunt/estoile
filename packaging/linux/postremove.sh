#!/bin/sh
# After the files have gone: systemd forgets the unit, and the recorder's
# logs, which no later recorder would trust, go too, as leita journal off
# removes them (deb "purge" or "remove", rpm's 0; an upgrade keeps them).
set -e
case "$1" in
remove | purge | 0)
    rm -rf /var/lib/leita/journal
    rmdir /var/lib/leita 2>/dev/null || true
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload || true
    fi
    ;;
esac
