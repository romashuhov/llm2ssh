# llm2ssh — Shared Contracts (single source of truth)

Every component obeys this document. If code and this file disagree, the code is
wrong. Changing a contract here is a deliberate, reviewed act — not a side effect
of an implementation tweak. (Rationale: three independent designs originally
diverged at exactly these seams; freezing them here is what keeps the parts
composable.)

## Threat model

The adversary is an **over-eager or prompt-injected LLM agent**, not a human
attacker with a root shell. Therefore:

- The enforcement boundary is **the kernel + sudo + root-owned file permissions**.
- Anything under `/home/<agent>` (rc files, `~/.claude/settings.json`, hooks the
  agent can edit) is **UX guidance, never security**.
- The `docker` group is **never** used — membership equals root. All docker
  access is sudoers whitelists of exact subcommands.
- Every privileged and every *denied* action is logged to root-owned, agent-
  unreadable logs.

## Agent model

- **Per-agent.** Multiple agents may coexist. All are members of the system
  group `llm2ssh`. A single sshd `Match Group llm2ssh` block covers them all.
- Agent names match `^[a-z_][a-z0-9_-]{0,31}$` (see `valid_agent_name`).
- Permission changes are per-agent: `llm2ssh grant <agent> <profile>` /
  `llm2ssh revoke <agent>` (never a global `use`).

## Canonical paths

| Path | Owner:mode | Meaning |
|---|---|---|
| `/usr/local/bin/llm2ssh` | root 0755 | CLI entrypoint |
| `/usr/local/lib/llm2ssh/` | root 0755 | code (lib, profiles, wrappers, hooks, bot); upgraded in place |
| `/usr/local/lib/llm2ssh/bin/llm2ssh-svc` | root 0755 | sudo-whitelisted systemctl wrapper |
| `/usr/local/bin/llm2ssh-approve` | root 0755 | approval spool client (agents may call) |
| `/usr/local/bin/llm2ssh-ctx` | root 0755 | prints the agent's live context |
| `/etc/llm2ssh/config` | root 0600 | global config (may hold TG token) |
| `/etc/llm2ssh/keys/<agent>` | root 0644 | authorized_keys (root-owned!) |
| `/etc/llm2ssh/profiles.d/*.profile` | root 0644 | custom profiles (never upgraded) |
| `/etc/sudoers.d/llm2ssh-<agent>` | root 0440 | generated grants (name has NO dot) |
| `/etc/ssh/sshd_config.d/60-llm2ssh.conf` | root 0644 | Match Group hardening |
| `/etc/audit/rules.d/llm2ssh-<agent>.rules` | root 0640 | per-agent execve audit |
| `/etc/claude-code/managed-settings.json` | root 0644 | enforced Claude policy + hook |
| `/var/lib/llm2ssh/agents/<agent>/state` | root 0600 | key=value agent state |
| `/var/lib/llm2ssh/agents/<agent>/services.allow` | root 0644 | unit allowlist (services) |
| `/var/lib/llm2ssh/agents/<agent>/sudoers.prev` | root 0440 | last good sudoers (rollback) |
| `/var/log/llm2ssh/` | root 0700 | sudo log, audit cache, decisions |
| `/run/llm2ssh/agents/<agent>.frozen` | root 0644 | **freeze flag** (world-readable) |
| `/home/<agent>/workspace/` | agent 0750 | Mode B project dir |

**AuthorizedKeysFile is always `/etc/llm2ssh/keys/%u`** — root-owned so the agent
cannot self-persist a key in its own `~/.ssh/authorized_keys`.

## Freeze flag

The enforcement decision ("is this agent frozen?") is read from
`/run/llm2ssh/agents/<agent>.frozen` — **world-readable**, root-written. The gate,
the bot, and `_gc` all check this file. The human-readable reason and audit
detail live in the root-only state file; the *flag* used by enforcers must be
readable by them.

## Profile format

Line-oriented directives, **parsed, never `source`d** (sourcing a shared profile
would be RCE as root). Directives: `name`, `description`, `include <profile>`
(one level, for `observer`), `group <grp>`, `sudo <Cmnd spec>`,
`needs-services yes`, `warn <text>`, `sudo-all yes`. Unknown directive = hard
error. Each `sudo` line is validated: absolute path, binary exists, contains
none of `, : = \ ( )` or newline (sudoers metacharacters → alias injection), and
is not on the shell-escape/pager denylist. The Claude-layer allow/deny lists are
generated mechanically from the same `sudo` directives so they cannot drift.

## Approval spool contract

Directories (created by tmpfiles.d):

- `/run/llm2ssh/approvals/req/` — `3770 root:llm2ssh`. Agents write their own
  request files; sticky bit blocks cross-user deletion.
- `/run/llm2ssh/approvals/res/` — `2750 llm2ssh-bot:llm2ssh`. **Only the bot user
  mints decisions.** The requester verifies `stat -c %U` of the response file is
  `llm2ssh-bot` before trusting it.
- `/run/llm2ssh/notify/` — `0750 root:llm2ssh`. Only root/bot write; **agents must
  not** (else a compromised agent phishes the owner).

**IDs:** 8 lowercase hex chars. Telegram `callback_data` is `a:<id>:1` (allow) /
`a:<id>:0` (deny), validated by `^a:[0-9a-f]{8}:[01]$`.

**Request JSON** (`req/<id>.json`):
```json
{ "id":"9f3a1c2e", "ts":1752912000, "source":"claude-hook|sudo-wrapper|cli",
  "user":"llmagent", "profile":"services", "command":"systemctl restart nginx",
  "cwd":"/home/llmagent/workspace", "timeout_s":180 }
```

**Response JSON** (`res/<id>.json`, written by bot or local approver):
```json
{ "id":"9f3a1c2e", "decision":"allow|deny", "decided_by":"tg:123|tty|timeout|freeze",
  "reason":"", "decided_at":1752912031 }
```

**Client:** `llm2ssh-approve request --timeout <secs>` — request JSON on stdin,
decision JSON on stdout. **Exit codes: `0`=allow, `1`=deny, `2`=timeout,
`3`=broker unavailable.** Every non-zero path is fail-closed (the caller denies).

**Heartbeat:** the approval daemon (bot or `approve --watch`) touches
`/run/llm2ssh/approvald.alive` at least every 10 s. The client treats a missing
or >30 s-stale heartbeat as exit 3 (broker down → deny). While the freeze flag
exists, all approvals auto-deny with `decided_by:"freeze"`.

## Exit codes (CLI)

`0` ok · `1` error · `2` usage · `3` validation failed (e.g. visudo) · `4` not
found.

## Dependencies

bash (4+), coreutils, `curl`, `jq`, `tmux`, `auditd`. Installed once by
`install.sh`. `jq` is the single blessed non-coreutils dependency; all JSON is
built/parsed with jq (never string-interpolated).

## Agent provider abstraction (Mode B)

Claude Code is the v1 provider. Its specifics (apt install, managed-settings,
PreToolUse hook, `claude -p` relay) live behind an interface in
`lib/agents/claude.sh`: `agent_install`, `agent_auth`, `agent_run`,
`agent_compile_policy`. Adding a provider is a new `lib/agents/<name>.sh`; the
enforcement core (sudoers/SSH/freeze/audit) is provider-independent.
