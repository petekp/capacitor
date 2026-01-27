# Terminal Activation Test Matrix

**Purpose:** Pre-release manual verification of terminal activation scenarios
**Last Updated:** 2026-01-26

---

## Quick Reference

Run this matrix before releases to verify terminal activation works across all supported scenarios.

---

## 1. TERMINAL APP TESTS

### 1.1 Direct Shell (No Tmux)

| Test | Steps | Expected | ✅/❌ |
|------|-------|----------|-------|
| **Ghostty direct** | 1. Open Ghostty<br>2. `cd /project`<br>3. Click project in Capacitor | Ghostty window activates | |
| **iTerm direct** | 1. Open iTerm<br>2. `cd /project`<br>3. Click project in Capacitor | iTerm window activates | |
| **Terminal.app direct** | 1. Open Terminal<br>2. `cd /project`<br>3. Click project in Capacitor | Terminal window activates | |
| **Warp direct** | 1. Open Warp<br>2. `cd /project`<br>3. Click project in Capacitor | Warp window activates | |
| **kitty direct** | 1. Open kitty<br>2. `cd /project`<br>3. Click project in Capacitor | kitty window activates | |

### 1.2 IDE Integrated Terminals

| Test | Steps | Expected | ✅/❌ |
|------|-------|----------|-------|
| **Cursor terminal** | 1. Open Cursor with project<br>2. Open integrated terminal<br>3. Click project in Capacitor | Cursor window activates | |
| **VS Code terminal** | 1. Open VS Code with project<br>2. Open integrated terminal<br>3. Click project in Capacitor | VS Code window activates | |
| **IDE closed, shell tracked** | 1. Open Cursor terminal<br>2. Close Cursor<br>3. Click project in Capacitor | Launches new terminal (doesn't hang) | |

---

## 2. TMUX TESTS

### 2.1 Tmux Session Management

| Test | Steps | Expected | ✅/❌ |
|------|-------|----------|-------|
| **Tmux + client attached** | 1. Start tmux session<br>2. `cd /project`<br>3. Click project in Capacitor | Terminal with tmux activates, session switches | |
| **Tmux + NO client** | 1. Start tmux session<br>2. `cd /project`<br>3. Detach (`tmux detach`)<br>4. Click project in Capacitor | Launches new terminal with `tmux attach` | |
| **Tmux session gone** | 1. Create shell-cwd.json entry for tmux session<br>2. Kill the tmux session<br>3. Click project in Capacitor | Falls through to new terminal launch | |

### 2.2 Tmux Multi-Client

| Test | Steps | Expected | ✅/❌ |
|------|-------|----------|-------|
| **Client in iTerm** | 1. Start tmux in iTerm<br>2. Have Ghostty frontmost<br>3. Click project in Capacitor | iTerm activates (where tmux is) | |
| **Multiple clients** | 1. Start tmux<br>2. Attach in iTerm<br>3. Attach in Terminal.app<br>4. Use iTerm (make recent)<br>5. Click project in Capacitor | Most recent client activates | |

---

## 3. FOCUS RESOLUTION TESTS

### 3.1 Manual Override

| Test | Steps | Expected | ✅/❌ |
|------|-------|----------|-------|
| **Override persists** | 1. Click project A<br>2. In shell, `cd /project-b` (no Claude session)<br>3. Observe Capacitor | A stays highlighted | |
| **Override clears** | 1. Click project A<br>2. Start Claude in project B<br>3. In shell, `cd /project-b`<br>4. Observe Capacitor | B becomes highlighted | |
| **Override replaced** | 1. Click project A<br>2. Click project B<br>3. Observe Capacitor | B now highlighted | |

### 3.2 Session Priority

| Test | Steps | Expected | ✅/❌ |
|------|-------|----------|-------|
| **Working beats Ready** | 1. Have Claude Working in project A<br>2. Have Claude Ready in project B<br>3. Observe Capacitor | A is active (Working > Ready) | |
| **Active beats timestamp** | 1. Have older Working session in A<br>2. Have newer Ready session in B<br>3. Observe Capacitor | A is active (state > timestamp) | |

---

## 4. MONOREPO TESTS

### 4.1 Path Independence

| Test | Steps | Expected | ✅/❌ |
|------|-------|----------|-------|
| **Parent-child independent** | 1. Pin `/monorepo` and `/monorepo/packages/app`<br>2. Start Claude in `/monorepo/packages/app`<br>3. Observe Capacitor | Only `/monorepo/packages/app` shows active | |
| **Child navigates** | 1. Pin `/project`<br>2. Shell in `/project/src`<br>3. Click `/project` in Capacitor | Activates shell (child path finds parent project) | |

---

## 5. SHELL STALENESS TESTS

| Test | Steps | Expected | ✅/❌ |
|------|-------|----------|-------|
| **Fresh shell** | 1. `cd /project` (within last 10 min)<br>2. Check Capacitor | Shell shows as active source | |
| **Stale shell** | 1. `cd /project`<br>2. Wait >10 minutes<br>3. Check Capacitor | Shell excluded from resolution | |

---

## 6. ERROR RECOVERY TESTS

| Test | Steps | Expected | ✅/❌ |
|------|-------|----------|-------|
| **Dead PID in shell-cwd.json** | 1. Add fake entry for PID 999999<br>2. Click project in Capacitor | Falls through, launches new terminal | |
| **Corrupt shell-cwd.json** | 1. Write invalid JSON to shell-cwd.json<br>2. `cd /project`<br>3. Check Capacitor | Recovers, tracking works | |
| **Missing lock directory** | 1. Delete ~/.capacitor/sessions/<br>2. Start Claude session<br>3. Check Capacitor | Lock created, session tracked | |

---

## Test Execution Log

| Date | Tester | Version | Pass/Fail | Notes |
|------|--------|---------|-----------|-------|
| | | | | |

---

## Known Limitations

1. **Screen sessions** — Not supported (only tmux)
2. **SSH sessions** — Not detected as parent app
3. **kitty remote protocol** — May fail silently if not available
4. **Alacritty** — Basic activation only (no window selection)
