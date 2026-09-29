# Security

Report ordinary bugs and feature requests in [Issues](https://github.com/toss/necto/issues).

For a potential vulnerability, use **Security → Advisories → Report a vulnerability**
if that option is available. Otherwise, open an issue requesting a private reporting
channel, without exploit steps, credentials, captured traffic or other sensitive data.
Wait for a maintainer to provide a private channel before sharing those details.

Include the affected Necto/SDK versions, operating systems and whether the connection
uses USB or a simulator. Check the latest release when it is safe to do so; support
for older releases is not guaranteed.

Necto is a development tool, not a sandbox for untrusted plugins. Keep it out of
production app builds. Device plugins trust their integrating app, and desktop
plugins require approval of their source and requested bridges. Shell execution can
modify files and run processes as the logged-in user. See the
[plugin trust policy](docs/plugin-manifest.md#identity-and-trust) and
[production build guidance](docs/setup.md#keeping-it-away-from-users).

For optional SDK connection authentication, see the
[connection authentication and Keychain registration guide](docs/connection-security.md)
([한국어](docs/ko/connection-security.md)). It covers app public keys, private setup
tools, Mac Keychain entries and troubleshooting unauthorized connections.
