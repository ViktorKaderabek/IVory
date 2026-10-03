# Rozložení okna instalačního DMG pro dmgbuild (spouští ho scripts/build_dmg.sh).
import os

app = defines["app"]
app_name = os.path.basename(app)

format = "ULFO"                      # LZFSE – menší než UDZO, macOS 10.11+
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")   # ikona připojeného disku

background = defines["background"]
window_rect = ((200, 140), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {app_name: (165, 190), "Applications": (495, 190)}
