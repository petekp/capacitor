# /batch

Fan out parallel work across Codex workers for independent, same-layer changes.

## Usage

```
/batch <description of work>
```

## How it works

### Step 1: Decompose into slices

Read the work description and decompose it into independent slices. Each slice must:
- Be completable by a single worker without depending on another slice's output
- Stay within one architecture layer (Rust core OR Swift UI OR scripts — not across the FFI boundary)
- Have a clear success criterion

Present the slices to the user:

```
Proposed slices:
1. [slice-name] — description (scope: files)
2. [slice-name] — description (scope: files)
...

Ready to dispatch N workers in parallel?
```

### Step 2: Set up relay workspace

For each slice, create the dispatch structure:

```bash
BATCH_ROOT=".relay/batch-runs/<batch-name>"
mkdir -p "${BATCH_ROOT}/slices/<slice-name>/handoffs"
mkdir -p "${BATCH_ROOT}/slices/<slice-name>/last-messages"
```

Initialize batch.json using `scripts/relay/update-batch.sh`.

### Step 3: Write prompt headers

For each slice, write a self-contained prompt header at `${BATCH_ROOT}/slices/<slice-name>/prompt-header.md` with:
- Mission: what this specific slice must accomplish
- Scope: which files to modify (and which NOT to)
- Success criteria: how to verify the slice is done
- Boundary: explicit statement of what is OUT of scope for this slice

### Step 4: Compose and dispatch in parallel

```bash
for slice in ${BATCH_ROOT}/slices/*/; do
  ./scripts/relay/compose-prompt.sh \
    --header "${slice}/prompt-header.md" \
    --skills <domain-skills> \
    --root "${slice}" \
    --out "${slice}/prompt.md"
done

# Parallel dispatch (Codex backend)
for slice in ${BATCH_ROOT}/slices/*/; do
  name=$(basename "$slice")
  ./scripts/relay/dispatch.sh \
    --prompt "${slice}/prompt.md" \
    --output "${slice}/last-messages/last-message.txt" &
done
wait
```

### Step 5: Collect and report

After all workers complete:
1. Check each slice's handoff for `### Completion Claim`
2. Run verification commands from each slice
3. Report:
   - **Completed:** slices that finished successfully
   - **Partial:** slices that need follow-up
   - **Failed:** slices that couldn't complete

## Important constraints

- **Never batch across the FFI boundary.** Rust type changes → UniFFI regen → Swift bridge updates are inherently serial. Batch WITHIN a layer.
- **Workers must be independent.** If slice B needs slice A's output, they can't be parallel — use sequential dispatch instead.
- **Each slice gets its own worktree** when using Codex backend (automatic via `codex exec`).
- **Keep slices small.** A slice that touches >5 files is probably too broad. Split further.
- **Use `update-batch.sh`** for all state transitions — don't manually edit batch.json.
