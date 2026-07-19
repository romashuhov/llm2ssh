name        full
description UNRESTRICTED ROOT. sudo ALL. Use with --ttl.
sudo-all    yes
warn        The agent can do ANYTHING as root — including disabling llm2ssh, editing sudoers, and wiping its own audit logs.
warn        TTL on `full` is best-effort: a root agent can stop the gc timer. Prefer --ttl WITH --kill-on-expiry, and keep sessions short.
