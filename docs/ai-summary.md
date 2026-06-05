# AI summary — design rationale

Durable notes for the per-pane AI summary feature (the session subject + the
done/now/next "stand" line shown in the tmux status bar). This is the place to
start a revisit: it records *why* the design is shaped this way and which
approaches are already ruled out, so we measure and move forward instead of
re-deriving and re-trying dead ends.

> **Start every revisit by running the replay eval (see "How to evaluate"),
> before forming any hypothesis.** A screenshot or a stale `/tmp` summary will
> lead you to the wrong cause — that mistake has been made more than once here.
> Reproduce the bad subject from a real transcript first, *then* theorize.

It is **not** a changelog or a spec. The current *implementation* is documented
in the code comments and in `CLAUDE.md`; this doc holds only the cross-cutting,
slowly-evolving understanding that has no other home. When an open question is
resolved, fold the answer into the relevant section and delete the question —
keep this lean.

## Pipeline

```
agent hook  →  scripts/claude/status.sh  →  scripts/tmux-status.sh  ─┬─→ ctx.sh   (transcript → goal / recent / todos)
(per agent)    (adapter: state + payload)   (core: tab + summary)    ├─→ digest.sh (transcript → done/now/next signal)
                                                                     ├─→ summarise.sh (local LM: label | stand)
                                                                     └─→ strip_unbacked_done.sh (anti-invention gate)
```

- **Tab label** is state-only: `<emoji> <agent>`, driven by the hook state
  (start/working/permission/notify/done). Independent of the AI summary.
- **AI summary** has two channels with two different scopes (see invariants):
  - **subject** — the stable goal label. Derived from the *goal context*
    (`ctx` head + todos), held in `<agent>-subject-<pane>.txt`, used only as LM
    context (`AGENTMUX_SUBJECT`), never rendered as a tmux label.
  - **stand line** — the moving done/now/next, re-derived each refresh from
    `digest.sh` output piped through `summarise.sh` stand mode, written to
    `agentmux-status-<pane>.txt` and rendered by `summary_rows.sh`.
- Per-pane temp files (all under `/tmp`, keyed by pane id): `agentmux-status-*`
  (stand line), `agentmux-diag-*` (pipeline diagnostic), `<agent>-subject-*`
  (subject), `<agent>-substart-*` (digest start offset), `agentmux-sum-*.lock.d`
  (overlap lock), `agentmux-sum-*.ts` (refresh throttle stamp),
  `agentmux-sum-*.drift` (sustained-drift counter). The `start` hook clears all
  of them.

## Invariants

These are load-bearing. Breaking one reintroduces a failure below.

1. **Cosmetic-hook contract.** The summary path must never block the agent's
   turn and never write to stdout (hook stdout is injected into the agent's
   prompt context; a non-zero exit alters agent behaviour). All LM work is
   detached; the foreground exits 0 unconditionally.
2. **Degrade silently.** Every script prints nothing and exits 0 on any problem;
   callers keep their last good value rather than show an error or a worse label.
3. **Subject = goal (stable); stand line = current task (moving).** Two
   channels, two scopes. The subject names *what the session is about*; the
   subtask churn belongs in done/now/next.
4. **`recent` never feeds the subject.** Recent activity reliably narrows the
   goal to the latest action. Recent is for the drift probe and the stand line
   only.
5. **`head` = session start; `tail` = recent.** The stated goal lives at the
   opening of the transcript. Never bound the head window with a `tail` cap, or
   long sessions lose their goal.
6. **The subject is LM context only, never a rendered label.** So punctuation /
   junk inside it is harmless; only the stand line and tab label reach the
   screen. (This is why the subject can carry `plan:`/early prose freely.)
7. **Anti-invention.** The stand line must not fabricate milestones, generic
   domain-stereotyped steps, or a `done:` clause unbacked by file-mutation
   evidence (`strip_unbacked_done.sh` is the defence-in-depth gate). Read-only
   investigation is not "done".
8. **Third-party scope.** "another agent is doing X", "my other branch" etc. are
   background context, not the current activity.

## Failure taxonomy (ruled out — do not re-try)

| Approach | Why it fails |
|---|---|
| Append the fresh candidate to the subject | Accretes stale slices into "soup" (e.g. `modal focus ring; siteexit…; redirecting click handlers`). |
| Replace the subject on *any* drift (zero word-overlap) | A deep subgoal dive has no overlap with the goal, so the goal gets thrown away and replaced by the subtask. |
| Include `recent` in the subject context | Narrows the goal to the latest action (`tiptap editor` → `…init destroy race guard`; `…rangeerror repro test`). |
| Bound the head window with `tail -n N` | On a session longer than the cap, "head" returns the earliest of the *last* N lines — mid-session — so the real goal (stated at line ~1) is invisible. |
| Gate the summary refresh on a non-empty user prompt | Only UserPromptSubmit carries a prompt; during a long autonomous turn (PostToolUse-only) the summary freezes at the last prompt. Gate on the transcript instead. |

Current design instead: subject from goal context (head-from-start + todos, no
recent); replace only on **sustained** drift (hysteresis counter, then re-derive
from the goal context, not a recent slice); refresh on every working hook with a
time throttle for the prompt-less ones.

## Signal sources and their limits

- **First user message** — clearest cross-session goal statement; reliable when
  the session opens with intent. Captured via head-from-start.
- **TodoWrite task list** — strongest goal signal *for orchestration sessions*,
  but **absent in single-focus debugging/audit sessions** (verified: real locus
  sessions had zero TodoWrite calls). Never the *only* anchor.
- **Early head turns** — good goal proxy, but interleave early *assistant*
  investigation prose that is already subgoal-flavoured and can dilute the goal.
- **Recent tail** — current activity. Good for the stand line and the drift
  probe; toxic to the subject (invariant 4).

## How to evaluate (measure, don't theorize)

The reliable signal is **offline replay over real transcripts**, not the live
`/tmp` files (those are pane-keyed and hard to map back to a session) and not
screenshots.

1. Pick recent transcripts: `~/.claude*/projects/<encoded-project>/*.jsonl`
   (longest sessions are the most drift-prone).
2. For each, extract the stated goal (first substantive user message), then run
   the real pipeline: `ctx.sh <tp> 8 300 head`, `ctx.sh <tp> 12 120 todos`,
   `ctx.sh <tp> 6 400 tail`, compose the goal blob as `tmux-status.sh` does, and
   pipe through `summarise.sh 6 label`. Compare the produced subject to the goal.
3. Requires a reachable LM (`llm-config.sh` resolves the endpoint;
   `summarise.sh` no-ops if unreachable). Output is deterministic (temperature 0).

`SUMMARISE_SMOKE=1 scripts/summarise.sh` is the live prompt-regression check
(third-party scope + anti-invention). Per-script selftests are listed in
`CLAUDE.md`.

## Open questions

- **Pivot-following without narrowing.** The subject is goal-anchored and will
  not follow a genuine mid-session pivot ("forget that, now do X") in a session
  with no task list — early/head stays the anchor. A "recent *user-message*-only"
  re-derive on sustained drift could capture a real pivot without reintroducing
  tool-action narrowing.
- **Goal anchoring without a task list.** Most non-orchestration sessions have no
  TodoWrite. Is the first user message enough, or do we need to weight it
  explicitly over early assistant prose?
- **Local-model naming quality.** Input scoping matters more than the model, but
  the chosen instruct model is worth a periodic re-check against the replay eval.
