# Changelog

Also shown in the app: **Settings › Versions**, where you can switch to any released version.


## 2.3.18

- When an app like KeePassXC locks the keyboard (secure input), ⌘Tab no longer dies: macOS's own ⌘Tab takes over meanwhile
- If AudioTab crashes or is force-quit, macOS shortcuts are restored on the next launch; shortcuts start on their own when permission is granted later

## 2.3.17

- The profile badge also recognizes profiles whose Chrome profile button shows the account name (the badge still shows the profile name)
- Settings › Browser profiles › Copy diagnostics: to track down a wrong badge

## 2.3.16

- The profile badge shows the right profile: it reads the profile button in the window's toolbar (bookmarks no longer confuse it)

## 2.3.15

- Profile badge rebuilt: the name is shown in full, not cut off
- Settings › Windows › Browser profiles: choose the name shown on each profile's badge

## 2.3.14

- Fixed the 2.3.13 build error (version series, the update window and notifications ship with this version)

## 2.3.13

- The Versions tab is grouped into series (1.0, 2.0, 2.1, 2.2, 2.3); open one to see its versions and switch to any of them
- Text no longer spills out of the version boxes
- "Check for updates…" in the menu shows the result in a small window; install a new version in one click
- A notification appears when a new version is out; click it to open the update window

## 2.3.12

- The profile badge is no longer cut off and shows the name you gave the Chrome profile (profiles with the same name are told apart by email)
- Mouse buttons 4 and 5 go back / forward in Finder (can be turned off)
- Add any apps you like to "Always find windows", alongside browsers
- New Versions tab layout: equal-size boxes; long lists expand with a button
- Long project names no longer disappear; they're shortened with "…"

## 2.3.11

- Browser cards show which profile the window belongs to in a small badge (Chrome, Brave, Edge, Vivaldi)

## 2.3.10

- Finder favorites now come straight from Finder's sidebar Favorites, in the same order
- The sidebar is set separately for ⌘Tab and ⌥Tab: each has its own toggles and folder list

## 2.3.9

- Optional ⌘Tab sidebar: your favorite folders and Finder Favorites on the far right, just like in Finder
- Drag to the Dock: hovering a dragged file over an app in the Dock brings it forward right away (can be turned off)

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
