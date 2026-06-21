# AutoChamber

Bootstrap scripts for deploying [OpenCode](https://github.com/anomalyco/opencode), [OpenChamber](https://github.com/openchamber/openchamber), and [Swarm Tools](https://github.com/joelhooks/opencode-config).  These is meant to be used on Ubuntu VM's only accessible on your network to quickly standup disposable agent-based dev environments.

## Quick Start

```bash
git clone https://github.com/corysutyak/autochamber
cd autochamber
cp config/default.env config/.env       # copy defaults, then edit
# Edit config/.env with your model choices and API keys
bash scripts/install.sh                  # full stack install
```

That's it. The install script handles everything below.

### Config Variables

The `config/.env` file controls which models OpenCode uses and how swarm-tools connects to Ollama:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCODE_MODEL` | `openai/gpt-5.2-codex` | Main model for build/plan agents |
| `OPENCODE_SMALL_MODEL` | `openai/gpt-5.2` | Smaller model for lightweight tasks |
| `OPENCODE_CUSTOM_PROVIDER` | `false` | Add a custom OpenAI-compatible provider |
| `OPENCODE_PROVIDER_URL` | *(empty)* | Base URL for custom provider |
| `OPENCODE_PROVIDER_API_KEY` | *(empty)* | API key for custom provider |
| `OLLAMA_MODEL` | `nomic-embed-text` | Embedding model for swarm-tools (768d, ~27MB) |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server address |
| `AGENT_NAME` | `OpenChamber Agent` | Git user.name for agent commits |
| `AGENT_EMAIL` | `agent@localvm` | Git user.email for agent commits |
| `GH_TOKEN` | *(empty)* | GitHub fine-grained PAT for auto-auth during install — needs at least **Read/Write Contents** and **Read/Write Pull Requests** permissions |

See the [Config](#config) section below for custom provider examples and hot-swap options.

## What Gets Installed (and Why)

| Component | What it is | Why we need it |
|-----------|-----------|----------------|
| **Node.js 22 LTS** | JavaScript runtime | Required by OpenChamber, Bun, and several CLI tools |
| **Bun** | Fast JS runtime + package manager | Used by the OpenCode config repo for dependencies |
| **Docker** | Container engine | OpenChamber agents manage containers; required for swarm worker isolation |
| **OpenCode** | AI coding agent CLI (port 4096) | The main interface — exposes MCP tools to any connected AI agent |
| **OpenChamber** | Web UI (port 3000) | Browser-based dashboard for managing sessions and swarm activity |
| **Ollama** | Local embedding server (port 11434) | Powers semantic memory for swarm-tools — stores and searches agent learnings via vector embeddings. Model: `nomic-embed-text` (~27MB, 768d) |
| **opencode-swarm-plugin** | Swarm orchestration backend | Multi-agent coordination: task decomposition, parallel workers, file reservations, inter-agent messaging |
| **CASS** | Cross-agent session search | Semantic search across all past AI coding agent histories (Claude, Cursor, etc.) — so agents can learn from what worked before |
| **UBS** | Ultimate Bug Scanner | Static analysis for pre-completion bug scanning in swarm workers — catches null safety, XSS, missing await, and 1000+ patterns before code ships |
| **GitHub CLI (gh)** | GitHub command-line tool | Required for opencode config sync (`/sync-init`) — authenticates to GitHub, manages repos and PRs |
| **uv** | Python package manager | Fast installer for the `fetch` MCP server |
| **opencode-models-discovery** | Model auto-discovery plugin | Queries custom OpenAI-compatible providers at startup to register available models — no hardcoded model lists needed |
| **opencode-synced** | Config sync plugin | Syncs global OpenCode config across machines via a GitHub repo — run `/sync-init` on first machine, `/sync-link` on additional machines |
| **next-devtools-mcp** | Next.js MCP server | Exposes Next.js dev server diagnostics, route info, and error reporting to AI agents |
| **chrome-devtools-mcp** | Browser DevTools MCP server | Enables AI agents to interact with Chrome DevTools for debugging and testing |
| **Biome** | Fast formatter and linter | Auto-formats JS/JSX/TS/TSX/JSON files on write — configured in OpenCode's `"formatter"` block |

### OpenCode Plugins

Two plugins are always included in the rendered config (`"plugin"` array in `opencode.jsonc`). OpenCode installs them from npm on startup — no manual install needed.

| Plugin | What it does | First-time setup |
|--------|-------------|-----------------|
| **opencode-models-discovery** | Auto-discovers models from custom OpenAI-compatible providers at startup | None — works automatically when `OPENCODE_CUSTOM_PROVIDER=true` |
| **opencode-synced** | Syncs your entire OpenCode config (agents, skills, themes, etc.) across machines via a private GitHub repo | Run `/sync-init` inside OpenCode to create the repo; run `/sync-link` on any additional machine |

### Global MCP Server Packages

Some MCP server packages are installed globally via npm to avoid npx overhead on every agent spawn:

| Package | Purpose | Config key |
|---------|---------|------------|
| **next-devtools-mcp** | Next.js dev server diagnostics, routes, errors | `mcp.next-devtools` |
| **chrome-devtools-mcp** | Chrome DevTools automation for browser debugging | `mcp.chrome-devtools` |
| **@biomejs/biome** | Fast formatter/linter for JS/TS/JSON | `formatter.biome` |
| **context7** | Remote (`https://mcp.context7.com/mcp`) | Documentation lookup for any library |
| **fetch** | `uvx mcp-server-fetch` (via uv) | Web page fetching for agents |

### Systemd Services

Three services are set up for auto-start on boot:

| Service | Port | Description |
|---------|------|-------------|
| `opencode` | 4096 | OpenCode MCP server — agents connect here |
| `openchamber` | 3000 | OpenChamber web dashboard |
| `ollama` | 11434 | Local embedding model for swarm semantic memory |

Check status: `systemctl status opencode openchamber ollama`
View logs: `journalctl -u opencode -f`

## Update

```bash
bash scripts/update.sh              # update all components
bash scripts/update.sh --help        # show options
```

Updates OpenChamber, OpenCode, Bun, CLI backends, Ollama model, pulls latest upstream config, then restarts services. Creates a rollback backup before making changes. Does **not** run `apt upgrade` — use your system's package manager for OS updates.

## Swarm Tools

[Swarm Tools](https://github.com/joelhooks/opencode-config) turns OpenCode into a multi-agent system. You describe what you want. It decomposes the work, spawns parallel workers, tracks what strategies work, and adapts over time.

Built on [`joelhooks/swarmtools`](https://github.com/joelhooks/swarmtools) — multi-agent orchestration with outcome-based learning.

### Why Swarm?

Most AI coding agents are single-threaded and context-limited. Swarm lets you:

- **Break tasks into pieces** that can be worked on simultaneously
- **Spawn parallel workers** that don't step on each other
- **Remember what worked** and avoid patterns that failed
- **Survive context compaction** without losing progress

### How to Use

All commands run **inside OpenCode**, not in your terminal.

1. Open an OpenCode session on your VM
2. Run: `/swarm "Add user authentication with OAuth"`
3. The coordinator decomposes the task, creates cells, spawns workers, and reviews each completion

Key commands:

```
/swarm <task>      # Decompose → spawn parallel agents → merge
/swarm-status      # Check running swarm progress
/swarm-collect     # Collect and merge swarm results
/parallel "a" "b"  # Run explicit tasks in parallel
/hive              # Query and manage tasks
/inbox             # Check messages from other agents
/handoff           # End session with sync and handoff notes
```

The full command set includes: `/commit`, `/pr-create`, `/worktree-task`, `/checkpoint`, `/retro`, `/review-my-shit`, `/sweep`, `/focus`, `/triage`, `/estimate`, `/standup`, `/migrate`, `/repo-dive`.

See [swarmtools.ai/docs](https://swarmtools.ai/docs) for the full reference.

## Config

Config is generated from a template + environment variables. The install script clones [joelhooks/opencode-config](https://github.com/joelhooks/opencode-config) to `~/.config/opencode/` for agents, commands, skills, and knowledge files. Then it renders the config template using values from `config/.env`.

**Config priority:**
1. `--config <path>` — any config file path you provide (skips templating)
2. `config/opencode.jsonc` — local override (gitignored)
3. Template (`default.opencode.jsonc`) rendered with `config/.env` values

### Custom provider example

To use a local Llama.cpp server, models are auto-discovered at runtime — no manual model config needed:

```bash
# In config/.env
OPENCODE_CUSTOM_PROVIDER=true
OPENCODE_PROVIDER_URL=http://llama.local/v1
OPENCODE_MODEL=llama-local/auto-discovered-model-id
OPENCODE_SMALL_MODEL=llama-local/auto-discovered-model-id
```

The `opencode-models-discovery` plugin queries your provider's `/v1/models` endpoint on startup and registers all available models automatically. Set `OPENCODE_MODEL` / `OPENCODE_SMALL_MODEL` to whichever discovered model id you want as default.

### Hot-swap configs on update

```bash
bash scripts/update.sh --config path/to/custom.opencode.jsonc
```

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/install.sh` | Full stack install (entry point) |
| `scripts/install-node.sh` | Node.js 22 LTS + Bun |
| `scripts/install-docker.sh` | Docker Engine |
| `scripts/install-opencode.sh` | OpenCode CLI |
| `scripts/install-git-hooks.sh` | Git pre-push hook (blocks force pushes, protected branches) |
| `scripts/install-skills.sh` | Global skills (systematic-debugging, test-driven-development, ask-questions-if-underspecified) |
| `scripts/install-ollama.sh` | Ollama + embedding model for swarm-tools |
| `scripts/install-openchamber.sh` | OpenChamber web UI |
| `scripts/health.sh` | Service and port health check |
| `scripts/lib.sh` | Shared helper library (sourced by other scripts) |

## Rollback

Every run of `update.sh` creates a timestamped backup in `/var/lib/autochamber/backups/`. To restore:

```bash
bash scripts/rollback.sh              # interactive selection
bash scripts/rollback.sh 20260620_143000  # specific backup
```

Backups include systemd service files, OpenCode config, agent definitions, and a version snapshot of all components.

## Security Considerations

This setup prioritizes agent usability while containing the blast radius of compromised or errant agents.

### What's Protected

| Control | Mechanism | What it blocks |
|---------|-----------|----------------|
| **Force pushes** | OpenCode permission `deny` + git pre-push hook | Agent cannot rewrite shared history |
| **Protected branches** | OpenCode permission `deny` + git pre-push hook | Agent cannot push to `main`, `master` directly |
| **All git pushes** | OpenCode permission `ask` | Agent must get user approval before any push |
| **Destructive commands** | OpenCode permission `deny` | `sudo`, `rm -rf /`, fork bombs blocked |
| **OpenCode server** | Binds to `127.0.0.1` only | Not accessible from LAN; local agents only |

