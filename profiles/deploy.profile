name        deploy
description Deploy owner-listed projects as their owner: update.sh and compose recreate (each approved with the commit range), deploy state, git log, .env view (masked) and edits (each approved). No shell, no docker logs/inspect.
include     observer
requestable yes
ttl-required yes
ttl-max     4h
# ONE root-owned wrapper, no raw commands: it reads the owner's targets from
# /etc/llm2ssh/deploy.d/<target>.conf and runs only the fixed actions described
# there, AS THE PROJECT OWNER (never root), in the project dir, clean env,
# stdin </dev/null. See docs/DEPLOY.md.
sudo        /usr/local/lib/llm2ssh/bin/llm2ssh-deploy *
# Enough docker to see whether a rollout came up — deliberately NOT inherited
# from docker-ro/docker-admin: `docker inspect`, `logs`, `top`, `diff`, `events`,
# `compose logs` and `start -a` show container env, output or files, i.e. the
# very secrets env-show masks. Need logs? Ask the owner for docker-ro separately.
sudo        %DOCKER% ps
sudo        %DOCKER% ps *
sudo        %DOCKER% images
sudo        %DOCKER% stats --no-stream
sudo        %DOCKER% system df
warn        deploy runs repository code AS THE PROJECT OWNER (often in the docker group = root-equivalent); the agent may have pushed that code itself. Each update/compose shows the owner the commit range first. Time-limited (max 4h). Targets: sudo /usr/local/lib/llm2ssh/bin/llm2ssh-deploy list
