import { useState, useEffect, useCallback, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import { getCurrentWindow } from "@tauri-apps/api/window";
import type { DashboardData, Project, ProjectDetails, Artifact, SuggestedProject, Plugin as PluginType, ProjectStatus, ProjectSessionState, SessionStatesFile, BringToFrontResult } from "./types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { Badge } from "@/components/ui/badge";

type Tab = "projects" | "artifacts";
type ProjectView = "list" | "detail" | "add";

function formatTokenCount(count: number): string {
  if (count >= 1_000_000_000) {
    return `${(count / 1_000_000_000).toFixed(1)}B`;
  }
  if (count >= 1_000_000) {
    return `${(count / 1_000_000).toFixed(1)}M`;
  }
  if (count >= 1_000) {
    return `${(count / 1_000).toFixed(1)}K`;
  }
  return count.toString();
}

const PRICING = {
  opus: { input: 15, output: 75 },
  sonnet: { input: 3, output: 15 },
  haiku: { input: 0.8, output: 4 },
} as const;

function calculateCost(stats: import("./types").ProjectStats): number {
  const totalMessages = stats.opus_messages + stats.sonnet_messages + stats.haiku_messages;
  if (totalMessages === 0) return 0;

  const opusRatio = stats.opus_messages / totalMessages;
  const sonnetRatio = stats.sonnet_messages / totalMessages;
  const haikuRatio = stats.haiku_messages / totalMessages;

  const weightedInputPrice =
    opusRatio * PRICING.opus.input +
    sonnetRatio * PRICING.sonnet.input +
    haikuRatio * PRICING.haiku.input;

  const weightedOutputPrice =
    opusRatio * PRICING.opus.output +
    sonnetRatio * PRICING.sonnet.output +
    haikuRatio * PRICING.haiku.output;

  const inputCost = (stats.total_input_tokens / 1_000_000) * weightedInputPrice;
  const outputCost = (stats.total_output_tokens / 1_000_000) * weightedOutputPrice;

  return inputCost + outputCost;
}

function formatCost(cost: number): string {
  return `$${cost.toFixed(1)}`;
}

function TabButton({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      className={`flex-1 flex items-center justify-center gap-1 px-3 py-2 text-[12px] font-medium transition-colors ${
        active
          ? "text-(--color-foreground) border-b-2 border-(--color-foreground)"
          : "text-(--color-muted-foreground) hover:text-(--color-foreground) border-b-2 border-transparent"
      }`}
    >
      {children}
    </button>
  );
}

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

  const prevSessionStatesRef = useRef<Record<string, ProjectSessionState>>({});
  const audioContextRef = useRef<AudioContext | null>(null);

  const playReadySound = useCallback(() => {
    if (!audioContextRef.current) {
      audioContextRef.current = new AudioContext();
    }
    const ctx = audioContextRef.current;
    const oscillator = ctx.createOscillator();
    const gainNode = ctx.createGain();

    oscillator.connect(gainNode);
    gainNode.connect(ctx.destination);

    oscillator.type = "sine";
    oscillator.frequency.setValueAtTime(880, ctx.currentTime);
    oscillator.frequency.setValueAtTime(1100, ctx.currentTime + 0.1);

    gainNode.gain.setValueAtTime(0.15, ctx.currentTime);
    gainNode.gain.exponentialRampToValueAtTime(0.01, ctx.currentTime + 0.3);

    oscillator.start(ctx.currentTime);
    oscillator.stop(ctx.currentTime + 0.3);
  }, []);

  useEffect(() => {
    const prev = prevSessionStatesRef.current;
    for (const [path, state] of Object.entries(sessionStates)) {
      const prevState = prev[path];
      if (state.state === "ready" && prevState?.state !== "ready" && prevState?.state !== undefined) {
        playReadySound();
        break;
      }
    }
    prevSessionStatesRef.current = sessionStates;
  }, [sessionStates, playReadySound]);

  useEffect(() => {
    let lastFocus = 0;
    const handleMouseEnter = () => {
      const now = Date.now();
      if (now - lastFocus < 500) return;
      lastFocus = now;
      if (!document.hasFocus()) {
        getCurrentWindow().setFocus();
      }
    };
    document.addEventListener("mouseenter", handleMouseEnter);
    return () => document.removeEventListener("mouseenter", handleMouseEnter);
  }, []);

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
          state: entry.state as "working" | "ready" | "idle" | "compacting",
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

  useEffect(() => {
    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");

    const updateTheme = (e: MediaQueryListEvent | MediaQueryList) => {
      document.documentElement.classList.toggle("dark", e.matches);
    };

    updateTheme(mediaQuery);
    mediaQuery.addEventListener("change", updateTheme);
    return () => mediaQuery.removeEventListener("change", updateTheme);
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

function Icon({ name, className = "" }: { name: string; className?: string }) {
  const icons: Record<string, string> = {
    home: "M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6",
    lightbulb: "M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z",
    terminal: "M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z",
    cpu: "M9 3v2m6-2v2M9 19v2m6-2v2M3 9h2m14 0h2M3 15h2m14 0h2M7 7h10a1 1 0 011 1v8a1 1 0 01-1 1H7a1 1 0 01-1-1V8a1 1 0 011-1z",
    puzzle: "M11 4a2 2 0 114 0v1a1 1 0 001 1h3a1 1 0 011 1v3a1 1 0 01-1 1h-1a2 2 0 100 4h1a1 1 0 011 1v3a1 1 0 01-1 1h-3a1 1 0 01-1-1v-1a2 2 0 10-4 0v1a1 1 0 01-1 1H7a1 1 0 01-1-1v-3a1 1 0 00-1-1H4a2 2 0 110-4h1a1 1 0 001-1V7a1 1 0 011-1h3a1 1 0 001-1V4z",
    refresh: "M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15",
    folder: "M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z",
    document: "M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z",
    external: "M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14",
    x: "M6 18L18 6M6 6l12 12",
    back: "M10 19l-7-7m0 0l7-7m-7 7h18",
    settings: "M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z M15 12a3 3 0 11-6 0 3 3 0 016 0z",
    git: "M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5",
    clock: "M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z",
    chat: "M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z",
    list: "M4 6h16M4 10h16M4 14h16M4 18h16",
    plus: "M12 4v16m8-8H4",
    trash: "M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16",
    play: "M5 3l14 9-14 9V3z",
    sparkle: "M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09zM18.259 8.715L18 9.75l-.259-1.035a3.375 3.375 0 00-2.455-2.456L14.25 6l1.036-.259a3.375 3.375 0 002.455-2.456L18 2.25l.259 1.035a3.375 3.375 0 002.456 2.456L21.75 6l-1.035.259a3.375 3.375 0 00-2.456 2.456z",
    chevronDown: "M19 9l-7 7-7-7",
    chevronRight: "M9 5l7 7-7 7",
    info: "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z",
    pin: "M16 12V4h1a1 1 0 000-2H7a1 1 0 000 2h1v8l-2 2v2h5v6l1 1 1-1v-6h5v-2l-2-2z",
  };

  return (
    <svg
      className={`w-4 h-4 ${className}`}
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={2}
    >
      <path strokeLinecap="round" strokeLinejoin="round" d={icons[name] || ""} />
    </svg>
  );
}

function ProjectsPanel({
  projects,
  projectStatuses,
  sessionStates,
  focusedProjectPath,
  acknowledgedProjects,
  onSelectProject,
  onAddProject,
  onLaunchTerminal,
  onAcknowledge,
}: {
  projects: Project[];
  projectStatuses: Record<string, ProjectStatus>;
  sessionStates: Record<string, ProjectSessionState>;
  focusedProjectPath: string | null;
  acknowledgedProjects: Set<string>;
  onSelectProject: (project: Project) => void;
  onAddProject: () => void;
  onLaunchTerminal: (path: string, runClaude: boolean) => void;
  onAcknowledge: (path: string) => void;
}) {
  const [searchQuery, setSearchQuery] = useState("");

  const projectsWithData = projects.map((project) => ({
    project,
    status: projectStatuses[project.path],
    sessionState: sessionStates[project.path],
  }));

  const filteredProjects = projectsWithData.filter(({ project }) => {
    if (searchQuery && !project.name.toLowerCase().includes(searchQuery.toLowerCase())) return false;
    return true;
  });

  const isRecentTimestamp = (timestamp: string | null | undefined, hoursThreshold = 24) => {
    if (!timestamp) return false;
    const hoursSince = (Date.now() - new Date(timestamp).getTime()) / 3600000;
    return hoursSince < hoursThreshold;
  };

  const isRecentOrActive = (item: typeof projectsWithData[0]) => {
    const { sessionState, project } = item;

    // Active Claude session (working, ready, compacting) = always show
    if (sessionState?.state === "working" || sessionState?.state === "ready" || sessionState?.state === "compacting") {
      return true;
    }

    // Session state changed recently (including "idle") = show
    if (sessionState?.state_changed_at && isRecentTimestamp(sessionState.state_changed_at)) {
      return true;
    }

    // Project has recent activity = show
    if (isRecentTimestamp(project.last_active)) {
      return true;
    }

    return false;
  };

  const getMostRecentTimestamp = (item: typeof projectsWithData[0]) => {
    const times = [
      item.sessionState?.state_changed_at,
      item.sessionState?.context?.updated_at,
      item.project.last_active,
    ].filter(Boolean).map(t => new Date(t!).getTime());
    return times.length > 0 ? Math.max(...times) : 0;
  };

  const sortByPriorityThenRecency = (a: typeof projectsWithData[0], b: typeof projectsWithData[0]) => {
    // "ready" (waiting for input) comes first - these need user attention NOW
    const aReady = a.sessionState?.state === "ready" ? 1 : 0;
    const bReady = b.sessionState?.state === "ready" ? 1 : 0;
    if (aReady !== bReady) return bReady - aReady;

    // Then by recency
    return getMostRecentTimestamp(b) - getMostRecentTimestamp(a);
  };

  const recentProjects = filteredProjects
    .filter(isRecentOrActive)
    .sort(sortByPriorityThenRecency);

  const dormantProjects = filteredProjects
    .filter((item) => !isRecentOrActive(item))
    .sort((a, b) => getMostRecentTimestamp(b) - getMostRecentTimestamp(a));

  return (
    <div>
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2 flex-1">
          {projects.length > 0 && (
            <Input
              type="text"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Search..."
              className="h-6 text-[11px] flex-1"
            />
          )}
        </div>
        <Button variant="ghost" size="sm" onClick={onAddProject} className="h-6 px-2 text-[11px] ml-2">
          + Add
        </Button>
      </div>

      {projects.length > 0 ? (
        <div className="space-y-6">
          {recentProjects.length > 0 && (
            <div>
              <h2 className="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground mb-2">
                Recent
              </h2>
              <div className="space-y-2">
                {recentProjects.map(({ project, status, sessionState }) => (
                  <ProjectCard
                    key={project.path}
                    project={project}
                    status={status}
                    sessionState={sessionState}
                    isFocused={focusedProjectPath === project.path}
                    isAcknowledged={acknowledgedProjects.has(project.path)}
                    onSelect={() => onSelectProject(project)}
                    onLaunchTerminal={() => { onAcknowledge(project.path); onLaunchTerminal(project.path, true); }}
                  />
                ))}
              </div>
            </div>
          )}

          {dormantProjects.length > 0 && (
            <div>
              <h2 className="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground mb-2">
                {recentProjects.length > 0 ? `Dormant (${dormantProjects.length})` : "Projects"}
              </h2>
              <div className="space-y-1.5">
                {dormantProjects.map(({ project, status }) => (
                  <CompactProjectCard
                    key={project.path}
                    project={project}
                    status={status}
                    onSelect={() => onSelectProject(project)}
                    onLaunchTerminal={() => onLaunchTerminal(project.path, true)}
                  />
                ))}
              </div>
            </div>
          )}

          {filteredProjects.length === 0 && (
            <div className="text-muted-foreground text-center py-8 text-xs">
              No projects match your search
            </div>
          )}
        </div>
      ) : (
        <Button
          variant="ghost"
          onClick={onAddProject}
          className="w-full text-muted-foreground py-16 h-auto text-sm"
        >
          No projects yet
        </Button>
      )}
    </div>
  );
}

function ProjectCard({
  project,
  status,
  sessionState,
  isFocused,
  isAcknowledged,
  onSelect,
  onLaunchTerminal,
}: {
  project: Project;
  status: ProjectStatus | undefined;
  sessionState: ProjectSessionState | undefined;
  isFocused: boolean;
  isAcknowledged: boolean;
  onSelect: () => void;
  onLaunchTerminal: () => void;
}) {
  const hasStatus = status && (status.working_on || status.next_step);

  const getStatusConfig = () => {
    if (!sessionState) return null;
    switch (sessionState.state) {
      case "ready": return { text: "Ready", bgClass: "bg-emerald-500/20", shimmerClass: "shimmer shimmer-bg shimmer-color-emerald-300/20 shimmer-speed-500", textClass: "text-emerald-400", dotClass: "bg-emerald-400" };
      case "compacting": return { text: "Compacting", bgClass: "bg-pink-500/20", textClass: "text-pink-400", dotClass: "bg-pink-400" };
      case "working": return { text: "Working", bgClass: "bg-orange-500/20", textClass: "text-orange-300", dotClass: "bg-orange-400" };
      default: return null;
    }
  };

  const statusConfig = getStatusConfig();

  const getCardStateClass = () => {
    if (isFocused) return "card-focused";
    if (!sessionState) return "";
    switch (sessionState.state) {
      case "working": return "card-working";
      case "ready": return "card-ready";
      case "compacting": return "card-compacting";
      default: return "";
    }
  };

  return (
    <div
      onClick={onLaunchTerminal}
      className={`p-2.5 rounded-lg border bg-(--color-card) hover:bg-(--color-muted) active:bg-(--color-muted)/70 transition-colors ${getCardStateClass()}`}
    >
      <div className="flex items-start justify-between gap-2 mb-1.5">
        <h3 className="font-semibold text-lg leading-tight tracking-[-0.01em]">
          {project.name}
        </h3>
        <div className="flex items-center gap-1 shrink-0">
          {statusConfig && (
            <div className={`inline-flex items-center gap-1 px-1.5 py-0.5 rounded ${statusConfig.bgClass} ${!isAcknowledged && statusConfig.shimmerClass ? statusConfig.shimmerClass : ""}`}>
              <span className={`w-1.5 h-1.5 rounded-full ${statusConfig.dotClass} animate-pulse`} />
              <span className={`text-[9px] font-semibold uppercase tracking-wide ${statusConfig.textClass}`}>
                {statusConfig.text}
              </span>
            </div>
          )}
          <Button
            variant="ghost"
            size="icon"
            onClick={(e) => {
              e.stopPropagation();
              onSelect();
            }}
            title="View details"
            className="h-5 w-5 opacity-50 hover:opacity-100"
          >
            <Icon name="info" className="w-3 h-3" />
          </Button>
        </div>
      </div>

      {(sessionState?.working_on || sessionState?.next_step || hasStatus) ? (
        <div className="space-y-0.5 mb-2">
          {(sessionState?.working_on || status?.working_on) && (
            <div className="text-[12px] text-foreground/90 leading-snug line-clamp-2">
              {sessionState?.working_on || status?.working_on}
            </div>
          )}
          {(sessionState?.next_step || status?.next_step) && (
            <div className="text-[11px] text-foreground/60 leading-snug line-clamp-1">
              <span className="text-muted-foreground">→</span> {sessionState?.next_step || status?.next_step}
            </div>
          )}
          {status?.blocker && (
            <div className="text-[10px] text-red-400 leading-snug">
              <span className="font-medium">Blocked:</span> {status.blocker}
            </div>
          )}
        </div>
      ) : (
        <div className="text-[11px] text-muted-foreground/40 italic mb-2">
          No recent activity
        </div>
      )}

    </div>
  );
}

function CompactProjectCard({
  project,
  status,
  onSelect,
  onLaunchTerminal,
}: {
  project: Project;
  status?: ProjectStatus;
  sessionState?: ProjectSessionState;
  onSelect: () => void;
  onLaunchTerminal: () => void;
}) {
  const formatRelativeTime = (dateStr: string | null | undefined) => {
    if (!dateStr) return "—";
    const date = new Date(dateStr);
    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffMins = Math.floor(diffMs / 60000);
    const diffHours = Math.floor(diffMs / 3600000);
    const diffDays = Math.floor(diffMs / 86400000);
    const diffWeeks = Math.floor(diffDays / 7);
    const diffMonths = Math.floor(diffDays / 30);

    if (diffMins < 1) return "now";
    if (diffMins < 60) return `${diffMins}m`;
    if (diffHours < 24) return `${diffHours}h`;
    if (diffDays < 7) return `${diffDays}d`;
    if (diffWeeks < 4) return `${diffWeeks}w`;
    return `${diffMonths}mo`;
  };

  const context = status?.working_on || status?.next_step;

  return (
    <div
      onClick={onLaunchTerminal}
      className="p-2 rounded-md border bg-(--color-card) hover:bg-(--color-muted) active:bg-(--color-muted)/70 transition-colors group"
    >
      <div className="flex items-center justify-between gap-2">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-medium text-[11px] leading-none truncate">{project.name}</span>
            <span className="text-[9px] text-muted-foreground/40 shrink-0">
              {formatRelativeTime(project.last_active)}
            </span>
          </div>
          {context && (
            <div className="text-[10px] text-muted-foreground/60 leading-snug line-clamp-1 mt-0.5">
              {context}
            </div>
          )}
        </div>
        <Button
          variant="ghost"
          size="icon"
          onClick={(e) => {
            e.stopPropagation();
            onSelect();
          }}
          title="View details"
          className="h-5 w-5 opacity-0 group-hover:opacity-50 hover:!opacity-100 transition-opacity shrink-0"
        >
          <Icon name="info" className="w-2.5 h-2.5" />
        </Button>
      </div>
    </div>
  );
}

function ProjectDetailPanel({
  project,
  details,
  onBack,
  onOpenEditor,
  onOpenFolder,
  onRemove,
}: {
  project: Project;
  details: ProjectDetails | null;
  onBack: () => void;
  onOpenEditor: (path: string) => void;
  onOpenFolder: (path: string) => void;
  onRemove: (path: string) => void;
}) {
  return (
    <div>
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-3">
          <Button variant="ghost" size="icon" onClick={onBack} className="h-8 w-8">
            <Icon name="back" />
          </Button>
          <div>
            <h2 className="font-semibold text-base">{project.name}</h2>
            <div className="text-xs text-muted-foreground">{project.display_path}</div>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" onClick={() => onOpenFolder(project.path)} className="gap-2">
            <Icon name="folder" />
            Open Folder
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => { onRemove(project.path); onBack(); }}
            className="text-muted-foreground hover:text-red-400"
          >
            Remove
          </Button>
        </div>
      </div>

      {!details ? (
        <div className="text-(--color-muted-foreground)">Loading project details...</div>
      ) : (
        <div className="space-y-6 max-w-3xl">
          {details.git_branch && (
            <div className="flex items-center gap-2 text-sm text-(--color-muted-foreground)">
              <Icon name="git" />
              <span className="font-mono">{details.git_branch}</span>
              {details.git_dirty && (
                <span className="text-yellow-500 text-xs">(uncommitted changes)</span>
              )}
            </div>
          )}

          <div className="flex items-center gap-2 text-sm">
            <Icon name="document" className="text-(--color-muted-foreground)" />
            <span className="text-muted-foreground">CLAUDE.md</span>
            {project.claude_md_path ? (
              <Button
                variant="link"
                size="sm"
                onClick={() => onOpenEditor(project.claude_md_path!)}
                className="h-auto p-0 text-sm gap-1"
              >
                Open
                <Icon name="external" className="w-3 h-3" />
              </Button>
            ) : (
              <span className="text-muted-foreground/60 text-xs">
                (not found)
              </span>
            )}
          </div>

          {details.project.stats && (details.project.stats.total_input_tokens > 0 || details.project.stats.total_output_tokens > 0) && (
            <section className="border border-(--color-border) rounded-(--radius-lg) overflow-hidden">
              <div className="flex items-center gap-2 px-4 py-2.5 bg-(--color-muted) border-b border-(--color-border)">
                <Icon name="cpu" className="text-(--color-muted-foreground)" />
                <span className="text-xs font-medium uppercase tracking-wide text-(--color-muted-foreground)">Usage Statistics</span>
              </div>
              <div className="p-4 grid grid-cols-3 gap-4">
                <div>
                  <div className="text-xl font-semibold text-(--color-foreground)/80 leading-tight tabular-nums">
                    {formatCost(calculateCost(details.project.stats))}
                  </div>
                  <div className="text-xs text-(--color-muted-foreground) mt-0.5">Estimated cost</div>
                </div>
                <div>
                  <div className="text-xl font-semibold text-(--color-foreground)/80 leading-tight tabular-nums">
                    {formatTokenCount(details.project.stats.total_input_tokens + details.project.stats.total_output_tokens)}
                  </div>
                  <div className="text-xs text-(--color-muted-foreground) mt-0.5">Total tokens</div>
                </div>
                <div>
                  <div className="text-xl font-semibold text-(--color-foreground)/80 leading-tight tabular-nums">
                    {details.project.stats.session_count}
                  </div>
                  <div className="text-xs text-(--color-muted-foreground) mt-0.5">Sessions</div>
                </div>
                <div className="col-span-3 pt-3 mt-1 border-t border-(--color-border) grid grid-cols-3 gap-4">
                  <div className="space-y-1">
                    <div className="text-xs">
                      <span className="font-medium tabular-nums">{formatTokenCount(details.project.stats.total_input_tokens)}</span>
                      <span className="text-(--color-muted-foreground)"> input</span>
                    </div>
                    <div className="text-xs">
                      <span className="font-medium tabular-nums">{formatTokenCount(details.project.stats.total_output_tokens)}</span>
                      <span className="text-(--color-muted-foreground)"> output</span>
                    </div>
                  </div>
                  <div className="space-y-1">
                    {details.project.stats.opus_messages > 0 && (
                      <div className="text-xs">
                        <span className="font-medium tabular-nums">{details.project.stats.opus_messages}</span>
                        <span className="text-(--color-muted-foreground)"> Opus</span>
                      </div>
                    )}
                    {details.project.stats.sonnet_messages > 0 && (
                      <div className="text-xs">
                        <span className="font-medium tabular-nums">{details.project.stats.sonnet_messages}</span>
                        <span className="text-(--color-muted-foreground)"> Sonnet</span>
                      </div>
                    )}
                    {details.project.stats.haiku_messages > 0 && (
                      <div className="text-xs">
                        <span className="font-medium tabular-nums">{details.project.stats.haiku_messages}</span>
                        <span className="text-(--color-muted-foreground)"> Haiku</span>
                      </div>
                    )}
                  </div>
                  <div className="space-y-1">
                    {(details.project.stats.total_cache_read_tokens > 0 || details.project.stats.total_cache_creation_tokens > 0) && (
                      <>
                        <div className="text-xs">
                          <span className="font-medium tabular-nums">{formatTokenCount(details.project.stats.total_cache_read_tokens)}</span>
                          <span className="text-(--color-muted-foreground)"> cache read</span>
                        </div>
                        <div className="text-xs">
                          <span className="font-medium tabular-nums">{formatTokenCount(details.project.stats.total_cache_creation_tokens)}</span>
                          <span className="text-(--color-muted-foreground)"> cache created</span>
                        </div>
                      </>
                    )}
                  </div>
                </div>
              </div>
            </section>
          )}

          {details.tasks.length > 0 && (
            <section className="border border-(--color-border) rounded-(--radius-lg) overflow-hidden">
              <div className="flex items-center gap-2 px-4 py-2.5 bg-(--color-muted) border-b border-(--color-border)">
                <Icon name="list" className="text-(--color-muted-foreground)" />
                <span className="text-xs font-medium uppercase tracking-wide text-(--color-muted-foreground)">Recent Sessions</span>
                <span className="text-xs text-(--color-muted-foreground)/60">
                  {details.tasks.length}
                </span>
              </div>
              <div className="divide-y divide-(--color-border)">
                {details.tasks.slice(0, 10).map((task) => (
                  <div
                    key={task.id}
                    className="px-4 py-2.5 flex items-start justify-between gap-4 hover:bg-(--color-muted)/50"
                  >
                    <div className="flex-1 min-w-0">
                      <div className="text-sm truncate">
                        {task.summary || task.first_message || (
                          <span className="text-muted-foreground italic">Session {task.name.slice(0, 8)}</span>
                        )}
                      </div>
                      <div className="text-xs text-muted-foreground font-mono mt-0.5 truncate">
                        {task.name}
                      </div>
                    </div>
                    <span className="text-xs text-muted-foreground tabular-nums shrink-0">
                      {task.last_modified}
                    </span>
                  </div>
                ))}
              </div>
            </section>
          )}

          <section className="text-xs text-(--color-muted-foreground)">
            <div className="flex items-center gap-2">
              <Icon name="clock" className="w-3 h-3" />
              Last active: {project.last_active || "Unknown"}
            </div>
            {project.has_local_settings && (
              <div className="flex items-center gap-2 mt-1">
                <Icon name="settings" className="w-3 h-3" />
                Has local Claude settings
              </div>
            )}
          </section>
        </div>
      )}
    </div>
  );
}

function AddProjectPanel({
  suggestions,
  onAdd,
  onBack,
  isAdding,
}: {
  suggestions: SuggestedProject[];
  onAdd: (path: string) => void;
  onBack: () => void;
  isAdding: boolean;
}) {
  const [manualPath, setManualPath] = useState("");
  const [isDragging, setIsDragging] = useState(false);

  useEffect(() => {
    let unlistenDrop: (() => void) | undefined;
    let unlistenHover: (() => void) | undefined;
    let unlistenCancel: (() => void) | undefined;

    const setupListeners = async () => {
      unlistenHover = await listen<{ paths: string[] }>("tauri://drag-enter", () => {
        setIsDragging(true);
      });

      unlistenCancel = await listen("tauri://drag-leave", () => {
        setIsDragging(false);
      });

      unlistenDrop = await listen<{ paths: string[] }>("tauri://drag-drop", (event) => {
        setIsDragging(false);
        if (event.payload.paths && event.payload.paths.length > 0) {
          setManualPath(event.payload.paths[0]);
        }
      });
    };

    setupListeners();

    return () => {
      unlistenDrop?.();
      unlistenHover?.();
      unlistenCancel?.();
    };
  }, []);

  const handleManualAdd = () => {
    if (manualPath.trim()) {
      onAdd(manualPath.trim());
      setManualPath("");
    }
  };

  const handleBrowse = async () => {
    const selected = await open({
      directory: true,
      multiple: false,
      title: "Select Project Folder",
    });
    if (selected && typeof selected === "string") {
      setManualPath(selected);
    }
  };

  if (isAdding) {
    return (
      <div className="max-w-3xl">
        <div className="flex items-center gap-3 mb-6">
          <div className="h-8 w-8" />
          <h2 className="text-base font-medium">Add Project</h2>
        </div>
        <div className="flex flex-col items-center justify-center py-16 text-muted-foreground">
          <div className="animate-pulse text-sm">Adding project and computing statistics...</div>
          <div className="text-xs mt-2">This may take a moment for projects with many sessions</div>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-3xl">
      <div className="flex items-center gap-3 mb-6">
        <Button variant="ghost" size="icon" onClick={onBack} className="h-8 w-8">
          <Icon name="back" />
        </Button>
        <h2 className="text-base font-medium">Add Project</h2>
      </div>

      <div className="space-y-6">
        <section
          className={`p-4 border-2 border-dashed rounded-(--radius-lg) transition-colors ${
            isDragging
              ? "border-(--color-accent) bg-(--color-accent)/10"
              : "border-(--color-border)"
          }`}
        >
          <div className="flex gap-2">
            <Input
              type="text"
              value={manualPath}
              onChange={(e) => setManualPath(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && handleManualAdd()}
              placeholder="Enter path or drag folder here"
              className="flex-1 text-xs"
            />
            <Button
              variant="outline"
              onClick={handleBrowse}
              className="gap-1.5"
              title="Browse for folder"
            >
              <Icon name="folder" className="w-4 h-4" />
              Browse
            </Button>
            <Button
              onClick={handleManualAdd}
              disabled={!manualPath.trim()}
            >
              Add
            </Button>
          </div>
          <p className="text-xs text-(--color-muted-foreground) mt-2">
            Drag and drop a folder here, browse, or enter the path manually
          </p>
        </section>

        {suggestions.length > 0 && (
          <section>
            <h3 className="text-xs font-medium uppercase tracking-wide text-(--color-muted-foreground) mb-3">
              Suggested Projects
            </h3>
            <p className="text-xs text-(--color-muted-foreground) mb-4">
              Projects where you've used Claude Code
            </p>
            <div className="space-y-2">
              {suggestions.map((suggestion) => (
                <div
                  key={suggestion.path}
                  className="flex items-center justify-between p-3 border border-(--color-border) rounded-(--radius-md) hover:border-(--color-accent) transition-colors"
                >
                  <div className="flex-1 min-w-0">
                    <div className="font-medium text-sm">{suggestion.name}</div>
                    <div className="text-xs text-(--color-muted-foreground) truncate">
                      {suggestion.display_path}
                    </div>
                    <div className="flex items-center gap-3 mt-1 text-xs text-(--color-muted-foreground)">
                      <span className="tabular-nums">{suggestion.task_count} sessions</span>
                      {suggestion.has_claude_md && <span>Has CLAUDE.md</span>}
                    </div>
                  </div>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => onAdd(suggestion.path)}
                    className="ml-4"
                  >
                    Add
                  </Button>
                </div>
              ))}
            </div>
          </section>
        )}

        {suggestions.length === 0 && (
          <div className="text-(--color-muted-foreground) text-center py-8 border border-dashed border-(--color-border) rounded-(--radius-lg) text-xs">
            No suggestions available. Enter a project path above to add it.
          </div>
        )}
      </div>
    </div>
  );
}

function ArtifactsPanel({
  artifacts,
  plugins,
  filter,
  onFilterChange,
  selectedArtifact,
  artifactContent,
  onSelectArtifact,
  onOpenEditor,
  onTogglePlugin,
  onOpenFolder,
  onCloseArtifact,
}: {
  artifacts: Artifact[];
  plugins: PluginType[];
  filter: "all" | "skill" | "command" | "agent" | "plugin";
  onFilterChange: (filter: "all" | "skill" | "command" | "agent" | "plugin") => void;
  selectedArtifact: Artifact | null;
  artifactContent: string | null;
  onSelectArtifact: (artifact: Artifact) => void;
  onOpenEditor: (path: string) => void;
  onTogglePlugin: (id: string, enabled: boolean) => void;
  onOpenFolder: (path: string) => void;
  onCloseArtifact: () => void;
}) {
  const isPluginView = filter === "plugin";

  return (
    <div className="flex gap-6 h-full">
      <div className={`${selectedArtifact && !isPluginView ? "w-1/2" : "w-full max-w-2xl"} space-y-4`}>
        <div className="flex gap-1.5">
          {(["all", "skill", "command", "agent", "plugin"] as const).map((f) => (
            <Button
              key={f}
              variant={filter === f ? "default" : "secondary"}
              size="sm"
              onClick={() => onFilterChange(f)}
              className="h-7 text-xs"
            >
              {f === "all" ? "All" : f.charAt(0).toUpperCase() + f.slice(1) + "s"}
            </Button>
          ))}
        </div>

        {isPluginView ? (
          <div className="space-y-2">
            {plugins.map((plugin) => (
              <div
                key={plugin.id}
                className="border border-(--color-border) rounded-(--radius-md) p-3 group"
              >
                <div className="flex items-start justify-between">
                  <div className="flex items-center gap-3">
                    <Switch
                      checked={plugin.enabled}
                      onCheckedChange={(checked) => onTogglePlugin(plugin.id, checked)}
                    />
                    <div>
                      <div className="font-medium text-sm">{plugin.name}</div>
                      <div className="text-xs text-muted-foreground font-mono">
                        {plugin.id}
                      </div>
                    </div>
                  </div>
                  <Button
                    variant="ghost"
                    size="icon"
                    onClick={() => onOpenFolder(plugin.path)}
                    className="opacity-0 group-hover:opacity-100 h-8 w-8"
                    title="Open folder"
                  >
                    <Icon name="folder" />
                  </Button>
                </div>
                {plugin.description && (
                  <div className="text-xs text-(--color-muted-foreground) mt-2 ml-12">
                    {plugin.description}
                  </div>
                )}
                <div className="text-xs text-(--color-muted-foreground) mt-1.5 ml-12 tabular-nums">
                  {[
                    plugin.skill_count && `${plugin.skill_count} skills`,
                    plugin.command_count && `${plugin.command_count} commands`,
                    plugin.agent_count && `${plugin.agent_count} agents`,
                    plugin.hook_count && `${plugin.hook_count} hooks`,
                  ]
                    .filter(Boolean)
                    .join(" · ") || "No artifacts"}
                </div>
              </div>
            ))}
            {plugins.length === 0 && (
              <div className="text-(--color-muted-foreground) text-center py-8 text-xs">
                No plugins installed
              </div>
            )}
          </div>
        ) : (
          <div className="space-y-1 overflow-auto">
            {artifacts.map((artifact) => (
              <button
                key={artifact.path}
                onClick={() => onSelectArtifact(artifact)}
                className={`w-full text-left p-2.5 rounded-(--radius-md) border transition-colors ${
                  selectedArtifact?.path === artifact.path
                    ? "border-(--color-accent) bg-(--color-muted)"
                    : "border-transparent hover:bg-(--color-muted)"
                }`}
              >
                <div className="flex items-center justify-between">
                  <span className="font-medium text-sm">{artifact.name}</span>
                  <Badge variant="secondary" className="text-xs font-mono">
                    {artifact.source}
                  </Badge>
                </div>
                {artifact.description && (
                  <div className="text-xs text-(--color-muted-foreground) mt-1 line-clamp-2">
                    {artifact.description}
                  </div>
                )}
              </button>
            ))}
            {artifacts.length === 0 && (
              <div className="text-(--color-muted-foreground) text-center py-8 text-xs">
                No artifacts found
              </div>
            )}
          </div>
        )}
      </div>

      {selectedArtifact && !isPluginView && (
        <div className="w-1/2 border-l border-(--color-border) pl-6">
          <div className="flex items-center justify-between mb-3">
            <h3 className="font-semibold text-sm">{selectedArtifact.name}</h3>
            <div className="flex items-center gap-2">
              <Button
                variant="ghost"
                size="sm"
                onClick={() => onOpenEditor(selectedArtifact.path)}
                className="h-auto py-1 px-2 text-xs text-muted-foreground hover:text-foreground gap-1"
              >
                Open
                <Icon name="external" className="w-3 h-3" />
              </Button>
              <Button
                variant="ghost"
                size="icon"
                onClick={onCloseArtifact}
                className="h-7 w-7"
              >
                <Icon name="x" />
              </Button>
            </div>
          </div>

          <div className="text-xs text-(--color-muted-foreground) mb-3 font-mono truncate">
            {selectedArtifact.path}
          </div>

          <pre className="text-xs bg-(--color-muted) p-4 rounded-(--radius-md) overflow-auto max-h-[calc(100vh-280px)] font-mono whitespace-pre-wrap leading-relaxed">
            {artifactContent || "Loading..."}
          </pre>
        </div>
      )}
    </div>
  );
}

export default App;
