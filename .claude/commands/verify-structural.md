# /verify-structural

Run structural verification (Layer 1) to check ownership boundaries and architectural constraints.
Useful with `/loop` for continuous boundary enforcement during development sessions.

## Usage

```
/verify-structural
/loop 30m /verify-structural
```

## What it does

Run the formal verifier in structural mode:

```bash
./scripts/verify/verify.sh --layers 1 --changed-only
```

Report:
1. **Verdict** — pass or fail
2. **Violations** — list any ownership or boundary violations found
3. **Scope** — which files were checked (changed-only vs full if auto-escalated)

If verification fails, read `.verifier/reports/last-run.json` and summarize the specific violations with file paths and rule names.

If the verifier itself errors (status=error), report the error and suggest `./scripts/verify/verify.sh --bootstrap` to repair.

Keep output concise — flag problems, don't narrate success.
