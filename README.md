<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Headroom icon: three nested rings">
</p>

<h1 align="center">Headroom</h1>

<p align="center">
  Your Claude, ChatGPT and Cursor usage limits in the macOS menu bar.<br>
  Free and open source.
</p>

<p align="center">
  <a href="https://github.com/itsfoxyy/headroom/releases/latest"><b>Download the latest version</b></a>
</p>

---

Subscriptions to AI tools come with rolling limits: Claude's 5-hour session
and weekly limits, ChatGPT's Codex 5-hour and weekly windows, Cursor's weekly
pool or monthly allowance. Headroom keeps all of them one glance away, so you
can plan heavy work instead of running into a wall.

## Features

- **One ring per service** in the menu bar, plus the limit that's closest to
  running out. Past 80% it names the service; at 100% it counts down to the reset.
- **Two layouts:** Compact (one row per service, weekly limit underneath) or
  Standard (every limit listed).
- **Global shortcut** (⌥⌘U by default) shows a quick peek from any app, even
  when the menu bar icon is hidden by a menu bar manager or the notch.
- **Alerts** at 80% and 95% of any limit.
- **Usage history:** 24-hour and 7-day charts for every limit, kept on your Mac.
- **Automatic updates,** so fixes arrive as soon as a service changes something.
- **Supports both Cursor plan types:** the new weekly plan and legacy monthly plans.
- Launch at login, light and dark mode, no Dock icon.

## Install

1. Download `Headroom-x.y.z.zip` from the [latest release](https://github.com/itsfoxyy/headroom/releases/latest) and unzip it.
2. Move **Headroom.app** to your **Applications** folder.
3. Open it. If macOS says it can't verify the developer, open
   **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.
   You only need to do this once.
4. Click the rings in the menu bar, then **Settings… › Services** to sign in.

Requires macOS 13 Ventura or later.

### Signing in

Each service signs in through its own website, in a small window inside
Headroom. **Passkeys and some Google sign-ins don't work in that window**; use
email sign-in instead. For Claude you can also paste your `sessionKey` cookie
under Settings › Services.

## Privacy

- **Everything stays on your Mac.** Sign-ins are kept in Headroom's own web
  storage (`~/Library/WebKit/io.github.itsfoxyy.headroom`). An optional Claude
  session key is kept in your Keychain.
- **Headroom only talks to claude.ai, chatgpt.com and cursor.com**, making the
  same requests their own usage pages make. Each service's sign-in is only
  ever sent to that service. The only other request is the daily update check
  to this GitHub repository, which sends nothing about you.
- **Usage history** is kept for 7 days in
  `~/Library/Application Support/Headroom/history.json`. Clear it in Settings › General.
- **No servers, analytics, tracking or crash reporting.** The code is all here
  to check.
- Like browser cookies, the stored sign-ins are protected by your macOS user
  account and FileVault, not by a separate password. Sign out of a service
  under Settings › Services to remove its sign-in from Headroom.

## Good to know

- Headroom is **not affiliated with Anthropic, OpenAI or Anysphere (Cursor)**.
- None of these services offers an official usage API for subscriptions.
  Headroom reads the same data their websites use, which can change without
  notice and break a service until Headroom is updated. Each service's terms
  of use apply to your account; use Headroom at your own discretion.
- Cursor's prepaid credit balance isn't shown: it's only available on grok.com
  behind security an app can't use.

## Troubleshooting

- **The icon disappears when Hidden Bar (or a similar app) is collapsed:**
  quit and reopen the menu bar manager so it picks Headroom up again.
- **A service shows "Sign-in expired":** Settings › Services › Sign in again.
- **Numbers look wrong:** please [open an issue](https://github.com/itsfoxyy/headroom/issues)
  with what the service's own usage page shows.

## Build from source

Needs Apple's command line tools (`xcode-select --install`).

```bash
git clone https://github.com/itsfoxyy/headroom.git
cd headroom
./build.sh
```

This compiles the app, installs it in `/Applications` and starts it. Run it
again after any change. `./build.sh --release` makes a zip in `dist/` instead.

| File | What it does |
| --- | --- |
| `Sources/Headroom/Providers/` | One file per service: where its numbers come from |
| `Sources/Headroom/UsageStore.swift` | Refreshing and alerts |
| `Sources/Headroom/StatusItemController.swift` | Menu bar label, dropdown and quick peek windows |
| `Sources/Headroom/Views/` | Dropdown layouts, quick peek, Settings |
| `Sources/Headroom/HotKey.swift` | The global shortcut |
| `Sources/Headroom/UsageHistory.swift` | Saved usage history |
| `Sources/Headroom/Updater.swift` | Automatic updates (Sparkle) |
| `Scripts/make_icon.swift` | Draws the app icon at build time |

If a service stops working, the fix is almost always in its provider file.
Contributions are welcome.

## Releasing (for maintainers)

Push a version tag and GitHub builds the app and publishes a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

**Automatic updates** need a signing key, set up once with
`Scripts/setup_updates.sh`. It keeps the private key in your Keychain, writes
the public key to `Sparkle/public_ed_key` (commit it) and copies the private key
for the `SPARKLE_PRIVATE_KEY` repository secret. Each release then includes a
signed `appcast.xml` that installed copies check daily.

Releases are signed with a local signature unless these repository secrets
are set, in which case they're signed with a Developer ID and notarized by
Apple so they open without any warning:
`DEVELOPER_ID_P12` (base64 of the exported certificate), `DEVELOPER_ID_P12_PASSWORD`,
`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.

## License

[MIT](LICENSE)
