# Classics Cover KOReader Plugin
# Auto-Generate & Apply Book Covers (Tested on Kindle Paperwhite 12, KOReader 2026.03)
-----
## Fan fiction, missing covers, or blurry book cover? Fix them with Classics-style covers directly in KOReader.

<img width="1920" height="1080" alt="Untitled design" src="https://github.com/user-attachments/assets/c6f8e209-4ef9-4e0f-98cd-b5887908fe92" />

## 📚 Classics Cover Generator. How It Works
1. Long-press the book you want to change the cover of.
2. Tap **“Classics Cover”**.
3. Confirm or edit the book title and author.
4. Tap **Generate**.
5. Wait until you see the notification: _“Classics cover applied!”_
6. Done 🎉

No background images need to be copied to the device, and **no network connection is required**.
Each cover gets a randomly generated gradient background; generate again if you want a different one.

The cover is drawn entirely on the device, in the same layout as the original server-based version:
a 1236×1648 image with the gradient on top, the black bottom panel, the white
`CLASSICS <logo> EDITION` strip, the author name in orange and the title in white.

## Installation
-----
1. Download the Zip Below
2. Extract and copy the `classicscover.koplugin` folder to your device's `plugins/` directory
3. Restart KOReader and go to **Menu → Tools → Classics Cover Generator** to change the settings.

## Settings
-----
**Menu → Tools → Classics Cover Generator**

- **Set title font size** — default 70 px, range 12–160.
- **Set author font size** — default 52 px, range 12–160.
- **About**

Empty font-size settings mean “use the default”. If a long title does not fit even at the
chosen size, it is automatically reduced just enough to fit the cover.

## Technical Details
-----
Everything is rendered locally with KOReader's own libraries:

- `ffi/blitbuffer` — the 32-bit RGB cover canvas, gradients, panels and strip.
- `ffi/freetype` — text rendering with the bundled EB Garamond Italic (title) and
  Josefin Sans SemiBold (author, strip). The exact pixel sizes are used, independent of
  the screen's DPI scaling.
- `ffi/png` (LodePNG) — decoding the bundled logo and writing the final PNG.

The fonts and logo live in `assets/`. For characters missing from the two cover fonts,
the plugin falls back to the Noto fonts bundled with KOReader (for example for CJK titles).

The old PythonAnywhere Flask server is no longer used or needed. Its code remains available
in the repository history.
