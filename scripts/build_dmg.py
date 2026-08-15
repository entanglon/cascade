# build_dmg.py — creates the xCloud installer DMG using dmgbuild.
# Usage: python3 build_dmg.py <output.dmg> <staging_dir> <background.png> <volume.icns>
#
# dmgbuild writes the .DS_Store natively (no Finder automation needed),
# so the window gets the custom background and icon layout.
import os
import sys

from dmgbuild import build_dmg

output, staging, background, volume_icon = [os.path.abspath(p) for p in sys.argv[1:5]]

os.chdir(staging)

settings = {
    "format": "UDZO",
    "compression_level": 9,
    "size": None,
    "files": ["xCloud.app"],
    "symlinks": {"Applications": "/Applications"},
    "icon": volume_icon,
    "badge_icon": False,
    "icon_size": 112,
    "text_size": 11,
    "background": background,
    "icon_locations": {
        "xCloud.app": (170, 125),
        "Applications": (490, 125),
    },
    "window_rect": ((120, 160), (660, 400)),
    "show_status_bar": False,
    "show_tab_view": False,
    "show_toolbar": False,
    "show_pathbar": False,
    "show_sidebar": False,
    "grid_spacing": 100,
    "show_icon_preview": True,
}

build_dmg(output, "xCloud", settings=settings)
print("wrote", output)
