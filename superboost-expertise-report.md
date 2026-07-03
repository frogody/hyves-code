# Superboost v3.0 — Architecture & Expertise Report

*Generated: 2026-04-17 | Superboost v3.0.0 | Default model: Claude Opus 4.7*

---

## 1. What changed in v3

Three forces drove v3:

1. **Opus 4.7 became the default model.** 1M context window and `alwaysThinkingEnabled: true` invert several v2 assumptions about token frugality.
2. **Model-per-agent selection matured.** The Agent tool now accepts `model: "opus" | "sonnet" | "haiku"` — v2 didn't exploit this, so every spawned agent inherited Opus and burned rate budget.
3. **Installation drift was invisible.** v2 tracked checksums in version.json but never validated them; a silent hook edit could pass boot-check unchallenged.

| Change | v2 behavior | v3 behavior |
|--------|-------------|-------------|
| Pre-Flight Q2 context payload | "Path + line range, agent reads itself" | "Rich context upfront — main-thread reads cache; agent cold-reads don't" |
| Model tier on spawned agents | Inherited (usually Opus) | Deliberately chosen: Opus for synthesis/judgment, Sonnet for workers, Haiku for explorers |
| Fast mode (`/fast`) handling | Silent — no warning | Router downgrades to solo-only; statusline flashes `⚠ FAST` |
| Hook checksum validation | Tracked but never verified | Boot check warns on drift; `bless-hooks.sh` re-seeds after intentional edits |
| Version coherence | banner=2.0, json=1.3.0, CLAUDE.md=v2 | All three aligned at 3.0 |

---

## 2. System architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                         CLAUDE CODE RUNTIME                             │
│                                                                         │
│  ┌──────────────┐    ┌────────────────────────────────────────────┐    │
│  │ SessionStart │───▶│ superboost-banner.sh                       │    │
│  │              │    │  1. Self-test (18 checks incl. checksum)   │    │
│  │              │    │  2. Live RAM/CPU/agent-capacity readout    │    │
│  │              │    │  3. Emits banner for Claude to display     │    │
│  └──────────────┘    └────────────────────────────────────────────┘    │
│                                                                         │
│  ┌──────────────┐    ┌────────────────────────────────────────────┐    │
│  │ PreToolUse   │───▶│ resource-check.sh --quiet                  │    │
│  │ (Agent)      │    │  → JSON: can_spawn, max_new_agents, reason │    │
│  │              │    │  → Exit 1 BLOCKS the spawn                 │    │
│  └──────────────┘    └────────────────────────────────────────────┘    │
│                                                                         │
│  ┌──────────────┐    ┌────────────────────────────────────────────┐    │
│  │ PreToolUse   │───▶│ resource-guard.sh                          │    │
│  │ (TeamCreate) │    │  (delegates to resource-check.sh)          │    │
│  └──────────────┘    └────────────────────────────────────────────┘    │
│                                                                         │
│  ┌──────────────┐    ┌────────────────────────────────────────────┐    │
│  │ PostToolUse  │───▶│ ram-monitor.sh (5s timeout)                │    │
│  │ (every call) │    │  → ~/.claude/logs/ram-monitor.log          │    │
│  └──────────────┘    └────────────────────────────────────────────┘    │
│                                                                         │
│  ┌──────────────┐    ┌────────────────────────────────────────────┐    │
│  │ statusLine   │───▶│ superboost-statusline.sh                   │    │
│  │ (continuous) │    │  ⚠ FAST │ RAM bar │ GB free │ agents │ mdl │    │
│  └──────────────┘    └────────────────────────────────────────────┘    │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    ~/.claude/CLAUDE.md (v3)                       │  │
│  │  § Auto-Router       → Solo vs. team routing + auto-mode gating   │  │
│  │  § Resource Mgmt     → OP Mode, wave execution, rate-limit zones  │  │
│  │  § Agent Dispatch    → Pre-Flight Q1/Q2 + Progress Bar injection  │  │
│  │  § Model Tiering     → opus/sonnet/haiku selection matrix  (NEW)  │  │
│  │  § Fast Mode         → /fast incompatibility rules         (NEW)  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    ~/.claude/superboost-version.json              │  │
│  │  version: 3.0.0                                                   │  │
│  │  model_baseline: {opus-4-7, 4-6-fast, sonnet-4-6, haiku-4-5}      │  │
│  │  scripts: {sha256 of each tracked hook}  (validated on boot)      │  │
│  │  blessed_at: <timestamp>  (run bless-hooks.sh to refresh)         │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Agent dispatch flow (v3)

```
 User request
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│ Fast mode active? (statusline shows ⚠ FAST)                  │
│   ├─ YES → solo only, warn user, skip Pre-Flight altogether │
│   └─ NO  → continue                                          │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│ Auto-Router: decompose streams, check dependencies          │
│   ├─ 1 stream or < 20 min  → Solo                            │
│   └─ 2+ independent streams & > 20 min → Team                │
└─────────────────────────────────────────────────────────────┘
     │                              │
     ▼                              ▼
   Solo                         resource-check.sh → can_spawn/max
                                    │
                                    ▼
                     ┌──────────────────────────────────────┐
                     │ Per-agent: choose model tier         │
                     │   synthesizer/judge → opus (4.7)     │
                     │   worker            → sonnet (4.6)   │
                     │   explorer          → haiku (4.5)    │
                     └──────────────────────────────────────┘
                                    │
                                    ▼
                     ┌──────────────────────────────────────┐
                     │ Pre-Flight Q1 (quality) + Q2 (tokens)│
                     │   Q2 prefers RICH context upfront    │
                     │   (1M ctx + prompt cache — v3 shift) │
                     └──────────────────────────────────────┘
                                    │
                                    ▼
                     ┌──────────────────────────────────────┐
                     │ Inject Progress Bar block verbatim    │
                     │ Call Agent({model, prompt})          │
                     └──────────────────────────────────────┘
```

---

## 4. Model tiering matrix

| Role | Model | Rationale |
|------|-------|-----------|
| Orchestrator / Synthesizer (MoA) | `opus` (4.7) | Merging N worker outputs needs long-context judgment |
| Judge (Judge Gate) | `opus` (4.7) | Verdict quality > verdict cost; don't cheap out |
| Reflector (between waves) | `opus` (4.7) | Must evaluate Wave N AND shape Wave N+1 prompts |
| Implementation worker | `sonnet` (4.6) | ~90% of Opus quality on scoped coding tasks, 3–5× cheaper |
| Read-only explorer / grep / file hunt | `haiku` (4.5) | Cheapest; perfect for mechanical "find X" work |
| Debater (adversarial hypothesis) | `sonnet` (4.6) | Independence > depth; cheaper = more voices |

**Never**: `opus` for grep-style work, `haiku` for synthesis/judgment (no extended thinking).

**Team economics**: 5 Opus agents = 5× rate burn for ≤5% quality gain over 4 Sonnet workers + 1 Opus synthesizer. The synthesizer pattern dominates.

---

## 5. Pre-Flight Q2 philosophy (v3 shift)

v2 optimization levers assumed a small context window: trim file contents, trust agents to re-read. With Opus 4.7's 1M context + Anthropic prompt caching (5-min TTL), the math flipped:

**Main thread reads a file once → cached.**
**Spawning an agent that cold-reads the same file → uncached read.**

So the token-cheapest agent prompt is often the one that *includes* the relevant context, because the main thread already paid for the read and the cache is warm. The v3 table:

| Lever | v2 rule | v3 rule |
|-------|---------|---------|
| Context payload | Trim aggressively | Send rich context; only trim genuinely irrelevant material |
| Parallelism | Spawn N parallel workers | Prefer serial when sub-5-min per agent (cache stays warm) |
| Model tier | (unused) | Right-size per agent |

---

## 6. File inventory

| Path | Purpose | v3 status |
|------|---------|-----------|
| `~/.claude/hooks/superboost-banner.sh` | SessionStart: self-test + banner | v3 — checksum validation added |
| `~/.claude/hooks/superboost-statusline.sh` | Continuous statusline | v3 — fast-mode flag added |
| `~/.claude/hooks/resource-check.sh` | Spawn gating (JSON output) | unchanged |
| `~/.claude/hooks/resource-guard.sh` | TeamCreate guard | unchanged |
| `~/.claude/hooks/ram-monitor.sh` | PostToolUse RAM logger | unchanged |
| `~/.claude/hooks/bless-hooks.sh` | Re-seed hook checksums | new in v3 |
| `~/.claude/CLAUDE.md` | Global rules (auto-router, OP mode, dispatch protocol) | v3 — model tiering + fast mode sections |
| `~/.claude/superboost-version.json` | Version manifest + sha256 checksums | v3 — aligned at 3.0.0, real hashes |
| `~/.claude/settings.json` | Hook bindings, plugins, permissions | unchanged |

---

## 7. Operational runbook

**After intentionally editing a hook:**
```bash
~/.claude/hooks/bless-hooks.sh
```
Regenerates sha256s in version.json; silences the drift warning on next session.

**Investigate a drift warning:**
```bash
cat ~/.claude/superboost-version.json | python3 -m json.tool
shasum -a 256 ~/.claude/hooks/*.sh
```
Compare; if the edit was intentional, bless. If not, restore from git or `.claude/backups/`.

**Check self-test without starting a session:**
```bash
~/.claude/hooks/superboost-banner.sh | head -20
```
Should show `18/18 checks passed` when healthy.

**Force resource check:**
```bash
~/.claude/hooks/resource-check.sh           # verbose
~/.claude/hooks/resource-check.sh --quiet   # JSON for scripting
```

---

## 8. Known limitations

1. **Fast-mode detection is heuristic** — statusline checks the model name for "4.6". If a user explicitly picks Opus 4.6 (not via `/fast`), they still get the ⚠ FAST flag even though extended thinking may actually be enabled. Acceptable false positive — the warning is still correct: Pre-Flight "think deeply" is weaker on 4.6.
2. **Checksum validation only covers tracked hooks** — other files in `~/.claude/` (plugins, skills, MCP configs) aren't verified.
3. **Rate-limit zones (CLAUDE.md § Resource Management) use hardcoded thresholds** — not parameterized per model tier. Opus 4.7 has a different tier than Sonnet 4.6; a fully correct calculation would track per-tier budgets.
4. **Expertise report is a snapshot** — not regenerated automatically. Treat as v3.0 baseline documentation, not live state.

---

## 9. Version history

| Version | Date | Key change |
|---------|------|------------|
| 1.1.0 | 2026-03-07 | Initial architecture report |
| 1.3.0 | 2026-03-08 | Installed hooks + benchmark framework |
| 2.0 | (banner only — json never synced) | Agent Dispatch Protocol + Pre-Flight Optimization |
| **3.0.0** | **2026-04-17** | **Opus 4.7 alignment — model tiering, checksum validation, fast-mode warning, version coherence** |
