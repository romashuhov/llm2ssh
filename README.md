# llm2ssh

**Give an LLM agent exactly as much access to your server as you want — and take
it back in one command.**

`llm2ssh` provisions a locked-down Linux user for an AI agent (Claude Code and
friends) and switches its permissions between simple **profiles**. Start with
read-only hardware/process visibility; grant Docker or service control when you
need it; hand over full root for a risky task with an auto-expiring, one-command
kill-switch standing by. Pure bash, Ubuntu/Debian, no daemons in the core.

> Design stance: the thing you're guarding against isn't a hacker — it's an
> over-eager or prompt-injected agent. So the enforcement boundary is the kernel
> + sudo + root-owned files, never anything the agent can edit. See
> [docs/SECURITY.md](docs/SECURITY.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/llm2ssh/main/install.sh | sudo bash
```

(Or clone the repo and run `sudo ./install.sh`.) Ubuntu/Debian only.
Dependencies (`sudo`, `curl`, `jq`, `tmux`, `auditd`) plus a curated set of
**monitoring tools** (htop, sysstat, lsof, ncdu, lm-sensors, smartmontools,
dmidecode, …) are installed for you, so the agent has real tooling from the
start. Skip them with `--no-tools`; manage later with `llm2ssh tools`.

## Quick start

**Fastest path — `onboard`:** one command creates the agent, generates a key on
the server, and prints a single block you paste straight into your agent's chat.
The agent sets up its key and starts working — no key wrangling on your side.

```bash
sudo llm2ssh onboard bot            # → paste the printed block into the agent's chat
```

The key it prints grants only the current profile (observer = read-only) and is
revocable instantly (`llm2ssh freeze bot`). Prefer not to move a private key at
all? Use the bring-your-own-key flow instead:

```bash
# 1. Create an agent user, starting read-only, with your SSH key
sudo llm2ssh create bot --github your-handle          # or --key "ssh-ed25519 ..."

# 2. See what it can do / how to connect a local agent to it
sudo llm2ssh connect-info bot

# 3. Grant more when needed — auto-revoked after 4h
sudo llm2ssh grant bot docker-ro --ttl 4h
sudo llm2ssh grant bot services --services nginx,redis

# 4. Watch what it did
sudo llm2ssh log bot --denied

# 5. Panic button: revoke everything and sever its sessions, now
sudo llm2ssh freeze bot
sudo llm2ssh unfreeze bot                              # when you're ready
```

## Two ways to run the agent

- **Mode A — local agent over SSH.** Your Claude Code runs on your machine and
  reaches the server as the restricted user. `llm2ssh connect-info` prints a
  ready-to-paste SSH config, `known_hosts` line, and a `CLAUDE.md` snippet that
  tells the agent to check its live permissions with `ssh <host> llm2ssh-ctx`.

- **Mode B — Claude Code on the server.** `llm2ssh agent install/auth/start`
  runs Claude Code on the box under the restricted user in a tmux session you can
  attach to (`llm2ssh agent attach bot`) or drive from Telegram.

## Permission profiles

`observer` → `observer-logs` → `docker-ro` → `docker-admin` → `services` →
`full`. Preview any with `llm2ssh profile show <name>`; write your own in
`/etc/llm2ssh/profiles.d/`. Full format in [docs/PROFILES.md](docs/PROFILES.md).

## Telegram bot (optional)

```bash
sudo llm2ssh bot setup            # BotFather token + a one-time /start handshake
```

Then, from your phone: `/status`, `/docker`, `/log`, `/freeze`, chat directly
with the on-server agent — and approve or deny its dangerous commands with an
inline **Allow / Deny** button. Human-in-the-loop, fail-closed: no answer means
no. The bot answers only the chat you bound it to.

## Commands

```
create   grant   revoke   freeze   unfreeze   status   list   log
profiles profile connect-info key   agent      approve  bot    doctor   delete
```

Run `llm2ssh help` for the full reference.

## How it's kept honest

- **sudoers, generated and `visudo`-validated** — the docker profiles never use
  the (root-equivalent) docker group; they whitelist exact subcommands.
- **Root-owned keys** so the agent can't self-persist access.
- **`freeze`** uses account expiry (which actually blocks pubkey SSH) and kills
  root-side sudo children by login-uid.
- **Audit** via sudo logs + auditd (keyed on login-uid, so it survives `sudo`).
- **Approvals fail closed**; the notify channel isn't agent-writable.

Every shell script passes `shellcheck -S warning`; the test suite runs under
`bats` in Ubuntu 24.04 and Debian 12 containers (`bash test/run.sh`).

## Development

```bash
bash test/run.sh                 # full suite in Docker (ubuntu:24.04 + debian:12)
bash test/run.sh ubuntu:24.04    # one image
```

## License

See [LICENSE](LICENSE).
