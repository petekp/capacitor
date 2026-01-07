# Tauri v2 macOS Native App Guide

Reference documentation for making Tauri apps feel native on macOS.

---

## Current State (January 2025)

### Known Issues

1. **Overlay Titlebar Drag Bug** ([#9503](https://github.com/tauri-apps/tauri/issues/9503))
   - Windows with `titleBarStyle: "Overlay"` cannot be dragged on macOS Sonoma
   - Status: Open, unresolved

2. **Unfocused Window Drag** ([#4316](https://github.com/tauri-apps/tauri/issues/4316))
   - `data-tauri-drag-region` doesn't work when window is not focused
   - Requires two clicks: one to focus, one to drag

3. **`-webkit-app-region: drag` Not Supported**
   - Tauri v2 does not support the CSS property
   - Must use `data-tauri-drag-region` attribute or `startDragging()` API

---

## Titlebar Approaches

### Option 1: Standard Titlebar (Recommended)

Keep the native macOS titlebar. Most reliable.

```json
// tauri.conf.json
{
  "app": {
    "windows": [{
      "title": "My App",
      "width": 900,
      "height": 700
    }]
  }
}
```

**Pros**: Native drag, window snapping, traffic lights work perfectly
**Cons**: Less custom appearance

---

### Option 2: Transparent Titlebar with Custom Background

Keeps native controls but allows custom window background color.

```json
// tauri.conf.json
{
  "app": {
    "windows": [{
      "titleBarStyle": "Transparent"
    }]
  }
}
```

```toml
# Cargo.toml
[target."cfg(target_os = \"macos\")".dependencies]
cocoa = "0.26"
```

```rust
// lib.rs - in setup()
#[cfg(target_os = "macos")]
{
    use cocoa::appkit::{NSColor, NSWindow};
    use cocoa::base::{id, nil};
    use tauri::Manager;

    if let Some(window) = app.get_webview_window("main") {
        let ns_window = window.ns_window().unwrap() as id;
        unsafe {
            let bg_color = NSColor::colorWithRed_green_blue_alpha_(
                nil,
                10.0 / 255.0,  // R
                10.0 / 255.0,  // G
                10.0 / 255.0,  // B
                1.0            // A
            );
            ns_window.setBackgroundColor_(bg_color);
        }
    }
}
```

**Pros**: Native drag works, custom background color
**Cons**: Traffic lights in standard position

---

### Option 3: Overlay Titlebar (Currently Buggy)

Traffic lights overlay your content. **Not recommended until bugs are fixed.**

```json
// tauri.conf.json
{
  "app": {
    "windows": [{
      "titleBarStyle": "Overlay",
      "hiddenTitle": true
    }]
  }
}
```

Requires manual drag implementation - see Programmatic Dragging section.

---

### Option 4: Fully Custom (No Decorations)

Complete control but lose all native window behavior.

```json
// tauri.conf.json
{
  "app": {
    "windows": [{
      "decorations": false,
      "transparent": true
    }]
  }
}
```

Must implement: drag, close, minimize, maximize, resize manually.

---

## Programmatic Window Dragging

When `data-tauri-drag-region` doesn't work, use the JavaScript API:

### Permission Required

```json
// src-tauri/capabilities/default.json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "default",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "core:window:allow-start-dragging"
  ]
}
```

### React Implementation

```tsx
import { getCurrentWindow } from '@tauri-apps/api/window';

function DragRegion({ children, className }: { children: React.ReactNode; className?: string }) {
  const handleMouseDown = async (e: React.MouseEvent) => {
    // Only drag if clicking directly on this element, not children
    if (e.target === e.currentTarget && e.button === 0) {
      await getCurrentWindow().startDragging();
    }
  };

  return (
    <div onMouseDown={handleMouseDown} className={className}>
      {children}
    </div>
  );
}

// Usage
<DragRegion className="h-8 w-full">
  <nav className="pointer-events-auto">
    {/* Interactive elements work normally */}
  </nav>
</DragRegion>
```

### Vanilla TypeScript

```typescript
import { getCurrentWindow } from '@tauri-apps/api/window';

document.getElementById('titlebar')?.addEventListener('mousedown', async (e) => {
  if (e.target === e.currentTarget && e.button === 0) {
    await getCurrentWindow().startDragging();
  }
});
```

---

## Vibrancy (Frosted Glass Effect)

### Setup

```toml
# Cargo.toml
[dependencies]
window-vibrancy = "0.7"
```

```json
// tauri.conf.json
{
  "app": {
    "windows": [{
      "transparent": true
    }]
  }
}
```

```css
/* index.css */
html, body, #root {
  background: transparent;
}
```

```rust
// lib.rs - in setup()
#[cfg(target_os = "macos")]
{
    use tauri::Manager;
    use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial};

    if let Some(window) = app.get_webview_window("main") {
        apply_vibrancy(&window, NSVisualEffectMaterial::Sidebar, None, None)
            .expect("Failed to apply vibrancy");
    }
}
```

### Available Materials

| Material | Use Case |
|----------|----------|
| `Sidebar` | Finder-style sidebar |
| `HudWindow` | HUD overlay windows |
| `FullScreenUI` | Full-screen UI elements |
| `Popover` | Popover windows |
| `Menu` | Menu backgrounds |
| `HeaderView` | Header areas |
| `UnderWindowBackground` | Behind window content |

---

## Native Polish CSS

Add to your base CSS for native feel:

```css
/* Disable text selection globally */
body {
  user-select: none;
  -webkit-user-select: none;
}

/* Allow selection in inputs and code */
input, textarea, pre, code, [contenteditable] {
  user-select: text;
  -webkit-user-select: text;
}

/* Default cursor (not I-beam) */
body {
  cursor: default;
}

/* Pointer cursor only on interactive elements */
button, a, [role="button"] {
  cursor: pointer;
}

/* Prevent bounce scrolling */
body {
  overflow: hidden;
}

/* Use system fonts */
body {
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

/* System monospace */
code, pre, .mono {
  font-family: "SF Mono", SFMono-Regular, ui-monospace, Menlo, monospace;
}
```

---

## Suppress Beep Sounds

macOS WebView beeps on unhandled keystrokes. Suppress selectively:

```typescript
// In your app initialization
document.addEventListener('keydown', (e) => {
  const target = e.target as HTMLElement;
  const isInput = target.tagName === 'INPUT' ||
                  target.tagName === 'TEXTAREA' ||
                  target.isContentEditable;

  // Don't suppress in input fields
  if (isInput) return;

  // Suppress beep for unhandled keys
  // But allow browser shortcuts (Cmd+C, Cmd+V, etc.)
  if (!e.metaKey && !e.ctrlKey) {
    e.preventDefault();
  }
});
```

---

## Dark Mode Support

```typescript
import { getCurrentWindow } from '@tauri-apps/api/window';

// Get current theme
const theme = await getCurrentWindow().theme(); // 'light' | 'dark'

// Listen for changes
await getCurrentWindow().onThemeChanged(({ payload }) => {
  console.log('Theme changed to:', payload);
  document.documentElement.classList.toggle('dark', payload === 'dark');
});
```

### CSS with Tailwind

```css
@media (prefers-color-scheme: dark) {
  :root {
    --background: #0a0a0a;
    --foreground: #fafafa;
  }
}
```

---

## Helpful Plugins

| Plugin | Purpose |
|--------|---------|
| [tauri-plugin-decorum](https://github.com/clearlysid/tauri-plugin-decorum) | Overlay titlebar helpers, traffic light positioning |
| [window-vibrancy](https://github.com/tauri-apps/window-vibrancy) | macOS vibrancy effects |
| [tauri-nspanel](https://github.com/nicholasblackburn1/tauri-nspanel) | Convert windows to panels (Spotlight-style) |
| [tauri-plugin-spotlight](https://github.com/nicholasblackburn1/tauri-plugin-spotlight) | Spotlight-like behavior |

---

## Example Apps for Reference

From [awesome-tauri](https://github.com/tauri-apps/awesome-tauri):

- **Cap** - Screen recording app with native feel
- **Spacedrive** - File manager with custom UI
- **Cider** - Apple Music client
- **Paperlib** - Paper management tool

---

## Checklist for Native Feel

- [ ] Disable text selection on UI elements
- [ ] Use system fonts (-apple-system)
- [ ] Set `cursor: default` globally
- [ ] Disable bounce scrolling
- [ ] Implement dark mode support
- [ ] Suppress beep sounds on keystrokes
- [ ] Use native dialogs where possible
- [ ] Implement keyboard shortcuts (Cmd+Q, Cmd+W, etc.)
- [ ] Custom app menu (or customize default)
- [ ] Test on both light and dark mode
- [ ] Test window dragging behavior
- [ ] Test with multiple monitors

---

## Resources

- [Tauri v2 Window Customization](https://v2.tauri.app/learn/window-customization/)
- [Tauri v2 Core Permissions](https://v2.tauri.app/reference/acl/core-permissions/)
- [Tauri v2 Capabilities](https://v2.tauri.app/security/capabilities/)
- [8 Tips for Native Look in Tauri](https://dev.to/akr/8-tips-for-creating-a-native-look-and-feel-in-tauri-applications-3loe)
- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/macos)

---

*Last updated: January 2025*
