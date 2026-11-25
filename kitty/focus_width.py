"""Give the active agent four fifths of its paired Kitty tab."""

def widen_active_pane(boss, window):
    tab = boss.tab_for_id(window.tab_id)
    if tab is None or tab.active_window is not window or tab.windows.num_groups != 2:
        return
    layout = tab.current_layout
    if layout.name != "horizontal":
        return
    # Kitty's horizontal layout adds this fraction to the equal-width share.
    bias = {tab.windows.active_group_idx: 0.30}
    if layout.biased_map != bias:
        layout.biased_map = bias
        tab.relayout()


def on_focus_change(boss, window, data):
    if data["focused"]:
        widen_active_pane(boss, window)


def on_resize(boss, window, data):
    # Initial pane creation can happen before the OS window receives focus.
    widen_active_pane(boss, window)
