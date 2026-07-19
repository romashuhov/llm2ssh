# llm2ssh — Security Model & Pitfalls Checklist

## Threat model

The adversary llm2ssh defends against is **not a human attacker with a shell** —
it is the LLM agent itself: over-eager, possibly prompt-injected by content it
reads, and prone to "creative" workarounds. Consequences:

- **The enforcement boundary is the kernel + sudo + root-owned file permissions.**
  Nothing the agent can edit is ever load-bearing.
- Everything under `/home/<agent>` (shell rc files, `~/.claude/settings.json`,
  the workspace `CLAUDE.md`) is **UX guidance, not security**. A jailbroken agent
  can rewrite all of it; the design stays safe when it does.
- Every privileged action and **every denied attempt** is logged to root-owned,
  agent-unreadable logs.

## The two layers

| Layer | Mechanism | Who can tamper | Purpose |
|---|---|---|---|
| **Enforcement (hard)** | sudoers whitelists, sshd config, file perms, root-owned gated wrappers, Claude *managed-settings* | root only | the actual wall |
| **Guidance (soft)** | `llm2ssh-ctx` context, workspace `.claude/settings.json`, the PreToolUse hook | the agent | make a well-behaved agent efficient; reduce noise |

If a soft-layer control is stripped, the hard layer still holds.

## Pitfalls checklist (for contributors)

1. **`docker` group == root.** Never add an agent to it. All docker access is
   sudoers whitelists of exact subcommands.
2. **`docker run/exec/cp/commit/build/load/save/create` and `compose up` are
   root-equivalent** (`docker run -v /:/host …`). They belong only to `full`,
   never to `docker-admin`.
3. **sudoers `*` spans multiple words, including flags.** Never wildcard a path
   argument or a command where a flag can reach files.
4. **A comma / `:` / `=` / `\` in a profile `sudo` line is alias injection.** The
   parser rejects them.
5. **Never whitelist shell/pager/interpreter escapes** (`bash`, `less`, `vi`,
   `find -exec`, `git`, `tar --checkpoint-action`, `systemctl status` → pager →
   `!sh`). Enforced by the denylist in `lib/profile.sh`.
6. **`authorized_keys` in `$HOME` = agent self-persistence.** Keys live in
   root-owned `/etc/llm2ssh/keys/%u` (`AuthorizedKeysFile`), so the agent cannot
   append its own key.
7. **`usermod -L` does NOT block pubkey SSH.** `freeze` uses
   `usermod --expiredate 1` (account expiry blocks every auth method) and kills
   processes running as the agent plus root-side sudo children via
   `/proc/*/loginuid`. **Limit:** a root process whose loginuid is *reset* (a
   systemd service / cron / at job) is not killed — that can't be distinguished
   from a legitimate daemon, and planting one requires a prior `full` grant, for
   which freeze/TTL are already documented as best-effort. Key management and
   `create` also warn (and `doctor` fails) if the sshd drop-in isn't actually in
   effect, since a missing `Include` would let the agent's own
   `~/.ssh/authorized_keys` grant access.
8. **Files in `/etc/sudoers.d` containing a `.` are silently ignored.** Generated
   names are dot-free; temp files are dot-prefixed so a crash mid-write leaves an
   *inactive* file.
9. **Never write sudoers without `visudo -cf`** on a temp file first — a syntax
   error can lock the admin out of sudo host-wide.
10. **Transient timers die on reboot** → a TTL would silently become permanent.
    The state file is the source of truth; one persistent gc timer enforces it.
11. **auditd immutable mode (`-e 2`) requires a reboot to change rules** — never
    set it. Audit keys on `auid` so root-side execs after `sudo` are attributed
    to the agent.
12. **The Claude PreToolUse hook is advisory.** A model can hide
    `sudo systemctl …` inside `bash notes/x.sh`; the hook sees only
    `bash notes/x.sh`. Anything that must never happen without approval goes
    behind a **gated sudo wrapper** (e.g. `llm2ssh-svc`), not the hook.
13. **Approvals fail closed.** The client (`llm2ssh-approve`) denies on timeout,
    on a missing/stale broker heartbeat, and trusts a decision only if the
    `res/` file is owned by root or `llm2ssh-bot`. Agents can write `req/` but not
    `res/`.
14. **The notify spool is not agent-writable.** Group `llm2ssh-bot` owns it, so a
    prompt-injected agent cannot phish the owner with fake Telegram alerts.
15. **Bot token = credential.** `/etc/llm2ssh/bot.env` is `0640 root:llm2ssh-bot`
    (agents cannot read it); the token is scrubbed from logs. A stolen token
    permits DoS/phishing but **not** approvals — those require the bound owner's
    Telegram `from.id`.
16. **`docker inspect`/`logs` leak env-var secrets.** `docker-ro` is read-only,
    not secret-free — documented in its `warn`.
17. **`full` TTL is best-effort.** A root agent can stop the gc timer. Prefer
    `--ttl … --kill-on-expiry` and keep sessions short.
18. **Claude Code install**: prefer the APT method (root-owned `/usr/bin/claude`)
    so the agent cannot replace the binary that enforces managed-settings/hooks.
    Pin the signing-key fingerprint and abort on mismatch.

## Reporting

Security issues: please open a private report rather than a public issue.
