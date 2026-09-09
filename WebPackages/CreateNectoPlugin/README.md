# create-necto-plugin

Creates a standalone Necto plugin project with a manifest and a Vite panel.

```bash
create-necto-plugin Uptime --type device
create-necto-plugin HostStatus --type desktop
```

A device project also includes a Swift package, an Xcode project and an ExampleApp.
The generated ID uses `com.example.<name>` as a placeholder. Before distribution,
choose your own stable lowercase reverse-domain ID and update the Swift `id` and
panel manifest together. Display `name` is independent; renaming a screen must not
change its ID. Existing short IDs remain valid; no domain ownership is verified.
The release tarball can be run directly without publishing it to an npm registry:

```bash
npx --yes \
  --package=https://github.com/toss/toss-necto/releases/download/0.4.0/create-necto-plugin-0.4.0.tgz \
  create-necto-plugin Uptime --type device
```
