use super::types::AgentSession;
use super::AgentAdapter;

macro_rules! stub_adapter {
    ($name:ident, $id:expr, $display_name:expr) => {
        pub struct $name;

        impl $name {
            pub fn new() -> Self {
                Self
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl AgentAdapter for $name {
            fn id(&self) -> &'static str {
                $id
            }

            fn display_name(&self) -> &'static str {
                $display_name
            }

            fn is_installed(&self) -> bool {
                false
            }

            fn detect_session(&self, _project_path: &str) -> Option<AgentSession> {
                None
            }
        }
    };
}

stub_adapter!(CodexAdapter, "codex", "OpenAI Codex");
stub_adapter!(AiderAdapter, "aider", "Aider");
stub_adapter!(AmpAdapter, "amp", "Amp");
stub_adapter!(OpenCodeAdapter, "opencode", "OpenCode");
stub_adapter!(DroidAdapter, "droid", "Droid");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_codex_adapter() {
        let adapter = CodexAdapter::new();
        assert_eq!(adapter.id(), "codex");
        assert_eq!(adapter.display_name(), "OpenAI Codex");
        assert!(!adapter.is_installed());
        assert!(adapter.detect_session("/project").is_none());
    }

    #[test]
    fn test_aider_adapter() {
        let adapter = AiderAdapter::new();
        assert_eq!(adapter.id(), "aider");
        assert_eq!(adapter.display_name(), "Aider");
        assert!(!adapter.is_installed());
    }

    #[test]
    fn test_amp_adapter() {
        let adapter = AmpAdapter::new();
        assert_eq!(adapter.id(), "amp");
        assert_eq!(adapter.display_name(), "Amp");
        assert!(!adapter.is_installed());
    }

    #[test]
    fn test_opencode_adapter() {
        let adapter = OpenCodeAdapter::new();
        assert_eq!(adapter.id(), "opencode");
        assert_eq!(adapter.display_name(), "OpenCode");
        assert!(!adapter.is_installed());
    }

    #[test]
    fn test_droid_adapter() {
        let adapter = DroidAdapter::new();
        assert_eq!(adapter.id(), "droid");
        assert_eq!(adapter.display_name(), "Droid");
        assert!(!adapter.is_installed());
    }
}
