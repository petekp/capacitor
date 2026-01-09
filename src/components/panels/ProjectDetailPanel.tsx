import type { Project, ProjectDetails } from "@/types";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/Icon";
import { formatTokenCount, formatCost } from "@/utils/format";
import { calculateCost } from "@/utils/pricing";

interface ProjectDetailPanelProps {
  project: Project;
  details: ProjectDetails | null;
  onBack: () => void;
  onOpenEditor: (path: string) => void;
  onOpenFolder: (path: string) => void;
  onRemove: (path: string) => void;
}

export function ProjectDetailPanel({
  project,
  details,
  onBack,
  onOpenEditor,
  onOpenFolder,
  onRemove,
}: ProjectDetailPanelProps) {
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
