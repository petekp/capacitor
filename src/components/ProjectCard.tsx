import { motion } from "motion/react";
import type { Project, ProjectStatus, ProjectSessionState } from "@/types";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/Icon";
import { springs, cardVariants } from "@/lib/motion";

interface ProjectCardProps {
  project: Project;
  status: ProjectStatus | undefined;
  sessionState: ProjectSessionState | undefined;
  isFocused: boolean;
  isAcknowledged: boolean;
  flashState: string | undefined;
  onSelect: () => void;
  onLaunchTerminal: () => void;
}

export function ProjectCard({
  project,
  status,
  sessionState,
  isFocused,
  isAcknowledged,
  flashState,
  onSelect,
  onLaunchTerminal,
}: ProjectCardProps) {
  const hasStatus = status && status.working_on;

  const getStatusConfig = () => {
    if (!sessionState) return null;
    switch (sessionState.state) {
      case "ready": return { text: "Ready", pillClass: "status-ready", shimmer: true };
      case "compacting": return { text: "Compacting", pillClass: "status-compacting", shimmer: false };
      case "working": return { text: "Working", pillClass: "status-working", shimmer: false };
      case "waiting": return { text: "Input needed", pillClass: "status-waiting", shimmer: true };
      default: return null;
    }
  };

  const statusConfig = getStatusConfig();

  const getFlashShadow = () => {
    if (!flashState) return "0 0 0 0 transparent";
    switch (flashState) {
      case "ready": return "0 0 0 3px oklch(0.75 0.18 145 / 0.25)";
      case "compacting": return "0 0 0 3px oklch(0.7 0.15 60 / 0.2)";
      case "waiting": return "0 0 0 3px oklch(0.8 0.15 85 / 0.25)";
      default: return "0 0 0 0 transparent";
    }
  };

  return (
    <motion.div
      variants={cardVariants}
      initial="initial"
      animate="animate"
      whileHover="hover"
      whileTap="tap"
      onClick={onLaunchTerminal}
      style={{
        boxShadow: getFlashShadow(),
      }}
      transition={springs.snappy}
      className={`project-card cursor-pointer ${isFocused ? "card-focused" : ""}`}
    >
      <div className="flex items-start justify-between gap-2 mb-2">
        <h3 className="project-name">
          {project.name}
        </h3>
        <div className="flex items-center gap-1 shrink-0">
          {statusConfig && (
            <motion.div
              initial={{ opacity: 0, scale: 0.9 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={springs.bouncy}
              className={`status-pill ${statusConfig.pillClass} ${statusConfig.shimmer && !isAcknowledged ? "shimmer shimmer-bg" : ""}`}
            >
              <span className="status-dot" />
              <span>{statusConfig.text}</span>
            </motion.div>
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

      {(sessionState?.working_on || hasStatus) ? (
        <div className="space-y-0.5 mb-2">
          {(sessionState?.working_on || status?.working_on) && (
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.1 }}
              className="session-summary line-clamp-2"
            >
              {sessionState?.working_on || status?.working_on}
            </motion.div>
          )}
          {status?.blocker && (
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.15 }}
              className="text-[10px] text-red-400 leading-snug"
            >
              <span className="font-medium">Blocked:</span> {status.blocker}
            </motion.div>
          )}
        </div>
      ) : (
        <div className="text-[11px] text-muted-foreground/40 italic mb-2">
          No recent activity
        </div>
      )}
    </motion.div>
  );
}
