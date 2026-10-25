# dmgbuild settings for dist/Burnish.dmg (used by scripts/make-dmg.sh).
# The window is 660 x 440 (the art plus the title bar); icon centres match App/dmg-background.png
# when it exists. No hide_extensions: it writes Finder info onto the app bundle, which strict
# code-signature checks reject (Finder hides .app on its own).
import os.path

app = defines.get("app", "build/Burnish.app")  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

icon = defines.get("volume_icon")  # noqa: F821
background = defines.get("background") or "builtin-arrow"  # noqa: F821

window_rect = ((160, 120), (660, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (170, 190),
    "Applications": (490, 190),
}
