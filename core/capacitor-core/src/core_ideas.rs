use super::*;

#[uniffi::export]
impl CoreRuntime {
    pub fn capture_idea(
        &self,
        project_path: String,
        idea_text: String,
    ) -> Result<String, CoreRuntimeError> {
        runtime::ideas::capture_idea_with_storage(&self.app_storage, &project_path, &idea_text)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_status(
        &self,
        project_path: String,
        idea_id: String,
        new_status: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::update_idea_status_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_status,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_effort(
        &self,
        project_path: String,
        idea_id: String,
        new_effort: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::update_idea_effort_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_effort,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_triage(
        &self,
        project_path: String,
        idea_id: String,
        new_triage: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::update_idea_triage_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_triage,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_title(
        &self,
        project_path: String,
        idea_id: String,
        new_title: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::update_idea_title_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_title,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_description(
        &self,
        project_path: String,
        idea_id: String,
        new_description: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::update_idea_description_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_description,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn save_ideas_order(
        &self,
        project_path: String,
        idea_ids: Vec<String>,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::save_ideas_order_with_storage(&self.app_storage, &project_path, idea_ids)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }
}
