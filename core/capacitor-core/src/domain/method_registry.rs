//! Built-in method templates.
//!
//! These are the default workflow templates available for runs.
//! Methods define an ordered sequence of phases with checkpoint policies.

use super::run_types::{InvolvementLevel, MethodTemplate, PhaseTemplate};

/// Returns all built-in method templates.
#[must_use]
pub fn builtin_methods() -> Vec<MethodTemplate> {
    vec![
        execution_only(),
        shape_and_execute(),
        deep_debug(),
        greenfield_build(),
    ]
}

/// Look up a built-in method by ID.
#[must_use]
pub fn find_method(id: &str) -> Option<MethodTemplate> {
    builtin_methods().into_iter().find(|m| m.id == id)
}

/// Single-phase execution. Best for well-scoped implementation tasks.
fn execution_only() -> MethodTemplate {
    MethodTemplate {
        id: "execution_only".to_string(),
        name: "Execute".to_string(),
        description: "Direct implementation with milestone checkpoints.".to_string(),
        task_archetype: "implementation".to_string(),
        default_involvement: InvolvementLevel::Supervised,
        phases: vec![PhaseTemplate {
            id: "execute".to_string(),
            name: "Execute".to_string(),
            checkpoint_policy: "implementation_milestone".to_string(),
            skill_hint: None,
        }],
    }
}

/// Two-phase: shape the approach, then execute.
fn shape_and_execute() -> MethodTemplate {
    MethodTemplate {
        id: "shape_and_execute".to_string(),
        name: "Shape & Execute".to_string(),
        description: "Align on approach before implementation.".to_string(),
        task_archetype: "feature".to_string(),
        default_involvement: InvolvementLevel::Supervised,
        phases: vec![
            PhaseTemplate {
                id: "shape".to_string(),
                name: "Shape".to_string(),
                checkpoint_policy: "proposal".to_string(),
                skill_hint: None,
            },
            PhaseTemplate {
                id: "execute".to_string(),
                name: "Execute".to_string(),
                checkpoint_policy: "implementation_milestone".to_string(),
                skill_hint: None,
            },
        ],
    }
}

/// Multi-phase debugging workflow.
fn deep_debug() -> MethodTemplate {
    MethodTemplate {
        id: "deep_debug".to_string(),
        name: "Deep Debug".to_string(),
        description: "Systematic investigation with hypothesis validation.".to_string(),
        task_archetype: "debugging".to_string(),
        default_involvement: InvolvementLevel::Collaborative,
        phases: vec![
            PhaseTemplate {
                id: "investigate".to_string(),
                name: "Investigate".to_string(),
                checkpoint_policy: "proposal".to_string(),
                skill_hint: None,
            },
            PhaseTemplate {
                id: "hypothesize".to_string(),
                name: "Hypothesize".to_string(),
                checkpoint_policy: "proposal".to_string(),
                skill_hint: None,
            },
            PhaseTemplate {
                id: "validate".to_string(),
                name: "Validate".to_string(),
                checkpoint_policy: "implementation_milestone".to_string(),
                skill_hint: None,
            },
        ],
    }
}

/// Full greenfield build workflow.
fn greenfield_build() -> MethodTemplate {
    MethodTemplate {
        id: "greenfield_build".to_string(),
        name: "Greenfield Build".to_string(),
        description: "Scope, design, implement, and verify from scratch.".to_string(),
        task_archetype: "greenfield".to_string(),
        default_involvement: InvolvementLevel::Supervised,
        phases: vec![
            PhaseTemplate {
                id: "scope".to_string(),
                name: "Scope".to_string(),
                checkpoint_policy: "proposal".to_string(),
                skill_hint: None,
            },
            PhaseTemplate {
                id: "design".to_string(),
                name: "Design".to_string(),
                checkpoint_policy: "alignment_review".to_string(),
                skill_hint: None,
            },
            PhaseTemplate {
                id: "implement".to_string(),
                name: "Implement".to_string(),
                checkpoint_policy: "implementation_milestone".to_string(),
                skill_hint: None,
            },
            PhaseTemplate {
                id: "verify".to_string(),
                name: "Verify".to_string(),
                checkpoint_policy: "implementation_milestone".to_string(),
                skill_hint: None,
            },
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_methods_non_empty() {
        let methods = builtin_methods();
        assert!(!methods.is_empty());
        assert!(methods.len() >= 4);
    }

    #[test]
    fn find_method_works() {
        assert!(find_method("execution_only").is_some());
        assert!(find_method("shape_and_execute").is_some());
        assert!(find_method("deep_debug").is_some());
        assert!(find_method("greenfield_build").is_some());
        assert!(find_method("nonexistent").is_none());
    }

    #[test]
    fn each_method_has_phases() {
        for method in builtin_methods() {
            assert!(
                !method.phases.is_empty(),
                "Method {} has no phases",
                method.id
            );
            for phase in &method.phases {
                assert!(!phase.id.is_empty(), "Phase in {} has empty id", method.id);
                assert!(
                    !phase.name.is_empty(),
                    "Phase {} in {} has empty name",
                    phase.id,
                    method.id
                );
            }
        }
    }
}
