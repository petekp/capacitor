import { useState, useEffect } from "react";
import { motion } from "motion/react";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import type { SuggestedProject } from "@/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Icon } from "@/components/Icon";
import { springs, stagger } from "@/lib/motion";

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
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        className="max-w-3xl"
      >
        <div className="flex items-center gap-3 mb-6">
          <div className="h-8 w-8" />
          <h2 className="text-base font-medium">Add Project</h2>
        </div>
        <div className="flex flex-col items-center justify-center py-16 text-muted-foreground">
          <div className="flex gap-1.5 mb-3">
            {[0, 1, 2].map((i) => (
              <motion.div
                key={i}
                className="w-2 h-2 rounded-full bg-(--color-muted-foreground)"
                animate={{
                  y: [0, -8, 0],
                  opacity: [0.4, 1, 0.4],
                }}
                transition={{
                  duration: 0.8,
                  repeat: Infinity,
                  delay: i * 0.15,
                  ease: "easeInOut",
                }}
              />
            ))}
          </div>
          <div className="text-sm">Adding project and computing statistics...</div>
          <div className="text-xs mt-2 opacity-60">This may take a moment for projects with many sessions</div>
        </div>
      </motion.div>
    );
  }

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
        <h2 className="text-base font-medium">Add Project</h2>
      </motion.div>

      <div className="space-y-6">
        <motion.section
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.1, ...springs.smooth }}
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
            <motion.div whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.98 }}>
              <Button
                variant="outline"
                onClick={handleBrowse}
                className="gap-1.5"
                title="Browse for folder"
              >
                <Icon name="folder" className="w-4 h-4" />
                Browse
              </Button>
            </motion.div>
            <motion.div whileHover={{ scale: 1.02 }} whileTap={{ scale: 0.98 }}>
              <Button
                onClick={handleManualAdd}
                disabled={!manualPath.trim()}
              >
                Add
              </Button>
            </motion.div>
          </div>
          <p className="text-xs text-(--color-muted-foreground) mt-2">
            Drag and drop a folder here, browse, or enter the path manually
          </p>
        </motion.section>

        {suggestions.length > 0 && (
          <motion.section
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.2, ...springs.smooth }}
          >
            <h3 className="text-xs font-medium uppercase tracking-wide text-(--color-muted-foreground) mb-3">
              Suggested Projects
            </h3>
            <p className="text-xs text-(--color-muted-foreground) mb-4">
              Projects where you've used Claude Code
            </p>
            <div className="space-y-2">
              {suggestions.map((suggestion, index) => (
                <motion.div
                  key={suggestion.path}
                  initial={{ opacity: 0, x: -10 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ delay: 0.25 + index * stagger.fast, ...springs.smooth }}
                  whileHover={{ scale: 1.01, x: 2 }}
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
                  <motion.div whileHover={{ scale: 1.05 }} whileTap={{ scale: 0.95 }}>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => onAdd(suggestion.path)}
                      className="ml-4"
                    >
                      Add
                    </Button>
                  </motion.div>
                </motion.div>
              ))}
            </div>
          </motion.section>
        )}

        {suggestions.length === 0 && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.2 }}
            className="text-(--color-muted-foreground) text-center py-8 border border-dashed border-(--color-border) rounded-(--radius-lg) text-xs"
          >
            No suggestions available. Enter a project path above to add it.
          </motion.div>
        )}
      </div>
    </motion.div>
  );
}
