# SPDX-License-Identifier: GPL-3.0-or-later
"""Finder layout written directly by dmgbuild; no Finder/AppleScript automation."""
from pathlib import Path

application = Path(defines['app'])
format = 'ULFO'
filesystem = 'HFS+'
files = [str(application), defines['license'], (defines['background_license'], '.dmgbuild-LICENSE.txt')]
symlinks = {'Applications': '/Applications'}
background = defines['background']
window_rect = ((100, 300), (640, 400))
default_view = 'icon-view'
icon_size = 112
text_size = 13
icon_locations = {application.name: (140, 120), 'Applications': (500, 120), 'COPYING': (320, 280)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
