# Screenshot Quick Markup

Fast macOS screenshot markup tool for `Option+Shift+S`.

Workflow:

1. Press `Option+Shift+S`
2. Drag an area, or press `Return` for the full main display
3. Mark up the image
4. Close the editor window to copy the edited PNG to the clipboard

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

- Tools: select, pen, highlighter, arrow, rectangle, ellipse, blur/mosaic, numbered marker, text
- Color swatches and custom color picker are available in the toolbar
- Double-click the image to add text quickly
- `Cmd+Z`: undo
- `Cmd+Shift+Z`: redo
- `Cmd+C`: copy edited image to clipboard
- `Cmd+S`: save edited PNG
- Toolbar `Copy`, `Save`, and `Done` buttons are available
- Close window: copy edited image to clipboard

## Install As Login Agent

```sh
cd /Users/yuhyeongchan/project/apps/screenshot-quick-markup
./install-launch-agent.sh
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
