# __DISPLAY_NAME__

`__PLUGIN_ID__` is a placeholder ID. Before sharing the plugin, replace `com.example`
with your namespace in both the Swift plugin and `panel/public/manifest.json`.
Keep the ID stable across updates; the display name can change independently.
Duplicate IDs in an app assert in debug and are rejected in all builds. For an
intentional runtime replacement, call `NectoSDK.unregister(id:)` before registering.

A Necto device plugin. Its Swift package answers `necto.device.*` operations and
carries the built web panel into the connected app.

```bash
npm install
script/build
```

Open `__PROJECT_NAME__.xcodeproj` and run the `ExampleApp` scheme. The plugin appears
in Necto while the example app is connected.
