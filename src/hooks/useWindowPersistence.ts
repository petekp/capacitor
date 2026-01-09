import { useEffect } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { saveWindowState, restoreStateCurrent, StateFlags } from "@tauri-apps/plugin-window-state";

export function useWindowPersistence() {
  useEffect(() => {
    restoreStateCurrent(StateFlags.ALL).catch(() => {});

    const win = getCurrentWindow();
    let saveTimeout: ReturnType<typeof setTimeout> | null = null;

    const debouncedSave = () => {
      if (saveTimeout) clearTimeout(saveTimeout);
      saveTimeout = setTimeout(() => {
        saveWindowState(StateFlags.ALL).catch(() => {});
      }, 500);
    };

    const unlistenMove = win.onMoved(debouncedSave);
    const unlistenResize = win.onResized(debouncedSave);

    return () => {
      if (saveTimeout) clearTimeout(saveTimeout);
      unlistenMove.then((f) => f());
      unlistenResize.then((f) => f());
    };
  }, []);
}
