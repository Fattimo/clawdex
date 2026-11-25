"""Custom Kitty sidebar with session status and timer controls."""

import math
import json
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


def shutdown_state():
    boss = get_boss()
    state = getattr(boss, "_clawdex_shutdown", None)
    if state is None:
        state = {"deadline": 0, "timer": None, "pending": None}
        boss._clawdex_shutdown = state
    return state


def refresh_shutdown(timer_id):
    state = shutdown_state()
    pending = state["pending"]
    if pending is not None:
        process, minutes = pending
        if process.poll() is not None:
            output, _ = process.communicate()
            state["pending"] = None
            if process.returncode == 0:
                state["deadline"] = monotonic() + minutes * 60 if minutes else 0
            elif "(-128)" not in output:
                # Authentication cancellation leaves the previous schedule intact.
                # Other failures may occur after the previous timer was canceled.
                state["deadline"] = 0
                get_boss().show_error("Cannot change Mac shutdown", output.strip())
    if state["pending"] is None and state["deadline"] <= monotonic():
        state["deadline"] = 0
        if state["timer"] is not None:
            remove_timer(state["timer"])
            state["timer"] = None
    repaint_caffeine()


def change_shutdown(cancel=False):
    state = shutdown_state()
    if state["pending"] is not None:
        return
    minutes = 0 if cancel else max(0, math.ceil((state["deadline"] - monotonic()) / 60)) + 15
    # Native shutdown survives Kitty exiting and bypasses GUI quit confirmations.
    # Only these fixed commands and an internally calculated integer run as root.
    command = "/usr/bin/killall -q -u root shutdown; "
    command += f"/sbin/shutdown -h +{minutes} >/dev/null 2>&1" if minutes else "true"
    script = f"do shell script {json.dumps(command)} with administrator privileges"
    try:
        process = subprocess.Popen(
            ["/usr/bin/osascript", "-e", script],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, start_new_session=True,
        )
    except OSError as error:
        get_boss().show_error("Cannot change Mac shutdown", str(error))
        return
    state["pending"] = (process, minutes)
    if state["timer"] is None:
        state["timer"] = add_timer(refresh_shutdown, 1.0, True)
    repaint_caffeine()


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
    shutdown = shutdown_state()
    active = shutdown["deadline"] > monotonic()
    remaining = max(1, math.ceil((shutdown["deadline"] - monotonic()) / 60))
    label = "Authorizing…" if shutdown["pending"] else (f"Shutdown · {remaining}m" if active else "Shutdown · 15m")
    draw_timer_footer(
        bar, first_unused, bar.screen.lines - 6, active, label, "shutdown",
        controls if shutdown["pending"] is None else [],
        (0x2B2024 if active else 0x19202A, 0xD6A2A5 if active else 0xABB5C5, 0xD6A2A5),
    )
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
    pending = getattr(manager, "_sidebar_control_pressed", None)
    if pending is not None:
        if button == GLFW_MOUSE_BUTTON_LEFT and action == GLFW_RELEASE:
            manager._sidebar_control_pressed = None
            if not modifiers and icon_at(manager, x, y) == pending:
                tab_id, control = pending
                if control in ("shutdown", "shutdown-stop"):
                    change_shutdown(cancel=control == "shutdown-stop")
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
        tab_id = icon_at(manager, x, y)
        if tab_id is not None:
            manager._sidebar_control_pressed = tab_id
            manager.recent_tab_bar_mouse_events.clear()
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
