name        services
description Start/stop/restart/reload a fixed allowlist of systemd units.
include     observer
needs-services yes
# sudo goes ONLY to the root-owned wrapper, which enforces the per-agent unit
# allowlist (/var/lib/llm2ssh/agents/<agent>/services.allow) and verb whitelist.
# Raw `sudo systemctl` is on the denylist (pager escape + broad power).
sudo        /usr/local/lib/llm2ssh/bin/llm2ssh-svc *
warn        Dangerous verbs (e.g. restart) additionally require owner approval via the broker when the bot or a local approver is running.
