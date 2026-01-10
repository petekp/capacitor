import { useState } from "react";
import { motion, AnimatePresence } from "motion/react";
import type { Project, ProjectStatus, ProjectSessionState } from "@/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ProjectCard } from "@/components/ProjectCard";
import { CompactProjectCard } from "@/components/CompactProjectCard";
import { listVariants, springs, stagger } from "@/lib/motion";

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
  // eslint-disable-next-line react-hooks/purity -- Date.now() is stable within a render cycle; 24h threshold tolerates ms-level variance
  const now = Date.now();

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
    const hoursSince = (now - new Date(timestamp).getTime()) / 3600000;
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

  const sortAlphabetically = (a: typeof projectsWithData[0], b: typeof projectsWithData[0]) =>
    a.project.name.localeCompare(b.project.name);

  const recentProjects = filteredProjects
    .filter(isRecentOrActive)
    .sort(sortAlphabetically);

  const dormantProjects = filteredProjects
    .filter((item) => !isRecentOrActive(item))
    .sort(sortAlphabetically);

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      transition={{ duration: 0.2 }}
    >
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
        <motion.div whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.98 }}>
          <Button variant="ghost" size="sm" onClick={onAddProject} className="h-6 px-2 text-[11px] ml-2">
            + Add
          </Button>
        </motion.div>
      </div>

      <AnimatePresence mode="wait">
        {projects.length > 0 ? (
          <motion.div
            key="projects"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="space-y-6"
          >
            {recentProjects.length > 0 && (
              <div>
                <motion.h2
                  initial={{ opacity: 0, x: -10 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={springs.smooth}
                  className="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground mb-2"
                >
                  Recent
                </motion.h2>
                <motion.div
                  variants={listVariants}
                  initial="initial"
                  animate="animate"
                  className="space-y-2"
                >
                  {recentProjects.map(({ project, status, sessionState }, index) => (
                    <motion.div
                      key={project.path}
                      initial={{ opacity: 0, y: 10 }}
                      animate={{ opacity: 1, y: 0 }}
                      transition={{ delay: index * stagger.fast, ...springs.smooth }}
                    >
                      <ProjectCard
                        project={project}
                        status={status}
                        sessionState={sessionState}
                        isFocused={focusedProjectPath === project.path}
                        isAcknowledged={acknowledgedProjects.has(project.path)}
                        flashState={flashingProjects[project.path]}
                        onSelect={() => onSelectProject(project)}
                        onLaunchTerminal={() => { onAcknowledge(project.path); onLaunchTerminal(project.path, true); }}
                      />
                    </motion.div>
                  ))}
                </motion.div>
              </div>
            )}

            {dormantProjects.length > 0 && (
              <div>
                <motion.h2
                  initial={{ opacity: 0, x: -10 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ delay: recentProjects.length * stagger.fast + 0.1, ...springs.smooth }}
                  className="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground mb-2"
                >
                  {recentProjects.length > 0 ? `Dormant (${dormantProjects.length})` : "Projects"}
                </motion.h2>
                <motion.div className="space-y-1.5">
                  {dormantProjects.map(({ project, status }, index) => (
                    <motion.div
                      key={project.path}
                      initial={{ opacity: 0, y: 8 }}
                      animate={{ opacity: 1, y: 0 }}
                      transition={{
                        delay: (recentProjects.length + index) * stagger.fast + 0.15,
                        ...springs.smooth
                      }}
                    >
                      <CompactProjectCard
                        project={project}
                        status={status}
                        onSelect={() => onSelectProject(project)}
                        onLaunchTerminal={() => onLaunchTerminal(project.path, true)}
                      />
                    </motion.div>
                  ))}
                </motion.div>
              </div>
            )}

            {filteredProjects.length === 0 && (
              <motion.div
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                className="text-muted-foreground text-center py-8 text-xs"
              >
                No projects match your search
              </motion.div>
            )}
          </motion.div>
        ) : (
          <motion.div
            key="empty"
            initial={{ opacity: 0, scale: 0.95 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: 0.95 }}
            transition={springs.gentle}
          >
            <Button
              variant="ghost"
              onClick={onAddProject}
              className="w-full text-muted-foreground py-16 h-auto text-sm"
            >
              No projects yet
            </Button>
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>
  );
}
