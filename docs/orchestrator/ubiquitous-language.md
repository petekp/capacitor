# Ubiquitous Language

## Core orchestration terms

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Project** | A normalized repository/workspace tracked by Capacitor. | Repo card, workspace item |
| **Project Key** | The durable encoded-path identity for a Project. | Display name, project title |
| **Orchestrator** | The single interactive Claude session representing one Project. | Main worker, assistant, chat |
| **Worker** | A headless `claude -p` execution unit for substantial delegated work in one Project. | Workstream, task runner |
| **Worker Session** | The Claude conversation identity used to resume a Worker. | Run, PID |
| **Run** | One launched or resumed process episode for a Worker. | Session |
| **Delegation Loop** | The validated vertical slice where one idea launches one Worker, pauses for review, and resumes. | Orchestrator mode |
| **Milestone** | A versioned checkpoint published by a Worker for review. | Proposal, draft |
| **Review** | A typed pending decision over a Milestone. | Modal state, interruption |
| **Decision** | The human response that resolves a Review. | Comment, note |
| **Artifact** | A durable file published by the Orchestrator or a Worker. | Temp output |
| **Journal** | The append-only runtime record of orchestration events. | Snapshot log |
| **Review Surface** | The UI surface that renders a pending Review. | Modal, web sandbox |
| **Worktree** | The git isolation unit used by a Worker. | Workstream |
| **Workstreams** | The legacy worktree CRUD feature slated for excision. | Worker system, orchestrator substrate |

## Identity and state terms

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Orchestrator Registration** | The explicit handshake that makes an interactive session the active Orchestrator for a Project. | Discovery, guess |
| **Orchestrator Liveness** | The runtime-owned judgment of whether the registered Orchestrator is still live and reconnectable. | Tab exists |
| **Review Needed** | A state where a Milestone has produced a pending Review and is waiting for a Decision. | Paused, blocked |
| **Restart Recovery** | Deterministic reconstruction of orchestration state after app or process restart. | Best effort resume |

## Relationships

- A **Project** has exactly one **Project Key**.
- A **Project** has at most one active **Orchestrator**.
- A **Project** may have zero or more active **Workers** in the target architecture.
- A **Worker** uses one **Worktree** while active.
- A **Worker** may span multiple **Runs** over one **Worker Session**.
- A **Worker** may publish one or more **Milestones**.
- A **Milestone** can create one pending **Review**.
- A **Decision** resolves one **Review**.
- The **Journal** records lifecycle transitions for **Orchestrators**, **Workers**, **Milestones**, and **Decisions**.

## Example dialogue

> **Dev:** "If the user asks the assistant to do some async work, do we create a new **Workstream**?"
>
> **Domain expert:** "No. The legacy **Workstreams** feature is separate. We create a **Worker**, and that **Worker** runs in a git **Worktree**."
>
> **Dev:** "Is the **Worker Session** the same thing as a **Run**?"
>
> **Domain expert:** "No. A **Worker Session** is the Claude conversation identity. A **Run** is one launched or resumed process episode for that Worker."
>
> **Dev:** "So when the user reviews a milestone and clicks approve, that produces a **Decision** that resumes the same **Worker Session**?"
>
> **Domain expert:** "Exactly. The **Review** is pending on the **Milestone**, the **Decision** resolves it, and the runtime records the transition in the **Journal**."

## Flagged ambiguities

- "workstream" was previously used near worktree- and worker-related conversations. This is ambiguous. Use **Worktree** for git isolation, **Worker** for delegated execution, and **Workstreams** only for the legacy feature slated for removal.
- "session" can mean either the interactive **Orchestrator** session or a **Worker Session**. Always qualify it.
- "delegation" and "orchestration" are related but distinct. **Delegation Loop** is the validated narrow slice; **Orchestrator** is the broader target architecture.
- "project name" and **Project Key** are distinct. The name is presentation; the key is durable identity.
