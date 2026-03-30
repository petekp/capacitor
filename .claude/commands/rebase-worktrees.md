# /rebase-worktrees

Check all active Capacitor worktrees and report which are behind main.
Useful with `/loop` to catch merge conflicts early before they compound.

## Usage

```
/rebase-worktrees
/loop 1h /rebase-worktrees
```

## What it does

1. List all worktrees in `.worktrees/`:
```bash
git worktree list | grep '.worktrees/'
```

2. For each worktree, check if it's behind main:
```bash
# For each worktree branch
git log --oneline <branch>..main | wc -l
```

3. Report:
   - **Up to date** — worktrees that are current with main
   - **Behind** — worktrees that are N commits behind main (list the branch name and count)
   - **Conflict risk** — if any behind worktree touches files that main also changed, flag it

Do NOT automatically rebase — just report status. The developer decides when to rebase.

If no worktrees exist in `.worktrees/`, report "No active worktrees found" and exit.
