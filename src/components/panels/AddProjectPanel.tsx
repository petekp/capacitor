import { useState, useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import type { SuggestedProject } from "@/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Icon } from "@/components/Icon";

interface AddProjectPanelProps {
  suggestions: SuggestedProject[];
  onAdd: (path: string) => void;
  onBack: () => void;
  isAdding: boolean;
}

export function AddProjectPanel({
  suggestions,
  onAdd,
  onBack,
  isAdding,
}: AddProjectPanelProps) {
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
