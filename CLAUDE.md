# Superboost v4.0 — Global Configuration

Everything in this file is part of Superboost v4.0. It activates when the SessionStart hook (`~/.claude/hooks/superboost-banner.sh`) fires — you'll see **"SUPERBOOST V4 ACTIVE"** in your system context.

**Activation check:** If your system context contains "SUPERBOOST V4 ACTIVE", these rules apply. If it does not, Superboost is not installed and you should IGNORE everything below.

**Design philosophy (v4):** Enforce with hooks, don't narrate with ceremony. Prefer the native harness (Workflow tool, agent teams, ultracode) over hand-rolled orchestration. Keep the machine safe and observable; keep the model focused on the task, not on rituals. v4 removed the mandatory banner render, the per-agent progress-bar injection, the printed Pre-Flight block, the OP-Mode/wave/rate-zone machinery, and the (obsolete) Fast-Mode rules that v3 carried.

---

## 1. Boot check (silent)

The SessionStart hook runs an install self-test (scripts present + executable, settings wired, checksums un-drifted) **silently**. On a clean boot it says so in one line — **do not render a banner**. Only if the self-test reports FAIL/WARN, surface those issues to the user so they can repair the install, then continue. That's it.

---

## 2. Auto-Router (solo vs. team)

Before a non-trivial task, quickly (internally) decide solo vs. parallel. **Default to solo.** Teams/workflows have overhead — only fan out when there are genuinely independent workstreams *and* the work is large enough to pay for the coordination.

- 1 independent stream, or < ~20 min of work → **solo**.
- 2+ independent streams that don't depend on each other's output, and non-trivial → consider the **Workflow tool** (see §4).
- Big *sequential* task → still solo. Size is not a reason to fan out; independence is.

You don't need to print a routing decision every time. Just make the call and go. Mention it only when you actually spawn parallel work.

---

## 3. Resource awareness

`resource-guard.sh` (PreToolUse on Agent/TeamCreate/Task/Workflow) blocks a spawn only when the machine genuinely can't take it (swap / low RAM / memory pressure). It's a **performance** guard, not a security one, and fails open on error so it can never lock you out. You don't have to think about it — it just prevents thrashing this laptop during heavy fan-out.

If you want a manual read: `~/.claude/hooks/resource-check.sh` (add `--quiet` for JSON).

---

## 4. Orchestration → use the native Workflow tool

For multi-agent work, use the **Workflow tool** — it handles concurrency capping (min(16, cores−2)), a shared token budget, resume, and a live `/workflows` progress UI. Don't hand-roll wave loops, rate-limit "zones", or progress bars; the harness does these better. Patterns worth composing (see the Workflow tool docs): pipeline fan-out, adversarial verify, judge panel, MoA (independent solvers → synthesizer), loop-until-dry.

- **MoA / synthesis** and **model-tiering** have no native auto-equivalent — those are where Superboost still adds value (see §5).
- For code-quality review of a diff, prefer `/code-review` (or `/code-review ultra`) over a hand-built judge.
- Sub-agents do **not** inherit this file. Put whatever they need directly in their prompt. Write good, specific prompts (clear task, success criteria, constraints, relevant paths) — that discipline matters; a printed ceremony announcing it does not.

---

## 5. Model Tiering (alias-only)

The Agent/Workflow `model` option accepts the aliases **`opus | sonnet | haiku`** only — you cannot pin a minor version, so never write "4.7"/"4.6" in guidance (it drifts and can't be passed).

| Role | Alias | Why |
|------|-------|-----|
| Orchestrator / synthesizer / judge | `opus` | Merging + judgment need the strongest reasoning |
| Implementation worker | `sonnet` | ~90% of Opus quality on scoped tasks, much cheaper |
| Read-only explorer / grep / file-hunt | `haiku` | Cheapest; ideal for mechanical "find X" work |

Rule of thumb: cheap explorers + Sonnet workers + one Opus synthesizer beats an all-Opus team on cost for near-identical quality. Omit the override to inherit the session model when unsure.

---

## 6. Safety (enforced, not narrated)

Auto-mode is on (`defaultMode: auto`), so permission prompts are suppressed — which is safe **because `safety-guard.sh` (PreToolUse on Bash/Write/Edit/MultiEdit) actually blocks the dangerous cases**: `rm -rf` of / or $HOME, disk formatting, fork bombs, `git push --force`, secret exfiltration over the network, and edits to calculator-locked files. It's deliberately conservative — ordinary `git push`, deploys, and SQL are allowed.

Still use judgment the hook can't encode:
- **Irreversible / outward-facing actions** (deploys, sending messages/emails, deleting remote branches, publishing) — confirm with the user first unless they've told you to proceed.
- **Secrets** live in the macOS keychain / git-ignored `.env`, referenced by name. Never paste a secret value into a file, a commit, or a sub-agent prompt.
- The config lives in git (`~/.claude`), so your edits are recoverable — but `git push` for it is a deliberate, user-authorized action.

---

## 7. First-boot credentials

User-specific credentials (API tokens/keys) are provisioned **once** and reused. On session start, `superboost-secrets.sh check` reports any *required* credential that isn't yet in the macOS keychain. If you see a **"SUPERBOOST FIRST-BOOT SETUP"** message listing missing credentials:

1. Ask the user for each missing value (one prompt is fine).
2. Store each — never write a secret into a file:
   - `~/.claude/hooks/superboost-secrets.sh set <name> <value>` (or the user runs `set <name>` for a hidden prompt so the value never enters chat).
3. Confirm with `~/.claude/hooks/superboost-secrets.sh list`.

After that, sessions read the fixed values silently. To USE a stored credential in a command, retrieve it by name, e.g. `TOKEN=$(~/.claude/hooks/superboost-secrets.sh get supabase-mgmt-token)`. Slots are defined in `~/.claude/superboost-secrets.json` (git-ignored; names only, never values).

## 8. Integrity

Hook scripts are sha256-tracked in `superboost-version.json`. The boot check warns on drift. After intentionally editing a hook, re-seed with `~/.claude/hooks/bless-hooks.sh`. This is drift-detection, not tamper-proofing — treat it as "did I change a hook and forget," not a security boundary.

---

*Superboost v4.0 · ISYNCSO · github.com/frogody/superboost-v4*
