# Supplemental licenses

These upstream texts cover bundled dependencies and assets whose packages omit
the required license files:

- `DocSearch-3.8.2.txt`: [`@docsearch/css` 3.8.2](https://github.com/algolia/docsearch/blob/v3.8.2/LICENSE).
- `Inter.txt`: [Inter](https://github.com/rsms/inter/blob/master/LICENSE.txt), bundled by VitePress as WOFF2 fonts.
- `BoringSSL-817ab07.txt`: [BoringSSL revision 817ab07](https://raw.githubusercontent.com/google/boringssl/817ab07ebb53da35afea409ab9328f578492832d/LICENSE), vendored by `swift-nio-ssl` 2.37.5. Includes its OpenSSL, SSLeay, ISC and fiat-crypto MIT terms.

`script/licenses.mjs` reads other licenses from the installed dependencies. Review
these copies when upgrading DocSearch, VitePress or `swift-nio-ssl`; builds do not
download licenses. App packaging stops if the vendored BoringSSL revision no longer
matches this copy.
