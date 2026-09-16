# Necto

English | [한국어](README-ko.md)

Necto is a macOS debugging tool for iOS apps. Use plugins to inspect network
requests, events and performance metrics, or add tools for your app.

![Necto showing CPU, memory, and frame rate in the Performance plugin](docs/images/necto.png)

- Connect to apps running on USB devices or iOS simulators.
- Feature screens are web plugins made up of a `manifest.json` and web assets.
  They use the same design tokens as the app
  ([docs/design.md](docs/design.md)).
- Add a device plugin's Swift package to your app and register it with the SDK
  ([docs/setup.md](docs/setup.md)). Its panel appears in Necto when the app connects.
- Desktop plugins work without a connected app and install in Necto from a
  GitHub release, folder or ZIP ([docs/plugin-manifest.md](docs/plugin-manifest.md)).
- Install, delete and call desktop plugins from the terminal with `necto`
  (`necto-cli` remains supported)
  ([docs/control-socket.md](docs/control-socket.md)).
- The Mac app and SDK use Swift, while plugin screens use web technologies.
  The Mac app manages connections and execution without a separate server process
  ([docs/architecture.md](docs/architecture.md)).

## Getting started

Download the DMG from [Releases](https://github.com/toss/necto/releases) and
drag Necto into Applications. See the [installation guide](docs/install.md) for
checksum verification and the app's ad-hoc signing policy.

Building from source requires macOS 14 or later, Xcode with Swift 6.0 or later,
Node.js 22.12 or later and Yarn 4.6.0. The iOS SDK supports iOS 16 or later.

```bash
script/build   # web packages, Swift packages, then the app
script/test    # unit tests and static checks
open Build/Products/Debug/Necto.app
```

After building the web packages, you can also open `Necto.xcodeproj` and run the
`Necto` scheme. To build `ExampleApp` with `script/build`, start an iOS simulator
before running the script.

To integrate the SDK into your app and exclude SDK calls from Release builds, see
[docs/setup.md](docs/setup.md).

## Create a plugin

Requires Node.js 20+ and npm. Uses the latest release.

```bash
curl -fsSL https://raw.githubusercontent.com/toss/necto/main/script/create-plugin | bash -s -- Example --type device
```

Replace `Example` with your project name. `--type`: `device` or `desktop`.

## Documentation

- Plugin tutorials: [desktop](docs/tutorial-desktop.md) · [device](docs/tutorial-device.md)
- Plugin specification: [manifest](docs/plugin-manifest.md) · [IDs and trust](docs/plugin-manifest.md#identity-and-trust)
- Bridge reference: [available operations](docs/bridges.md) · [web API](WebPackages/Bridge/README.md) · [shell access](docs/bridges.md#shell-access)
- [CLI usage](docs/control-socket.md)
- Contributor guides: [architecture](docs/architecture.md) · [design](docs/design.md) · [verification](docs/verification.md)

## Contributing

Anyone is welcome to contribute. Read
[CONTRIBUTING.md](CONTRIBUTING.md) ([한국어](CONTRIBUTING-ko.md)) for how to
report an issue and open a pull request.

## License

MIT © Viva Republica, Inc. See [LICENSE](LICENSE) for details.
