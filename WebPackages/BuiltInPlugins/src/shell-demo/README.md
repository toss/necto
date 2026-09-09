# Shell Demo

A desktop plugin for exercising Necto's shell policy without connecting an app.

## Install

```bash
yarn workspace @necto-plugin/shell-demo build
```

In Necto, open **Settings → Desktop Plugins → Choose…** and select:

```text
WebPackages/BuiltInPlugins/Plugins/shell-demo
```

Approve the two declared bridges during installation.

## Verify

1. Keep **Settings → Shell Access → Shell Demo** in Protected mode.
2. Open Shell Demo and choose **Run command**. It must return `PERMISSION_DENIED`.
3. Choose **Request approval**, then approve the native Necto dialog.
4. Run the command again. It must return `Hello from Necto Shell Demo` and `exitCode` 0.
5. Choose **Try unapproved command**. It must return `PERMISSION_DENIED` because the exact command differs.
6. Add or remove the command in **Settings → Shell Access → Shell Demo** and repeat.
7. Return to Protected mode, choose **Request Full Access**, and approve the stronger warning.
8. Confirm **Settings → Shell Access → Shell Demo** now says Full access and both run buttons succeed.

Full Access intentionally makes both run buttons succeed.
