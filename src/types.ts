export interface GlobalConfig {
  settings_path: string;
  settings_exists: boolean;
  instructions_path: string | null;
  skills_dir: string | null;
  commands_dir: string | null;
  agents_dir: string | null;
  skill_count: number;
  command_count: number;
  agent_count: number;
}

export interface Plugin {
  id: string;
  name: string;
  description: string;
  enabled: boolean;
  path: string;
  skill_count: number;
  command_count: number;
  agent_count: number;
  hook_count: number;
}

export interface ProjectStats {
  total_input_tokens: number;
  total_output_tokens: number;
  total_cache_read_tokens: number;
  total_cache_creation_tokens: number;
  opus_messages: number;
  sonnet_messages: number;
  haiku_messages: number;
  session_count: number;
  latest_summary: string | null;
  first_activity: string | null;
  last_activity: string | null;
}

export interface Project {
  name: string;
  path: string;
  display_path: string;
  last_active: string | null;
  claude_md_path: string | null;
  claude_md_preview: string | null;
  has_local_settings: boolean;
  task_count: number;
  stats: ProjectStats | null;
}

export interface Task {
  id: string;
  name: string;
  path: string;
  last_modified: string;
  summary: string | null;
  first_message: string | null;
}

export interface ProjectDetails {
  project: Project;
  claude_md_content: string | null;
  tasks: Task[];
  git_branch: string | null;
  git_dirty: boolean;
}

export interface Artifact {
  artifact_type: "skill" | "command" | "agent";
  name: string;
  description: string;
  source: string;
  path: string;
}

export interface DashboardData {
  global: GlobalConfig;
  plugins: Plugin[];
  projects: Project[];
}

export interface SuggestedProject {
  path: string;
  display_path: string;
  name: string;
  task_count: number;
  has_claude_md: boolean;
  has_project_indicators: boolean;
}

export interface ProjectStatus {
  working_on: string | null;
  next_step: string | null;
  status: "in_progress" | "blocked" | "needs_review" | "paused" | "done" | null;
  blocker: string | null;
  updated_at: string | null;
}

export type SessionState = "working" | "ready" | "idle" | "compacting";

export interface ContextInfo {
  percent_used: number;
  tokens_used: number;
  context_size: number;
  updated_at: string | null;
}

export interface ProjectSessionState {
  state: SessionState;
  state_changed_at: string | null;
  session_id: string | null;
  working_on: string | null;
  next_step: string | null;
  context: ContextInfo | null;
}

export interface SessionStatesFile {
  version: number;
  projects: Record<string, SessionStateEntry>;
}

export interface SessionStateEntry {
  state: string;
  state_changed_at: string | null;
  session_id: string | null;
  working_on: string | null;
  next_step: string | null;
  context?: {
    percent_used: number;
    tokens_used: number;
    context_size: number;
    updated_at: string | null;
  };
}

export interface FocusedWindow {
  app_name: string;
  window_type: "terminal" | "browser" | "ide";
  details: string | null;
}

export interface BringToFrontResult {
  focused_windows: FocusedWindow[];
  launched_terminal: boolean;
}
