"""Custom Kitty sidebar with session status and timer controls."""

import fcntl
import math
import os
import pty
import re
import select
import struct
import termios
import json
import subprocess
from pathlib import Path
from shutil import which
from threading import Thread, Timer
from time import monotonic, time

from kitty.fast_data_types import (
    add_timer,
    remove_timer,
    os_window_is_invisible,
    GLFW_MOUSE_BUTTON_LEFT,
    GLFW_PRESS,
    GLFW_RELEASE,
    get_boss,
    get_tab_being_dragged,
    set_tab_being_dragged,
)
from kitty.tab_bar import draw_tab_with_powerline, truncate_line, TabBar, CellRange
from kitty.fast_data_types import wcswidth
from kitty.tabs import TabManager


def paired_status(tab):
    if tab is None or len(tab) < 2:
        return None
    dots = {}
    for window in tab:
        fields = window.user_vars.get("clawdex_status", "").split(":")
        if len(fields) != 4:
            continue
        agent, marker, state, color = fields
        if (agent not in ("claude", "codex") or marker not in ("●", "○", "◉", "◐", "◑")
                or state not in ("ready", "dim") or len(color) != 7 or color[0] != "#"
                or any(c not in "0123456789abcdefABCDEF" for c in color[1:])):
            continue
        # Codex can already be mid-turn when Clawdex starts observing it.
        # Its live child title keeps spinning even with a fixed Kitty pane title.
        title = window.child_title or ""
        if agent == "codex" and len(title) >= 2 and title[0] in "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" and title[1] == " ":
            marker, state = "○", "dim"
        dots[agent] = marker, state == "ready", int(color[1:], 16)
    if dots:
        missing = ("·", False, 0x667386)
        return [dots.get(agent, missing) for agent in ("claude", "codex")]


def draw_tab(draw_data, screen, tab, before, max_tab_length, index, is_last, extra_data):
    manager = get_boss().os_window_map.get(tab.os_window_id)
    if draw_data.tab_bar_edge in ("left", "right"):
        row = screen.cursor.y
        width = screen.columns
        height = max(1, min(3, draw_data.max_tab_title_lines, screen.lines - row))
        center = row + height // 2
        title = " ".join(tab.title.split())
        marker = title[0] if title.startswith(("● ", "○ ", "◉ ", "◐ ", "◑ ")) else ""
        if marker:
            title = title[2:]
        # ◐/◑ mean subagents are running. clawdex paints a ready tab's text
        # pure white, so a half dot on a white-text tab is still ready.
        ready = marker == "●" or (marker in ("◐", "◑") and tab.active_fg == 0xFFFFFF)
        # Use the full session accent even on an inactive tab. Readiness lights
        # the whole card; focus adds a brighter edge without changing its state.
        accent = tab.active_bg if tab.active_bg is not None else screen.cursor.bg >> 8
        def blend(first, second, amount):
            channels = [round(((first >> shift) & 255) * (1 - amount)
                              + ((second >> shift) & 255) * amount)
                        for shift in (16, 8, 0)]
            return (channels[0] << 16) | (channels[1] << 8) | channels[2]
        dots = paired_status(manager.tab_for_id(tab.tab_id) if manager else None) if width >= 8 else None
        if dots:
            ready_colors = [color for _, lit, color in dots if lit]
            ready = bool(ready_colors)
            if ready:
                accent = blend(ready_colors[0], ready_colors[-1], 0.5)
        background = 0x222936 if tab.is_active else 0x101318
        if ready:
            background = blend(0x101318, accent, 0.62 if tab.is_active else 0.46)
        edge = blend(accent, 0xFFFFFF, 0.30) if ready else 0x8797AE
        text_color = ((0xF1F5FA if tab.is_active or ready else 0xABB5C5) << 8) | 2
        screen.cursor.bg = (background << 8) | 2
        screen.cursor.fg = text_color
        screen.cursor.bold = tab.is_active
        screen.cursor.italic = False
        for line in range(row, row + height):
            screen.cursor.x, screen.cursor.y = 0, line
            screen.draw(" " * width)
            if tab.is_active:
                screen.cursor.x = 0
                screen.cursor.fg = (edge << 8) | 2
                screen.draw("▏")
                screen.cursor.fg = text_color
        screen.cursor.x, screen.cursor.y = 0, center
        close_column = width - 2
        show_close = width >= 6
        title_column = 5 if dots else 3
        title_width = max(0, close_column - title_column - 1)
        if dots:
            for index, (symbol, lit, color) in enumerate(dots):
                screen.cursor.x = 1 + 2 * index
                dot = blend(color, 0xFFFFFF, 0.28) if lit else color
                screen.cursor.fg = (dot << 8) | 2
                screen.draw(symbol)
            screen.cursor.fg = text_color
        elif marker and width >= 6:
            screen.cursor.x = 1
            dot = blend(accent, 0xFFFFFF, 0.28) if ready else 0x667386
            if marker in ("◐", "◑") and not ready:
                # Subagents running: brighter than an idle working ring.
                dot = 0x8797AE
            if marker == "◉":
                dot = tab.active_fg if tab.active_fg is not None else 0x8797AE
            screen.cursor.fg = (dot << 8) | 2
            screen.draw("●" if marker == "◉" else marker)
            screen.cursor.fg = text_color
        if title_width:
            if wcswidth(title) > title_width:
                title = truncate_line(title, title_width)
            screen.cursor.x = title_column
            screen.draw(title)
        if not extra_data.for_layout and manager is not None:
            close_hitboxes = getattr(manager, "_agent_close_hitboxes", {})
            manager._agent_close_hitboxes = close_hitboxes
            close_hitboxes.pop(tab.tab_id, None)
            if show_close:
                screen.cursor.x = close_column
                screen.cursor.bold = False
                screen.cursor.fg = (0x8797AE << 8) | 2
                screen.draw("×")
                close_hitboxes[tab.tab_id] = (close_column, center)
        # kitty uses the final cursor row to measure the tab's clickable extent.
        screen.cursor.x, screen.cursor.y = max(0, width - 1), row + height - 1
        return screen.cursor.x
    return draw_tab_with_powerline(draw_data, screen, tab, before, max_tab_length, index, is_last, extra_data)


def caffeine_state():
    boss = get_boss()
    state = getattr(boss, "_clawdex_caffeine", None)
    if state is None:
        state = {"process": None, "deadline": 0, "timer": None}
        boss._clawdex_caffeine = state
    state["retired"] = [process for process in state.get("retired", []) if process.poll() is None]
    process = state["process"]
    if process is not None and process.poll() is not None:
        state["process"] = None
        state["deadline"] = 0
    return state


def repaint_caffeine():
    for manager in tuple(get_boss().os_window_map.values()):
        manager.mark_tab_bar_dirty()


def refresh_caffeine(timer_id):
    state = caffeine_state()
    if state["process"] is None and not state["retired"]:
        if state["timer"] is not None:
            remove_timer(state["timer"])
            state["timer"] = None
    repaint_caffeine()


def extend_caffeine():
    state = caffeine_state()
    previous = state["process"]
    now = monotonic()
    deadline = max(now, state["deadline"]) + 3600 if previous is not None else now + 3600
    try:
        replacement = subprocess.Popen(
            ["/usr/bin/caffeinate", "-di", "-t", str(math.ceil(deadline - now))],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except OSError as error:
        get_boss().show_error("Cannot keep Mac awake", str(error))
        return
    state["process"], state["deadline"] = replacement, deadline
    if previous is not None:
        try:
            previous.terminate()
        except ProcessLookupError:
            pass
        state["retired"].append(previous)
    if state["timer"] is None:
        state["timer"] = add_timer(refresh_caffeine, 5.0, True)
    repaint_caffeine()


def stop_caffeine():
    state = caffeine_state()
    if state["process"] is not None:
        try:
            state["process"].terminate()
        except ProcessLookupError:
            pass
    add_timer(refresh_caffeine, 0.1, False)
    repaint_caffeine()


def claude_weekly_percent(output):
    # Positioning escapes can separate words in the CLI's terminal rendering.
    text = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b" ", output)
    match = re.search(rb"Current\s+week\s+\(all\s+models\)\s+"
                      rb"[^\r\n%0-9]*(\d{1,3})%\s+used", text)
    if match and int(match[1]) <= 100:
        return int(match[1])


def usage_working_directory(roots, projects):
    for root in roots:
        path = Path(root)
        for directory in (path, *path.parents):
            if projects.get(str(directory), {}).get("hasTrustDialogAccepted") and directory.is_dir():
                return directory
    return None


def fetch_claude_weekly(state):
    binary = which("claude") or str(Path.home() / ".local/bin/claude")
    # Ask the subscription CLI for its own usage, independent of API-key panes.
    env = os.environ.copy()
    for key in ("ANTHROPIC_API_KEY", "KITTY_WINDOW_ID", "KITTY_LISTEN_ON"):
        env.pop(key, None)
    try:
        config_dir = Path(env.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
        config_file = config_dir / ".claude.json"
        if not config_file.is_file():
            config_file = Path.home() / ".claude.json"
        try:
            projects = json.loads(config_file.read_text()).get("projects", {})
        except (OSError, ValueError):
            projects = {}
        cwd = usage_working_directory(state.get("pane_roots", ()), projects)
        master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
            with subprocess.Popen([binary, "--safe-mode", "--strict-mcp-config", "/usage"],
                                  stdin=slave, stdout=slave, stderr=slave, env=env, cwd=cwd,
                                  start_new_session=True) as client:
                try:
                    deadline = monotonic() + 15
                    output = bytearray()
                    while client.poll() is None and len(output) < 512_000:
                        remaining = deadline - monotonic()
                        if remaining <= 0:
                            break
                        if not select.select([master], [], [], min(1, remaining))[0]:
                            continue
                        output.extend(os.read(master, 65536))
                        used = claude_weekly_percent(output)
                        if used is not None:
                            state["claude_cli"] = (used, time() + 900)
                            break
                finally:
                    client.kill()
        finally:
            os.close(master)
            os.close(slave)
    except (OSError, ValueError):
        pass


def codex_weekly_window(result):
    limits = (result.get("rateLimitsByLimitId") or {}).get("codex") or result.get("rateLimits") or {}
    for key in ("primary", "secondary"):
        window = limits.get(key) or {}
        if window.get("windowDurationMins") == 7 * 24 * 60:
            return window.get("usedPercent"), window.get("resetsAt")


def fetch_codex_weekly(state):
    # Run the signed-in CLI off the GUI thread. Only retain the weekly window.
    binary = which("codex") or str(Path.home() / ".local/bin/codex")
    try:
        with subprocess.Popen([binary, "app-server"], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True) as client:
            timeout = Timer(15, client.kill)
            timeout.start()
            try:
                def send(message):
                    client.stdin.write(json.dumps(message) + "\n")
                    client.stdin.flush()

                send({"id": 1, "method": "initialize", "params": {
                    "clientInfo": {"name": "clawdex-kitty", "version": "1"}}})
                for line in client.stdout:
                    reply = json.loads(line)
                    if "error" in reply:
                        break
                    if reply.get("id") == 1:
                        send({"method": "initialized"})
                        send({"id": 2, "method": "account/rateLimits/read", "params": {}})
                    elif reply.get("id") == 2:
                        state["Codex"] = codex_weekly_window(reply["result"])
                        break
            finally:
                client.kill()
                timeout.cancel()
    except (OSError, ValueError, KeyError, TypeError):
        pass


def refresh_usage(timer_id):
    boss = get_boss()
    state = boss._clawdex_usage
    if not any(not os_window_is_invisible(window) for window in boss.os_window_map):
        state["paused"] = True
        return
    resumed = state.pop("paused", False)
    try:
        state["CC"] = json.loads((Path.home() / ".clawdex/claude-weekly.json").read_text())
    except (OSError, ValueError):
        state["CC"] = None
    now = monotonic()
    for agent, fetch, interval in (("codex", fetch_codex_weekly, 180),
                                   ("claude", fetch_claude_weekly, 600)):
        worker = state.get(agent + "_worker")
        if worker is not None and worker.is_alive():
            continue
        if resumed or now >= state.get(agent + "_due", 0):
            state[agent + "_due"] = now + interval
            if agent == "claude":
                state["pane_roots"] = tuple(w.child.cwd for w in boss.window_id_map.values() if w.child.cwd)
            worker = Thread(target=fetch, args=(state,), daemon=True)
            state[agent + "_worker"] = worker
            worker.start()
    repaint_caffeine()


def paired_agent_windows(tab):
    if tab.windows.num_groups != 2 or len(tab) != 2:
        return {}
    panes = {}
    for window in tab:
        provider = window.user_vars.get("clawdex_status", "").partition(":")[0] or window.title.lower()
        panes[provider] = window
    return panes if panes.keys() == {"claude", "codex"} else {}


def close_agent_panes(manager, agent):
    targets = {}
    for tab in manager.tabs:
        panes = paired_agent_windows(tab)
        if panes:
            targets[tab.id] = panes[agent].id
    boss = get_boss()
    if not targets:
        boss.show_error("Close terminals", "No paired agent terminals in this window.")
        return

    def close_confirmed(confirmed):
        if not confirmed:
            return
        saved = getattr(manager, "_clawdex_split_views", {})
        for tab in manager.tabs:
            if tab.id not in targets:
                continue
            pane = paired_agent_windows(tab).get(agent)
            if pane is None or pane.id != targets[tab.id]:
                continue
            if tab.id in saved:
                layout, _ = saved.pop(tab.id)
                tab.goto_layout(layout)
            boss.mark_window_for_close(pane)
        if not saved:
            manager._clawdex_hidden_agent = None
        manager.mark_tab_bar_dirty()

    name = "Claude" if agent == "claude" else "Codex"
    count = len(targets)
    noun = "terminal" if count == 1 else "terminals"
    boss.confirm(f"Close {count} {name} {noun} in this window? This ends their running sessions.",
                 close_confirmed, window=manager.active_tab.active_window)


def toggle_agent_panes(manager, agent):
    saved = getattr(manager, "_clawdex_split_views", {})
    hidden = None if getattr(manager, "_clawdex_hidden_agent", None) == agent else agent
    for tab in manager.tabs:
        if hidden is None:
            if tab.id in saved:
                layout, focus = saved[tab.id]
                tab.goto_layout(layout)
                original = next((w for w in tab if w.id == focus), None)
                if original is not None:
                    tab.set_active_window(original)
            continue
        panes = paired_agent_windows(tab)
        if not panes or "stack" not in tab.enabled_layouts:
            continue
        saved.setdefault(tab.id, (tab.current_layout.full_name, tab.active_window.id))
        tab.set_active_window(panes["codex" if hidden == "claude" else "claude"])
        tab.goto_layout("stack")
    manager._clawdex_split_views = saved if hidden else {}
    manager._clawdex_hidden_agent = hidden if manager._clawdex_split_views else None
    manager.mark_tab_bar_dirty()


def draw_usage_footer(screen, first_unused, controls, hidden):
    top = screen.lines - 5
    if top < first_unused or screen.columns < 12:
        return
    boss = get_boss()
    if not hasattr(boss, "_clawdex_usage"):
        boss._clawdex_usage = {}
    state = boss._clawdex_usage
    if state.get("timer_callback") is not refresh_usage:
        if "usage_timer" in state:
            remove_timer(state["usage_timer"])
        state["timer_callback"] = refresh_usage
        state["usage_timer"] = add_timer(refresh_usage, 5, True)
        add_timer(refresh_usage, 0.1, False)
    screen.cursor.bg = (0x101318 << 8) | 2
    screen.cursor.bold = screen.cursor.italic = False
    width = screen.columns - 11
    for row, (label, color) in enumerate((("CC", 0xFF9230), ("Codex", 0x449FFF)), top):
        screen.cursor.bg = (0x101318 << 8) | 2
        window = boss._clawdex_usage.get(label)
        native = boss._clawdex_usage.get("claude_cli")
        if label == "CC" and native and native[1] > time():
            window = native
        used = None
        if isinstance(window, (tuple, list)) and len(window) == 2:
            value, reset = window
            if (type(value) in (int, float) and 0 <= value <= 100
                    and type(reset) in (int, float) and reset > time()):
                used = value
        filled = round(width * used / 100) if used is not None else 0
        screen.cursor.x, screen.cursor.y = 0, row
        screen.cursor.fg = (color << 8) | 2
        value_text = f"{used:.0f}%" if used is not None else "—"
        screen.draw(value_text.ljust(5))
        screen.draw("█" * filled)
        screen.cursor.fg = (0x445064 << 8) | 2
        screen.draw("░" * (width - filled))
        agent = "claude" if label == "CC" else "codex"
        screen.cursor.bg = (0x202733 << 8) | 2
        screen.cursor.fg = (color << 8) | 2
        screen.draw(" + " if hidden == agent else " − ")
        controls.append(((screen.columns - 6, row, screen.columns - 3, row + 1), "toggle-" + agent))
        screen.cursor.bg = (0x30252B << 8) | 2
        screen.cursor.fg = (0xE4A5AB << 8) | 2
        screen.draw(" × ")
        controls.append(((screen.columns - 3, row, screen.columns, row + 1), "close-" + agent))


def draw_timer_footer(bar, first_unused, top, active, label, action, controls, colors):
    screen = bar.screen
    if top < first_unused or screen.columns < 12:
        return
    bottom = top + 3
    background, foreground, accent = colors
    column = screen.columns - 6
    cursor = (screen.cursor.x, screen.cursor.y, screen.cursor.bg,
              screen.cursor.fg, screen.cursor.bold, screen.cursor.italic)
    try:
        screen.cursor.bg = (background << 8) | 2
        screen.cursor.fg = (foreground << 8) | 2
        screen.cursor.bold = active
        screen.cursor.italic = False
        for row in range(top, bottom):
            screen.cursor.x, screen.cursor.y = 0, row
            screen.draw(" " * screen.columns)
        if wcswidth(label) > column - 2:
            label = truncate_line(label, column - 2)
        screen.cursor.x, screen.cursor.y = max(1, (column - wcswidth(label)) // 2), top + 1
        screen.draw(label)
        screen.cursor.bold = False
        for start, icon, button_action, color, button_bg in (
            (column, "+", action, accent, 0x302A22 if active else 0x202733),
            (column + 3, "■", action + "-stop", 0xD6A2A5 if active else 0x46505E, 0x2B2525 if active else 0x1C222C),
        ):
            screen.cursor.bg = (button_bg << 8) | 2
            screen.cursor.fg = (color << 8) | 2
            for row in range(top, bottom):
                screen.cursor.x, screen.cursor.y = start, row
                screen.draw(" " * 3)
            screen.cursor.x, screen.cursor.y = start + 1, top + 1
            screen.draw(icon)
            if active or button_action == action:
                controls.append(((start, top, start + 3, bottom), button_action))
        if not active:
            controls.append(((0, top, column, bottom), action))
    finally:
        (screen.cursor.x, screen.cursor.y, screen.cursor.bg,
         screen.cursor.fg, screen.cursor.bold, screen.cursor.italic) = cursor


def draw_caffeine_footer(bar, first_unused):
    controls = bar._clawdex_caffeine_controls = []
    cursor = bar.screen.cursor
    saved = cursor.x, cursor.y, cursor.bg, cursor.fg, cursor.bold, cursor.italic
    manager = get_boss().os_window_map.get(bar.os_window_id)
    draw_usage_footer(bar.screen, first_unused, controls, getattr(manager, "_clawdex_hidden_agent", None))
    cursor.x, cursor.y, cursor.bg, cursor.fg, cursor.bold, cursor.italic = saved
    state = caffeine_state()
    active = state["process"] is not None
    remaining = max(1, math.ceil((state["deadline"] - monotonic()) / 60))
    draw_timer_footer(
        bar, first_unused, bar.screen.lines - 3, active,
        f"Awake · {remaining}m" if active else "Stay awake · 1h", "caffeine", controls,
        (0x25221D if active else 0x19202A, 0xEBC58D if active else 0xABB5C5, 0xEBC58D),
    )


def icon_at(manager, x, y):
    bar = manager.tab_bar
    geometry = bar.window_geometry
    cell = ((int(x) - geometry.left) // bar.cell_width, (int(y) - geometry.top) // bar.cell_height)
    if bar.is_vertical:
        footer_cell = ((x - geometry.left) / bar.cell_width, (y - geometry.top) / bar.cell_height)
        for bounds, action in getattr(bar, "_clawdex_caffeine_controls", ()):
            if bounds[0] <= footer_cell[0] < bounds[2] and bounds[1] <= footer_cell[1] < bounds[3]:
                return (None, action)
    tab_id = bar.tab_id_at(int(x), int(y))
    if bar.is_vertical and cell == getattr(manager, "_agent_close_hitboxes", {}).get(tab_id):
        return (tab_id, "close")
    return None


def handle_tab_bar_mouse(manager, x, y, button, modifiers, action):
    if button == GLFW_MOUSE_BUTTON_LEFT and action == GLFW_PRESS:
        manager._pane_cycle_tab = None
    pending = getattr(manager, "_sidebar_control_pressed", None)
    if pending is not None:
        if button == GLFW_MOUSE_BUTTON_LEFT and action == GLFW_RELEASE:
            manager._sidebar_control_pressed = None
            if not modifiers and icon_at(manager, x, y) == pending:
                tab_id, control = pending
                if control in ("close-claude", "close-codex"):
                    close_agent_panes(manager, control[6:])
                    return
                if control in ("toggle-claude", "toggle-codex"):
                    toggle_agent_panes(manager, control[7:])
                    return
                if control in ("caffeine", "caffeine-stop"):
                    if control == "caffeine-stop":
                        stop_caffeine()
                    else:
                        extend_caffeine()
                    return
                tab = manager.tab_for_id(tab_id)
                if tab is not None and control == "close":
                    get_boss().close_tab(tab)
        return
    if button == GLFW_MOUSE_BUTTON_LEFT and action == GLFW_PRESS and not modifiers:
        control = icon_at(manager, x, y)
        if control is not None:
            manager._sidebar_control_pressed = control
            manager.recent_tab_bar_mouse_events.clear()
            return
        tab = manager.active_tab
        if (manager.tab_bar.is_vertical and tab is not None and tab.windows.num_groups == 2
                and tab.id not in getattr(manager, "_clawdex_split_views", {})
                and manager.tab_bar.tab_id_at(int(x), int(y)) == tab.id):
            manager._pane_cycle_tab = tab.id
    elif button == GLFW_MOUSE_BUTTON_LEFT and action == GLFW_RELEASE:
        pressed_tab = getattr(manager, "_pane_cycle_tab", None)
        manager._pane_cycle_tab = None
        if pressed_tab is not None and not modifiers:
            tab = manager.active_tab
            dragged_tab, dragging, _, _ = get_tab_being_dragged()
            if (not dragging and dragged_tab == pressed_tab and tab is not None and tab.id == pressed_tab
                    and tab.windows.num_groups == 2 and manager.tab_bar.tab_id_at(int(x), int(y)) == pressed_tab
                    and icon_at(manager, x, y) is None):
                set_tab_being_dragged()
                manager.recent_tab_bar_mouse_events.clear()
                tab.next_window()
                return
    return manager._agent_swap_original_mouse(x, y, button, modifiers, action)


# Keep the original handler across config reloads rather than wrapping it twice.
if not hasattr(TabManager, "_agent_swap_original_mouse"):
    TabManager._agent_swap_original_mouse = TabManager.handle_tab_bar_mouse
TabManager.handle_tab_bar_mouse = handle_tab_bar_mouse


# Kitty 0.49 inserts one blank row between vertical tabs. Compact that row
# after native layout, moving both native click bounds and close hitboxes.
def compact_vertical_tabs(bar, data):
    # Native layout clears using the current background, which may be the
    # previously selected card's color. Begin with the sidebar canvas instead.
    bar.screen.cursor.bg = (0x101318 << 8) | 2
    changed = bar._agent_compact_original_vertical(data)
    extents = tuple(bar.tab_extents)
    manager = get_boss().os_window_map.get(bar.os_window_id)
    close_hitboxes = getattr(manager, "_agent_close_hitboxes", {})
    compacted = []
    removed = 0
    previous_end = None
    screen = bar.screen
    for extent in extents:
        gap = 0 if previous_end is None else max(0, extent.y.start - previous_end - 1)
        if gap:
            start = extent.y.start - gap - removed
            if 0 <= start < screen.lines:
                screen.cursor.x, screen.cursor.y = 0, start
                screen.cursor.bg = (0x101318 << 8) | 2
                screen.delete_lines(min(gap, screen.lines - start))
                removed += gap
        compacted.append(extent._replace(y=CellRange(extent.y.start - removed, extent.y.end - removed)))
        if extent.tab_id in close_hitboxes:
            x, y = close_hitboxes[extent.tab_id]
            close_hitboxes[extent.tab_id] = (x, y - removed)
        previous_end = extent.y.end
    bar.tab_extents = tuple(compacted)
    # Empty space is sidebar canvas, never an extension of the final card.
    first_unused = compacted[-1].y.end + 1 if compacted else 0
    if 0 <= first_unused < screen.lines:
        cursor = (screen.cursor.x, screen.cursor.y, screen.cursor.bg, screen.cursor.fg)
        screen.cursor.x, screen.cursor.y = 0, first_unused
        screen.cursor.bg = (0x101318 << 8) | 2
        screen.cursor.fg = 0
        screen.erase_in_display(0, False)
        screen.cursor.x, screen.cursor.y, screen.cursor.bg, screen.cursor.fg = cursor
    draw_caffeine_footer(bar, first_unused)
    return changed


if not hasattr(TabBar, "_agent_compact_original_vertical"):
    TabBar._agent_compact_original_vertical = TabBar.update_vertical
TabBar.update_vertical = compact_vertical_tabs
