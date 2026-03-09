use crate::runtime_storage::StorageConfig;

use crate::runtime_ideas::{
    capture_idea_with_storage, load_ideas_order_with_storage, load_ideas_with_storage,
    save_ideas_order_with_storage, update_idea_description_with_storage,
    update_idea_effort_with_storage, update_idea_status_with_storage,
    update_idea_title_with_storage, update_idea_triage_with_storage,
};

use super::domain::{
    CaptureIdeaRequest, IdeaBacklog, IdeaFieldUpdateRequest, IdeasOrderRequest, WorkstreamPlan,
};
use super::ports::{IdeaPortError, IdeaRepository, WorktreePort};

pub(crate) struct LiveIdeaRepository {
    app_storage: StorageConfig,
}

impl LiveIdeaRepository {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl IdeaRepository for LiveIdeaRepository {
    fn load_backlog(&self, project_path: &str) -> Result<IdeaBacklog, IdeaPortError> {
        Ok(IdeaBacklog {
            ideas: load_ideas_with_storage(&self.app_storage, project_path)
                .map_err(|error| IdeaPortError::from(error.to_string()))?,
            order: load_ideas_order_with_storage(&self.app_storage, project_path)
                .map_err(|error| IdeaPortError::from(error.to_string()))?,
        })
    }

    fn capture_idea(&self, request: &CaptureIdeaRequest) -> Result<String, IdeaPortError> {
        capture_idea_with_storage(&self.app_storage, &request.project_path, &request.idea_text)
            .map_err(|error| IdeaPortError::from(error.to_string()))
    }

    fn update_idea_status(&self, request: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError> {
        update_idea_status_with_storage(
            &self.app_storage,
            &request.project_path,
            &request.idea_id,
            &request.new_value,
        )
        .map_err(|error| IdeaPortError::from(error.to_string()))
    }

    fn update_idea_effort(&self, request: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError> {
        update_idea_effort_with_storage(
            &self.app_storage,
            &request.project_path,
            &request.idea_id,
            &request.new_value,
        )
        .map_err(|error| IdeaPortError::from(error.to_string()))
    }

    fn update_idea_triage(&self, request: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError> {
        update_idea_triage_with_storage(
            &self.app_storage,
            &request.project_path,
            &request.idea_id,
            &request.new_value,
        )
        .map_err(|error| IdeaPortError::from(error.to_string()))
    }

    fn update_idea_title(&self, request: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError> {
        update_idea_title_with_storage(
            &self.app_storage,
            &request.project_path,
            &request.idea_id,
            &request.new_value,
        )
        .map_err(|error| IdeaPortError::from(error.to_string()))
    }

    fn update_idea_description(
        &self,
        request: &IdeaFieldUpdateRequest,
    ) -> Result<(), IdeaPortError> {
        update_idea_description_with_storage(
            &self.app_storage,
            &request.project_path,
            &request.idea_id,
            &request.new_value,
        )
        .map_err(|error| IdeaPortError::from(error.to_string()))
    }

    fn save_ideas_order(&self, request: &IdeasOrderRequest) -> Result<(), IdeaPortError> {
        save_ideas_order_with_storage(
            &self.app_storage,
            &request.project_path,
            request.idea_ids.clone(),
        )
        .map_err(|error| IdeaPortError::from(error.to_string()))
    }

    fn load_ideas_order(&self, project_path: &str) -> Result<Vec<String>, IdeaPortError> {
        load_ideas_order_with_storage(&self.app_storage, project_path)
            .map_err(|error| IdeaPortError::from(error.to_string()))
    }

    fn ideas_file_path(&self, project_path: &str) -> String {
        self.app_storage
            .project_ideas_file(project_path)
            .to_string_lossy()
            .to_string()
    }
}

pub(crate) struct LiveWorktreePort {
    app_storage: StorageConfig,
}

impl LiveWorktreePort {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl WorktreePort for LiveWorktreePort {
    fn create_project_from_idea(&self, plan: &WorkstreamPlan) -> Result<(), IdeaPortError> {
        let _ = (&self.app_storage, plan);
        Err(IdeaPortError::Unimplemented)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn live_idea_repository_round_trips_capture_updates_and_order() {
        let temp = tempdir().expect("temp dir");
        let storage =
            StorageConfig::with_roots(temp.path().join(".capacitor"), temp.path().join(".claude"));

        let project_path = "/tmp/idea-project";
        let repository = LiveIdeaRepository::new(storage.clone());

        let idea_id = repository
            .capture_idea(&CaptureIdeaRequest {
                project_path: project_path.to_string(),
                idea_text: "ship the release".to_string(),
            })
            .expect("capture idea");

        let backlog = repository.load_backlog(project_path).expect("load backlog");
        assert_eq!(backlog.ideas.len(), 1);
        assert_eq!(backlog.ideas[0].id, idea_id);
        assert!(backlog.order.is_empty());

        repository
            .update_idea_status(&IdeaFieldUpdateRequest {
                project_path: project_path.to_string(),
                idea_id: idea_id.clone(),
                new_value: "done".to_string(),
            })
            .expect("update status");
        repository
            .update_idea_effort(&IdeaFieldUpdateRequest {
                project_path: project_path.to_string(),
                idea_id: idea_id.clone(),
                new_value: "medium".to_string(),
            })
            .expect("update effort");
        repository
            .update_idea_triage(&IdeaFieldUpdateRequest {
                project_path: project_path.to_string(),
                idea_id: idea_id.clone(),
                new_value: "validated".to_string(),
            })
            .expect("update triage");
        repository
            .update_idea_title(&IdeaFieldUpdateRequest {
                project_path: project_path.to_string(),
                idea_id: idea_id.clone(),
                new_value: "Ship the release".to_string(),
            })
            .expect("update title");
        repository
            .update_idea_description(&IdeaFieldUpdateRequest {
                project_path: project_path.to_string(),
                idea_id: idea_id.clone(),
                new_value: "Ship the release note".to_string(),
            })
            .expect("update description");

        repository
            .save_ideas_order(&IdeasOrderRequest {
                project_path: project_path.to_string(),
                idea_ids: vec![idea_id.clone()],
            })
            .expect("save order");
        let loaded_order = repository
            .load_ideas_order(project_path)
            .expect("load ideas order");
        assert_eq!(loaded_order, vec![idea_id.clone()]);

        let updated_backlog = repository
            .load_backlog(project_path)
            .expect("reload backlog");
        assert_eq!(updated_backlog.ideas[0].status, "done");
        assert_eq!(updated_backlog.ideas[0].effort, "medium");
        assert_eq!(updated_backlog.ideas[0].triage, "validated");
        assert_eq!(updated_backlog.ideas[0].title, "Ship the release");
        assert_eq!(
            updated_backlog.ideas[0].description,
            "Ship the release note"
        );
        assert_eq!(
            repository.ideas_file_path(project_path),
            storage.project_ideas_file(project_path).to_string_lossy()
        );
    }
}
