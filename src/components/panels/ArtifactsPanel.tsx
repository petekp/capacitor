import type { Artifact, Plugin as PluginType } from "@/types";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { Badge } from "@/components/ui/badge";
import { Icon } from "@/components/Icon";

interface ArtifactsPanelProps {
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
}

export function ArtifactsPanel({
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
}: ArtifactsPanelProps) {
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
