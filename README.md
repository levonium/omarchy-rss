# levonium.rss

A local RSS/Atom feed reader for the [Omarchy](https://omarchy.org/) shell.
An RSS icon in the top bar shows an unread count; click it to open a popup
where you can browse, add, edit and remove feeds. No accounts, no sync, no
daemon: everything is local.

## Features

- Bar icon with an unread badge, opening a popup styled like the built-in
  wifi/battery panels (uses your Omarchy theme).
- Add a feed by feed URL **or just a site URL** (the feed is auto-discovered).
- Edit (name / URL), remove (with confirmation), per-feed unread counts,
  per-feed error display.
- Browse a feed's items with a plain-text summary; selecting one opens it in
  your browser and marks it read. "Mark all read" globally or per feed.
- Background refresh (default every 30 minutes) with a desktop notification
  for new items. A newly added feed does not notify for its existing items.
- Fully keyboard-driven.
- Starts with Omarchy News subscribed; everything else is yours to add.

## Requirements

- Omarchy with the Quickshell-based shell (`omarchy-shell`).
- `python3` (standard library only, no pip packages).
- `notify-send` (libnotify) for new-item notifications, `xdg-open` to open links.
- A Font Awesome / Nerd Font (Omarchy ships one) for the icons.

## Install (on a new machine)

Copy this folder to `~/.config/omarchy/plugins/levonium.rss/`. The folder name
must match the `id` in `manifest.json`. Then:

```bash
omarchy-shell shell rescanPlugins
omarchy plugin enable levonium.rss    # adds it to the right side of the bar
omarchy restart shell                 # only if the icon doesn't appear
```

If you keep the folder in a git repo, `omarchy plugin add <git-url> --enable`
does the copy and enable in one step.

Move the icon with `omarchy bar move levonium.rss --section left|center|right`
or by dragging it in the bar.

To carry your feeds over, also copy `~/.local/share/levonium-rss/state.json`
(see [Data](#data)).

## Usage

Click the bar icon to open the panel.

| Key | Action |
|---|---|
| `j` / `k` or `↓` / `↑` | Move the cursor |
| `Enter` | Open the feed under the cursor, or open the item in your browser |
| `a` | Add a feed |
| `e` | Edit the feed under the cursor |
| `x` | Remove the feed under the cursor (asks first) |
| `m` | Mark all read (everything on the feed list, one feed inside a feed) |
| `r` | Refresh all feeds now |
| `Esc` | Go back, then close the panel |
| `Tab` | Next bar panel (Omarchy shell behaviour, not specific to this plugin) |

In the add/edit form, `Tab` moves between the fields and buttons, `Enter`
submits, and `Esc` cancels.

You can also drive it from a keybinding or script:

```bash
omarchy-shell levonium.rss toggle   # also: open, close
```

## Configuration

The refresh interval defaults to 30 minutes. To change it, add the setting to
the plugin's entry in the bar layout in `~/.config/omarchy/shell.json`
(hot-reloaded on save):

```json
{ "id": "levonium.rss", "refreshIntervalMin": 60 }
```

## Data

| What | Where |
|---|---|
| Feeds, items, read state | `~/.local/share/levonium-rss/state.json` (honours `XDG_DATA_HOME`) |
| Plugin code | `~/.config/omarchy/plugins/levonium.rss/` |

Each feed keeps only its newest 10 items (`MAX_ITEMS_PER_FEED` in `feeds.py`), so a
newly added feed starts with 10 unread. Back it up by copying it.

**Default feeds:** on first run (when `state.json` doesn't exist yet) the plugin
subscribes you to Omarchy News. This happens once. If you remove it, it stays
removed. Deleting `state.json` resets everything, including this default. To
change the defaults, edit `DEFAULT_FEEDS` at the top of `feeds.py`.

## The helper CLI

`feeds.py` does all the fetching, parsing and saving, so it can be used and
tested without the UI:

```bash
./feeds.py add https://example.com/           # site or feed URL, optional name as 2nd arg
./feeds.py refresh [FEED_ID]                  # fetch now and notify on new items
./feeds.py edit FEED_ID "New name" NEW_URL
./feeds.py remove FEED_ID
./feeds.py read ITEM_ID | all [FEED_ID]
```

Errors are printed as `error: ...` on stdout with exit code 1. Concurrent
runs are safe (a file lock serialises writes).

## How it works

- `manifest.json` registers the plugin as a bar widget.
- `Panel.qml` is only a view: it watches `state.json` and shells out to
  `feeds.py` for every change.
- `feeds.py` owns `state.json`. Network fetching happens outside the lock, so
  a slow feed never blocks marking items read.

## Troubleshooting

- **Icon missing or changes not showing:** `omarchy restart shell`. Hot reload
  sometimes keeps stale QML.
- **Icons show as blanks or boxes:** the shell font lacks Font Awesome glyphs.
  Glyphs in `Panel.qml` are written as `\uXXXX` escapes (editors and tools can
  strip raw private-use characters; keep them as escapes).
- **A feed shows a red error under its name:** the last fetch failed (HTTP
  error, timeout, or not valid RSS/Atom). It retries on the next refresh.
- **Check for QML errors:** `quickshell log -n -p /usr/share/omarchy/shell | grep -i levonium`
