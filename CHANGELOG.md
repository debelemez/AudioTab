# Changelog

Also shown in the app: **Settings › Versions**, where you can switch to any released version.


## 2.3.8

- In ⌘Tab, press the key above Tab (`) on a card to show only that app's windows; press again for all (temporary). F works too
- Split-screen panels now close when you click outside them (like Esc)

## 2.3.7

- Grouped view: at most 2 cards per column; extra windows go to a new column so the panel stays short

## 2.3.6

- Project names are now large and clear: a band in the app's own color under the preview
- The card title shows the project name instead of the long window title
- Grouped view is horizontal: sections side by side with thin dividers; Folders always on the far right

## 2.3.5

- Optional grouped ⌘Tab view: Folders · Browsers · Projects · Development · Apps
- Folder cards show the folder name in large type instead of a preview
- DaVinci, Adobe, Final Cut, Logic, Ableton, Blender… are detected and the project name is shown on the preview
- Edit the list of project apps in Settings › Windows

## 2.3.4

- Hidden helper windows no longer show up in the list
- Browser windows (every Chrome profile) show in ⌘Tab and ⌥Tab even when minimized to the Dock

## 2.3.3

- Limit ⌘Tab / ⌥Tab to one app (e.g. only Chrome windows); press A in the panel to switch apps
- New Chrome windows from another profile or desktop now show up right away

## 2.3.2

- New Versions tab in Settings: what changed in every release
- You can pick an older version and go back to it (the signature is still checked)

## 2.3.1

- Hardening after a security audit (Cloudflare security-audit)
- The updater installs only packages signed with the AudioTab certificate
- The version inside the package must match the release; auto-update never downgrades
- install.sh checks the signature before installing
- Audio assignments no longer move silently to a different device with the same name

## 2.3.0

- English interface (default); Turkish can be chosen in Settings › General
- README in English and Turkish, with screenshots

## 2.2.4

- Fixed a build error (split-screen picker)

## 2.2.3

- More reliable update check: fallback when the GitHub API is unreachable, real error messages

## 2.2.2

- Preview card at the bottom right after a screenshot or recording; click to reveal the file in Finder
- The split-screen picker is no longer cut off

## 2.2.1

- Clicking empty space closes the ⌘Tab panel

## 2.2.0

- Automatic updates from GitHub: download, verify and relaunch in one click
- Releases are signed, so permissions survive updates

## 2.1 (before GitHub)

- Split screen with ⌘<; works across 2–3 monitors, with monitor choice
- Red close dot and tile button on ⌘Tab cards
- ⌘⇧3 captures the current monitor, ⌘⇧4 an area, plus scrolling screenshots
- ⌘⇧5 MP4 (H.264) screen recording; the red dot isn't recorded
- Choose save folders; capture features can be turned off

## 2.0 (before GitHub)

- GlassTab and AudioHop merged into one app: AudioTab
- One menu bar icon and a settings window; old settings migrated automatically
- Bigger icons, faster ⌘Tab, list view
- Audio device per app; Permissions tab
- Windows of every Chrome profile are always found

## 1.0 (before GitHub)

- AudioHop: switch audio output with a shortcut (⌘⇧ or ⌘⇪)
- Remembers unplugged devices; glass device list, select on ⌘ release
