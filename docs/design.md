# Design

The macOS shell and web plugins share design tokens and components to keep
plugin screens consistent with the built-in UI.

## Contents

- The gallery
- Principles
- The four layers
- Colour
- Type
- Space, radius, borders
- Component rules
- Dark mode
- Accessibility
- Using it in a plugin
- Using it in SwiftUI
- What this guide covers

## The gallery

`docs/design/index.html` renders every component from the stylesheets that
ship. It imports `WebPackages/Bridge/theme.css` and
`WebPackages/Bridge/components.css` directly so you can preview stylesheet changes.

```bash
yarn workspace @necto/bridge build
script/serve-design
```

Serve it rather than opening the file: the page imports the stylesheets by path.

Add a class to `components.css` and add an example to the gallery in the same change.

The app and gallery share stylesheets. If they look different, check the plugin's CSS
and the Swift host. Editing `components.css` changes the shared design in both places.

The app also pins the current appearance and palette variables on every WebView. A
device plugin carries the stylesheet from the app that built it, which may predate the
Mac shell; host-owned variables keep that older panel on the current background and
surface colours. CSS that ignores the variables remains the plugin author's choice.

Before changing a component, check every example in the gallery. Styles vary by
context: `.necto-body` has padding in prose panes, but not in table panes.

## Principles

**Reserve emphasis for important states.** Use text weight and muted colours for
normal states. Reserve saturated colours for failures and the highest-priority item.

**Use text colour for selection and focus.** Reserve hues for status changes,
rather than tinting every selected row.

**Use one separator.** Separate items with space or a line, not both. Avoid
combining row borders with hover fills.

**Keep row density consistent.** Every screen uses `--necto-row-height`.

**Type carries hierarchy.** Weight and colour do the work that size and rules would
otherwise do. Three sizes are usually enough on one screen.

**UI and code type are separate.** Labels and controls use the UI face; code, values
and plugin data use the code face. Both are user configurable, and the same choice is
applied to the native shell and web plugins.

## The four layers

A token belongs to exactly one layer, and each layer may only read the one above it.

| Layer | Holds | Example |
| --- | --- | --- |
| Foundation | The neutral ladder, one per theme | `--necto-base-40` |
| Semantic | Token roles | `--necto-text-secondary` |
| Component | Sizes a widget needs | `--necto-row-height` |
| State | Focus, disabled | `--necto-focus-ring` |

A plugin styles itself from the semantic and component layers. Reaching into the
foundation is how a colour ends up correct in one theme and wrong in the other.

Both ladders are authoritative at the top of `theme.css`. The theme rules below them
only *choose* between the two. Swift and the WebView host mirror the values they need;
`NectoThemeTests` compares native colors with rendered WebView colors, including built
panels and host overrides. Run it with `script/test native`.

## Colour

### Foundation

`--necto-base-00` through `--necto-base-100`. In light mode the numbers run light to
dark; in dark mode they run dark to light. Everything below derives from them, so one
ladder swap moves the whole system.

### Semantic

| Token | Use |
| --- | --- |
| `--necto-bg` | Content background |
| `--necto-sidebar` | Sidebar and window chrome |
| `--necto-surface` | Panels that sit on the background |
| `--necto-hover` | Hovered row |
| `--necto-selected` | Selected row |
| `--necto-border` | Hairlines and dividers |
| `--necto-border-strong` | Input borders, active edges |
| `--necto-text` | Primary text |
| `--necto-text-secondary` | Labels and metadata |
| `--necto-text-tertiary` | Placeholders, hosts, timestamps |
| `--necto-accent` | Text colour for selection and focus |
| `--necto-brand` | Identity only: the app icon and the brand line |
| `--necto-success` `--necto-warning` `--necto-danger` `--necto-info` | Status |

`--necto-accent` resolves to the text colour. Necto's orange is defined by
`--necto-brand` and used only on the app icon, leaving colours in the workspace
available for status indicators.

Never write a colour as a literal. If a token is missing, add one.

## Type

Use the UI face for prose, labels and controls, and the code face for code and data.
Follow the host's font preferences rather than bundling a separate display face.

| Role | Size | Token |
| --- | --- | --- |
| Title | 17px | `--necto-size-title` |
| Body | 13px | `--necto-size-body` |
| Label | 12px | `--necto-size-label` |
| Caption | 11px | `--necto-size-caption` |

Sizes are not literals. Each derives from `--necto-font-scale`, which the host sets
from the user's text size preference, so one setting scales the shell and every plugin
together. Never write a `px` font size in a component.

The Appearance editor and About rows are the exception: they stay at the base size,
and Appearance uses the system UI face while it edits those values. A control must not
move or change typeface underneath the pointer because it just changed its own preference.
Settings navigation, plugin management and logs still follow the chosen text size.

The native shell follows the system language by default and can be pinned to English
or Korean in Settings. Web plugins own their copy and localization. The host writes the
selected language to `<html lang>` before plugin code runs and reloads the open panel
when it changes; it does not rewrite plugin content or add a locale operation to the
app-to-desktop protocol.

Numeric columns use `--necto-font-mono` with `font-variant-numeric: tabular-nums` and
right alignment, heading over the digits, so a column is compared by scanning rather
than reading.

Timestamps are fixed, not localised. `toLocaleTimeString` renders "12시 46분 21초" or
"12:46:21 PM" — both wider than the column and harder to compare down a list.

**Do not set `-webkit-font-smoothing`.** It makes plugin text thinner than
the shell's AppKit-rendered text.

## Space, radius, borders

Space on a 4px grid: `--necto-space-1` through `--necto-space-5` (4, 8, 12, 16, 24).

Radius: `--necto-radius-control` (4px) for controls and rows, `--necto-radius-panel`
(10px) for panels. Nested radius never exceeds its parent.

Borders are `1px solid var(--necto-border)`. A region gets a border or a different
surface, not both.

## Component rules

**Rows** are borderless. Hover fills with `--necto-hover`, selection with
`--necto-selected` plus an ink bar down the leading edge. Selection is never colour
alone.

**Tables** are compact, fixed layout, and truncate with an ellipsis rather than
wrapping. Headers are caption sized, secondary coloured, sticky, and not uppercased.

**Status** pairs a mark with a value: a small square and the code. One shape for every
state: a 200, a 404 and a failure use the same shape. A pending row uses an outlined
square rather than a filled one, so the meaning survives without the hue.

**Icons** are line weight, sized to the text beside them. SF Symbols are a Mac font:
the shell may use them, a plugin draws its own strokes with inline SVG. Necto does not
ship an icon set through the bridge.

**Connection state** uses a filled dot for connected targets and a ring for
disconnected targets, including simulators. The icon beside the name identifies
the target type.

**Buttons** are quiet until needed. A destructive action reads as plain text and only
colours itself when the pointer is on it.

**Code blocks** show a copy button on hover or keyboard focus.

**JSON editors** use `.necto-json-editor`. They keep at least six rows visible and
grow into available space when their container has a defined height. Keep labels and
actions outside the scrolling editor so the data gets the usable area.

**Empty state** says what is missing and what to do next, in two lines at most. It
never advertises features.

**Search and filters** belong on growing logs and lookup-heavy lists. Search matches
the summary text already in memory; it never fetches detail payloads as an index.
Stable facets such as level, status and kind are separate filters and combine with
the search term. Updating a live list must not take focus or the caret from the field.

**Detail panes open on the right by default.** Use `createDetailPane` from
`@necto/bridge` with the shared `.necto-detail` styles. Stack the panes on narrow
viewports. Store each axis's size under a plugin-specific key and preserve it across
selection changes, live updates and reopening the panel. Tables adapt to their
pane's width, not only the window's width.

Create one controller per plugin view and call `mount(aside)` after appending each
detail to `.necto-app`. Call `unmount()` before removing it. The list uses
`.necto-body`; an optional `.detail-slot` wrapper uses `display: contents`.
Separators expose their orientation and value to assistive technology and support
arrow keys. A one-pane screen does not add a decorative separator.

**Scrollbars** take `scrollbar-color` from the ladder. Left to the UA they arrive as a
bright band in a dark window.

## Dark mode

Dark mode is a peer, not an inversion. Surfaces come forward by getting *lighter*,
which is the opposite of light mode.

Check that text is readable in both themes. Consider comfort during extended use
as well as contrast ratios.

`color-scheme` is set per theme. Without it the UA paints scrollbars, form controls and
the caret from the system preference, and they stay bright in a dark window.

A plugin needs no theme code. The host pins the window with `data-theme`, and
`prefers-color-scheme` is the fallback for a plugin opened outside the app. Do not add
a separate theme toggle; follow the host's appearance setting.

## Accessibility

For normal text, target the [WCAG AA contrast ratio](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)
of at least 4.5:1. Measure it against the background, sidebar, surface, hover and
selected states. Adjust colour tokens that fall below the threshold and check them
in the other appearance too.

Hairline borders separate regions rather than carry meaning. Do not rely on them
alone to convey information.

Colour never carries meaning alone. A status colour is always paired with a word, a
number, or a shape.

Keep the 2px accent outline from `:focus-visible` so keyboard focus remains visible.
Interactive rows must be keyboard-accessible, and navigable lists must support arrow keys.

Respect what the OS already exposes: **Reduce Motion** removes transitions, and no
animation may be required to understand a state change.

## Using it in a plugin

```ts
import "@necto/bridge/theme.css";
import "@necto/bridge/components.css";
```

```css
.row {
  height: var(--necto-row-height);
  background: var(--necto-surface);
  border-radius: var(--necto-radius-control);
  color: var(--necto-text);
}
```

`components.css` covers the widgets a debugging plugin keeps needing — table, toolbar,
tabs, field, button, status, badge, pairs, code, empty state — as plain CSS on plain
elements, independent of the plugin's framework.

## Using it in SwiftUI

`NectoTheme` holds the same values.

```swift
Text(app.appName)
    .font(.necto(.body))
    .foregroundStyle(NectoTheme.textSecondary)
```

Never use `Color.blue` or a raw hex in a view. If a token is missing, add it to
`theme.css` first and then mirror it in Swift. The design token harness compares
the values.

## What this guide covers

Necto's own UI — `Necto/`, `WebPackages/Bridge/`, `WebPackages/BuiltInPlugins/src/` —
must follow this guide. External plugins may use other styles; the bridge does not
check styling or reject plugins based on their appearance.
