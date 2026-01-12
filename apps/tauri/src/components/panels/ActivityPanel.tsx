import { motion, AnimatePresence } from "motion/react";
import type { ProjectCreation } from "@/types";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/Icon";
import { springs, stagger } from "@/lib/motion";

interface ActivityPanelProps {
  creations: ProjectCreation[];
  onBack: () => void;
  onCancel?: (id: string) => void;
  onRetry?: (id: string) => void;
  onOpenProject?: (path: string) => void;
}

const phaseLabels: Record<string, string> = {
  setup: "Setting up",
  dependencies: "Installing dependencies",
  building: "Building",
  testing: "Testing",
  thinking: "Planning",
  complete: "Complete",
};

function getPhaseIcon(phase: string): string {
  switch (phase) {
    case "setup":
      return "folder";
    case "dependencies":
      return "package";
    case "building":
      return "code";
    case "testing":
      return "check";
    case "thinking":
      return "sparkles";
    case "complete":
      return "checkCircle";
    default:
      return "spinner";
  }
}

function getStatusColor(status: string): string {
  switch (status) {
    case "completed":
      return "text-green-500";
    case "failed":
      return "text-orange-500";
    case "cancelled":
      return "text-(--color-muted-foreground)";
    default:
      return "text-accent";
  }
}

function CreationCard({
  creation,
  onCancel,
  onRetry,
  onOpenProject,
  index,
}: {
  creation: ProjectCreation;
  onCancel?: (id: string) => void;
  onRetry?: (id: string) => void;
  onOpenProject?: (path: string) => void;
  index: number;
}) {
  const isActive = creation.status === "pending" || creation.status === "in_progress";
  const phase = creation.progress?.phase ?? "setup";
  const percentComplete = creation.progress?.percent_complete ?? 0;

  return (
    <motion.div
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -10 }}
      transition={{ delay: index * stagger.fast, ...springs.smooth }}
      className="p-4 border border-(--color-border) rounded-(--radius-md) bg-(--color-card)"
    >
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-center gap-2">
          <div className={`h-8 w-8 rounded-full flex items-center justify-center ${
            isActive ? "bg-accent/15" : creation.status === "completed" ? "bg-green-500/15" : "bg-orange-500/15"
          }`}>
            <Icon
              name={isActive ? "sparkles" : creation.status === "completed" ? "checkCircle" : "alert"}
              className={`w-4 h-4 ${getStatusColor(creation.status)}`}
            />
          </div>
          <div>
            <h3 className="font-medium text-sm">{creation.name}</h3>
            <p className="text-xs text-(--color-muted-foreground) truncate max-w-[200px]">
              {creation.description}
            </p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {isActive && onCancel && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => onCancel(creation.id)}
              className="h-7 px-2 text-xs"
            >
              Cancel
            </Button>
          )}
          {creation.status === "failed" && onRetry && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => onRetry(creation.id)}
              className="h-7 px-2 text-xs"
            >
              Retry
            </Button>
          )}
          {creation.status === "completed" && onOpenProject && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => onOpenProject(creation.path)}
              className="h-7 px-2 text-xs gap-1"
            >
              <Icon name="terminal" className="w-3 h-3" />
              Open
            </Button>
          )}
        </div>
      </div>

      {isActive && (
        <>
          <div className="flex items-center gap-2 mb-2">
            <Icon name={getPhaseIcon(phase)} className="w-3.5 h-3.5 text-(--color-muted-foreground)" />
            <span className="text-xs text-(--color-muted-foreground)">
              {phaseLabels[phase] ?? phase}
            </span>
            {creation.progress?.message && (
              <span className="text-xs text-(--color-muted-foreground) truncate flex-1">
                — {creation.progress.message}
              </span>
            )}
          </div>

          <div className="h-1.5 bg-(--color-muted) rounded-full overflow-hidden">
            <motion.div
              className="h-full bg-accent rounded-full"
              initial={{ width: 0 }}
              animate={{ width: `${percentComplete}%` }}
              transition={{ duration: 0.3 }}
            />
          </div>

          {percentComplete > 0 && (
            <div className="flex justify-end mt-1">
              <span className="text-xs text-(--color-muted-foreground) tabular-nums">
                {percentComplete}%
              </span>
            </div>
          )}
        </>
      )}

      {creation.status === "failed" && creation.error && (
        <div className="mt-2 p-2 rounded bg-orange-500/10 border border-orange-500/20">
          <div className="flex items-center gap-2 text-orange-500">
            <Icon name="alert" className="w-3.5 h-3.5" />
            <span className="text-xs">{creation.error}</span>
          </div>
        </div>
      )}

      {creation.status === "completed" && (
        <div className="mt-2 text-xs text-(--color-muted-foreground)">
          Project created at <span className="font-mono">{creation.path}</span>
        </div>
      )}
    </motion.div>
  );
}

export function ActivityPanel({
  creations,
  onBack,
  onCancel,
  onRetry,
  onOpenProject,
}: ActivityPanelProps) {
  const activeCreations = creations.filter(
    (c) => c.status === "pending" || c.status === "in_progress"
  );
  const completedCreations = creations.filter(
    (c) => c.status === "completed" || c.status === "failed" || c.status === "cancelled"
  );

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="max-w-3xl"
    >
      <motion.div
        initial={{ opacity: 0, y: -10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={springs.smooth}
        className="flex items-center gap-3 mb-6"
      >
        <motion.div whileHover={{ x: -2 }} whileTap={{ scale: 0.95 }}>
          <Button variant="ghost" size="icon" onClick={onBack} className="h-8 w-8">
            <Icon name="back" />
          </Button>
        </motion.div>
        <div className="flex items-center gap-2">
          <div className="h-8 w-8 rounded-full bg-(--color-accent)/15 flex items-center justify-center">
            <Icon name="activity" className="w-4 h-4 text-(--color-accent)" />
          </div>
          <div>
            <h2 className="text-base font-medium">Activity</h2>
            <p className="text-xs text-(--color-muted-foreground)">
              {activeCreations.length > 0
                ? `${activeCreations.length} project${activeCreations.length > 1 ? "s" : ""} in progress`
                : "No active creations"}
            </p>
          </div>
        </div>
      </motion.div>

      <div className="space-y-6">
        {activeCreations.length > 0 && (
          <motion.section
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.1, ...springs.smooth }}
          >
            <h3 className="text-xs font-medium uppercase tracking-wide text-(--color-muted-foreground) mb-3">
              In Progress
            </h3>
            <div className="space-y-3">
              <AnimatePresence mode="popLayout">
                {activeCreations.map((creation, index) => (
                  <CreationCard
                    key={creation.id}
                    creation={creation}
                    onCancel={onCancel}
                    onRetry={onRetry}
                    onOpenProject={onOpenProject}
                    index={index}
                  />
                ))}
              </AnimatePresence>
            </div>
          </motion.section>
        )}

        {completedCreations.length > 0 && (
          <motion.section
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: activeCreations.length > 0 ? 0.2 : 0.1, ...springs.smooth }}
          >
            <h3 className="text-xs font-medium uppercase tracking-wide text-(--color-muted-foreground) mb-3">
              Recent
            </h3>
            <div className="space-y-3">
              <AnimatePresence mode="popLayout">
                {completedCreations.map((creation, index) => (
                  <CreationCard
                    key={creation.id}
                    creation={creation}
                    onCancel={onCancel}
                    onRetry={onRetry}
                    onOpenProject={onOpenProject}
                    index={index}
                  />
                ))}
              </AnimatePresence>
            </div>
          </motion.section>
        )}

        {creations.length === 0 && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.2 }}
            className="text-(--color-muted-foreground) text-center py-12 border border-dashed border-(--color-border) rounded-(--radius-lg)"
          >
            <Icon name="sparkles" className="w-8 h-8 mx-auto mb-3 opacity-40" />
            <p className="text-sm mb-1">No active creations</p>
            <p className="text-xs opacity-60">
              Use "New Idea" to start building a project
            </p>
          </motion.div>
        )}
      </div>
    </motion.div>
  );
}
