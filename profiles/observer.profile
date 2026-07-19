name        observer
description Read-only: hardware, processes, disk, network. No sudo, no extra groups.
# An unprivileged user can already run ps, top, free, df, ss, lscpu, lsblk,
# and `systemctl status <unit>` without any privilege. So observer grants
# NOTHING extra — that is the point, and it is the safest possible default.
warn        observer cannot read /var/log or the journal (those hold secrets). Use 'observer-logs' if the agent needs them.
