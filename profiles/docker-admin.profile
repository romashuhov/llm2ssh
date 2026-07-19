name        docker-admin
description docker-ro + container lifecycle (start/stop/restart/pull/rm/prune).
include     docker-ro
requestable yes
sudo        %DOCKER% start *
sudo        %DOCKER% stop *
sudo        %DOCKER% restart *
sudo        %DOCKER% kill *
sudo        %DOCKER% pause *
sudo        %DOCKER% unpause *
sudo        %DOCKER% pull *
sudo        %DOCKER% rm *
sudo        %DOCKER% image prune -f
sudo        %DOCKER% container prune -f
sudo        %DOCKER% system prune -f
sudo        %DOCKER% compose restart *
sudo        %DOCKER% compose down
sudo        %DOCKER% compose stop *
sudo        %DOCKER% compose pull
# DELIBERATELY EXCLUDED (each is root-equivalent — they belong to `full`):
#   run, exec, cp, commit, build, load, save, create, and `compose up`/`create`.
#   e.g. `docker run -v /:/host ...` or a compose file with volumes ['/:/host']
#   is full host root. docker-admin manages EXISTING containers, it does not
#   create new ones from agent-controlled definitions.
warn        docker-admin excludes run/exec/cp/build/compose-up (all root-equivalent). Need those? That is the `full` profile.
