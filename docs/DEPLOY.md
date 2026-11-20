# llm2ssh — the `deploy` profile

Lets an agent **ship** projects that belong to another user (e.g. `update.sh` in
`/home/owner/app`) without giving it a shell as that user, read access to the
project tree, or sight of the secrets in `.env`.

## Model

- The agent asks: `llm2ssh-request deploy --reason "ship pratimo"`. The owner gets a
  Telegram card with **1h / 4h / 1d / Deny** — `deploy` is `ttl-required`, so there
  is no "Forever" button and `llm2ssh grant <agent> deploy` without `--ttl` is refused.
- The grant adds ONE sudo rule (on top of `docker-admin`):
  `sudo /usr/local/lib/llm2ssh/bin/llm2ssh-deploy *`.
- `llm2ssh-deploy` is a root-owned wrapper. It reads targets from
  `/etc/llm2ssh/deploy.d/<target>.conf` (root-owned, **parsed, never sourced**) and
  runs a fixed set of actions **as the project owner** (`run-as`, never root),
  in the project dir, with `env -i`, stdin from `/dev/null`, and a timeout.
- There is no verb that takes a command, a path, or a compose file from the agent.

## Verbs

| Verb | What runs (as `run-as`, in `dir`) |
|---|---|
| `list` | targets and what each allows |
| `update <t>` | `bash ./<update-script> </dev/null` |
| `compose <t> <name>` | `docker compose [--env-file <env-file>] -f <file> up -d --build --force-recreate`, with the `compose-env` variables set |
| `query <t> <name>` | the configured SQL via `docker exec -i <ctr> psql`, session forced **read-only** (`default_transaction_read_only=on`) |
| `git-log <t>` / `git-status <t>` | `git log -1 --stat` / `git status --short --branch --untracked-files=no` |
| `restart-policy <t> <ctr> <policy>` | `docker update --restart <policy> <ctr>` — only for listed containers, policy ∈ `no|always|unless-stopped|on-failure[:N]` |
| `env-show <t>` | every `NAME=value` with line numbers; secrets masked to the last 4 chars (short ones fully) and URL passwords masked |
| `env-set <t> <NAME> <VALUE> [--line N]` | proposes ONE line change; the owner gets `line N: NAME: old → new` (secrets masked) in Telegram; only on **Allow** is a root-only backup taken and the line replaced atomically |

Exit codes: `0` ok · `2` usage · `3` refused/denied · `4` not found · otherwise the
action's own exit code.

## Guards

- Calling agent comes from `SUDO_USER`; a frozen agent is refused.
- Config file and `deploy.d/` must be root-owned and not group/other-writable.
- `run-as` must exist, must not be root, must not be the agent; `dir` must be owned
  by `run-as`.
- **Closed tree:** before running anything the wrapper checks, *as the agent*
  (`setpriv`, so groups and ACLs count), that the agent cannot write the project
  dir, any of its parents, the update script, `.git`, the compose file or `.env`.
  If it could plant code, running it as the owner would be an escalation — refused.
- One action per target at a time (`flock`).
- `.env` edits: always need a fresh owner Allow — **fail-closed** (no bot, timeout,
  deny → nothing changes). Names matching `PATH|HOME|SHELL|ENV|BASH_ENV|IFS|LD_*|
  DOCKER_*|COMPOSE_*|BUILDKIT_*|GIT_*|SSH_*|NODE_OPTIONS|PYTHON*|PERL*|RUBY*` can
  never be changed. Values may not contain newlines, `$`, backticks, `\`, quotes or
  ` #`; max 1024 chars. A double-quoted old value keeps its quotes. The file must
  not change while the owner decides (sha256 check). Backups:
  `/var/lib/llm2ssh/deploy/<t>/env-backups/` (root 0600, newest 30 kept).
- Secret detection: names containing `KEY TOKEN SECRET PASS PWD PRIVATE CREDENTIAL
  AUTH COOKIE SALT SIGNATURE SESSION DSN WEBHOOK LOGIN`, values that look like keys
  (32+ chars of base64/hex alphabet), plus `env-secret` names; `env-public` overrides.
- Every action is logged to syslog (`llm2ssh` tag, `auth` facility) with its exit code.

## Config reference

```
run-as        <user>                    # required
dir           /abs/path                 # required, owned by run-as
update-script update.sh                 # default update.sh
env-file      .env                      # enables env-show / env-set
timeout       3600                      # seconds per action
compose       <name> <relative file>    # repeatable
compose-env   <VAR> <value|%DIR_UID%|%DIR_GID%|%DOCKER_GID%>
query         <name> <container> <db user> <db> <SQL to end of line>
container     <name...>                 # for restart-policy
env-edit      <NAME...> | *             # names the agent may PROPOSE to change
env-secret    <NAME...>                 # always mask
env-public    <NAME...>                 # never mask
confirm       <verb...> | all           # also ask the owner before these verbs
allow-agent   <agent...>                # default: any agent holding `deploy`
```

Examples: [`examples/deploy.d/pratimo.conf`](../examples/deploy.d/pratimo.conf),
[`examples/deploy.d/csbro.conf`](../examples/deploy.d/csbro.conf) (installed to
`/usr/local/lib/llm2ssh/examples/deploy.d/`).

## Setup on a server

```bash
sudo llm2ssh update                                   # or: git pull && sudo ./install.sh
sudo install -m 0644 /usr/local/lib/llm2ssh/examples/deploy.d/pratimo.conf /etc/llm2ssh/deploy.d/
sudo install -m 0644 /usr/local/lib/llm2ssh/examples/deploy.d/csbro.conf   /etc/llm2ssh/deploy.d/
sudoedit /etc/llm2ssh/deploy.d/pratimo.conf           # check run-as / dir / query
sudo llm2ssh profile show deploy
sudo -u agent sudo -n /usr/local/lib/llm2ssh/bin/llm2ssh-deploy list   # after a grant
```

## What it does NOT protect against

`run-as` usually belongs to the `docker` group, so whatever the project's own
`update.sh` / compose file does runs with that power. The wrapper guarantees the
agent can only *trigger* what the owner already wrote and committed — it cannot
change it. Keep the grant short (`--ttl 1h`) and keep the project tree closed to
the agent.
