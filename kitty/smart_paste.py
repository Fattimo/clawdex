# Cmd+V that also handles screenshots: text pastes normally; an image-only
# clipboard in a Claude Code or Codex window is handed over as Ctrl+V, which
# is the key both CLIs listen on to attach clipboard images.
import os
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


IMAGE_PASTE_CLIS = ('claude', 'codex')


def _runs_image_paste_cli(window):
    try:
        procs = window.child.foreground_processes
    except Exception:
        return False
    for p in procs:
        # argv[0] for native binaries, argv[1] for `node /path/to/cli`.
        for arg in (p.get('cmdline') or [])[:2]:
            if os.path.basename(arg).startswith(IMAGE_PASTE_CLIS):
                return True
    return False


@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    window = boss.window_id_map.get(target_window_id)
    if window is None:
        return
    types = _clipboard_types()
    has_text = 'utf8' in types or 'string' in types
    has_image = any(t in types for t in ('PNGf', 'TIFF', 'JPEG'))
    if has_image and not has_text and _runs_image_paste_cli(window):
        window.send_key('ctrl+v')
    else:
        boss.paste_from_clipboard()
