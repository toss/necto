# Contributing to Necto

English | [한국어](CONTRIBUTING-ko.md)

Thank you for your interest in Necto.

## Reference

- Architecture and module boundaries — [docs/architecture.md](docs/architecture.md)
- The rules a change must survive — [docs/harness.md](docs/harness.md)
- How to verify a change — [docs/verification.md](docs/verification.md)
- Plugin manifest and the bridge contract — [docs/plugin-manifest.md](docs/plugin-manifest.md)
- What a plugin can ask Necto to do — [docs/bridges.md](docs/bridges.md)
- Design tokens, dark mode and accessibility — [docs/design.md](docs/design.md)

## Write in English

Write code, comments, documentation and commit messages in English. Documentation
may include a Korean translation.

## Issues

For potential vulnerabilities, follow [SECURITY.md](SECURITY.md) before posting details.

Use issues to report bugs or propose features. A bug report needs the Necto
version, the macOS version, how the target was connected
(USB device or simulator), and steps to reproduce.

Necto's feature screens are web plugins. When proposing a feature, consider a
plugin implementation before changes to the shell, SDK or runtime.

## Pull requests

1. Fork this repository, then clone your fork to your computer.

2. Create a branch from `main`. Name it by intent, like `feature/<topic>`,
   `fix/<topic>` or `docs/<topic>`.

3. Make the change, and run the verification matching its scope.
   [docs/verification.md](docs/verification.md) says which change needs which
   check.

4. Push the branch to your fork, and open a pull request against `main` of
   this repository. Fill in the Test Plan section of the template.

### Discuss large changes in an issue first

For the following changes, agree on an approach with a maintainer in an issue
before starting work:

- adds a new built-in plugin, or a new operation to an existing plugin's
  manifest;

- touches the wire protocol, the control socket, or the SDK's public API —
  anything a connected app or the CLI depends on;

- adds a bridge or changes a bridge contract, in
  [docs/bridges.md](docs/bridges.md) terms;

- changes the design system itself — changing the tokens, `WebPackages/Bridge/*.css` or
  the gallery affects all plugins;

- moves code across the module boundaries described in
  [docs/architecture.md](docs/architecture.md).

In the issue, describe the problem you are solving, the approach you have in
mind, and where the change lives (a device plugin, a desktop plugin, or the
core).

Everything else needs no issue — a bug fix with a reproduction, a
documentation fix, added tests, a small improvement inside one module. Open
the pull request directly.

## License

Contributing to Necto means agreeing that your contributions are distributed
under the [MIT License](LICENSE).
