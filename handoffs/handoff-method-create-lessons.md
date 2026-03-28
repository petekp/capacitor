# Resume: Update method:create with janitor authoring lessons

## Mission
Use `manage-codex` to update `~/.claude/skills/method/create/SKILL.md` (829 lines) so that every future method authored by `method:create` avoids the redundancy and boilerplate patterns discovered during the `method:janitor` authoring + adversarial review cycle. The lessons are concrete, evidence-backed, and should become part of the compiler's quality contract.

## Immediate First Action
Dispatch a Codex worker via `manage-codex` to edit `~/.claude/skills/method/create/SKILL.md`, incorporating the specific lessons below into the existing Quality Gate Checklist, Anti-Pattern Catalog, and authoring instructions.

## What to Change in method:create

### 1. Add new anti-patterns to the Anti-Pattern Catalog

Add these after AP-20:

- **AP-21: Setup Duplicates Intake** — The Setup section lists runtime inputs that Step 1's interactive intake already captures. Keep runtime inputs in one place (the intake step). Setup should only contain `RUN_ROOT` creation and a forward reference to Step 1.
- **AP-22: Repeated Dispatch Shell Blocks** — Near-identical `compose-prompt.sh | codex exec --full-auto` blocks appear in every dispatch step. Show the full recipe once (first dispatch step), then reference it. Per-step blocks should only name the header path, skills, and template if non-default.
- **AP-23: Duplicate Readback Orders** — The same readback order (e.g., handoff-converge → batch.json → last slice) appears in both the adapter contract and a later summary. Keep it in one location (the adapter contract section).
- **AP-24: Standalone Verify Lines** — A `Verify: test -f ...` line that duplicates the gate check immediately below it. Every existence check should live in the gate, not also as a standalone line.
- **AP-25: Circuit Breaker Echoes Alternatives** — A "Good alternatives" list at the end that repeats the redirects already named in the circuit breaker bullets. Remove the echo list.

### 2. Add a "Conciseness Rules" section to the Authoring Checklist

After item 10 ("Cross-validate SKILL.md and method.yaml") and before item 11, add:

**10b. Apply conciseness rules:**
- Setup must not re-list inputs that Step 1 captures — forward-reference only
- The canonical header schema should be shown compressed (required section names + relay heading rule), not as a full markdown template
- Show the dispatch recipe (compose-prompt + codex exec) in full exactly once; subsequent steps reference it
- Tighten adapter seam contracts to required fields, not heredoc templates — keep child-root layout, required CHARTER sections, readback order, and escalation rule; cut the shell heredoc
- Remove standalone `Verify: test -f` lines — the gate owns existence checks
- Principles should not restate the intro or the dual-mode description in abstract form
- Body negative scope can reference frontmatter instead of repeating the full list

### 3. Add to the Quality Gate Checklist (Prose/YAML Consistency section)

Add this check:
- Verify total SKILL.md line count is proportional to method complexity. Comparable methods in the corpus: flow-audit-and-repair (593), research-to-implementation (646), spec-hardening (628), decision-pressure-loop (600). A method with similar topology should not exceed ~750 lines without justification. If it does, run the conciseness rules before shipping.

### 4. Update the Refinement step (Phase 5, Step 5)

Add to the refinement checklist (after item 5 "Cross-validate again"):

**5b. Conciseness pass** — Before installing, verify:
- No setup/intake duplication (AP-21)
- Dispatch recipe shown in full once only (AP-22)
- No duplicate readback orders (AP-23)
- No standalone verify lines (AP-24)
- No circuit breaker echo lists (AP-25)
- Canonical header schema is compressed, not templated
- SKILL.md line count is proportional to corpus norms

### 5. Update the Validation step (Phase 4, Step 4) prompt header

In the validation worker instructions, add to the list of anti-patterns to check:
- AP-21 through AP-25 (see full catalog)

Pay special attention to:
- AP-22 (Repeated Dispatch Shell Blocks) — count the number of full compose+exec blocks. More than one is a smell.
- AP-21 (Setup Duplicates Intake) — check if Setup lists runtime inputs that the intake step already collects.

## Evidence: The Janitor Authoring Cycle

### What happened
1. `method:create` compiled `method:janitor` — 5 phases, 8 steps, dual-mode, manage-codex adapter
2. The validation worker (Phase 4) caught 6 mechanical defects: AP-01, AP-03, AP-04, AP-06, AP-15, AP-17
3. After fixing those, the installed SKILL.md was 814 lines
4. An adversarial Codex review found ~120 lines of cuttable redundancy, recommending target of ~690
5. We trimmed to 693 lines (15% reduction) without losing any janitor-specific contract

### Specific patterns found
| Pattern | Lines wasted | Root cause |
|---------|-------------|------------|
| Setup re-listing intake inputs | ~10 | No forward-reference convention |
| Duplicate dual-mode explanation (intro + principles) | ~3 | No "state it once" rule |
| Full canonical header schema template | ~20 | Should be compressed to section names + relay heading rule |
| Repeated dispatch shell blocks (3x) | ~14 | No "show once, reference later" convention |
| Duplicate readback orders in Step 6 | ~5 | Same info in adapter contract and summary |
| Standalone Verify lines duplicating gates | ~2 | Gate should own existence checks |
| Good alternatives echoing circuit breaker | ~5 | Redundant redirect list |
| CHARTER heredoc ceremony | ~20 | Should be field list, not bash heredoc |
| Repeated negative scope (frontmatter + body) | ~3 | Body can reference frontmatter |

### What the adversarial review said was justified
- 5-category survey taxonomy (category-specific false-positive modes)
- 8-point dynamic usage proof checklist (the heart of the method)
- Batch/revert semantics in Step 6 (safety-critical)
- Deferred-review model for autonomous mode (makes auto mode trustworthy)
- Resume awareness (5-worker fanout + nested manage-codex state)

## Key Artifacts
- `~/.claude/skills/method/create/SKILL.md` — the file to edit (829 lines)
- `~/.claude/skills/method/create/method.yaml` — topology only, probably unchanged (108 lines)
- `.relay/method-runs/janitor-method-create/artifacts/adversarial-review.md` — full review with quotes and line references
- `.relay/method-runs/janitor-method-create/artifacts/validation-report.md` — the 6 mechanical defects found
- `~/.claude/skills/method/janitor/SKILL.md` — the trimmed result (693 lines) as a reference for what "right-sized" looks like

## Project Rules
- Use `manage-codex` to dispatch implementation — never code directly in conversation
- Never use zsh globs or `||` chains to verify worker output; use `test -f`
- Worker prompts must encode the implementation boundary explicitly
- All method skills live under `~/.claude/skills/method/` with `method:` prefix
- After editing method:create, run `method:dry-run` to validate the updated skill

## Established Decisions
- The 5 new anti-patterns (AP-21 through AP-25) are the right granularity — they name specific, observable patterns, not vague style preferences
- The conciseness rules belong in the authoring checklist AND the refinement step — they need to be checked at generation time and again at install time
- The validation worker needs to know about the new anti-patterns so it can flag them
- The line-count proportionality check is a soft guideline, not a hard gate — it triggers a conciseness review, not a rejection

## Notes for the Next Agent
- The adversarial review at `.relay/method-runs/janitor-method-create/artifacts/adversarial-review.md` has exact quotes and line references — use it as the evidence base for the worker prompt
- method:create is itself a method skill, so editing it is self-referential — be careful not to break the compiler while improving it
- The existing Quality Gate Checklist has 6 categories; the conciseness rules should integrate into existing categories (especially "Prose/YAML Consistency") rather than creating a 7th
- After the update, the new anti-patterns should be detectable by the validation worker in future method:create runs
- Consider whether method:create's own SKILL.md (829 lines) should also be trimmed — it may exhibit some of the same patterns it's now supposed to catch
