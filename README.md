# Screenshot Quick Markup

Fast macOS screenshot markup tool for `Option+Shift+S`.

Workflow:

1. Press `Option+Shift+S`
2. Drag an area, or press `Return` for the full display under the pointer
3. Mark up the image
4. Click `Copy & Close`, or use `Cmd+C` to copy without closing

You can also choose `Mark Up Clipboard Image` from the menu bar item to edit an
image that is already on the clipboard.

## Build

```sh
cd /Users/yuhyeongchan/project/apps/screenshot-quick-markup
swift build -c release
```

## Run

```sh
.build/release/screenshot-quick-markup
```

## Editor Controls

- Tools: select, pen, highlighter, arrow, rectangle, ellipse, blur/mosaic, numbered marker, check, text
- Select supports click-to-select, drag-to-move, arrow-key nudging, and `Delete`
- Color swatches and custom color picker are available in the toolbar
- Double-click the image to add text quickly
- Tool shortcuts: `V` select, `P` pen, `H` highlighter, `A` arrow, `R` rectangle, `O` ellipse, `B` blur, `N` marker, `K` check, `T` text
- `Cmd+Z`: undo
- `Cmd+Shift+Z`: redo
- `Cmd+C`: copy edited image to clipboard
- `Cmd+S`: save edited PNG
- `Cmd+W`: close the current capture tab/window without changing the clipboard
- Toolbar `Undo`, `Redo`, `Delete`, `Copy`, `Save`, and `Copy & Close` buttons are available
- Closing the window normally discards the editor session without replacing the clipboard
- PNG export preserves the captured image's native pixel dimensions

## Test

```sh
swift test
```

## Install As Login Agent

```sh
cd /Users/yuhyeongchan/project/apps/screenshot-quick-markup
./install-launch-agent.sh
```

By default the bundle is ad-hoc signed, so macOS can ask for Screen Recording
permission again after the executable changes. If you have a stable local code
signing identity, preserve permission across rebuilds with:

```sh
SCREENSHOT_QUICK_MARKUP_SIGNING_IDENTITY="Apple Development: Your Name" ./install-launch-agent.sh
```

Logs:

- `/tmp/screenshot-quick-markup.out.log`
- `/tmp/screenshot-quick-markup.err.log`

## Screen Recording Permission

The installer builds a stable app bundle at:

```text
/Users/yuhyeongchan/project/apps/screenshot-quick-markup/dist/Screenshot Quick Markup.app
```

Grant Screen Recording permission to `Screenshot Quick Markup.app`, not the raw
`.build/release/screenshot-quick-markup` executable. If macOS keeps returning
only the desktop wallpaper, remove the old raw executable entry from Screen
Recording, add the app bundle, then restart the launch agent.
