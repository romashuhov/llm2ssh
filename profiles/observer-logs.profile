name        observer-logs
description Observer + read access to /var/log (adm) and the systemd journal.
include     observer
requestable yes
group       adm
group       systemd-journal
warn        Journals and /var/log routinely contain secrets, tokens, and other users' data. This profile exposes them read-only host-wide.
