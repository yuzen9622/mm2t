# dmgbuild settings for the installer DMG. Run from the release workflow as:
#   dmgbuild -s settings.py -D app=<mm2t.app> -D icon=<.icns> -D background=<background.tiff> mm2t out.dmg
# Icon positions must match the arrow drawn by make_background.py.
import os.path

app = defines["app"]  # path to mm2t.app
icon = defines["icon"]  # .icns used as the volume icon
background = defines["background"]  # TIFF holding the 1x and 2x background

format = "ULFO"
filesystem = "APFS"
size = None

files = [app]
symlinks = {"Applications": "/Applications"}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"

arrange_by = None
icon_size = 128
text_size = 14
label_pos = "bottom"
icon_locations = {
    os.path.basename(app): (180, 170),
    "Applications": (480, 170),
}
