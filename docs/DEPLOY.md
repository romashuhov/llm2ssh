# llm2ssh — the `deploy` profile

Lets an agent **ship** projects that belong to another user (e.g. `update.sh` in
`/home/owner/app`) without a shell as that user, without access to the rest of
that user's home, and without seeing `.env` values the owner did not mark public.

## Trust boundary — read this first

`deploy` does **not** make deploying safe from the agent. `update` and `compose`
run whatever the repository holds after the pull, as the project owner — who is
usually in the `docker` group, i.e. root-equivalent. An agent that can push to the
repository can therefore get its own code executed by deploying it. The controls are:

- **The owner approves every `update` and `compose`** (default `confirm update compose`)
  and the Telegram card shows exactly what will run: `HEAD abc1234 → origin/main
  def5678, N new commit(s): <hash subject> · …` for `update`, the HEAD being built
  and the number of locally modified files for `compose`. Review the range before Allow.
- The grant is short: `ttl-required` + `ttl-max 4h` (no "Forever"; `grant` without
  `--ttl` or longer than 4h is refused; the wrapper re-checks the expiry itself).
- The agent cannot change *what the owner's processes load from disk on the server*:
  the wrapper refuses to run if the agent could write anything in the project, the
  owner's home (`~/.gitconfig`, `~/.ssh`, `~/.docker`, `~/.bun`, rc files…), extra
  PATH dirs, or their parents.

## Model

- The agent asks: `llm2ssh-request deploy --reason "ship pratimo"`. The owner gets a
  card with **1h / 4h / Deny**.
- The grant adds to `observer` ONE wrapper rule —
  `sudo /usr/local/lib/llm2ssh/bin/llm2ssh-deploy *` — plus read-only
  `docker ps`, `docker images`, `docker stats --no-stream`, `docker system df`.
  It deliberately does **not** include `docker-ro`/`docker-admin`: `inspect`, `logs`,
  `top`, `diff`, `events`, `compose logs`, `start -a` expose container env, output
  or files — the very secrets `env-show` masks. If logs are needed, the owner grants
  `docker-ro` separately (it replaces `deploy`).
- `llm2ssh-deploy` is root-owned. It reads targets from
  `/etc/llm2ssh/deploy.d/<target>.conf` (root-owned, **parsed, never sourced**) and
  runs a fixed set of actions **as the project owner** (`run-as`, never root), in the
  project dir, `env -i`, `LC_ALL=C` in the wrapper, stdin from `/dev/null`, timeout.
  No verb takes a command, a path or a compose file from the agent.

## Verbs (`sudo /usr/local/lib/llm2ssh/bin/llm2ssh-deploy <verb> …`)

| Verb | What runs (as `run-as`, in `dir`) |
|---|---|
| `list` | targets and what each allows |
| `update <t>` | owner Allow (card: commit range) → `bash ./<update-script> </dev/null`, **detached** |
| `compose <t> <name>` | owner Allow (card: HEAD + local changes) → `docker compose [--env-file <env-file>] -f <file> up -d --build --force-recreate` with the `compose-env` variables, **detached** |
| `status <t>` | last update/compose run: running / finished + exit code, last 60 log lines |
| `query <t> <name>` | the configured SQL via `docker exec -i <ctr> psql`, session forced **read-only** |
| `git-log <t>` / `git-status <t>` | `git log -1 --stat` / `git status --short --branch --untracked-files=no` |
| `restart-policy <t> <ctr> <policy>` | `docker update --restart <policy> <ctr>` — listed containers only |
| `env-show <t>` | every `NAME=value` with line numbers; **every value masked** (last 4 chars, nothing for short ones) **except `env-public` names**; URL passwords masked even for public names |
| `env-set <t> <NAME> <VALUE> [--line N] [--add]` | owner Allow on `line N: NAME: <old, masked unless public> → <new, in full>` → root-only backup → atomic one-line replace |

**Detached runs.** `update`/`compose` start in their own session (`setsid`), so an SSH
drop does not kill a deploy half-way. Output goes to
`/var/log/llm2ssh/deploy/<t>/<time>-<verb>.log` (root 0700, newest 30 kept); the caller
follows it live and gets the job's exit code; after a disconnect, `status <t>` shows it.
The per-target lock is held by the runner until the job ends and is never inherited by
the owner's processes.

Exit codes: `0` ok · `2` usage · `3` refused/denied · `4` not found · otherwise the
action's own exit code.

## `.env` editing rules

- Only names listed in `env-edit` (explicit names — no wildcard).
- Never, even if listed (checked on the upper-cased name): `PATH HOME SHELL ENV BASH_ENV
  IFS PS* PROMPT_COMMAND TMPDIR EDITOR PAGER LOCPATH NLSPATH GCONV_PATH HOSTALIASES
  RESOLV_* GLIBC_TUNABLES MALLOC_* LD_* DYLD_* XDG_* *_PROXY NODE_* NPM_CONFIG_* YARN_*
  PNPM_* BUN_* DENO_* COREPACK_* JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS
  CLASSPATH PYTHON* PIP_* PERL* RUBY* GEM_* BUNDLE_* DOCKER_* COMPOSE_* BUILDKIT_*
  BUILDX_* GIT_* SSH_* GPG_* SSL_CERT_* CURL_CA_BUNDLE REQUESTS_CA_BUNDLE OPENSSL_*
  KUBECONFIG AWS_CONFIG_FILE PG* SUDO_* LLM2SSH_*` and a few more (see the wrapper).
- Values: one token of `A-Z a-z 0-9 _ . , : / @ + = % -`, at most 512 chars — no
  spaces, quotes, `$`, `\`, `#`, `;`, `|`, newlines.
- A missing variable is appended only with `--add`; `--line N` asserts the line.
- No "already has this value" shortcut — that would let the agent confirm a guessed
  secret. The owner always sees the new value in full (the agent chose it anyway).
- The file must not change while the owner decides (sha256). Backups:
  `/var/lib/llm2ssh/deploy/<t>/env-backups/` (root 0600, newest 30 kept).
- Running containers see a new value only after a restart/redeploy.

## Approval cards

Cards for requests written by a root wrapper are labelled `🔒 llm2ssh-deploy (agent X)`.
The requester shown is always derived from the **request file owner**: only root-owned
requests may name the agent in the json, and only they get the 🔒 label — an agent's own
request (e.g. from the Claude hook) is shown as `🛑 Approval needed (agent X)` whatever
its json says. Control characters are stripped, so a commit subject or value cannot
fake extra lines.

## Config reference

```
run-as        <user>                    # required; not root, not the agent
dir           /abs/path                 # required, owned by run-as
update-script update.sh                 # default update.sh
env-file      .env                      # enables env-show / env-set
timeout       3600                      # seconds per action
path-prepend  /home/<user>/.bun/bin     # extra PATH dir (owned by root/run-as, closed to the agent)
confirm       update compose            # default; `confirm none` to disable, `all` for every verb
compose       <name> <relative file>
compose-env   <VAR> <value|%DIR_UID%|%DIR_GID%|%DOCKER_GID%>
query         <name> <container> <db user> <db> <SQL to end of line>
container     <name...>                 # for restart-policy
env-edit      <NAME...>                 # names the agent may PROPOSE to change
env-public    <NAME...>                 # the only names env-show reveals
allow-agent   <agent...>                # default: any agent holding `deploy`
```

Examples: [`examples/deploy.d/pratimo.conf`](../examples/deploy.d/pratimo.conf),
[`examples/deploy.d/csbro.conf`](../examples/deploy.d/csbro.conf) (installed to
`/usr/local/lib/llm2ssh/examples/deploy.d/`).

## Setup on a server

```bash
sudo llm2ssh update                                   # or: git pull && sudo ./install.sh
sudo install -m 0644 -o root -g root /usr/local/lib/llm2ssh/examples/deploy.d/pratimo.conf /etc/llm2ssh/deploy.d/
sudo install -m 0644 -o root -g root /usr/local/lib/llm2ssh/examples/deploy.d/csbro.conf   /etc/llm2ssh/deploy.d/
sudoedit /etc/llm2ssh/deploy.d/pratimo.conf           # run-as / dir / query / env-edit / env-public
sudo llm2ssh profile show deploy
```

The owner's git must work non-interactively from a clean environment (no ssh-agent):
a passphrase-less key in `~/.ssh` or a token in the origin URL.
