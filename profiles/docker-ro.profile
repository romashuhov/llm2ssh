name        docker-ro
description Read-only Docker: ps, logs, stats, inspect, images, compose ls/ps/logs.
include     observer
# Docker access via sudo whitelist only — the docker group is NEVER used (== root).
# %DOCKER% resolves to the real docker binary at grant time (handles snap).
sudo        %DOCKER% ps
sudo        %DOCKER% ps *
sudo        %DOCKER% logs *
sudo        %DOCKER% stats *
sudo        %DOCKER% inspect *
sudo        %DOCKER% images
sudo        %DOCKER% images *
sudo        %DOCKER% version
sudo        %DOCKER% info
sudo        %DOCKER% top *
sudo        %DOCKER% port *
sudo        %DOCKER% diff *
sudo        %DOCKER% events *
sudo        %DOCKER% system df
sudo        %DOCKER% compose ls
sudo        %DOCKER% compose ps *
sudo        %DOCKER% compose logs *
warn        `docker inspect`/`logs` can expose secrets passed as env vars. Read-only is not secret-free.
