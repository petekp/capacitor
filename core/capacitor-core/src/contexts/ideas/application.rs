use std::sync::Arc;

use super::domain::{
    CaptureIdeaRequest, IdeaBacklog, IdeaFieldUpdateRequest, IdeasOrderRequest, WorkstreamPlan,
};
use super::ports::{IdeaPortError, IdeaRepository, WorktreePort};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum IdeaServiceError {
    #[error(transparent)]
    Port(#[from] IdeaPortError),
}

pub(crate) struct IdeaService {
    repository: Arc<dyn IdeaRepository>,
    worktree_port: Arc<dyn WorktreePort>,
}

impl IdeaService {
    pub(crate) fn new(
        repository: Arc<dyn IdeaRepository>,
        worktree_port: Arc<dyn WorktreePort>,
    ) -> Self {
        Self {
            repository,
            worktree_port,
        }
    }

    pub(crate) fn load_idea_backlog(
        &self,
        project_path: &str,
    ) -> Result<IdeaBacklog, IdeaServiceError> {
        self.repository
            .load_backlog(project_path)
            .map_err(Into::into)
    }

    pub(crate) fn capture_idea(
        &self,
        request: &CaptureIdeaRequest,
    ) -> Result<String, IdeaServiceError> {
        self.repository.capture_idea(request).map_err(Into::into)
    }

    pub(crate) fn update_idea_status(
        &self,
        request: &IdeaFieldUpdateRequest,
    ) -> Result<(), IdeaServiceError> {
        self.repository
            .update_idea_status(request)
            .map_err(Into::into)
    }

    pub(crate) fn update_idea_effort(
        &self,
        request: &IdeaFieldUpdateRequest,
    ) -> Result<(), IdeaServiceError> {
        self.repository
            .update_idea_effort(request)
            .map_err(Into::into)
    }

    pub(crate) fn update_idea_triage(
        &self,
        request: &IdeaFieldUpdateRequest,
    ) -> Result<(), IdeaServiceError> {
        self.repository
            .update_idea_triage(request)
            .map_err(Into::into)
    }

    pub(crate) fn update_idea_title(
        &self,
        request: &IdeaFieldUpdateRequest,
    ) -> Result<(), IdeaServiceError> {
        self.repository
            .update_idea_title(request)
            .map_err(Into::into)
    }

    pub(crate) fn update_idea_description(
        &self,
        request: &IdeaFieldUpdateRequest,
    ) -> Result<(), IdeaServiceError> {
        self.repository
            .update_idea_description(request)
            .map_err(Into::into)
    }

    pub(crate) fn save_ideas_order(
        &self,
        request: &IdeasOrderRequest,
    ) -> Result<(), IdeaServiceError> {
        self.repository
            .save_ideas_order(request)
            .map_err(Into::into)
    }

    pub(crate) fn load_ideas_order(
        &self,
        project_path: &str,
    ) -> Result<Vec<String>, IdeaServiceError> {
        self.repository
            .load_ideas_order(project_path)
            .map_err(Into::into)
    }

    pub(crate) fn ideas_file_path(&self, project_path: &str) -> String {
        self.repository.ideas_file_path(project_path)
    }

    pub(crate) fn create_project_from_idea(
        &self,
        plan: &WorkstreamPlan,
    ) -> Result<(), IdeaServiceError> {
        self.worktree_port
            .create_project_from_idea(plan)
            .map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::runtime_types::Idea;

    #[derive(Default)]
    struct StubIdeaRepository {
        captured_texts: Mutex<Vec<String>>,
        status_updates: Mutex<Vec<String>>,
        order_saves: Mutex<Vec<Vec<String>>>,
    }

    impl IdeaRepository for StubIdeaRepository {
        fn load_backlog(&self, project_path: &str) -> Result<IdeaBacklog, IdeaPortError> {
            Ok(IdeaBacklog {
                ideas: vec![Idea {
                    id: "idea-1".to_string(),
                    title: "Idea".to_string(),
                    description: project_path.to_string(),
                    added: "2026-03-08T00:00:00Z".to_string(),
                    effort: "unknown".to_string(),
                    status: "open".to_string(),
                    triage: "pending".to_string(),
                    related: None,
                }],
                order: vec!["idea-1".to_string()],
            })
        }

        fn capture_idea(&self, request: &CaptureIdeaRequest) -> Result<String, IdeaPortError> {
            self.captured_texts
                .lock()
                .expect("captured texts")
                .push(request.idea_text.clone());
            Ok("idea-1".to_string())
        }

        fn update_idea_status(
            &self,
            request: &IdeaFieldUpdateRequest,
        ) -> Result<(), IdeaPortError> {
            self.status_updates
                .lock()
                .expect("status updates")
                .push(request.new_value.clone());
            Ok(())
        }

        fn update_idea_effort(&self, _: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError> {
            Ok(())
        }

        fn update_idea_triage(&self, _: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError> {
            Ok(())
        }

        fn update_idea_title(&self, _: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError> {
            Ok(())
        }

        fn update_idea_description(&self, _: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError> {
            Ok(())
        }

        fn save_ideas_order(&self, request: &IdeasOrderRequest) -> Result<(), IdeaPortError> {
            self.order_saves
                .lock()
                .expect("order saves")
                .push(request.idea_ids.clone());
            Ok(())
        }

        fn load_ideas_order(&self, _: &str) -> Result<Vec<String>, IdeaPortError> {
            Ok(vec!["idea-1".to_string()])
        }

        fn ideas_file_path(&self, project_path: &str) -> String {
            format!("{project_path}/ideas.md")
        }
    }

    #[derive(Default)]
    struct StubWorktreePort;

    impl WorktreePort for StubWorktreePort {
        fn create_project_from_idea(&self, _: &WorkstreamPlan) -> Result<(), IdeaPortError> {
            Ok(())
        }
    }

    #[test]
    fn idea_service_routes_repository_and_worktree_operations() {
        let repository = Arc::new(StubIdeaRepository::default());
        let service = IdeaService::new(repository.clone(), Arc::new(StubWorktreePort));

        let backlog = service
            .load_idea_backlog("/tmp/project")
            .expect("load backlog");
        assert_eq!(backlog.ideas.len(), 1);
        assert_eq!(backlog.order, vec!["idea-1"]);

        let captured_id = service
            .capture_idea(&CaptureIdeaRequest {
                project_path: "/tmp/project".to_string(),
                idea_text: "new idea".to_string(),
            })
            .expect("capture idea");
        assert_eq!(captured_id, "idea-1");
        assert_eq!(
            repository
                .captured_texts
                .lock()
                .expect("captured texts")
                .as_slice(),
            ["new idea"],
        );

        service
            .update_idea_status(&IdeaFieldUpdateRequest {
                project_path: "/tmp/project".to_string(),
                idea_id: "idea-1".to_string(),
                new_value: "done".to_string(),
            })
            .expect("update status");
        assert_eq!(
            repository
                .status_updates
                .lock()
                .expect("status updates")
                .as_slice(),
            ["done"],
        );

        service
            .save_ideas_order(&IdeasOrderRequest {
                project_path: "/tmp/project".to_string(),
                idea_ids: vec!["idea-1".to_string()],
            })
            .expect("save order");
        assert_eq!(
            repository
                .order_saves
                .lock()
                .expect("order saves")
                .as_slice(),
            [vec!["idea-1".to_string()]],
        );

        let loaded_order = service
            .load_ideas_order("/tmp/project")
            .expect("load order");
        assert_eq!(loaded_order, vec!["idea-1"]);
        assert_eq!(
            service.ideas_file_path("/tmp/project"),
            "/tmp/project/ideas.md"
        );

        service
            .create_project_from_idea(&WorkstreamPlan {
                idea_id: "idea-1".to_string(),
                project_path: Some("/tmp/project".to_string()),
                worktree_name: Some("feature-1".to_string()),
            })
            .expect("create project from idea");
    }
}
