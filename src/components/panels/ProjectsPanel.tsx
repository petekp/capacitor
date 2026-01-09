import { useState } from "react";
import type { Project, ProjectStatus, ProjectSessionState } from "@/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ProjectCard } from "@/components/ProjectCard";
import { CompactProjectCard } from "@/components/CompactProjectCard";

interface ProjectsPanelProps {
  projects: Project[];
  projectStatuses: Record<string, ProjectStatus>;
  sessionStates: Record<string, ProjectSessionState>;
  focusedProjectPath: string | null;
  acknowledgedProjects: Set<string>;
  flashingProjects: Record<string, string>;
  onSelectProject: (project: Project) => void;
  onAddProject: () => void;
  onLaunchTerminal: (path: string, runClaude: boolean) => void;
  onAcknowledge: (path: string) => void;
}

export function ProjectsPanel({
  projects,
  projectStatuses,
  sessionStates,
  focusedProjectPath,
  acknowledgedProjects,
  flashingProjects,
  onSelectProject,
  onAddProject,
  onLaunchTerminal,
  onAcknowledge,
}: ProjectsPanelProps) {
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

    if (sessionState?.state === "working" || sessionState?.state === "ready" || sessionState?.state === "compacting") {
      return true;
    }

    if (sessionState?.state_changed_at && isRecentTimestamp(sessionState.state_changed_at)) {
      return true;
    }

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
    const aReady = a.sessionState?.state === "ready" ? 1 : 0;
    const bReady = b.sessionState?.state === "ready" ? 1 : 0;
    if (aReady !== bReady) return bReady - aReady;

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
                    flashState={flashingProjects[project.path]}
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
