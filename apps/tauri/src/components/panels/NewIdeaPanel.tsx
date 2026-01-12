import { useState } from "react";
import { motion } from "motion/react";
import { invoke } from "@tauri-apps/api/core";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Icon } from "@/components/Icon";
import { springs } from "@/lib/motion";

interface NewIdeaPanelProps {
  onBack: () => void;
  onSuccess: (projectPath: string) => void;
}

interface CreateProjectResult {
  success: boolean;
  project_path: string;
  session_id?: string;
  error?: string;
}

const LANGUAGES = ["TypeScript", "Python", "Rust", "Go", "JavaScript"];
const DEFAULT_LOCATION = "~/Code";

export function NewIdeaPanel({ onBack, onSuccess }: NewIdeaPanelProps) {
  const [projectName, setProjectName] = useState("");
  const [description, setDescription] = useState("");
  const [selectedLanguage, setSelectedLanguage] = useState<string | null>(null);
  const [framework, setFramework] = useState("");
  const [isCreating, setIsCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isFormValid = projectName.trim() && description.trim();

  const handleCreate = async () => {
    if (!isFormValid) return;

    setIsCreating(true);
    setError(null);

    try {
      const result = await invoke<CreateProjectResult>("create_project_from_idea", {
        request: {
          name: projectName.trim(),
          description: description.trim(),
          location: DEFAULT_LOCATION,
          language: selectedLanguage?.toLowerCase() ?? null,
          framework: framework.trim() || null,
        },
      });

      if (result.success) {
        onSuccess(result.project_path);
      } else {
        setError(result.error ?? "Failed to create project");
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setIsCreating(false);
    }
  };

  if (isCreating) {
    return (
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        className="max-w-3xl"
      >
        <div className="flex items-center gap-3 mb-6">
          <div className="h-8 w-8" />
          <h2 className="text-base font-medium">Creating Project...</h2>
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
          <div className="text-sm">Claude is building your project...</div>
          <div className="text-xs mt-2 opacity-60">
            Creating files, installing dependencies, and setting up the project
          </div>
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
        <div className="flex items-center gap-2">
          <div className="h-8 w-8 rounded-full bg-(--color-accent)/15 flex items-center justify-center">
            <Icon name="sparkles" className="w-4 h-4 text-(--color-accent)" />
          </div>
          <div>
            <h2 className="text-base font-medium">New Idea</h2>
            <p className="text-xs text-(--color-muted-foreground)">Claude will build a working v1</p>
          </div>
        </div>
      </motion.div>

      <div className="space-y-5">
        <motion.section
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.1, ...springs.smooth }}
        >
          <label className="block text-xs font-medium uppercase tracking-wide text-(--color-muted-foreground) mb-2">
            Project Name
          </label>
          <Input
            type="text"
            value={projectName}
            onChange={(e) => setProjectName(e.target.value)}
            placeholder="my-awesome-project"
            className="text-sm"
          />
        </motion.section>

        <motion.section
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.15, ...springs.smooth }}
        >
          <label className="block text-xs font-medium uppercase tracking-wide text-(--color-muted-foreground) mb-2">
            What do you want to build?
          </label>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="Describe your project idea in a few sentences..."
            className="w-full min-h-[80px] max-h-[120px] text-sm p-3 rounded-(--radius-md) border border-(--color-border) bg-transparent resize-none focus:outline-none focus:ring-1 focus:ring-(--color-accent)"
          />
        </motion.section>

        <motion.section
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2, ...springs.smooth }}
        >
          <label className="block text-xs font-medium uppercase tracking-wide text-(--color-muted-foreground) mb-2">
            Language (optional)
          </label>
          <div className="flex flex-wrap gap-2">
            {LANGUAGES.map((lang) => (
              <motion.button
                key={lang}
                whileHover={{ scale: 1.02 }}
                whileTap={{ scale: 0.98 }}
                onClick={() =>
                  setSelectedLanguage(selectedLanguage === lang ? null : lang)
                }
                className={`px-3 py-1.5 text-xs font-medium rounded-(--radius-md) transition-colors ${
                  selectedLanguage === lang
                    ? "bg-(--color-accent) text-(--color-background)"
                    : "bg-(--color-muted) text-(--color-muted-foreground) hover:bg-(--color-muted)/80"
                }`}
              >
                {lang}
              </motion.button>
            ))}
          </div>
        </motion.section>

        {selectedLanguage && (
          <motion.section
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: "auto" }}
            exit={{ opacity: 0, height: 0 }}
            transition={springs.smooth}
          >
            <label className="block text-xs font-medium uppercase tracking-wide text-(--color-muted-foreground) mb-2">
              Framework (optional)
            </label>
            <Input
              type="text"
              value={framework}
              onChange={(e) => setFramework(e.target.value)}
              placeholder="e.g., Next.js, FastAPI, Actix"
              className="text-sm"
            />
          </motion.section>
        )}

        {error && (
          <motion.div
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            className="p-3 rounded-(--radius-md) bg-orange-500/10 border border-orange-500/20"
          >
            <div className="flex items-center gap-2 text-orange-500">
              <Icon name="alert" className="w-4 h-4" />
              <span className="text-sm">{error}</span>
            </div>
          </motion.div>
        )}

        <motion.div
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.25, ...springs.smooth }}
        >
          <motion.div whileHover={{ scale: 1.01 }} whileTap={{ scale: 0.99 }}>
            <Button
              onClick={handleCreate}
              disabled={!isFormValid}
              className="w-full gap-2"
            >
              <Icon name="sparkles" className="w-4 h-4" />
              Create Project
            </Button>
          </motion.div>
        </motion.div>
      </div>
    </motion.div>
  );
}
