import type { Project, ProjectStatus } from "@/types";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/Icon";

interface CompactProjectCardProps {
  project: Project;
  status?: ProjectStatus;
  onSelect: () => void;
  onLaunchTerminal: () => void;
}

export function CompactProjectCard({
  project,
  status,
  onSelect,
  onLaunchTerminal,
}: CompactProjectCardProps) {
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
