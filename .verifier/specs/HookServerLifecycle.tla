---- MODULE HookServerLifecycle ----
EXTENDS Integers

CONSTANT
  \* @type: Int;
  MaxConsecutiveFailures

VARIABLES
  \* @type: Str;
  status,
  \* @type: Int;
  failures,
  \* @type: Bool;
  stopRequested,
  \* @type: Str;
  directive

Statuses == {"stopped", "starting", "running", "failed"}
Directives == {"none", "serverReady", "restart"}

Init ==
  /\ status = "stopped"
  /\ failures = 0
  /\ stopRequested = FALSE
  /\ directive = "none"

LaunchRequested ==
  /\ status' = "starting"
  /\ failures' = 0
  /\ stopRequested' = FALSE
  /\ directive' = "none"

AdoptedExistingProcess == LaunchRequested

HealthyCheck ==
  /\ status \in {"starting", "running"}
  /\ IF stopRequested
        THEN /\ status' = status
             /\ failures' = failures
             /\ stopRequested' = stopRequested
             /\ directive' = "none"
        ELSE /\ failures' = 0
             /\ stopRequested' = stopRequested
             /\ IF status = "starting"
                   THEN /\ status' = "running"
                        /\ directive' = "serverReady"
                   ELSE /\ status' = status
                        /\ directive' = "none"

UnhealthyCheck ==
  /\ status \in {"starting", "running"}
  /\ IF stopRequested
        THEN /\ status' = status
             /\ failures' = failures
             /\ stopRequested' = stopRequested
             /\ directive' = "none"
        ELSE LET nextFailures == failures + 1 IN
             /\ stopRequested' = FALSE
             /\ IF nextFailures >= MaxConsecutiveFailures
                   THEN /\ status' = "starting"
                        /\ failures' = 0
                        /\ directive' = "restart"
                   ELSE /\ status' = status
                        /\ failures' = nextFailures
                        /\ directive' = "none"

StopRequested ==
  /\ status' = "stopped"
  /\ failures' = 0
  /\ stopRequested' = TRUE
  /\ directive' = "none"

Next ==
  LaunchRequested
  \/ AdoptedExistingProcess
  \/ HealthyCheck
  \/ UnhealthyCheck
  \/ StopRequested

TypeInvariant ==
  /\ status \in Statuses
  /\ failures \in 0..MaxConsecutiveFailures
  /\ stopRequested \in BOOLEAN
  /\ directive \in Directives

NoRestartAfterStop ==
  stopRequested => directive # "restart"

RestartShape ==
  directive = "restart" => /\ status = "starting" /\ failures = 0

ServerReadyShape ==
  directive = "serverReady" => /\ status = "running" /\ failures = 0

Invariant ==
  /\ TypeInvariant
  /\ NoRestartAfterStop
  /\ RestartShape
  /\ ServerReadyShape

Spec == Init /\ [][Next]_<<status, failures, stopRequested, directive>>

THEOREM Spec => []Invariant
====
