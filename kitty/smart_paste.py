# Cmd+V that also handles screenshots: text pastes normally; an image-only
# clipboard in a Claude Code window is handed over as Ctrl+V, which is the
# key Claude Code listens on to attach clipboard images.
import subprocess

from kittens.tui.handler import result_handler


def main(args):
    pass


def _clipboard_types():
    try:
        return subprocess.run(
            ['osascript', '-e', 'clipboard info'],
            capture_output=True, text=True, timeout=2,
        ).stdout
    except Exception:
        return ''


def _runs_claude(window):
    try:
        procs = window.child.foreground_processes
    except Exception:
        return False
    return any('claude' in ' '.join(p.get('cmdline') or []) for p in procs)


@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    window = boss.window_id_map.get(target_window_id)
    if window is None:
        return
    types = _clipboard_types()
    has_text = 'utf8' in types or 'string' in types
    has_image = any(t in types for t in ('PNGf', 'TIFF', 'JPEG'))
    if has_image and not has_text and _runs_claude(window):
        window.send_key('ctrl+v')
    else:
        boss.paste_from_clipboard()
