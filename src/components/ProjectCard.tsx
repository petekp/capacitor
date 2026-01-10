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
  const hasStatus = status && (status.working_on || status.next_step);

  const getStatusConfig = () => {
    if (!sessionState) return null;
    switch (sessionState.state) {
      case "ready": return { text: "Ready", bgClass: "bg-emerald-500/20", shimmerClass: "shimmer shimmer-bg shimmer-color-emerald-300/20 shimmer-speed-500", textClass: "text-emerald-400", dotClass: "bg-emerald-400" };
      case "compacting": return { text: "Compacting", bgClass: "bg-amber-700/20", textClass: "text-amber-500", dotClass: "bg-amber-500" };
      case "working": return { text: "Working", bgClass: "bg-orange-500/20", textClass: "text-orange-300", dotClass: "bg-orange-400" };
      case "waiting": return { text: "Input needed", bgClass: "bg-yellow-500/20", shimmerClass: "shimmer shimmer-bg shimmer-color-yellow-300/30 shimmer-speed-600", textClass: "text-yellow-300", dotClass: "bg-yellow-400" };
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
      layout
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
      className={`p-2.5 rounded-lg border bg-(--color-card) cursor-pointer ${isFocused ? "ring-2 ring-blue-500/40" : ""}`}
    >
      <div className="flex items-start justify-between gap-2 mb-1.5">
        <h3 className="font-semibold text-lg leading-tight tracking-[-0.01em]">
          {project.name}
        </h3>
        <div className="flex items-center gap-1 shrink-0">
          {statusConfig && (
            <motion.div
              initial={{ opacity: 0, scale: 0.9 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={springs.bouncy}
              className={`inline-flex items-center gap-1 px-1.5 py-0.5 rounded ${statusConfig.bgClass} ${(sessionState?.state === "waiting" || !isAcknowledged) && statusConfig.shimmerClass ? statusConfig.shimmerClass : ""}`}
            >
              <motion.span
                animate={{
                  scale: [1, 1.2, 1],
                  opacity: [1, 0.7, 1],
                }}
                transition={{
                  duration: 1.5,
                  repeat: Infinity,
                  ease: "easeInOut",
                }}
                className={`w-1.5 h-1.5 rounded-full ${statusConfig.dotClass}`}
              />
              <span className={`text-[9px] font-semibold uppercase tracking-wide ${statusConfig.textClass}`}>
                {statusConfig.text}
              </span>
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

      {(sessionState?.working_on || sessionState?.next_step || hasStatus) ? (
        <div className="space-y-0.5 mb-2">
          {(sessionState?.working_on || status?.working_on) && (
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.1 }}
              className="text-[12px] text-foreground/90 leading-snug line-clamp-2"
            >
              {sessionState?.working_on || status?.working_on}
            </motion.div>
          )}
          {(sessionState?.next_step || status?.next_step) && (
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.15 }}
              className="text-[11px] text-foreground/60 leading-snug line-clamp-1"
            >
              <span className="text-muted-foreground">→</span> {sessionState?.next_step || status?.next_step}
            </motion.div>
          )}
          {status?.blocker && (
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.2 }}
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
