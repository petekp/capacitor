---- MODULE TerminalActivationCoordinator ----
EXTENDS Integers

VARIABLES
  \* @type: Int;
  latestID,
  \* @type: Int;
  processingID,
  \* @type: Bool;
  cancelled,
  \* @type: Int;
  emittedID

Init ==
  /\ latestID = 0
  /\ processingID = 0
  /\ cancelled = FALSE
  /\ emittedID = 0

LaunchRequest ==
  /\ latestID' = latestID + 1
  /\ processingID' = latestID + 1
  /\ cancelled' = FALSE
  /\ emittedID' = 0

SupersedeRequest ==
  /\ latestID' = latestID + 1
  /\ processingID' = latestID + 1
  /\ cancelled' = FALSE
  /\ emittedID' = 0

CancelTask ==
  /\ processingID > 0
  /\ cancelled' = TRUE
  /\ UNCHANGED <<latestID, processingID, emittedID>>

ResolveStep ==
  /\ processingID > 0
  /\ UNCHANGED <<latestID, processingID, cancelled, emittedID>>

EmitResult ==
  /\ processingID > 0
  /\ ~cancelled
  /\ processingID = latestID
  /\ processingID' = 0
  /\ emittedID' = processingID
  /\ UNCHANGED <<latestID, cancelled>>

DropStale ==
  /\ processingID > 0
  /\ (cancelled \/ processingID # latestID)
  /\ processingID' = 0
  /\ cancelled' = FALSE
  /\ emittedID' = 0
  /\ UNCHANGED <<latestID>>

Next ==
  LaunchRequest
  \/ SupersedeRequest
  \/ CancelTask
  \/ ResolveStep
  \/ EmitResult
  \/ DropStale

TypeInvariant ==
  /\ latestID \in Nat
  /\ processingID \in Nat
  /\ emittedID \in Nat
  /\ cancelled \in BOOLEAN
  /\ processingID <= latestID
  /\ emittedID <= latestID

EmittedOnlyLatest ==
  emittedID = 0 \/ emittedID = latestID

CancelledSuppressesEmission ==
  cancelled => emittedID = 0

Invariant ==
  /\ TypeInvariant
  /\ EmittedOnlyLatest
  /\ CancelledSuppressesEmission

Spec == Init /\ [][Next]_<<latestID, processingID, cancelled, emittedID>>

THEOREM Spec => []Invariant
====
