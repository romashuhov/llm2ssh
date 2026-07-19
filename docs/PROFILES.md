# llm2ssh — Permission Profiles

A **profile** is a declarative description of what an agent may do. Switching an
agent between profiles (`llm2ssh grant <agent> <profile>`) is the core operation.

## Shipped presets

| Profile | Grants | Notes |
|---|---|---|
| `observer` | **nothing extra** — a normal unprivileged shell | Can already read `/proc`, run `ps`, `df`, `free`, `ss`, `lscpu`, `systemctl status`. The safest default. |
| `observer-logs` | `observer` + groups `adm`, `systemd-journal` | Reads `/var/log` and the journal — **which contain secrets**. Opt-in. |
| `observer-hw` | `observer` + root-only hardware reads (`dmidecode` no-args, `smartctl --scan`) | For SMART/DMI info. Most hardware tools (`sensors`, `lspci`, `lshw`, `iostat`) need no sudo. |
| `docker-ro` | `sudo docker ps/logs/stats/inspect/images/...` (read-only) | Via sudo whitelist; the `docker` group is never used. `inspect`/`logs` can leak env secrets. |
| `docker-admin` | `docker-ro` + `start/stop/restart/pull/rm/prune/...` | **Excludes** `run/exec/cp/build/compose up` — each is root-equivalent. |
| `services` | restart/reload a fixed allowlist of systemd units | `llm2ssh grant a services --services nginx,redis`. Goes through a gated wrapper. |
| `full` | `sudo ALL` — unrestricted root | Requires typed confirmation. Use `--ttl ... --kill-on-expiry`. |

Preview any profile with `llm2ssh profile show <name>`.

## File format

Profiles are line-oriented and **parsed, never executed** (sourcing an untrusted
shared profile would be arbitrary code execution as root). One directive per
line; blank lines and `#` comments are ignored. Custom profiles live in
`/etc/llm2ssh/profiles.d/<name>.profile` and shadow shipped presets of the same
name.

| Directive | Meaning |
|---|---|
| `name <str>` | Profile name (top-level only; not inherited via `include`). |
| `description <str>` | One-line description. |
| `include <profile>` | Merge another profile's groups/sudo/warn/ask. Cycles and duplicates are handled; a profile is merged at most once. |
| `group <grp>` | Supplementary group to add to the agent (e.g. `adm`). |
| `sudo <Cmnd spec>` | A sudoers command the agent may run as root, NOPASSWD. Use the `%DOCKER%` token for the docker binary (resolved at grant time, snap-aware). |
| `ask <pattern>` | A Bash-command glob that requires owner approval (via the broker) in Mode B before Claude runs it. |
| `needs-services yes` | Profile requires `--services <unit,...>` at grant time. |
| `warn <text>` | Printed at grant time and shown in the agent's context. |
| `sudo-all yes` | Grants unrestricted root (`full`). Mutually exclusive with `sudo` lines. |

An unknown directive is a hard error (typo safety).

### `sudo` line validation (enforced)

Every `sudo` line is validated before it can be activated. A line is **rejected**
if it:

- does not start with an absolute path;
- contains a sudoers metacharacter — `,` `:` `=` `\` `(` `)` or a newline (a
  comma would smuggle a second command into the alias);
- names a binary that does not exist; or
- names a binary on the shell-escape/pager **denylist** (`bash`, `sh`, `env`,
  `find`, `less`, `vi`, `tar`, `awk`, `sed`, `python*`, `systemctl`,
  `journalctl`, `curl`, `wget`, … — anything that yields a root shell or reads
  arbitrary files as root). Extend the denylist via `LLM2SSH_EXTRA_DENYLIST` in
  `/etc/llm2ssh/config`; a profile cannot override it.

The generated `/etc/sudoers.d/llm2ssh-<agent>` is always checked with
`visudo -cf` on a temporary (inactive) file before an atomic activation, and the
previous version is kept for rollback.

## Example custom profile

```
# /etc/llm2ssh/profiles.d/web.profile
name        web
description Manage the web stack; approve restarts.
include     docker-ro
sudo        %DOCKER% restart web
sudo        %DOCKER% restart api
ask         sudo docker restart *
warn        Restarts require owner approval via Telegram.
```

```
sudo llm2ssh grant myagent web --ttl 8h
```

## Monitoring tools

So the `observer` profile is actually useful on a bare server, `install.sh`
installs a curated set of monitoring/utility packages at init (htop, sysstat →
`iostat`/`pidstat`, lsof, ncdu, lm-sensors, pciutils/usbutils, lshw,
smartmontools, dmidecode, bind9-dnsutils, tree…). Most work **without sudo**.

- `llm2ssh tools list` — show the set and what's installed.
- `llm2ssh tools install [pkg…]` — (re)install the set plus any extras.
- Override the list with `LLM2SSH_TOOLS="…"` in `/etc/llm2ssh/config`, or skip
  entirely with `install.sh --no-tools`.

A few tools (`smartctl`, `dmidecode`, `nvme`) need root to read a device — the
`observer-hw` profile grants the safe, read-only forms.

## How profiles reach the agent

- **OS enforcement**: the generated sudoers file (the hard wall).
- **Mode A / Mode B guidance**: `llm2ssh-ctx` prints the agent's live context
  (allowed commands, warnings, freeze status), regenerated on every change.
- **Claude Code (Mode B)**: `profile-compile` derives the gate policy and
  advisory allow/deny lists from the *same* `sudo`/`ask` directives, so the OS
  layer and the Claude layer cannot drift.
