---
title: If The Mac Mini is the Brain, OpenClaw is the Nervous System - OpenClaw Installation
date: 2026-05-29
draft: false
tags:
  - AI
  - librarian
  - openclaw
description: Setting up OpenClaw for the first time for my personal intelligence assistant.
---
I never really used AI all that much prior to this. I've had GPT or Claude write me up some scripts or helped me do some research in the past, but nothing huge like some of these developers out here. But when I heard about OpenClaw and its ability to ease of access ratio, I have to say it was one of those "oh wow" moments. OpenClaw is the piece that turns a local language model into an actual AI assistant. Without it, the Mac Mini is just a "dumb" model with no real applications other than chat, kind of like a brain without a body. With it, you have an agent with a persistent identity, vault access, tool calling, Telegram integration, and the ability to spawn specialist sub-agents. This post covers how I deployed it, the problems that I came across, and the solutions implemented to get around them.

## What OpenClaw Is

OpenClaw is an open-source AI gateway that runs on your own hardware. It bridges messaging platforms — Telegram, Discord, Slack, WhatsApp — to AI models, while adding the infrastructure that makes an agent actually useful: persistent memory, file access, tool calling, scheduled tasks, and multi-agent orchestration. Basically, you're giving the models access to its own computer. 

The architecture for my stack:

```
Me (Telegram)
    ↓
OpenClaw Gateway (Ubuntu VM, running on my Proxmox home server)
    ↓
Ollama Inference Server (Mac Mini M4)
    ↓
Qwen3.5 9B (librarian model)
```

Every message I send to the Librarian via Telegram goes through OpenClaw first. OpenClaw loads the agent's identity files, applies the configured tools and permissions, and routes the request to the right model on the Mac Mini. The response comes back through the same chain.

Nothing touches the cloud. No API keys, no third-party inference, no external services involved in the core loop.

## Why a Dedicated VM

OpenClaw is an agent that executes tools, runs shell commands through sub-agents, accesses files, and controls a browser. If something goes wrong — a prompt injection, a misconfigured skill, a bad tool call — I want that contained to a single machine, not sharing a host with everything else.

I used a simple Ubuntu Server VM on Proxmox: 2 cores, 4GB RAM, 32GB disk.

## The Installation

OpenClaw is an npm package, so the installation is as simple as making sure npm is installed on your server and then running:

```bash
npm install -g openclaw
```

The onboard wizard handles the initial setup:

```bash
openclaw onboard
```

The wizard asks about your model provider, sets up the workspace directory, and walks you through connecting a channel. For Ollama, I had to point it to the Mac Mini inference server via its IP address and select the primary model, being the Qwen3.5:9b model mentioned last post.

One thing the wizard does not tell you: it will supposedly ask you to describe your agent's personality to generate a soul.md file. This happens late in the process, after the agent has been hatched. If the hatch fails — and it did for me — you never see that prompt. This led to some confusion since I had to manually write these files instead. 

## The Workspace

An important concept in OpenClaw is the workspace, which is not only where the files that the agent creates is managed and stored, but is also a folder of plain text files that define who the agent is and how it behaves. OpenClaw reads these at the start of every session.

```
~/.openclaw/workspace/
├── soul.md        ← personality, tone, hard limits only
├── agents.md      ← operating instructions and procedures
├── user.md        ← context about the human
├── identity.md    ← name and emoji
├── tools.md       ← tool access documentation
├── heartbeat.md   ← scheduled tasks
├── boot.md        ← startup health checks
├── memory.md      ← persistent learned context
└── skills/        ← on-demand procedure files
```

The key insight I kept getting wrong early on: `soul.md` is for personality and hard limits only. Not procedures, workflows, or operating instructions. It sucked up way too much of the context for the agent, resulting in a single "hello" prompt extending beyond the Mac Mini's available resources. 

After a little bit of investigation, I come to find out Skills are the right home for anything procedural. A skill file loads only when that skill is active. I will eventually build a lot of these; from Obsidian vault management to morning new briefings. It makes sense now that I understand it, of course the agent doesn't and shouldn't carry all of that in every conversation.

---

## Problem 1: The Hatch Abort

The onboard wizard hatches the agent by sending a test prompt to verify the model responds. If the workspace directory doesn't exist the hatch aborts before it ever reaches the soul.md creation prompt.

The fix: create the workspace manually first.

```bash
mkdir -p ~/.openclaw/workspace
cat > ~/.openclaw/workspace/soul.md << 'EOF'
# Librarian
You are the Librarian. A calm, precise personal intelligence assistant.
EOF
```

A minimal soul.md satisfied the hatch. I replaced it with the full version after the wizard completed.

---

## Problem 2: The Streaming Bug

Every response was failing with this in Telegram:

```
⚠️ Agent couldn't generate a response.
```

And this in the OpenClaw logs:

```
incomplete turn detected: payloads=0
```

The model was running — `ollama ps` showed it loading and generating tokens. Direct curl calls to Ollama returned correct responses. The problem was specifically in how OpenClaw parsed the streaming response.

OpenClaw uses streaming by default when calling language models. There is evidently a bug where the streaming protocol handling breaks tool calling and response parsing for local Ollama models. The model generates a valid response and OpenClaw receives it. The streaming parser fails to assemble it into a response payload. Zero payloads means incomplete turn resulting in the error to the user.

**The fix:**

```bash
export OLLAMA_DISABLE_STREAMING=true
```

This needs to be set before starting the gateway. With streaming disabled, OpenClaw waits for the complete response rather than trying to assemble a stream.

**Critical: this variable must be in the process environment, not just exported in your shell.** I spent a significant amount of time debugging this because I had set the variable in my shell session but the gateway was running under a different process that never inherited it.

When running OpenClaw as a systemd service the variable must be in the service file itself:

```bash
sudo sed -i '/Environment=OPENCLAW_SERVICE_KIND=gateway/a Environment=OLLAMA_DISABLE_STREAMING=true' \
  ~/.config/systemd/user/openclaw-gateway.service

systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service
```

Verify it's actually in the running process:

```bash
grep -z OLLAMA /proc/$(pgrep -f "openclaw" | head -1)/environ
```

Should return `OLLAMA_DISABLE_STREAMING=true`. If it returns nothing, the fix is not active regardless of what you think you set.

---

## Problem 3: Context Window Explosion

Even after fixing the streaming bug, the Librarian was taking 5+ minutes to respond to simple messages. `ollama ps` revealed the problem immediately:

```
NAME              SIZE     PROCESSOR          CONTEXT
librarian:latest  19 GB    40%/60% CPU/GPU    262144
```

19GB on a 16GB machine, of course it wasn't functioning. The model was spilling to CPU because it couldn't fit in memory, but these Mac Minis share memory between the CPU and GPU. The context window was 262,144 tokens because OpenClaw was requesting the full context window rather than respecting the 32,768 set in the Modelfile.

The fix is explicit `contextWindow` values in `openclaw.json`:

```json
{
  "id": "librarian:latest",
  "contextWindow": 32768,
  "reasoning": false
}
```

I set `"reasoning": false` for all local models too. OpenClaw uses this flag to handle extended chain-of-thought output. With local Qwen3 models, `reasoning: true` creates a format mismatch — OpenClaw expects thinking tokens that the model doesn't produce in that format — and it generates another source of the `payloads=0` error.

After fixing both:

```
NAME              SIZE    PROCESSOR    CONTEXT
librarian:latest  9.7GB   100% GPU     32768
```

Response times dropped from 5+ minutes to 20-60 seconds.

**There is also a per-agent models.json file that overrides the main config.** This is not obvious. After the onboard wizard runs it creates a cached model config at `~/.openclaw/agents/librarian/agent/models.json`. This file takes precedence over `openclaw.json` for that agent. Check it and update it to match:

```bash
cat ~/.openclaw/agents/librarian/agent/models.json
```

If it has `contextWindow: 32768` but your main config says 65536, the agent will use 32768. Both files need to be consistent.

---

## Problem 4: Thinking Mode Active

The startup log showed:

```
agent model: ollama/librarian:latest (thinking=medium, fast=off)
```

Despite `reasoning: false` in the model config, OpenClaw was enabling thinking mode. This is controlled by a separate config key:

```bash
openclaw config set agents.defaults.thinkingDefault off
```

After restarting:

```
agent model: ollama/librarian:latest (thinking=off, fast=off)
```

The `reasoning` flag in the model definition and the `thinkingDefault` agent setting are two separate controls. Both need to be set.

---
## Problem 6: The Config Got Wiped

At one point I asked the Librarian to enable image processing via a tool call. It used `gateway.config.patch` to modify `openclaw.json` directly. The patch was malformed. The config file went from 9,662 bytes to 105 bytes. Everything was gone.

The log entry that tells the story:

```
Config observe anomaly: size-drop-vs-last-good:9662->105
```

Two lessons from this:

**First:** Never let the agent modify its own config. Add `config.patch` and `gateway.config.patch` to the tool deny list:

```json
"tools": {
  "deny": [
    "shell", "exec", "system.run", "system.exec",
    "gateway.config.patch", "config.patch"
  ]
}
```

**Second:** Back up the config. The automatic `.bak` files OpenClaw creates are single-step backups — if two writes happen in quick succession the backup is the second-to-last write, not the last known good state. Set up a daily cron backup to a dated file:

```bash
(crontab -l 2>/dev/null; echo '0 2 * * * cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw-backup-$(date +\%Y-\%m-\%d).json') | crontab -
```

---

## Problem 7: The Gateway Not Persisting

Running the gateway with `nohup` works but the process doesn't survive VM reboots, and if it crashes it doesn't restart. OpenClaw installs a systemd user service during setup:

```bash
systemctl --user status openclaw-gateway.service
```

Use the service instead of nohup. The service handles automatic restarts (`Restart=always`) and starts on boot (`WantedBy=default.target`).

The important thing is that environment variables set with `systemctl --user set-environment` do not actually persist into the service's process environment — they only affect manually started units. Variables needed by the gateway must be in the service file itself under `Environment=` lines.

Check the service file to see what's actually set:

```bash
cat ~/.config/systemd/user/openclaw-gateway.service | grep Environment
```

Add anything missing directly to that file, then reload and restart:

```bash
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service
```

The correct startup optimisation flags for a VM environment:

```
Environment=OLLAMA_DISABLE_STREAMING=true
Environment=NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
Environment=OPENCLAW_NO_RESPAWN=1
```

---

## Problem 8: Keep-Alive Expiring

Ollama unloads models from memory after 4 minutes of inactivity by default. When the Librarian received a message after a period of silence, the model had to reload from disk before inference could start — adding latency and causing stalls.

I fixed this via the Ollama startup script on the Mac Mini:

```bash
# ~/start-ollama.sh
export OLLAMA_HOST=0.0.0.0:11434
export OLLAMA_KEEP_ALIVE=-1
ollama serve &
```

`-1` keeps the model loaded indefinitely.

---

## The Final Configuration

After working through all of the above, the production `openclaw.json`:

```json
{
  "agents": {
    "defaults": {
      "workspace": "/home/dgegare/.openclaw/workspace",
      "model": {
        "primary": "ollama/librarian:latest"
      },
      "thinkingDefault": "off",
      "subagents": {
        "maxSpawnDepth": 2,
        "maxChildrenPerAgent": 5,
        "runTimeoutSeconds": 600,
        "model": "ollama/huihui_ai/qwen2.5-coder-abliterate:7b"
      }
    },
    "list": [
      {
        "id": "librarian",
        "workspace": "/home/dgegare/.openclaw/workspace",
        "model": {
          "primary": "ollama/librarian:latest"
        },
        "tools": {
          "deny": [
            "shell", "exec", "system.run", "system.exec",
            "gateway.config.patch", "config.patch"
          ],
          "alsoAllow": [
            "web_search", "web_fetch", "browser",
            "sessions_spawn", "subagents"
          ]
        }
      },
      {
        "id": "coder",
        "workspace": "/home/dgegare/.openclaw/workspace-coder",
        "model": {
          "primary": "ollama/huihui_ai/qwen2.5-coder-abliterate:7b"
        },
        "tools": {
          "alsoAllow": ["shell", "exec", "file"]
        }
      }
    ]
  }
}
```

And the Librarian model config in the models array:

```json
{
  "id": "librarian:latest",
  "reasoning": false,
  "contextWindow": 65536,
  "maxTokens": 8192,
  "compat": {
    "supportsTools": true,
    "supportsUsageInStreaming": true
  }
}
```

---

## Debugging Reference

Things to check when something isn't working, in order:

**Is Ollama reachable?**

```bash
curl http://192.168.0.145:11434/api/tags
```

**Is the model loaded and using GPU?**

```bash
ollama ps
# Check PROCESSOR column — should be 100% GPU
# Check CONTEXT column — should match your contextWindow config
# Check SIZE — should fit within available RAM
```

**Is OLLAMA_DISABLE_STREAMING actually set in the process?**

```bash
grep -z OLLAMA /proc/$(pgrep -f "openclaw" | head -1)/environ
```

**Is the model receiving requests at all?**

Watch `ollama ps` while sending a message. If the model never shows any activity during a 2+ minute stall, the request is not leaving OpenClaw. The stall is internal, not inference-side.

**What does the actual log say?**

The systemd service writes to `/tmp/openclaw/openclaw-YYYY-MM-DD.log`, not to `~/openclaw.log`. Filter out the noise:

```bash
tail -f /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log | grep -v "liveness\|diagnostic"
```

**Is the config valid?**

```bash
python3 -m json.tool ~/.openclaw/openclaw.json > /dev/null && echo "valid"
```

---

## What's Working

The Librarian is responding via Telegram, loading its workspace files, and running entirely on local hardware with no cloud dependencies.

Response times on a Mac Mini M4 16GB with the model fully loaded in Metal:

- Simple conversational responses: 15-30 seconds
- Research tasks with web search: 1-3 minutes
- Coding delegation to the Coder: 2-5 minutes

This is the trade-off for local inference. The Librarian will know things about my infrastructure, my projects, and my research that I would rather not put through a cloud AI service. The latency is worth the control.

## Next Steps

The intelligence pipeline: SearXNG for private web search, obsidian-headless for vault sync, and the morning brief skill wired to the heartbeat scheduler. That's the next post. 