import { motion } from "motion/react";
import { springs } from "@/lib/motion";

interface TabButtonProps {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}

export function TabButton({ active, onClick, children }: TabButtonProps) {
  return (
    <motion.button
      onClick={onClick}
      whileHover={{ backgroundColor: "var(--color-muted)" }}
      whileTap={{ scale: 0.98 }}
      transition={springs.snappy}
      className={`flex-1 flex items-center justify-center gap-1 px-3 py-2 text-[12px] font-medium relative ${
        active
          ? "text-(--color-foreground)"
          : "text-(--color-muted-foreground)"
      }`}
    >
      {children}
      {active && (
        <motion.div
          layoutId="tab-indicator"
          className="absolute bottom-0 left-2 right-2 h-0.5 bg-(--color-foreground) rounded-full"
          transition={springs.snappy}
        />
      )}
    </motion.button>
  );
}
