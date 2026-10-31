# SPDX-License-Identifier: GPL-3.0-or-later
"""Finder layout written directly by dmgbuild; no Finder/AppleScript automation."""
from pathlib import Path

application = Path(defines['app'])
format = 'ULFO'
filesystem = 'APFS'
files = [str(application), defines['license'], (defines['background_license'], '.dmgbuild-LICENSE.txt')]
symlinks = {'Applications': '/Applications'}
background = 'builtin-arrow'
window_rect = ((100, 100), (640, 340))
default_view = 'icon-view'
icon_size = 112
text_size = 13
icon_locations = {application.name: (140, 120), 'Applications': (500, 120), 'COPYING': (320, 260)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
