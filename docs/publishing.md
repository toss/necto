# Publishing a desktop plugin

A desktop plugin release contains a ZIP with `manifest.json` and web assets at its
root. Attach it to a GitHub release; building and packaging do not require macOS.

Someone installs it by pasting your repository address into Necto, under
Settings → Desktop Plugins.

Device plugins are not published this way. They reach an app through the Swift
package at your tag, so for those the tag is the release.

## From a tag

`create-necto-plugin` writes `.github/workflows/release.yml` into a new desktop
project. Set the version in `public/manifest.json`, then push a tag:

```bash
git tag v0.1.1 && git push --tags
```

The workflow builds the plugin, checks the tag against the manifest, zips `dist/`
and creates the release using the token provided by GitHub. The runner already
includes `zip`, `jq` and `gh`; no additional configuration is needed.

The tag has to match the manifest version, and the workflow stops if it does not.
Necto uses the manifest version to detect updates; a new tag alone does not
make a release available as an update.

## By hand

```bash
npm run build
cd dist && zip -r ../my-plugin.zip . && cd ..
gh release create v0.1.1 my-plugin.zip
```

The archive's name does not matter. What matters is that `manifest.json` sits at its
root, and that the version inside it went up.

If you have Necto installed, `necto-cli` will check the plugin before you publish
it, with the same manifest type the app installs by:

```bash
necto-cli plugin pack dist
```

The `pack` command supports desktop plugins only and rejects `necto.device.*`
bindings. Device plugins ship in the app's Swift package.
After validation, it prints the `gh` command to run next.

To try a built plugin locally before publishing, keep Necto running and use
`necto install dist --local` (or pass a ZIP with `--local`). Review its source and bridges in
Necto's approval window; the command waits for the installation result. Add
`--json` for a machine-readable result. Both the CLI and app must support this command.

The same command accepts a GitHub repository URL:

```bash
necto install owner/plugins --json
necto install https://github.com/owner/plugins --remote
necto install https://github.com/owner/plugins/releases/tag/v1.2.0
```

The app reads the release and downloads its plugin archive. If there are several
plugins, choose one in Necto before approving. Repository source information is
retained for updates, and the CLI waits for that plugin's completed installation.
The existing GUI release source's private/Enterprise authentication requirements apply.

Remote installation is the default; `--remote` is optional and cannot be combined
with `--local`. Settings → About has the command that puts both `necto` and the
compatible `necto-cli` name on your `PATH`. Copy and run it again after updating if
only the old command name is linked.

To remove a test installation, find its ID with `necto plugin list --desktop`, then run
`necto delete <pluginID> --json`. This moves the installed folder to Trash and revokes
its registration and permissions. It does not remove the source folder or repository.
See [the CLI guide](control-socket.md) for aliases, responses and cancellation behavior.

## Publishing several from one repository

Attach one archive per plugin. Necto lists what a release holds and asks which to
install.

For the list to say anything before downloading, publish each plugin's
`manifest.json` beside its archive, named after it:

```
my-plugin-0.2.0.zip
my-plugin-0.2.0.manifest.json
other-plugin-0.2.0.zip
other-plugin-0.2.0.manifest.json
```

Without separate manifest files, installation still works. The list displays file
names and the approval screen shows plugin details. Update checking is unavailable
because Necto compares versions in the attached manifests.

## What people see before they agree

Necto lists the plugin's source and each bound bridge using host-provided
descriptions. Installation approval grants access to those bridges.
Updates that add bindings require approval again.

Permissions are scoped to the normalized repository source and plugin ID together.
Different IDs in one repository do not share grants, and the same ID in different
repositories remains separate. Local folder/ZIP installations use a host-created
installation UUID plus plugin ID. Changing the source changes the principal and
does not transfer the old source's grants.

## Being found

There is no central registry, and adding one is not planned. Tag your repository
`necto-plugin` on GitHub so it turns up in that topic, and put the install line in
your README:

```
Settings → Desktop Plugins → Install from GitHub → your-name/your-plugin
```
