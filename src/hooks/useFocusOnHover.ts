import { useEffect } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";

export function useFocusOnHover() {
  useEffect(() => {
    let lastFocus = 0;
    const handleMouseEnter = () => {
      const now = Date.now();
      if (now - lastFocus < 500) return;
      lastFocus = now;
      if (!document.hasFocus()) {
        getCurrentWindow().setFocus();
      }
    };
    document.addEventListener("mouseenter", handleMouseEnter);
    return () => document.removeEventListener("mouseenter", handleMouseEnter);
  }, []);
}
