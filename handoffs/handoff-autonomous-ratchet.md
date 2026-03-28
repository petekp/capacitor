# Resume: Build method:autonomous-ratchet using the ratchet pattern itself

## Mission
Create `method:autonomous-ratchet` — a general-purpose method skill for autonomous overnight quality improvement runs. The method takes freeform instructions describing scope, goals, and quality bar, then executes a 6-phase ratcheting loop: Triage → Stabilize → Envision → Plan → Execute → Finalize. It is autonomous-only (user is away), uses manage-codex throughout, runs janitor after each batch, and injects additional steps at moderate-to-aggressive frequency when adversarial reviews or tests reveal quality gaps.

## Immediate First Action
Add the following tasks to your task list, then begin executing them in order. These tasks mirror the ratchet pattern itself — you're using the pattern to build the pattern.

### Task List

1. **Triage: Read the proposal and existing methods**
   - Read this handoff thoroughly
   - Read `~/.claude/skills/method/create/SKILL.md` (the compiler, 854 lines — just updated with AP-21 through AP-25 conciseness anti-patterns)
   - Read 2-3 existing methods for corpus calibration: `janitor` (693 lines, the most recently trimmed), `research-to-implementation` (646 lines), `decision-pressure-loop` (600 lines)
   - Produce: a triage report in your task notes covering what the proposal gets right, what's underspecified, and what's over-specified

2. **Explore improvements to the proposal**
   - Compare the 6-phase topology against the existing corpus — does it fit the artifact-centric family?
   - Evaluate whether the autonomous step-injection mechanism is well-enough defined to be actionable
   - Consider: how does the method handle context window exhaustion mid-run? Each phase needs resume artifacts.
   - Consider: how does the method know what "taste" and "slop sensitivity" mean in a given domain? The triage step must produce enough domain context for downstream adversarial reviewers.
   - Consider: should the Envision phase (explore + propose + adversarial review) use a 2-worker or 3-worker dispatch, or sequential steps?
   - Consider: the Execute phase uses manage-codex — how does the method compose with the existing manage-codex adapter seam contract?
   - Produce: improvement notes

3. **Propose a revised topology**
   - Write a concrete revised proposal with:
     - Phase/step inventory (IDs, titles, actions, artifacts, gates)
     - Artifact chain
     - Adapter seam contracts (manage-codex)
     - Autonomous step injection rules (when, how, ceiling)
     - Resume awareness design
     - The "taste calibration" mechanism (how triage informs adversarial reviews)
   - Save to `.relay/method-runs/autonomous-ratchet-method-create/artifacts/topology-proposal.md`

4. **Adversarial review of the topology proposal**
   - Dispatch a Codex worker to review the proposal for:
     - Missing gates or weak gates (AP-10)
     - Underspecified adapter seams
     - Resume gaps (what if context dies mid-Phase 5?)
     - Whether the step-injection mechanism creates unbounded loops
     - Whether the method is actually general-purpose or secretly hardcoded to one domain
     - Taste/quality criteria: are the adversarial review prompts specific enough to catch shallow work?
   - Save findings

5. **Revise topology based on review**
   - Address every finding from the adversarial review
   - Produce revised topology proposal
   - If the review recommended additional design steps, evaluate and add them before proceeding

6. **Compile with method:create**
   - Invoke `method:create` with the revised topology as the workflow source
   - The compiler will handle: intake (from the revised topology), analysis, authoring, validation, refinement
   - method:create will now enforce AP-21–25 (the conciseness anti-patterns we just installed)
   - The compiled method should be ~600-750 lines based on corpus norms

7. **Test with method:dry-run**
   - Run `method:dry-run` on the compiled method
   - Verify: resume awareness works, artifact chain is complete, adapter seams are concrete, gates are bounded

8. **Fix any issues from dry-run**
   - Address findings from dry-run
   - Re-run dry-run to verify fixes

9. **Final cleanup**
   - Run janitor on the method directory if needed
   - Verify line count is proportional to complexity (target: 600-750)
   - Prepare the updated method for the user's review

10. **Add any additional ratchet steps you identify**
    - At every step above, if you find quality gaps or opportunities, add tasks to your task list
    - This is the "moderate-to-aggressive" step injection in action

## Proposal Context (from the prior session)

### The User's Original Pattern
The user routinely writes 16-step overnight task lists like:
```
fix → test → fix → explore → propose → adversarial review → revise
→ plan → adversarial review → revise → implement → test → fix
→ ratchet → janitor → prep PR
```
This decomposes into 3 nested loops:
1. Fix loop: fix → test → fix residuals
2. Design loop: explore → propose → adversarially review → revise → plan → adversarially review → revise
3. Ship loop: implement → test → fix → ratchet → janitor → prep PR

### Proposed 6-Phase Topology
```
Phase 1: Triage         — Understand scope, current state, domain context
Phase 2: Stabilize      — Fix known issues, test, cleanup (manage-codex)
Phase 3: Envision       — Explore improvements, propose, adversarial review, revise
Phase 4: Plan           — Create impl plan, adversarial review, revise
Phase 5: Execute        — Implement in slices, janitor after each batch, test, fix
Phase 6: Finalize       — Final ratchet pass, prep branch for PR
```

### Design Decisions Already Made
- **Autonomous-only**: No interactive checkpoints. User is away (sleeping).
- **General-purpose**: Scope defined by freeform invocation instructions, not hardcoded to any domain.
- **No fixed reference product**: Triage step infers appropriate design influences from domain context.
- **Janitor after each batch**: Not just at the end.
- **Moderate-to-aggressive step injection**: After adversarial reviews AND test steps, evaluate whether to add steps for quality gaps.
- **Scope ceiling**: Defined at invocation time.

### Autonomous Step Injection Design (Needs Refinement)
The mechanism: after every adversarial review step and every test step, the reviewer/tester can output a "Recommended Additional Steps" section. The orchestrator evaluates these and inserts them if they meet the bar: "addresses a quality gap that the current plan doesn't cover." The ceiling: no more than 3 injected steps per phase (prevents unbounded loops).

### The "Taste Calibration" Problem
The user's prompts use phrases like "deep level of taste", "keen attention to detail", "sensitive to AI slop." These need to become concrete in the method. The triage step should produce a "Quality Calibration" section that names:
- The domain (design tool, CLI, data pipeline, etc.)
- Appropriate design influences for that domain
- Specific anti-patterns to watch for (generic gradients, placeholder content, shallow hover states, etc.)
- The user's stated quality bar
This calibration section feeds into every adversarial review prompt downstream.

## Key Artifacts
- `~/.claude/skills/method/create/SKILL.md` — the compiler (854 lines, just updated with AP-21–25)
- `~/.claude/skills/method/create/method.yaml` — compiler topology (108 lines)
- `~/.claude/skills/method/janitor/SKILL.md` — reference for a recently trimmed method (693 lines)
- `.relay/method-runs/janitor-method-create/artifacts/adversarial-review.md` — the adversarial review that produced the conciseness lessons (518 lines)
- `.relay/method-create-update/batch.json` — the manage-codex batch that applied the conciseness update (completed)
- `.relay/method-create-update/review-findings/review-findings-update-skill-md.md` — the clean review

## Project Rules
- Use `manage-codex` to dispatch implementation — never code directly in conversation
- Never use zsh globs or `||` chains to verify worker output; use `test -f`
- Worker prompts must encode the implementation boundary explicitly
- All method skills live under `~/.claude/skills/method/` with `method:` prefix
- User has ADHD — keep status updates concise, lead with the action

## Established Decisions
- Name: `method:autonomous-ratchet` (autonomous-only, quality ratcheting pattern)
- Family: artifact-centric (produces durable artifacts at every phase)
- Target line count: 600-750 (proportional to corpus norms for this complexity)
- method:create will be used to compile the final method (not hand-authored)
- AP-21–25 conciseness rules are now enforced by method:create

## Notes for the Next Agent
- This is self-referential: you're using the ratchet pattern (triage → explore → review → revise → implement → test) to build the ratchet method. Lean into it.
- The method:create compiler's validation worker now checks for AP-21–25 (conciseness). Your compiled method will be held to these standards automatically.
- The hardest design problem is "taste calibration" — how the triage step produces enough domain context to make downstream adversarial reviews actually catch shallow work. Spend extra time on this.
- The second hardest problem is autonomous step injection bounds. Without a ceiling, the method could loop forever. With too tight a ceiling, it can't ratchet. The proposal suggests 3 injected steps per phase max — validate whether this is right.
- The method:router skill (61 lines) handles method routing — the user mentioned "use the method router skill" in their original overnight pattern. The compiled method should work with method:router.
- Read `~/.claude/skills/method/janitor/SKILL.md` as a reference — it's the most recently trimmed method and a good example of "right-sized" for the complexity.
