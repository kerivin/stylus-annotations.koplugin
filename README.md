# stylus-annotations.koplugin

<img width="300" alt="Screenshot" src="https://github.com/user-attachments/assets/b555868d-4336-4ec8-a5e5-24133aa7e567" />

Hand-drawn stylus annotations for PDF, EPUB, FB2, etc. Tested on Android; if you're lucky, it might also work on Linux-based readers. The plugin supports both paged documents (PDFs) and reflowable ones (EPUBs, FB2s), although they work differently, and in reflowable documents your strokes may shift position.

> **Requirements:** KOReader v2026.07.2-60 (2026.08.12 nightly build) or later.

## How to install

- Use a plugin manager (AppStore, Storefront, etc.) and search for "stylus-annotations".
- Or download the zip from the Releases page, unzip it, and put the entire `stylus-annotations.koplugin` folder into the `koreader/plugins` directory, so you end up with the path `koreader/plugins/stylus-annotations.koplugin` with the plugin files. It should NOT be `koreader/plugins/stylus-annotations.koplugin/stylus-annotations.koplugin`.

You'll find the "Stylus annotations" settings in the second tab of the top menu, next to "Highlights".

## Features

- **Enable drawing:** when on, the plugin captures pen strokes. When off, you can use the pen as usual, as if the plugin weren't installed.
- **Tool palette:** the movable palette opens at the top of the screen when you start drawing or select a stroke. Choose Pen, Eraser, or Lasso; set the pen color and width; drag the palette with your finger and close it with ×. Its position updates every 0.5 seconds during a drag. The Show stylus toolbar menu item reopens it. The tool palette window is moveable.
- **Eraser:** move the stylus over a stroke to erase only the part inside the visible eraser circle. The hardware eraser is supported too.
- **Lasso selection:** choose Lasso, draw a black-and-white dashed loop around strokes with the stylus, then lift to select them together. Delete, Color, and Width in the toolbar act on the selected set. Drag a selected stroke with a finger or stylus to move it; touching outside the selection deselects it.
- **Undo/Redo:** reverse recent drawing, erasing, moving, deleting, and stroke color/width changes during the current reading session.
- **Live refresh:** on by default, using a faster refresh mode on e-ink devices. Turn it off if your device struggles to render strokes while you draw. When off, the stroke appears only after you finish drawing it.
- **Width and color:** change these options for all new strokes, or modify existing ones.
- **Selection and chain selection:** tap a stroke with your finger, or long-press with your stylus, to open the stroke's options. Long-press with your finger instead to select the whole chain of connected strokes and apply the options to all of them.
- **Deleting strokes:** remove all strokes on a page or in the whole document at once, so you don't have to delete them one by one.

## Disclaimer

Still under development. The code is AI-assisted, like, a lot, so beware of the slop.

## License

This project is licensed under the GNU General Public License, version 3 or later. See [LICENSE](LICENSE).

## TODO
- Some kind of bookmarks for pages with strokes
- Write strokes into PDF
- Stylus pressure?
