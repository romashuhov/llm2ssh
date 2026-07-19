name        disk-audit
description Read-only disk/space diagnosis: du, docker system df, journal usage.
include     observer-logs
requestable yes
# du is granted ONLY via a root-owned wrapper: raw `sudo du *` is an arbitrary
# file-read-as-root primitive (du --files0-from leaks file contents). The wrapper
# forces an absolute dir + `--`, so only directory sizes come back.
sudo        /usr/local/lib/llm2ssh/bin/llm2ssh-du *
# docker disk usage (read-only). `system df *` matches only `df` variants, never
# `system prune`, since the 3rd arg must be `df`.
sudo        %DOCKER% system df
sudo        %DOCKER% system df *
sudo        %DOCKER% ps
sudo        %DOCKER% ps *
sudo        %DOCKER% images
sudo        %DOCKER% images *
warn        read-only audit: shows WHAT fills the disk (du/docker df/journal) but grants nothing to change it.
