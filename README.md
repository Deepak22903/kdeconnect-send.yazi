# kdeconnect-send.yazi

Send selected files to your smartphone or other devices using KDE Connect. This plugin allows you to quickly share files from Yazi file manager directly to any KDE Connect-paired device.

## Features

- Select and send multiple files to KDE Connect devices
- Automatically pack selected folders into store-only ZIPs (no compression)
- Automatically detects available and reachable KDE Connect devices
- Configurable device selection behavior with `auto_select_single` option
- Prompts for device selection when multiple devices are available
- Provides notifications for successful and failed transfers
- Warns when no files are selected

## Requirements

- KDE Connect installed on your system
- `kdeconnect-cli` command available in your PATH
- At least one device paired and reachable via KDE Connect
- For folders: `zip` (Info-ZIP) and `mktemp` available in your PATH

## Installation

### Using `ya pkg`

```sh
ya pkg add Deepak22903/kdeconnect-send
```

### Using Git

Clone the repository directly into your Yazi plugins directory:

```sh
git clone https://github.com/Deepak22903/kdeconnect-send.yazi.git ~/.config/yazi/plugins/kdeconnect-send.yazi
```

## Usage

Add this to your `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = [ "<C-s>" ]
run  = "plugin kdeconnect-send"
desc = "Send selected files via KDE Connect"
```

Make sure the <kbd>ctrl</kbd> => <kbd>s</kbd> key combination is not used elsewhere.

## Configuration (optional)

If you want to always show device selection menu, regardless of device count, add this to your `~/.config/yazi/init.lua`:

```lua
-- Always show device selection
require("kdeconnect-send"):setup({
    auto_select_single = false,
})
```

## How to Use

1. Select one or more files in Yazi using your selection key (typically <kbd>Space</kbd>)
2. Press <kbd>ctrl</kbd> followed by <kbd>s</kbd> to activate the plugin
3. If multiple devices are available, select the device ID you want to send to
4. The files will be sent and you'll receive a notification of the results

## Folder transfers

Highlight a folder or select it alongside files, then use the normal send shortcut.
Each folder becomes a separate `<folder-name>.zip`, created with `zip -0` (store
only), and regular files are sent unchanged. Subfolders and empty directories are
preserved; symlinks are stored as links rather than following them outside the
selected folder. Extract the ZIP on the receiving device.

Packing avoids compression CPU work, but still reads and writes the full folder.
You need approximately the folder's size in free temporary storage. Archives are
created in private, unique directories under `$TMPDIR` (or the system temporary
location), not next to your source files. No existing ZIP is overwritten.

**Temporary ZIPs are retained:** KDE Connect queues transfers asynchronously, so
CLI exit is not evidence that the daemon has finished reading an archive. The
plugin displays the archive locations; remove them only after transfer completion
on the receiving device. Failed transfers keep their completed ZIPs for retry.
Failed ZIP creation removes partial output before any transfer is queued. Your
system's temporary-file cleanup policy still applies to retained archives.

## Tests

Run from this repository with Lua, Python, `zip`, and `mktemp` installed:

```sh
TEST_ROOT="$(mktemp -d)" lua tests/test_share.lua
python tests/test_yazi.py  # requires Yazi; uses an isolated PTY and fake CLI
ZIPOPT=-m ZIP=-m python tests/test_yazi.py  # source-preservation regression
TEST_ZIP_FAILURE=1 python tests/test_yazi.py  # real-Yazi cleanup regression
```

Tests create actual store-only archives but do not contact real KDE Connect
devices. The Lua test uses `$TEST_ROOT` for fixtures and leaves its generated
archives in temporary directories; the real-Yazi smoke test cleans up its sandbox.

## License

This plugin is MIT-licensed.
