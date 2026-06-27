# bolt-chunkman

A **Chunk Man** plugin for the [Bolt Launcher](https://codeberg.org/Adamcake/Bolt) for RuneScape 3.

This plugin draws the chunk grid directly onto the game world so you can see
exactly where the boundaries are, greys out everything you haven't unlocked yet, and lets
you unlock new chunks with a single click (`Ctrl + Alt + middle-click`).

<video src="images/chunkman-gif.webm" controls width="100%"></video>
> Use `Ctrl + Alt + middle-click` to unlock/lock chunks.
> If the video above doesn't play inline, [download / open `chunkman-gif.webm`](images/chunkman-gif.webm).

![Chunk Man overview](images/chunkman_plugin_overview.png)

## Features

- **Region / chunk grid overlay**: draws the RuneScape map-square grid (64×64 tiles per
  region) on the ground around you.
- **Grey out locked chunks**: everything outside your list of unlocked chunks is walled
  off with vertical "curtains" along the frontier of your unlocked area. Contiguous unlocked
  chunks stay fully clear inside; only the outer perimeter is curtained.
- **Click to unlock**: `Ctrl + Alt + middle-click` any chunk on the ground to toggle it
  in or out of your unlocked list. Unlocking a new chunk pops a celebratory card:

  ![Chunk unlocked popup](images/chunkman_plugin_unlocked_popup.png)

- **Locked-view dimming**: if you wander into a chunk you haven't unlocked, the whole view
  dims so it's obvious you've stepped out of bounds.
- **Chunk ID readout**: a small badge shows the ID of the chunk you're currently standing
  in.
- **Settings panel**: a gear icon at the top-left of the screen opens an in-game
  settings panel. Most settings apply instantly, but others may need a client restart.

## Settings

Click the gear icon at the top-left to open the panel. Most settings apply live and are
saved to `chunkman-settings.cfg` in the plugin's config directory.

![Settings panel](images/chunkman_plugin_settings.png)

| Group | Setting | Description |
| --- | --- | --- |
| **Unlocked Chunks** | Grey out locked chunks | Wall off everything except your unlocked chunks. |
| | Unlocked chunk IDs | Comma-separated list of chunk IDs, e.g. `13108, 13109`. |
| | Ctrl+Alt+middle-click to unlock/lock | Toggle a chunk by clicking it on the ground. |
| | Dim the view when in a locked chunk | Tint the whole screen when you're out of bounds. |
| | Locked-chunk colour & opacity | Curtain / dim colour and strength. |
| | Locked-chunk wall height | How far the curtains rise toward the sky (world units). |
| **Region grid lines** | Show region boundary lines | Draw the chunk grid. |
| | Region radius | How many rings of regions to draw around you (1 → 3×3). |
| | Grid line colour | Colour of the boundary lines. |
| | Current-region colour | Colour of the region you're standing in. |
| | Line thickness | Boundary line thickness. |
| | Black outline for contrast | Dark underlay so lines stay readable. |
| **Placement** | Pin overlay to a fixed height | Use a fixed world Y instead of detected ground. |
| | Fixed height | The world Y to pin the overlay to. |
| **Chunk ID readout** | Show current chunk ID | Show/hide the chunk ID badge. |
| **Interface** | UI scale | Scale the on-screen UI (icon, badge, panel, popup). |
| **Diagnostics** | Write diag.txt | Periodically dump diagnostics for troubleshooting. |

## How chunk IDs work

A region is 64×64 tiles, anchored at absolute tile `0`, so region edges fall on every tile
coordinate divisible by 64. A chunk's ID seems to follow `regionX * 256 + regionZ`. The badge in the
top-left always shows the ID of the chunk you're standing in, so the easiest way to build
your unlocked list is to just walk into a chunk and read the number — or `Ctrl+Alt+middle-click`
it to add it directly.

## Installation

### From an updater URL (recommended)

Bolt can install and auto-update this plugin straight from a URL to its `meta.json`:

1. In Bolt, open the **Play** menu → **Manage plugins** → **Install plugin from updater URL**.
2. Paste the updater URL:

   ```
   https://github.com/maplescaper/bolt-chunkman/releases/download/1.0/meta.json
   ```

3. Launch RuneScape 3. You should see `[chunk-man] loaded` in the console and the gear icon
   at the top-left of the game view.

Bolt reads [`meta.json`](meta.json), downloads the `.tar.gz` it points at, verifies the
`sha256`, and extracts it into the plugin directory. When a new release bumps the `version`
in `meta.json`, Bolt offers the update automatically.

### Manual install

1. Locate your Bolt plugins directory (on Windows this is typically
   `%AppData%\bolt-launcher\data\plugins`).
2. Copy this repository's plugin files into a folder there, e.g. `chunk-man-plugin`, so that
   `bolt.json` sits at the top of that folder.
3. In Bolt, add / enable the plugin and launch RuneScape 3.

## Publishing a release (for maintainers)

The updater URL above points at a GitHub release asset. To cut a release:

1. Bump `version` in both [`bolt.json`](bolt.json) and [`meta.json`](meta.json).
2. Build the plugin tarball (plugin files only — no README/images/`.git`):

   ```sh
   tar -czf bolt-chunkman-<version>.tar.gz bolt.json main.lua resources/ ui/
   ```

3. Compute its checksum and put it in `meta.json` (`sha256` field), and update the `url`
   field to the new tag/asset name:

   ```sh
   sha256sum bolt-chunkman-<version>.tar.gz
   ```

4. Create a GitHub release tagged `<version>` and upload **both** `bolt-chunkman-<version>.tar.gz`
   and `meta.json` as assets. The `meta.json` URL of that release is the updater URL users install.


## Credits

The line shader and vertex buffer are from [JasperSurmont's bolt-questhelper](https://codeberg.org/JasperSurmont/bolt-questhelper).
