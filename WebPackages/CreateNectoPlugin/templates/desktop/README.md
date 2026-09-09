# __DISPLAY_NAME__

`__PLUGIN_ID__` is a placeholder ID. Before sharing the plugin, replace `com.example`
with your namespace in `public/manifest.json`. Keep the ID stable across updates;
the display name can change independently. Lowercase reverse-domain is recommended,
not enforced or verified. Local/ZIP updates require the user's source confirmation
to retain installation identity and permissions. Removing and reinstalling creates
a new installation, even with the same ID.

A Necto desktop plugin. It runs without a connected app and may only bind
`necto.desktop.*` operations.

```bash
npm install
npm run build
```

Install the generated `dist/` folder or its zip in Necto.

With Necto running, copy and run the CLI setup command in Settings → About, then:

```bash
necto install dist --local --json
```

Approve the source and bridges in Necto; the command waits for installation to finish.
To remove it, use `necto delete <pluginID> --json` with the ID from `necto plugin list`.
Deletion moves the installed copy to Trash and revokes its permissions.

## Publishing

A published plugin is the `dist/` folder zipped and attached to a GitHub release.
You can create the archive with any ZIP tool.

`.github/workflows/release.yml` does it for you. Set the new version in
`public/manifest.json`, then push a tag:

```bash
git tag v0.1.1 && git push --tags
```

The tag must match the manifest version; otherwise the workflow stops.
Necto uses the manifest version to detect updates, so changing only the tag
does not make the release available as an update.

Anyone can then install it by pasting the repository address into Necto, under
Settings → Desktop Plugins. Necto reads the latest release, shows what the plugin
binds to, and installs it once they agree.

The CLI can start the same approval flow with `necto install owner/repo --json`.
Remote is the default; `--remote` is optional, while local folders and ZIPs require
`--local`. Use an HTTPS `/releases/tag/<tag>` URL to select a release. The
`necto-cli plugin install` and `necto-cli plugin delete` aliases are also supported.

To publish by hand instead:

```bash
npm run build
cd dist && zip -r ../my-plugin.zip . && cd ..
gh release create v0.1.1 my-plugin.zip
```

The zip's name does not matter. What matters is that `manifest.json` sits at its
root, and that the version inside it went up.
