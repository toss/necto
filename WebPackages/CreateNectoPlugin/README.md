# create-necto-plugin

Creates a standalone Necto plugin project with a manifest and a Vite panel.

```bash
create-necto-plugin Example --type device
create-necto-plugin Example --type desktop
```

A device project also includes a Swift package, an Xcode project and an ExampleApp.
The generated ID uses `com.example.<name>` as a placeholder. Before distribution,
choose your own stable lowercase reverse-domain ID and update the Swift `id` and
panel manifest together. Display `name` is independent; renaming a screen must not
change its ID. Existing short IDs remain valid; no domain ownership is verified.
Use the latest release (Node.js 20+ and npm required):

```bash
curl -fsSL https://raw.githubusercontent.com/toss/necto/main/script/create-plugin | bash -s -- Example --type device
```

Replace `Example` with your project name. `--type`: `device` or `desktop`.
