# Model-Backed Work Batch Classification

Status: accepted

Capacitor will classify newly captured Tasks into Work Batches using a model-backed classifier from the first Work Batch vertical slice. Deterministic rules may exist as fallback and guardrails, but the product behavior we need to prove is intelligent routing into existing or new batches, not manual method selection or static heuristics.

This is a deliberate trade-off: heuristics are easier to test and reason about, but they would mostly prove plumbing while avoiding the product's central bet. Model-backed classification lets Capacitor reduce session sprawl and preserve related context, while requiring visible decision records and fallback behavior so routing mistakes remain inspectable and recoverable.
