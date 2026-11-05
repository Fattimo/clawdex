"""Claude/Codex tab switch with sidebar and horizontal rendering for kitty 0.49."""

import os
import shlex
import shutil
import math
import subprocess
from time import monotonic

from kitty.fast_data_types import (
    add_timer,
    remove_timer,
    GLFW_MOUSE_BUTTON_LEFT,
    GLFW_PRESS,
    GLFW_RELEASE,
    get_boss,
)
from kitty.tab_bar import draw_tab_with_powerline, truncate_line, TabBar, CellRange
from kitty.fast_data_types import wcswidth
from kitty.tabs import TabManager


def process_agent(process):
    args = process.get("cmdline") or []
    if not args:
        return None
    executable = os.path.basename(args[0])
    candidates = args[1:2] if executable in ("node", "bun") else args[:1]
    for arg in candidates:
        name = os.path.basename(arg)
        if name in ("claude", "codex", "claude.js", "codex.js"):
            return name.removesuffix(".js")
    return None


def running_agent(window):
    agents = {process_agent(process) for process in window.child.foreground_processes}
    agents.discard(None)
    return next(iter(agents)) if len(agents) == 1 else None


def switchable_window(tab):
    windows = list(tab)
    if len(windows) != 1:
        return None
    window = windows[0]
    return window if running_agent(window) else None


def project_root(cwd):
    directory = os.path.abspath(cwd)
    while True:
        # A linked Git worktree has a .git file instead of a directory.
        if os.path.exists(os.path.join(directory, ".git")):
            return directory
        parent = os.path.dirname(directory)
        if parent == directory:
            return cwd
        directory = parent


def agent_project_root(tab, window):
    pinned = getattr(tab, "_agent_swap_project_root", None)
    if pinned and os.path.isdir(pinned):
        return pinned
    roots = {
        project_root(process["cwd"])
        for process in window.child.foreground_processes
        if process_agent(process) and process.get("cwd") and os.path.isdir(process["cwd"])
    }
    return next(iter(roots)) if len(roots) == 1 else None


def swap_agent(tab):
    last_swap = getattr(tab, "_agent_swap_last_started", 0)
    if monotonic() - last_swap < 1:
        return
    window = switchable_window(tab)
    if window is None:
        return
    boss = get_boss()
    agent = "codex" if running_agent(window) == "claude" else "claude"
    search_path = os.pathsep.join((os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", os.environ.get("PATH", "")))
    executable = shutil.which(agent, path=search_path)
    if executable is None:
        boss.show_error("Cannot switch agent", f"{agent} is not installed on your PATH.")
        return
    cwd = agent_project_root(tab, window)
    if cwd is None:
        boss.show_error("Cannot switch agent", "Could not identify a single project directory for this CLI.")
        return
    arguments = [executable, "resume", "--last"] if agent == "codex" else [executable, "--continue"]
    direnv = shutil.which("direnv", path=search_path)
    if direnv and os.path.isfile(os.path.join(cwd, ".envrc")):
        arguments = [direnv, "exec", ".", *arguments]
    command = shlex.join(arguments) + "; exec /bin/zsh -i"
    try:
        replacement = tab.new_window(use_shell=False, cmd=["/bin/zsh", "-ic", command], cwd=cwd, copy_colors_from=window, hold=True)
    except Exception as error:
        boss.show_error("Cannot switch agent", str(error))
        return
    if replacement is None:
        return
    tab._agent_swap_project_root = cwd
    tab._agent_swap_last_started = monotonic()
    tab.set_active_window(replacement)
    boss.mark_window_for_close(window)


def draw_tab(draw_data, screen, tab, before, max_tab_length, index, is_last, extra_data):
    manager = get_boss().os_window_map.get(tab.os_window_id)
    actual_tab = manager.tab_for_id(tab.tab_id) if manager is not None else None
    window = switchable_window(actual_tab) if actual_tab is not None else None
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
        column = width - 4
        show_close = width >= 6
        show_switch = window is not None and width >= 9
        title_width = max(0, (column - 1 if show_switch else close_column - 1) - 3)
        if marker and width >= 6:
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
            screen.cursor.x = 3
            screen.draw(title)
        if not extra_data.for_layout and manager is not None:
            hitboxes = getattr(manager, "_agent_swap_hitboxes", {})
            manager._agent_swap_hitboxes = hitboxes
            hitboxes.pop(tab.tab_id, None)
            close_hitboxes = getattr(manager, "_agent_close_hitboxes", {})
            manager._agent_close_hitboxes = close_hitboxes
            close_hitboxes.pop(tab.tab_id, None)
            if show_close:
                screen.cursor.x = close_column
                screen.cursor.bold = False
                screen.cursor.fg = (0x8797AE << 8) | 2
                screen.draw("×")
                close_hitboxes[tab.tab_id] = (close_column, center)
            if show_switch:
                screen.cursor.x = column
                screen.cursor.bold = False
                screen.cursor.fg = (0xC6CDD8 << 8) | 2
                screen.draw("⇄")
                hitboxes[tab.tab_id] = (column, center)
        # kitty uses the final cursor row to measure the tab's clickable extent.
        screen.cursor.x, screen.cursor.y = max(0, width - 1), row + height - 1
        return screen.cursor.x
    foreground, background = screen.cursor.fg, screen.cursor.bg
    end = draw_tab_with_powerline(draw_data, screen, tab, before, max_tab_length, index, is_last, extra_data)
    if not extra_data.for_layout:
        if manager is not None:
            hitboxes = getattr(manager, "_agent_swap_hitboxes", {})
            manager._agent_swap_hitboxes = hitboxes
            hitboxes.pop(tab.tab_id, None)
            # The title template reserves three trailing spaces before the separator.
            column = end - 3
            if window is not None and column > before + 3:
                cursor_x, cursor_fg, cursor_bg = screen.cursor.x, screen.cursor.fg, screen.cursor.bg
                screen.cursor.x = column
                screen.cursor.fg, screen.cursor.bg = foreground, background
                screen.draw("⇄")
                screen.cursor.x, screen.cursor.fg, screen.cursor.bg = cursor_x, cursor_fg, cursor_bg
                hitboxes[tab.tab_id] = (column, screen.cursor.y)
    return end



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


def draw_caffeine_footer(bar, first_unused):
    bar._clawdex_caffeine_controls = []
    screen = bar.screen
    top = screen.lines - 3
    if top < first_unused or screen.columns < 12:
        return
    state = caffeine_state()
    active = state["process"] is not None
    background = 0x25221D if active else 0x19202A
    foreground = 0xEBC58D if active else 0xABB5C5
    column = screen.columns - 6
    cursor = (screen.cursor.x, screen.cursor.y, screen.cursor.bg,
              screen.cursor.fg, screen.cursor.bold, screen.cursor.italic)
    try:
        screen.cursor.bg = (background << 8) | 2
        screen.cursor.fg = (foreground << 8) | 2
        screen.cursor.bold = active
        screen.cursor.italic = False
        for row in range(top, screen.lines):
            screen.cursor.x, screen.cursor.y = 0, row
            screen.draw(" " * screen.columns)
        remaining = max(1, math.ceil((state["deadline"] - monotonic()) / 60))
        label = f"Awake · {remaining}m" if active else "Stay awake · 1h"
        if wcswidth(label) > column - 2:
            label = truncate_line(label, column - 2)
        screen.cursor.x, screen.cursor.y = max(1, (column - wcswidth(label)) // 2), top + 1
        screen.draw(label)
        screen.cursor.bold = False
        for start, icon, action, color, button_bg in (
            (column, "+", "caffeine", 0xEBC58D, 0x302A22 if active else 0x202733),
            (column + 3, "■", "caffeine-stop", 0xD6A2A5 if active else 0x46505E, 0x2B2525 if active else 0x1C222C),
        ):
            screen.cursor.bg = (button_bg << 8) | 2
            screen.cursor.fg = (color << 8) | 2
            for row in range(top, screen.lines):
                screen.cursor.x, screen.cursor.y = start, row
                screen.draw(" " * 3)
            screen.cursor.x, screen.cursor.y = start + 1, top + 1
            screen.draw(icon)
            if active or action == "caffeine":
                bar._clawdex_caffeine_controls.append(((start, top, start + 3, screen.lines), action))
        if not active:
            bar._clawdex_caffeine_controls.append(((0, top, column, screen.lines), "caffeine"))
    finally:
        (screen.cursor.x, screen.cursor.y, screen.cursor.bg,
         screen.cursor.fg, screen.cursor.bold, screen.cursor.italic) = cursor


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
    if cell == getattr(manager, "_agent_swap_hitboxes", {}).get(tab_id):
        return (tab_id, "swap")
    return None


def handle_tab_bar_mouse(manager, x, y, button, modifiers, action):
    pending = getattr(manager, "_agent_swap_pressed", None)
    if pending is not None:
        if button == GLFW_MOUSE_BUTTON_LEFT and action == GLFW_RELEASE:
            manager._agent_swap_pressed = None
            if not modifiers and icon_at(manager, x, y) == pending:
                tab_id, control = pending
                if control in ("caffeine", "caffeine-stop"):
                    if control == "caffeine-stop":
                        stop_caffeine()
                    else:
                        extend_caffeine()
                    return
                tab = manager.tab_for_id(tab_id)
                if tab is not None:
                    if control == "close":
                        get_boss().close_tab(tab)
                    else:
                        manager.set_active_tab(tab)
                        swap_agent(tab)
        return
    if button == GLFW_MOUSE_BUTTON_LEFT and action == GLFW_PRESS and not modifiers:
        tab_id = icon_at(manager, x, y)
        if tab_id is not None:
            manager._agent_swap_pressed = tab_id
            manager.recent_tab_bar_mouse_events.clear()
            return
    return manager._agent_swap_original_mouse(x, y, button, modifiers, action)


# Keep the original handler across config reloads rather than wrapping it twice.
if not hasattr(TabManager, "_agent_swap_original_mouse"):
    TabManager._agent_swap_original_mouse = TabManager.handle_tab_bar_mouse
TabManager.handle_tab_bar_mouse = handle_tab_bar_mouse


# Kitty 0.49 inserts one blank row between vertical tabs. Compact that row
# after native layout, moving both native click bounds and switch hitboxes.
def compact_vertical_tabs(bar, data):
    # Native layout clears using the current background, which may be the
    # previously selected card's color. Begin with the sidebar canvas instead.
    bar.screen.cursor.bg = (0x101318 << 8) | 2
    changed = bar._agent_compact_original_vertical(data)
    extents = tuple(bar.tab_extents)
    manager = get_boss().os_window_map.get(bar.os_window_id)
    hitboxes = getattr(manager, "_agent_swap_hitboxes", {})
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
        for targets in (hitboxes, getattr(manager, "_agent_close_hitboxes", {})):
            if extent.tab_id in targets:
                x, y = targets[extent.tab_id]
                targets[extent.tab_id] = (x, y - removed)
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
