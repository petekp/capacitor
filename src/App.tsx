import { useState, useEffect, useCallback, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import type { DashboardData, Project, ProjectDetails, Artifact, SuggestedProject, ProjectStatus, ProjectSessionState, SessionState, SessionStatesFile, BringToFrontResult } from "./types";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/Icon";
import { TabButton } from "@/components/TabButton";
import { ProjectsPanel } from "@/components/panels/ProjectsPanel";
import { ProjectDetailPanel } from "@/components/panels/ProjectDetailPanel";
import { AddProjectPanel } from "@/components/panels/AddProjectPanel";
import { ArtifactsPanel } from "@/components/panels/ArtifactsPanel";
import { useWindowPersistence } from "@/hooks/useWindowPersistence";
import { useTheme } from "@/hooks/useTheme";
import { useFocusOnHover } from "@/hooks/useFocusOnHover";
import { useNotificationSound } from "@/hooks/useNotificationSound";

type Tab = "projects" | "artifacts";
type ProjectView = "list" | "detail" | "add";

function App() {
  const [activeTab, setActiveTab] = useState<Tab>("projects");
  const [dashboard, setDashboard] = useState<DashboardData | null>(null);
  const [artifacts, setArtifacts] = useState<Artifact[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [projectView, setProjectView] = useState<ProjectView>("list");
  const [selectedProject, setSelectedProject] = useState<Project | null>(null);
  const [projectDetails, setProjectDetails] = useState<ProjectDetails | null>(null);
  const [suggestedProjects, setSuggestedProjects] = useState<SuggestedProject[]>([]);
  const [selectedArtifact, setSelectedArtifact] = useState<Artifact | null>(null);
  const [artifactContent, setArtifactContent] = useState<string | null>(null);
  const [artifactFilter, setArtifactFilter] = useState<"all" | "skill" | "command" | "agent" | "plugin">("all");
  const [projectStatuses, setProjectStatuses] = useState<Record<string, ProjectStatus>>({});
  const [sessionStates, setSessionStates] = useState<Record<string, ProjectSessionState>>({});
  const [globalHookInstalled, setGlobalHookInstalled] = useState<boolean | null>(null);
  const [installingHook, setInstallingHook] = useState(false);
  const [addingProject, setAddingProject] = useState(false);
  const [alwaysOnTop, setAlwaysOnTop] = useState(false);
  const [focusedProjectPath, setFocusedProjectPath] = useState<string | null>(null);
  const [acknowledgedProjects, setAcknowledgedProjects] = useState<Set<string>>(new Set());
  const [flashingProjects, setFlashingProjects] = useState<Record<string, string>>({});

  const prevSessionStatesRef = useRef<Record<string, ProjectSessionState>>({});
  const flashTimeoutsRef = useRef<Record<string, ReturnType<typeof setTimeout>>>({});

  useWindowPersistence();
  useTheme();
  useFocusOnHover();
  const { playReadySound } = useNotificationSound();

  useEffect(() => {
    const prev = prevSessionStatesRef.current;
    for (const [path, state] of Object.entries(sessionStates)) {
      const prevState = prev[path];
      if (state.state && prevState?.state !== state.state && prevState?.state !== undefined) {
        if (state.state !== "working") {
          if (flashTimeoutsRef.current[path]) {
            clearTimeout(flashTimeoutsRef.current[path]);
          }
          setFlashingProjects((f) => ({ ...f, [path]: state.state }));
          flashTimeoutsRef.current[path] = setTimeout(() => {
            setFlashingProjects((f) => {
              const updated = { ...f };
              delete updated[path];
              return updated;
            });
            delete flashTimeoutsRef.current[path];
          }, 1450);
        }

        if (state.state === "ready") {
          playReadySound();
        }
      }
    }
    prevSessionStatesRef.current = sessionStates;
  }, [sessionStates, playReadySound]);

  const loadSessionStates = useCallback(async (projects: Project[]) => {
    if (projects.length === 0) return;
    try {
      const paths = projects.map((p) => p.path);
      const states = await invoke<Record<string, ProjectSessionState>>("get_all_session_states", { projectPaths: paths });
      setSessionStates(states);
    } catch (err) {
      console.error("Failed to load session states:", err);
    }
  }, []);

  const loadProjectStatuses = useCallback(async (projects: Project[]) => {
    const statuses: Record<string, ProjectStatus> = {};
    await Promise.all(
      projects.map(async (project) => {
        try {
          const status = await invoke<ProjectStatus | null>("get_project_status", { projectPath: project.path });
          if (status) {
            statuses[project.path] = status;
          }
        } catch (err) {
          console.error(`Failed to load status for ${project.path}:`, err);
        }
      })
    );
    setProjectStatuses(statuses);
  }, []);

  const loadData = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const [dashboardData, artifactsData, hookInstalled] = await Promise.all([
        invoke<DashboardData>("load_dashboard"),
        invoke<Artifact[]>("load_artifacts"),
        invoke<boolean>("check_global_hook_installed"),
      ]);
      setDashboard(dashboardData);
      setArtifacts(artifactsData);
      setGlobalHookInstalled(hookInstalled);
      loadProjectStatuses(dashboardData.projects);
      loadSessionStates(dashboardData.projects);

      const projectPaths = dashboardData.projects.map(p => p.path);
      if (projectPaths.length > 0) {
        invoke("start_status_watcher", { projectPaths }).catch(console.error);
      }
      invoke("start_session_state_watcher").catch(console.error);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, [loadProjectStatuses, loadSessionStates]);

  const handleInstallHook = async () => {
    setInstallingHook(true);
    try {
      await invoke("install_global_hook");
      setGlobalHookInstalled(true);
    } catch (err) {
      console.error("Failed to install hook:", err);
    } finally {
      setInstallingHook(false);
    }
  };

  const handleToggleAlwaysOnTop = async () => {
    try {
      const window = getCurrentWindow();
      const newValue = !alwaysOnTop;
      await window.setAlwaysOnTop(newValue);
      setAlwaysOnTop(newValue);
    } catch (err) {
      console.error("Failed to toggle always-on-top:", err);
    }
  };

  useEffect(() => {
    loadData();
  }, [loadData]);

  useEffect(() => {
    const unlistenStatus = listen<[string, ProjectStatus]>("status-changed", (event) => {
      const [projectPath, status] = event.payload;
      setProjectStatuses(prev => ({ ...prev, [projectPath]: status }));
    });

    const unlistenSessionStates = listen<SessionStatesFile>("session-states-changed", (event) => {
      const states: Record<string, ProjectSessionState> = {};
      for (const [path, entry] of Object.entries(event.payload.projects)) {
        states[path] = {
          state: entry.state as SessionState,
          state_changed_at: entry.state_changed_at,
          session_id: entry.session_id,
          working_on: entry.working_on,
          next_step: entry.next_step,
          context: entry.context ? {
            percent_used: entry.context.percent_used,
            tokens_used: entry.context.tokens_used,
            context_size: entry.context.context_size,
            updated_at: entry.context.updated_at,
          } : null,
        };
      }
      setSessionStates(prev => ({ ...prev, ...states }));
    });

    return () => {
      unlistenStatus.then(fn => fn());
      unlistenSessionStates.then(fn => fn());
    };
  }, []);

  useEffect(() => {
    if (!dashboard || activeTab !== "projects" || projectView !== "list") return;

    const interval = setInterval(() => {
      loadSessionStates(dashboard.projects);
    }, 10000);

    return () => clearInterval(interval);
  }, [dashboard, activeTab, projectView, loadSessionStates]);

  useEffect(() => {
    if (activeTab !== "projects" || projectView !== "list") return;

    const pollFocusedProject = async () => {
      try {
        const path = await invoke<string | null>("get_focused_project_path");
        setFocusedProjectPath(path);
      } catch (err) {
        console.error("Failed to get focused project:", err);
      }
    };

    pollFocusedProject();
    const interval = setInterval(pollFocusedProject, 2000);

    return () => clearInterval(interval);
  }, [activeTab, projectView]);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement;
      const isInput = target.tagName === "INPUT" ||
                      target.tagName === "TEXTAREA" ||
                      target.isContentEditable;

      if (isInput) return;

      if (!e.metaKey && !e.ctrlKey) {
        e.preventDefault();
      }
    };

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, []);

  const handleOpenEditor = async (path: string) => {
    try {
      await invoke("open_in_editor", { path });
    } catch (err) {
      console.error("Failed to open editor:", err);
    }
  };

  const handleOpenFolder = async (path: string) => {
    try {
      await invoke("open_folder", { path });
    } catch (err) {
      console.error("Failed to open folder:", err);
    }
  };

  const handleLaunchTerminal = async (path: string, runClaude: boolean = false) => {
    try {
      const result = await invoke<BringToFrontResult>("bring_project_windows_to_front", {
        path,
        launchIfNone: runClaude
      });
      if (result.focused_windows.length > 0) {
        console.log("Focused windows:", result.focused_windows.map(w => `${w.app_name} (${w.window_type})`).join(", "));
      }
    } catch (err) {
      console.error("Failed to bring windows to front:", err);
    }
  };

  const handleTogglePlugin = async (pluginId: string, enabled: boolean) => {
    try {
      await invoke("toggle_plugin", { pluginId, enabled });
      await loadData();
    } catch (err) {
      console.error("Failed to toggle plugin:", err);
    }
  };

  const handleSelectProject = async (project: Project) => {
    setSelectedProject(project);
    setProjectView("detail");
    try {
      const details = await invoke<ProjectDetails>("load_project_details", { path: project.path });
      setProjectDetails(details);
    } catch (err) {
      console.error("Failed to load project details:", err);
    }
  };

  const handleBackToProjects = () => {
    setSelectedProject(null);
    setProjectDetails(null);
    setProjectView("list");
  };

  const handleShowAddProject = async () => {
    setProjectView("add");
    try {
      const suggestions = await invoke<SuggestedProject[]>("load_suggested_projects");
      setSuggestedProjects(suggestions);
    } catch (err) {
      console.error("Failed to load suggestions:", err);
    }
  };

  const handleAddProject = async (path: string) => {
    try {
      setAddingProject(true);
      await invoke("add_project", { path });
      await loadData();
      setProjectView("list");
    } catch (err) {
      console.error("Failed to add project:", err);
    } finally {
      setAddingProject(false);
    }
  };

  const handleRemoveProject = async (path: string) => {
    try {
      await invoke("remove_project", { path });
      await loadData();
    } catch (err) {
      console.error("Failed to remove project:", err);
    }
  };

  const handleSelectArtifact = async (artifact: Artifact) => {
    setSelectedArtifact(artifact);
    try {
      const content = await invoke<string>("read_file_content", { path: artifact.path });
      setArtifactContent(content);
    } catch {
      setArtifactContent("Failed to load content");
    }
  };

  const filteredArtifacts = artifacts.filter((a) => {
    if (artifactFilter === "all") return true;
    return a.artifact_type === artifactFilter;
  });

  if (loading) {
    return (
      <div className="flex h-screen items-center justify-center bg-(--color-background)">
        <div className="text-(--color-muted-foreground)">Loading...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex h-screen items-center justify-center bg-(--color-background)">
        <div className="text-center">
          <div className="text-red-500 mb-2">Error loading configuration</div>
          <div className="text-(--color-muted-foreground) text-sm">{error}</div>
          <Button onClick={loadData} className="mt-4">
            Retry
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-screen bg-(--color-background) text-(--color-foreground)">
      <header className="flex-shrink-0 border-b border-(--color-border) bg-(--color-muted)/30">
        <div className="flex items-center">
          <nav className="flex flex-1">
            <TabButton
              active={activeTab === "projects"}
              onClick={() => { setActiveTab("projects"); setProjectView("list"); setSelectedProject(null); }}
            >
              Projects
              <span className="ml-1.5 text-xs opacity-60">{dashboard?.projects.length ?? 0}</span>
            </TabButton>
            <TabButton
              active={activeTab === "artifacts"}
              onClick={() => setActiveTab("artifacts")}
            >
              Artifacts
              <span className="ml-1.5 text-xs opacity-60">{artifacts.length}</span>
            </TabButton>
          </nav>
          <Button
            variant="ghost"
            size="icon"
            onClick={handleToggleAlwaysOnTop}
            title={alwaysOnTop ? "Unpin from top" : "Pin to top"}
            className={`h-7 w-7 mr-1 ${alwaysOnTop ? "text-blue-400" : "opacity-50 hover:opacity-100"}`}
          >
            <Icon name="pin" className="w-3.5 h-3.5" />
          </Button>
        </div>
      </header>

      <main className="flex-1 overflow-auto p-3">
        {globalHookInstalled === false && (
          <div className="mb-6 p-4 rounded-lg border border-blue-500/30 bg-blue-500/10">
            <div className="flex items-center justify-between">
              <div>
                <div className="font-medium text-sm">Enable Status Tracking</div>
                <div className="text-xs text-muted-foreground mt-0.5">
                  Track what you're working on across all projects
                </div>
              </div>
              <Button
                size="sm"
                onClick={handleInstallHook}
                disabled={installingHook}
              >
                {installingHook ? "Enabling..." : "Enable"}
              </Button>
            </div>
          </div>
        )}

        {activeTab === "projects" && dashboard && projectView === "list" && (
          <ProjectsPanel
            projects={dashboard.projects}
            projectStatuses={projectStatuses}
            sessionStates={sessionStates}
            focusedProjectPath={focusedProjectPath}
            acknowledgedProjects={acknowledgedProjects}
            flashingProjects={flashingProjects}
            onSelectProject={handleSelectProject}
            onAddProject={handleShowAddProject}
            onLaunchTerminal={handleLaunchTerminal}
            onAcknowledge={(path) => setAcknowledgedProjects((prev) => new Set(prev).add(path))}
          />
        )}

        {activeTab === "projects" && projectView === "detail" && selectedProject && (
          <ProjectDetailPanel
            project={selectedProject}
            details={projectDetails}
            onBack={handleBackToProjects}
            onOpenEditor={handleOpenEditor}
            onOpenFolder={handleOpenFolder}
            onRemove={handleRemoveProject}
          />
        )}

        {activeTab === "projects" && projectView === "add" && (
          <AddProjectPanel
            suggestions={suggestedProjects}
            onAdd={handleAddProject}
            onBack={handleBackToProjects}
            isAdding={addingProject}
          />
        )}

        {activeTab === "artifacts" && dashboard && (
          <ArtifactsPanel
            artifacts={filteredArtifacts}
            plugins={dashboard.plugins}
            filter={artifactFilter}
            onFilterChange={setArtifactFilter}
            selectedArtifact={selectedArtifact}
            artifactContent={artifactContent}
            onSelectArtifact={handleSelectArtifact}
            onOpenEditor={handleOpenEditor}
            onTogglePlugin={handleTogglePlugin}
            onOpenFolder={handleOpenFolder}
            onCloseArtifact={() => {
              setSelectedArtifact(null);
              setArtifactContent(null);
            }}
          />
        )}
      </main>
    </div>
  );
}

export default App;
