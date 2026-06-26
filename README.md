# Claude Bar

A dead-simple macOS menu bar app showing Claude Code rate limits as two tiny
horizontal bars under a small "Claude" label, battery-style: Session (5h) on
top, Weekly (7d) below. Green under 70%, orange from 70%, red from 90%. Click for the signed-in
account, exact percentages, reset times, and a manual refresh.

![Claude Bar in the macOS menu bar](docs/topbar.png)

## How it works

It reads your usage from the same first-party endpoint Claude Code itself uses
— `GET https://api.anthropic.com/api/oauth/usage` — with the OAuth token from
your login keychain. This is exactly what the `/usage` screen and the
VSCode/Cursor Claude extension's own usage display call; the app just draws it
as two bars. No transcript parsing, no estimates: these are the real numbers.

Because the data lives only on Anthropic's servers (nothing local caches it),
the app fetches it directly. It works no matter how you use Claude Code —
terminal, VSCode, or Cursor.

### First launch

macOS will ask once for permission to read the `Claude Code-credentials`
keychain item. Click **Always Allow** and it won't ask again. You must have
logged into Claude Code at least once.

## Notifications

Claude Bar can tell you when you're getting close to a limit so you don't have
to keep opening the menu. It posts a local notification the first time a window
(Session or Weekly) crosses **70% / 90% / 100%** on the way up, and once more
when that window resets back to zero. It remembers the highest level it already
announced for each window, so a meter parked at 72% won't re-notify on every
poll — only a real new crossing speaks up. Toggle it from **Notify Near Limits**
in the menu (on by default); macOS asks for notification permission once.

## Switching accounts

Have more than one Claude login (personal, work, a second Max seat)? The
**Accounts** submenu saves and swaps between them:

- **Save Current Account As…** snapshots the active login — the OAuth blob from
  the keychain plus the `oauthAccount`/`userID` identity from `~/.claude.json` —
  under a name you choose. Profiles are stored in the keychain (one item per
  name under service `ClaudeBar-account`), so refresh tokens never hit disk in
  the clear.
- **Click a saved account** to make it active: Claude Bar rewrites the live
  `Claude Code-credentials` keychain item and patches `~/.claude.json` in one
  go. The meter re-reads the new account on its next poll.
- **Hold ⌥** over a saved account to turn the row into **Remove**.

What this can and can't do: any `claude` session you start *after* switching uses
the new account immediately. Sessions **already running keep the token they
cached in memory** — Claude Code reads credentials at startup and doesn't re-read
the keychain mid-session, so a live process won't switch out from under itself.
To move a running session to the new account, restart it (or run `/login` inside
it). There is no supported way to hot-swap the login of a process that's already
running.

## Good citizen

Refreshing is deliberately lazy and power-friendly:

- Polls every ~3 minutes while the Mac is awake, via a run-loop timer. It
  **never wakes a sleeping Mac** (user-space timers fire on the next wake) and
  doesn't keep it awake either — it only opts out of App Nap so the timer isn't
  throttled in the background.
- Immediate refresh on launch, on wake-from-sleep, and when you open the menu
  (throttled to one network call per ~45s).
- No tight loops; idle CPU is effectively zero between polls. Zero
  dependencies, ~350 lines of Swift.
- Read-only: it only ever reads your usage, never makes inference calls.

## Build & install

```sh
make run        # build dist/ClaudeBar.app and launch it
make install    # copy the app to ~/Applications
make preview    # render icon samples to /tmp/claudebar-preview.png
```

Use "Start at Login" in the app's menu to keep it around.

### Code signing (optional, recommended)

By default the app is ad-hoc signed, so its code identity changes on every
build — which means macOS re-prompts for keychain access (the Claude Code
token) each time you rebuild. Sign with a **stable identity** and the "Always
Allow" grant persists across rebuilds. Create an untracked `local.mk`:

```makefile
# 40-char hash from: security find-identity -p codesigning -v
CODESIGN_IDENTITY = XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

Any Apple Development cert works, or a self-signed "Code Signing" certificate
made in Keychain Access. `local.mk` is gitignored, so your identity stays off
the repo.

## A note on the endpoint

`api/oauth/usage` is first-party (it's what Claude Code's own `/usage` uses)
but not part of the public API reference, so field names could change.
Separately, Anthropic's Feb 2026 ToS update frames third-party use of the
consumer OAuth token as non-compliant; enforcement targets *inference* through
non-official clients, not read-only usage checks like this one. It's your own
account, your own token, read-only — but worth knowing.

## Development

- `ClaudeBar --preview <out.png>` renders icon samples and exits.

## License

[MIT](LICENSE)
