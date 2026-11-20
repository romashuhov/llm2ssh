name        deploy
description Deploy owner-listed projects: update.sh, deploy-agent recreate, deploy state, git log, .env view/edit (each edit approved) — runs as the project owner, no shell.
include     docker-admin
requestable yes
ttl-required yes
# ONE root-owned wrapper, no raw commands: it reads the owner's targets from
# /etc/llm2ssh/deploy.d/<target>.conf and runs only the fixed actions described
# there, AS THE PROJECT OWNER (never root), inside the project dir, clean env,
# stdin </dev/null. The agent never gets a shell as the owner and never reads
# the project tree; .env secrets are masked, and every .env edit needs a fresh
# Allow in Telegram (fail-closed) with a root-only backup taken first.
sudo        /usr/local/lib/llm2ssh/bin/llm2ssh-deploy *
warn        deploy runs owner-defined scripts AS THE PROJECT OWNER (often in the docker group = root-equivalent). Grant it only with a short --ttl. Targets: sudo /usr/local/lib/llm2ssh/bin/llm2ssh-deploy list
