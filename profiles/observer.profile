name        observer
description Read-only: hardware, processes, disk, network. No sudo, no extra groups.
# An unprivileged user can already run ps, top, free, df, ss, lscpu, lsblk,
# and `systemctl status <unit>` without any privilege. So observer grants
# NOTHING extra — that is the point, and it is the safest possible default.
warn        observer is a plain unprivileged user: it CAN read world-readable files (incl. harmless logs like dpkg.log) but NOT the sensitive root:adm logs (auth.log, syslog) or the systemd journal. For those, grant 'observer-logs'.
