name        observer-hw
description observer + read-only hardware/SMART/DMI info (a few commands need root).
include     observer
# dmidecode with NO arguments = a full, read-only DMI/BIOS/memory dump. Pinning
# it to no-args is CRITICAL: `dmidecode --dump-bin FILE` would WRITE a file as
# root. In sudoers, "" means "exactly no arguments".
sudo        /usr/sbin/dmidecode ""
# `smartctl --scan` just enumerates devices. Per-disk SMART reads are NOT given a
# wildcard here, because a wildcard after -a/-H could smuggle a state-changing
# option (e.g. `-s on`, `-t`). Add exact per-device entries in a custom profile
# if you need them, e.g. `sudo /usr/sbin/smartctl -H /dev/sda`.
sudo        /usr/sbin/smartctl --scan
warn        `sensors`, `lspci`, `lsusb`, `lshw`, `iostat`, `htop`, `ss`, `dig` all work WITHOUT sudo — this profile only adds the few reads that require root.
warn        Requires the hardware tools to be installed: `llm2ssh tools install`.
