import type { Project, ProjectStatus, ProjectSessionState } from "@/types";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/Icon";

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

  const getCardStateClass = () => {
    const classes: string[] = [];
    if (isFocused) classes.push("card-focused");
    if (flashState) {
      classes.push(`card-flash-${flashState}`);
    }
    return classes.join(" ");
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
            <div className={`inline-flex items-center gap-1 px-1.5 py-0.5 rounded ${statusConfig.bgClass} ${(sessionState?.state === "waiting" || !isAcknowledged) && statusConfig.shimmerClass ? statusConfig.shimmerClass : ""}`}>
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
