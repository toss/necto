# Optional connection authentication

Keep Necto out of customer Release builds. Authentication is an additional control
for development and internal builds, not a substitute for excluding the SDK.

## App configuration

The package requires Swift 6.1 or later.

```swift
#if DEBUG
NectoSDK.start(publicKey: "<Base64 P-256 public key>")
#endif
```

The String is the Base64 encoding of a 65-byte ANSI X9.63 uncompressed P-256 public
key (the output of `SecKeyCopyExternalRepresentation` for that public key).
It is public information and can be checked into the app repository. An invalid
String stops the listener and reports a failed SDK status; it never enables a
plaintext connection.

`NectoSDK.start()` keeps the existing unencrypted protocol. Both entry points choose an available
port internally from 9979 through 9986; the public `port:` parameter is removed.

Authentication belongs to each connection, identified by device and app bundle ID.
An unconfigured app on the same device continues to work normally. The Keychain
credential belongs to the bundle ID: the same app on several devices can use one
credential, but every connection performs its own TLS handshake. Builds with the
same bundle ID must use the same pinned key to share that Mac credential.

Different bundle IDs may also share a key. Call `install` for each bundle ID with
the same private key and matching certificate. Each app gets its own registration;
the private key is stored once. An unregistered bundle ID cannot use it.

## Registering a key in Mac Keychain

### 1. Prepare the matching key and certificate

Use the following values to register the credential. The private key must match
the public key configured in the app. Keep it out of the SDK and public repository.

| Value | Where it is used |
| --- | --- |
| App bundle ID, such as `com.example.internal-app` | The app's actual bundle ID and the Mac registration must match. |
| Base64 P-256 public key | Pass it to `NectoSDK.start(publicKey:)` in the app. |
| P-256 private key in PEM format | Give it only to the private setup tool used by authorized developers. |
| Matching certificate, DER encoded as a Base64 String | The setup tool registers it together with the private key. |
| Installed Necto executable path | Grant that executable access to the key. |

A matching self-signed certificate is sufficient; no CA service is required. The
public key returned by `store.identity(bundleID:)` below is in the SDK's expected
format. The setup tool may receive its key and certificate as Strings; users do
not need to manage certificate files.

### 2. Register the credential in Mac Keychain

Install Necto first. Use the executable inside the app bundle, normally
`/Applications/Necto.app/Contents/MacOS/Necto`, as the trusted application. When
testing a locally built GUI, use that build's executable path instead.

Implement key registration in a setup tool that fits your project. The example
uses `NectoMacService` from the `NectoMac` subdirectory package. Adjust the package
path to your local checkout.

```swift
// In the private setup tool's Package.swift:
dependencies: [
    .package(path: "/path/to/necto/NectoMac"),
],
targets: [
    .executableTarget(
        name: "CompanyNectoSetup",
        dependencies: [.product(name: "NectoMacService", package: "NectoMac")]
    ),
]
```

Replace the placeholders with the matching values and run the code in your setup
tool. Do not generate a different key on each Mac.

```swift
import Foundation
import NectoMacService

let bundleID = "com.example.internal-app"
let privateKeyString = "<PEM private key from your restricted provisioning source>"
let certificateString = "<Base64 DER certificate matching that private key>"
guard let certificateData = Data(base64Encoded: certificateString) else {
    fatalError("Invalid Base64 certificate")
}

let store = try NectoKeychainCredentialStore()
try store.install(
    bundleID: bundleID,
    privateKeyPEM: Data(privateKeyString.utf8),
    certificateDER: certificateData,
    trustedApplications: [
        URL(fileURLWithPath: "/Applications/Necto.app/Contents/MacOS/Necto")
    ]
)
if let identity = try store.identity(bundleID: bundleID) {
    print("SDK publicKey: \(identity.publicKey)")
}
```

The printed value is public. Set it in the app's `NectoSDK.start(publicKey:)` and
rebuild the app if it was not configured already. Never print the private key.
Distribute any setup tool containing the private key only to authorized users.

### 3. Check the registered items

The installer imports the private key as sensitive and non-extractable, allows
signing, and grants access to the installer and specified Necto executable. Open
**Keychain Access**, select the default keychain (usually **login**) and **All
Items**, then search for the following names:

| Item | Lookup |
| --- | --- |
| Private key | Label: `Necto Connection: <first registered bundleID>` |
| Certificate | Label: `Necto Certificate: <first registered bundleID>` |
| App registration | Service: `im.necto.connection.certificate`; account: `<bundleID>` |

For example, the private key for `com.example.internal-app` is named
`Necto Connection: com.example.internal-app`. If another app shares this key, the
key keeps its original name and access permissions. The matching certificate is
also shared. Search for the registration's service name to check each app's bundle ID.
The registration stores a certificate reference in its public attributes. Neither
the registration lookup nor the certificate read needs permission to use the private
key; Keychain approval applies when Necto signs with that key.
Creating a password entry with the same name does not install a private key; use
the registration API so the key type and executable permissions are correct.

If the items do not appear, check whether the setup tool actually ran successfully.
Installing the GUI alone does not create them. Other bundle IDs have no fallback
credential. Duplicate installation is rejected and does not overwrite the old
key; the provisioning tool owns replacement and removal policy.
When removing one app's registration, keep a shared private key and certificate while
other apps still use them. Reusing a key preserves its access permissions. The installer and
specified Necto executable must already have access; otherwise registration fails.
The provisioning tool must handle any change to the shared key's permissions separately.

### 4. Confirm the connection

Necto reads the credential on each connection attempt, so installing a missing key
does not require restarting Necto or the SDK. The CLI talks to Necto's existing
local control socket; only the GUI process needs the connection key.

```bash
necto-cli device list --json
necto-cli plugin list --device <device-id> --app com.example.internal-app --json
```

Take `<device-id>` from the first command. The app should have `status: "connected"`
and its plugins should be listed. While `status` is `unauthorized`, plugin list,
help, commands and subscriptions return `UNAUTHORIZED`; listing devices remains
available.

| Reason | What to check |
| --- | --- |
| `missingKey` | Register the key for this app's exact bundle ID in the Mac user's default keychain. |
| `rejectedKey` | Check the SDK public key and Mac private key are a pair; also check the connection if TLS still fails. |
| `credentialUnavailable` | Check that the default keychain is unlocked, the registration, certificate and private key exist, and the running Necto executable has access. |

## Connection behavior

1. The SDK sends `NectoSecurityOffer` with public discovery information: bundle ID,
   app/device names, OS version, and simulator ID when available.
2. The host selects that bundle's Keychain identity and upgrades the existing USB
   or loopback socket to TLS 1.3. The socket-connecting Mac is the **TLS server**;
   the socket-listening SDK is the **TLS client**, verifying the pinned public key.
3. Only after TLS succeeds do `NectoHandshakeHello`, acknowledgement, plugin
   registrations, commands, results, events, and panel data cross the session.

The TLS implementation is SwiftNIO SSL. The private key stays in Keychain; TLS
signatures use `SecKeyCreateSignature` through `NIOSSLCustomPrivateKey`. Failed
authentication closes the session and never falls back to plaintext. A plaintext
host cannot enable a protected SDK by sending a normal handshake acknowledgement.

Protected connections allow up to two minutes for the TLS handshake, including
Keychain approval. Requests that share a private key sign one at a time; a queued
request for a closed connection is discarded before accessing the key. Discovery
and post-authentication messages keep their ordinary network deadlines.

The sidebar keeps a refused app visible with a red **Unauthorized** indicator and
a tooltip explaining a missing, rejected, or unreadable key. Clicking the row opens
setup guidance without selecting it as a connected target. The guidance explains
that both GUI and CLI debugging are blocked and that Necto retries automatically
after the key is configured. `necto-cli device list --json` reports `status: "unauthorized"`
and a reason; plugin discovery, commands, and subscriptions fail with `UNAUTHORIZED`.
Other connected apps and desktop plugins remain usable.

## Protection scope

Apps configured with a public key receive two protections:

- **Access control:** Without the matching private key, neither the GUI nor CLI
  can debug that app. Failed authentication closes the connection.
- **Encrypted communication:** After authentication, plugin information, data,
  and commands travel inside TLS 1.3. Authentication failure never falls back to
  an unencrypted connection.

The app checks that the Mac holds the matching private key.

Distribute the private key only to authorized users. A shared key cannot block
one user or device separately. If it leaks, replace both the app's public key and
the private key on authorized Macs.

::: details Encryption scope and key management details

App names, bundle IDs, device names, and other discovery fields are sent before
authentication and are not encrypted. They must not contain sensitive debugging
data. The separate GUI–CLI Unix control socket does not use TLS.

The SDK checks the certificate's public key against the configured key. It does
not check the issuer, hostname, or expiration date. Reissuing a certificate with
the same key keeps the app's public key setting valid.

Non-extractable Keychain storage blocks normal private key export APIs. It does
not hide the original key in a setup tool, prevent an authorized process from
signing, or protect against a compromised Mac. Distribute tools containing the
key only to authorized users, even if the tools are obfuscated.

:::

## Verification

`script/test swift` runs transport, TLS, Keychain, production SDK/host integration,
and CLI tests. Security tests use temporary keys and Keychains, real sockets, and a
separate trusted signing executable. They cover missing/wrong keys, plaintext
imitation, ciphertext tampering/replay, non-extractable keys, cancellation, legacy
connections, mixed protected/unprotected apps, and reconnecting after installation.

For a simulator check, launch ExampleApp with `SIMCTL_CHILD_NECTO_PUBLIC_KEY` set
to a test public key. The example's Start listening button preserves that setting.
Use an isolated app bundle ID and remove its test Keychain entries afterward.
Simulator tests do not verify the physical USB path.
