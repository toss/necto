# Control fixtures

ExampleApp registers `NectoUIControlPlugin()` and includes two test tabs:

- **Control**: UIKit buttons, text fields, scrolling, and multi-touch gestures.
- **Accessibility**: SwiftUI controls, navigation, and sheets.

## Run interaction checks

Build the panel before building ExampleApp:

```bash
yarn workspace @necto-plugin/control build
```

Install and freshly launch ExampleApp with a dedicated bundle identifier such as
`im.toss.necto.example.interaction-poc`. Connect it to Necto, then run:

```bash
necto device list --json
node script/tests/control-e2e.mjs <device-id> im.toss.necto.example.interaction-poc
```

The checks cover taps, text input, scrolling, navigation, and target validity.
Set `NECTO_CLI` to use a development CLI executable.
