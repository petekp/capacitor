---- MODULE SessionProjectionHysteresis ----
EXTENDS Integers

CONSTANT
  \* @type: Int;
  EmptyThreshold,
  \* @type: Int;
  IdleThreshold

VARIABLES
  \* @type: Int;
  consecutiveEmpty,
  \* @type: Bool;
  hasVisibleState,
  \* @type: Bool;
  emptyCommitted,
  \* @type: Int;
  consecutiveIdle,
  \* @type: Bool;
  previousActive,
  \* @type: Bool;
  idleCommitted

Init ==
  /\ consecutiveEmpty = 0
  /\ hasVisibleState = TRUE
  /\ emptyCommitted = FALSE
  /\ consecutiveIdle = 0
  /\ previousActive = TRUE
  /\ idleCommitted = FALSE

ReceiveEmptyHold ==
  /\ hasVisibleState
  /\ consecutiveEmpty + 1 < EmptyThreshold
  /\ consecutiveEmpty' = consecutiveEmpty + 1
  /\ hasVisibleState' = TRUE
  /\ emptyCommitted' = FALSE
  /\ UNCHANGED <<consecutiveIdle, previousActive, idleCommitted>>

ReceiveEmptyCommit ==
  /\ hasVisibleState
  /\ consecutiveEmpty + 1 >= EmptyThreshold
  /\ consecutiveEmpty' = 0
  /\ hasVisibleState' = FALSE
  /\ emptyCommitted' = TRUE
  /\ UNCHANGED <<consecutiveIdle, previousActive, idleCommitted>>

ReceiveNonEmpty ==
  /\ consecutiveEmpty' = 0
  /\ hasVisibleState' = TRUE
  /\ emptyCommitted' = FALSE
  /\ UNCHANGED <<consecutiveIdle, previousActive, idleCommitted>>

ReceiveIdleHold ==
  /\ previousActive
  /\ consecutiveIdle + 1 < IdleThreshold
  /\ consecutiveIdle' = consecutiveIdle + 1
  /\ previousActive' = TRUE
  /\ idleCommitted' = FALSE
  /\ UNCHANGED <<consecutiveEmpty, hasVisibleState, emptyCommitted>>

ReceiveIdleCommit ==
  /\ previousActive
  /\ consecutiveIdle + 1 >= IdleThreshold
  /\ consecutiveIdle' = 0
  /\ previousActive' = FALSE
  /\ idleCommitted' = TRUE
  /\ UNCHANGED <<consecutiveEmpty, hasVisibleState, emptyCommitted>>

ReceiveActive ==
  /\ consecutiveIdle' = 0
  /\ previousActive' = TRUE
  /\ idleCommitted' = FALSE
  /\ UNCHANGED <<consecutiveEmpty, hasVisibleState, emptyCommitted>>

Next ==
  ReceiveEmptyHold
  \/ ReceiveEmptyCommit
  \/ ReceiveNonEmpty
  \/ ReceiveIdleHold
  \/ ReceiveIdleCommit
  \/ ReceiveActive

TypeInvariant ==
  /\ consecutiveEmpty \in 0..EmptyThreshold
  /\ consecutiveIdle \in 0..IdleThreshold
  /\ hasVisibleState \in BOOLEAN
  /\ emptyCommitted \in BOOLEAN
  /\ previousActive \in BOOLEAN
  /\ idleCommitted \in BOOLEAN

EmptyCommitShape ==
  emptyCommitted => ~hasVisibleState

IdleCommitShape ==
  idleCommitted => ~previousActive

NoPrematureIdleCommit ==
  previousActive /\ consecutiveIdle < IdleThreshold => ~idleCommitted

Invariant ==
  /\ TypeInvariant
  /\ EmptyCommitShape
  /\ IdleCommitShape
  /\ NoPrematureIdleCommit

Spec == Init /\ [][Next]_<<consecutiveEmpty, hasVisibleState, emptyCommitted, consecutiveIdle, previousActive, idleCommitted>>

THEOREM Spec => []Invariant
====
