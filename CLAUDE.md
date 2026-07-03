# Superboost v3.0 — Global Configuration

Everything in this file is part of Superboost v3.0. It activates automatically when the SessionStart hook (`~/.claude/hooks/superboost-banner.sh`) fires — you'll see "SUPERBOOST SESSION START" in your system context. If that message is NOT present, Superboost is not installed/active and you should IGNORE all rules in this file.

**Activation check:** If your system context contains "SUPERBOOST SESSION START", Superboost v3 is active. All rules below apply. If it does not, skip everything below.

**v3 upgrade (Apr 2026):** Aligned with Opus 4.7 as the default model. Adds model-tiering for agent dispatch, inverts Pre-Flight Q2 context guidance for the 1M-context + prompt-caching era, and warns about `/fast` (Opus 4.6, no extended thinking) incompatibility with Pre-Flight Optimization.

---

## 1. Session Banner (MANDATORY)

The SessionStart hook runs a self-test (verifying all scripts, settings, and CLAUDE.md are intact) and outputs a formatted banner with version, boot check results, and live system stats. Display it exactly as provided in the hook output — do not reformat or re-run. The hook already ran; just show what it gave you as your first output.

If boot check shows failures or warnings, mention them to the user so they can fix the installation.

If the hook output is missing or you need fresh stats mid-session, run `~/.claude/hooks/resource-check.sh` and format:

```
⚡ ISYNCSO SUPERBOOST V3.0
Boot: [result] | RAM: [X] GB free / [Y] GB | CPU: [load] | Agents: up to [N] | Status: [STATUS]
```

---

## 2. Auto-Router (MANDATORY)

Before starting ANY non-trivial task, evaluate whether to work solo or spawn a team.

### Route Decision (run mentally, show result)

1. **Decompose**: List the independent workstreams this task requires.
   - Different directories/modules = separate streams
   - Research + implementation = separate streams
   - Frontend + backend + tests = separate streams
2. **Count**: How many truly independent streams? (streams that don't need each other's output)
3. **Check dependencies**: Would stream B need stream A's output before starting?
4. **Estimate scope**: Would solo work take > 20 minutes?
5. **Check resources**: Run `~/.claude/hooks/resource-check.sh` and read `max_new_agents`.
6. **Check OP eligibility**: Does the task qualify for MoA, Judge Gate, or Reflection? (see OP Mode below)
7. **Check Auto-Mode eligibility**: Should the session run with `--auto-mode`? (see Auto-Mode Decision below)

### Auto-Mode Decision

Auto-mode (`mode: "auto"` on agents, or recommending `--auto-mode` for the session) lets Claude bypass permission prompts for faster execution. The router MUST evaluate whether this is safe.

**Auto-Mode Safety Checklist** (ALL must be true to enable):

| # | Criterion | Description |
|---|-----------|-------------|
| 1 | **No irreversible external actions** | No git push, no PR creation, no deployment, no sending messages/emails, no deleting branches |
| 2 | **No secret/credential exposure risk** | Task doesn't involve `.env` files, API keys, tokens, or auth config |
| 3 | **Scope is well-defined** | Task has clear boundaries — not open-ended exploration that could spiral |
| 4 | **Files are version-controlled** | All affected files are in git — changes can be reverted with `git checkout` |
| 5 | **No protected files** | Task doesn't touch calculator-locked files or other protected resources |
| 6 | **No destructive DB operations** | No DROP, TRUNCATE, DELETE without WHERE, or schema-breaking migrations |
| 7 | **User trust signal** | User said "just do it", "go ahead", "handle it", or has established autonomous workflow preference |

**Scoring**:
- 7/7 criteria met → ✅ **Auto-mode recommended**
- 5-6/7 met → ⚡ **Auto-mode eligible** — mention the risks, let user decide
- < 5/7 met → 🛑 **Manual mode** — too risky, keep human checkpoints

**Auto-mode is ON by default** (configured in `settings.json` as `defaultMode: "auto"`). The router's job is to **downgrade to manual** when the task is risky:

- **Safe tasks (7/7)**: Stay in auto mode — proceed without permission prompts on file edits, test runs, builds
- **Borderline tasks (5-6/7)**: Warn the user which criteria failed, recommend staying auto or switching
- **Risky tasks (<5/7)**: **Actively pause and tell the user** before proceeding — treat as manual checkpoints even though auto-mode is on. Use explicit confirmation questions before irreversible actions.
- **Team agents**: Set `mode: "auto"` on spawned agents for safe tasks, `mode: "default"` for risky ones

### Output format (ALWAYS show to user before starting work)

Solo:
> 🔀 **Solo** | 🤖 **Auto** — [one-line reason]

Solo (manual):
> 🔀 **Solo** | 🧑‍✈️ **Manual** — [one-line reason, e.g. "touches .env + deploys"]

Team:
> 🔀 **Team of [N]** | 🤖 **Auto** — [one-line reason]
> | Agent | Role | Owns | Task |
> |---|---|---|---|
> | coder-1 | Frontend | src/components/ | Build login form |
> | coder-2 | Backend | src/api/ | Auth endpoint |
> | tester | Tests | tests/ | Auth test suite |

Team (manual):
> 🔀 **Team of [N]** | 🧑‍✈️ **Manual** — [one-line reason, includes why manual]
> | Agent | Role | Owns | Task |
> |---|---|---|---|

Team with OP Mode:
> 🔀 **Team of [N]** | 🤖 **Auto** — [one-line reason]
> ⚡ **OP Mode**: MoA on [subtask], Judge Gate active, Reflection between waves
> | Agent | Role | Owns | Task |
> |---|---|---|---|

### Decision Matrix

| Independent streams | Solo time estimate | OP Features | Auto-Mode | Decision |
|---|---|---|---|---|
| 1 | Any | — | If 7/7 safe | **Solo** — no parallelism benefit |
| 2 | < 20 min | — | If 7/7 safe | **Solo** — overhead not worth it |
| 2 | > 20 min | — | If 5+/7 safe | **Small team (2)** — if resources allow |
| 3-5 | Any | +Judge | If 5+/7 safe | **Team (3-4)** + Judge |
| 3-5 | Critical task | +MoA +Judge | 🛑 Manual | **Team (3-4)** + MoA on key subtasks + Judge |
| 5-9 independent | > 30 min | +Judge +Reflection | 🛑 Manual | **Team (4-6)** + Judge + Reflection between waves |
| 10+ independent | Any | +All OP | 🛑 Manual | **Wave execution** with MoA + Reflection + Judge |
| Competing hypotheses | Any | — | If 5+/7 safe | **Debate team (3)** — use debate protocol |

### Rules
- Default to solo. Teams have overhead — only spawn when the speedup clearly outweighs it.
- Never spawn a team just because a task is "big." Big sequential tasks are still solo.
- If you're unsure, start solo and escalate to a team if you discover independent workstreams mid-task.
- Always check resources before spawning. If max_new_agents < team size, reduce or go solo.
- OP features are additive — only activate the ones the task qualifies for.
- ALWAYS show the 🔀 routing decision (including auto/manual) to the user before starting any task. This is mandatory.
- **Auto-mode is ON by default.** The router's job is to downgrade to manual when needed, not to upgrade.
- **Never auto-mode with external side effects.** If the task involves push, deploy, send, delete, or any action visible outside the local repo — force manual mode regardless of other criteria.
- **Downgrade mid-task.** If you discover the task needs an irreversible action you didn't anticipate, switch from auto to manual immediately and inform the user.

---

## 3. Resource Management

Before spawning agents, run `~/.claude/hooks/resource-check.sh`. It returns JSON:
- `can_spawn`: Boolean. If `false`, do NOT spawn — report `reason` to user, work solo.
- `max_new_agents`: Max agents you can spawn. Your team MUST NOT exceed this.
- `available_ram_mb`: Below 2000 = do not spawn. `cpu_load`: Above 20 = do not spawn.

### Overpowered Mode (OP Mode)

Advanced coordination features for qualifying tasks. Each is independent — activate only those that apply.

**MoA (Mixture of Agents)**: Multiple agents independently solve the same subtask, then a Synthesizer merges the best elements. Activate when a subtask involves architecture decisions with multiple valid approaches, security-critical code, or complex algorithms. Apply per-subtask, not team-wide. Cost: N+1 slots (N workers + synthesizer).

**Judge Gate**: One agent reserved as Judge. Runs AFTER all workers complete, reviewing for correctness, consistency, and quality. Activate when team size >= 3 or task is critical. Judge evaluates — it does not produce code. Verdict: PASS (deliver), REVISE (fix + re-judge, max 2 rounds), REJECT (re-plan, max 1).

**Reflection Pass**: One agent reserved as Reflector between waves. Reviews Wave N outputs and feeds improvement notes into Wave N+1 prompts. Activate during wave execution (2+ waves). Decision: PROCEED / RE-RUN / ESCALATE.

**Resource math**: `total_slots = workers + (has_judge ? 1 : 0) + (moa_subtasks * 2) + (waves > 1 ? 1 : 0)`. If over budget, shed: MoA first, then Reflection, then Judge (last to go).

### Team Sizing and Rate Limits

Rate limits are SHARED. Calculate: `effective_msgs = total_budget / total_slots`

| effective_msgs | Zone | Action |
|---|---|---|
| 100+ | COMFORTABLE | Full team, full OP features |
| 60-100 | CAUTION | Cap per-agent tasks at 3-4, drop MoA |
| 40-60 | DANGER | Reduce team, Judge only |
| < 40 | CRITICAL | Solo or minimal team, no OP features |

Prefer 3 agents x 5 tasks over 5 agents x 3 tasks. Coordination overhead scales quadratically.

### Wave Execution

Use when tasks > agent slots or full team would hit DANGER zone.

1. Group tasks into waves (max `max_new_agents` per wave). Independent first, dependent later.
2. Spawn Wave 1 — assign 2-3 tasks per agent with file ownership. Wait for completion. Shut down.
3. If 2+ waves: activate Reflection Pass between waves — Reflector reviews, writes improvement notes.
4. Spawn Wave 2 with fresh agents, include Wave 1 results + Reflector notes. Repeat until done.

### Debugging Protocol

When investigating bugs with multiple possible causes:
1. Spawn read-only investigator agents (one per hypothesis)
2. Each investigator explores but does NOT modify code
3. Coordinator collects findings, identifies root cause
4. Single fixer agent applies the solution

---

## 4. Agent Dispatch Protocol (MANDATORY — every agent, every session)

This is the core Superboost v3 agent quality system. It applies to EVERY agent you spawn via the Agent tool — regardless of type (general-purpose, Explore, Plan, code-reviewer, or any custom/plugin agent). Agents do NOT inherit CLAUDE.md, so you MUST enforce these rules by injecting them into every agent's prompt. No exceptions. Skipping this protocol is a hard error.

### Step 1: Pre-Flight Optimization (BEFORE spawning — think hard)

Before dispatching ANY agent, STOP. Do not call the Agent tool yet. Use extended thinking — `alwaysThinkingEnabled: true` is set in settings, so thinking is always on (except in `/fast` mode — see Fast Mode note below). Answer two questions, then show the result to the user.

**Q1: Are these the best possible instructions for the best possible outcome?**

Think deeply:
- Is the task description precise enough? Would a fresh agent misunderstand anything?
- Are success criteria explicit? Does the agent know what "done" looks like?
- Is necessary context included (file paths, constraints, patterns to follow)?
- Are there edge cases or gotchas the agent should know about upfront?
- Would splitting or merging tasks produce a better result?
- Is the agent type (general-purpose, Explore, Plan, etc.) the right choice?

**Q2: Can we improve efficiency (tokens, time) WITHOUT sacrificing quality?**

Evaluate and optimize — but ONLY apply changes that are quality-neutral or quality-positive:

| Lever | Consider | Change only if... |
|-------|----------|-------------------|
| **Prompt format** | Would structured format (XML/YAML/JSON) reduce ambiguity vs prose? | It makes instructions clearer AND shorter |
| **Prompt length** | Are there redundant sentences, filler words, or repeated context? | Removing them doesn't lose information |
| **Task scope** | Is the agent doing work it doesn't need to? (e.g., reading files it won't use) | Narrowing scope doesn't risk missing context |
| **Context payload** | Are we sending redundant context vs. letting the agent re-read the same files? | Under Opus 4.7 (1M context + prompt caching), PREFER sending rich context upfront. Main-thread reads become cache hits; agent cold-reads don't. Trim only genuinely irrelevant context, not potentially-useful context. This inverts the V2 guidance. |
| **Output instructions** | Are we asking for verbose output when concise would do? | Less output doesn't lose actionable info |
| **Agent type** | Would a lighter agent (Explore vs general-purpose) suffice? | The lighter agent has all needed tools |
| **Model tier** | Does this agent need Opus, or would Sonnet/Haiku suffice? | See Model Tiering table below. Default workers to Sonnet; reserve Opus for orchestration/synthesis/judgment |
| **Parallelism** | Could one agent do what we planned for two? Or vice versa? | Merging/splitting improves token efficiency. With prompt caching, 2+ serial agents in-session beat 2+ parallel (cache warms between them) |

**Quality is sacred.** Never degrade outcome quality to save tokens. Only optimize when the change is free or improves quality. If there's any risk to quality, keep the original.

**Show your work** — display this to the user before every agent spawn:

```
🔍 PRE-FLIGHT — [agent name/role]
Q1 (quality): [1-2 sentence verdict — what you improved or confirmed]
Q2 (efficiency): [1-2 sentence verdict — what you optimized or "no changes, already lean"]
Dispatching agent...
```

When spawning multiple agents in parallel, show one pre-flight block per agent.

### Step 2: Inject Progress Bar (into every agent's prompt)

After pre-flight passes, you MUST append the following block VERBATIM to the END of every agent's prompt. Do not summarize, paraphrase, or omit. Copy-paste exactly:

```
--- PROGRESS BAR (MANDATORY) ---
You MUST follow this progress tracking protocol exactly:

1. BEFORE starting work, list all tasks you will complete as a numbered list.
2. AFTER completing each task, output a progress bar in this exact format:

   ▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░ 50% (3/6) ✅ Task just completed → Next: upcoming task

   Rules for the bar:
   - ▓ = completed portion, ░ = remaining portion
   - Bar is ALWAYS 20 characters wide
   - Show percentage, completed/total count
   - Show what was just done (✅) and what's next (→)

3. Show the progress bar AFTER each meaningful step — not just at start and end.
4. Your final output must include:

   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 100% (N/N) ✅ All tasks complete

5. If you discover additional tasks mid-work, update the total and recalculate.
--- END PROGRESS BAR ---
```

### Step 3: Dispatch

Only NOW call the Agent tool with the optimized prompt + injected progress bar.

### Enforcement Checklist (run mentally before EVERY Agent tool call)

- [ ] Pre-flight Q1+Q2 completed and shown to user?
- [ ] Progress bar block appended verbatim to the prompt?
- [ ] Agent type is the right fit for the task?
- [ ] Model tier chosen deliberately (see Model Tiering below)?
- [ ] Resource check passed (if spawning a team)?

If any box is unchecked, do NOT dispatch. Fix it first.

### Model Tiering (Opus 4.7 era — v3)

Pass `model: "opus" | "sonnet" | "haiku"` to the Agent tool to pick the right tier. Default behavior (no override) inherits from the parent session — usually Opus 4.7, which is overkill for most workers and burns the rate budget fast.

| Role | Model | Why |
|------|-------|-----|
| Orchestrator / Synthesizer (MoA) | `opus` (4.7) | Merging multiple worker outputs needs judgment + long-context reasoning |
| Judge (Judge Gate) | `opus` (4.7) | Verdict quality is critical — don't cheap out |
| Reflector (between waves) | `opus` (4.7) | Needs to evaluate quality of Wave N and shape Wave N+1 prompts |
| Implementation worker | `sonnet` (4.6) | Fast, cheap, handles well-scoped coding tasks at ~90% of Opus quality |
| Read-only explorer / researcher | `haiku` (4.5) | Cheapest; perfect for "find X", "grep Y", "list Z" work |
| Debater (adversarial hypothesis) | `sonnet` (4.6) | Independence matters more than depth; cheaper = more debaters possible |

**Rules**:
- Never use `opus` for read-only exploration or mechanical codegen — waste.
- Never use `haiku` for synthesis, judgment, or tasks requiring long-chain reasoning.
- When team size > 3, prefer `sonnet` workers + `opus` synthesizer. A team of 5 Opus agents burns 5× the rate budget of 4 Sonnet + 1 Opus for near-identical quality.
- Extended thinking is available on Opus and Sonnet, NOT Haiku. If you need `/think`-style reasoning in an agent, it must be Opus or Sonnet.

### Fast Mode (`/fast`) — Not Compatible with Pre-Flight Optimization

`/fast` switches the session to Opus 4.6 without extended thinking. This breaks Pre-Flight Optimization (Q1/Q2 require "think deeply"). When `/fast` is active:

- **Do NOT dispatch agents.** Work solo only. The router downgrades to "🔀 Solo | Manual" automatically.
- **Show this warning to the user** if they request team work: "Fast mode disables extended thinking — Pre-Flight Optimization would be shallow. Exit fast mode (`/fast` again to toggle) or proceed solo?"
- **Still show the routing decision** — just note "⚡ Fast mode: solo only".

### Why This Exists
Agents are blank slates — they don't read CLAUDE.md. The ONLY way to enforce rules on agents is to inject them into the prompt. This protocol ensures every agent gets optimized instructions and shows progress. Without it, agents run blind and the user has no visibility.
