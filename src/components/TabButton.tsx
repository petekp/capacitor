interface TabButtonProps {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}

export function TabButton({ active, onClick, children }: TabButtonProps) {
  return (
    <button
      onClick={onClick}
      className={`flex-1 flex items-center justify-center gap-1 px-3 py-2 text-[12px] font-medium transition-colors ${
        active
          ? "text-(--color-foreground) border-b-2 border-(--color-foreground)"
          : "text-(--color-muted-foreground) hover:text-(--color-foreground) border-b-2 border-transparent"
      }`}
    >
      {children}
    </button>
  );
}
