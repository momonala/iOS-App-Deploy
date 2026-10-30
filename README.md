# iOS-App-Deploy

Shows up as "iOS App Deploy". A menu bar app that keeps Trace and Urban Sports Club running on my iPhone. Without a paid developer account, Xcode signs apps with a free provisioning profile that expires after 7 days. It notices when one is getting close and rebuilds and reinstalls the app over Wi-Fi, with nothing for me to do.

It also owns the shared deploy script that both app repos call.

## Layout

```
config.json              phone UDID, redeploy threshold, the apps
scripts/deploy-ios.sh    build + install one app; Trace and USC's scripts/deploy.sh are wrappers around it
Sources/RedeployCore     pure logic: config, profile parsing, the schedule rules, script output parsing
Sources/Redeploy         the SwiftUI menu bar app
Resources/AppIcon.png    source for the .icns
build.sh                 build, sign, install to ~/Applications, relaunch
```

## Build and run

```bash
./build.sh         # release build, signs with the Apple Development identity, installs and relaunches
swift test         # RedeployCore tests
```

The first launch asks for notification permission and registers a login item. Both stick across rebuilds only because `build.sh` signs with a stable identity. Ad-hoc signing gives every build a new identity, so macOS forgets both.

## When it deploys

- **Triggers:** app launch, wake from sleep, screen unlock, an hourly timer, and the refresh button. **Deploy All** skips the threshold and redeploys every app. Wake and unlock wait a few seconds first so Wi-Fi can reconnect.
- **Once a day:** automatic triggers are skipped once a check has *succeeded* today. A failed check doesn't count, so the next unlock or the next hour tries again. The refresh button ignores this.
- **Threshold:** an app redeploys when its profile has `thresholdDays` (in `config.json`) or fewer days left. The threshold is also the longest stretch without opening the Mac that I can survive.
- **One at a time,** always with `--no-launch`, so the app never pops open on the phone.

## Where the expiry date comes from

After every successful install, `deploy-ios.sh` copies the built app's `embedded.mobileprovision` and writes a small JSON record (commit and its subject line, branch, version, build, duration) to `~/Library/Application Support/Redeploy/installed/<bundle id>.*`. That's what's actually on the phone, and terminal deploys write it too. The version next to each app name comes from this record.

The script sets the build number (`CFBundleVersion`) to the repo's commit count, so a build maps back to a commit. Builds run straight from Xcode keep the project's value, 1.

Xcode's profile folder can't be used for this: each deploy's `cert-exp clear` wipes it, so it only ever holds the last-deployed app's profile.

The phone's own profile list (`pymobiledevice3 provision list`) is the second source. The app uses whichever expires later, so a deploy straight from Xcode counts too, and a phone reading from before the last deploy doesn't drag the date back. iOS keeps superseded profiles until they expire, so only the newest per bundle ID counts. App extensions (Trace's widget) have their own profiles and show nested under the app.

## Phone details

Click the phone row to expand it. Most fields come from `devicectl`, which reaches the phone over Wi-Fi whenever a deploy could:
model, iOS build, lock state, Developer Mode, connection, storage, serial, UDID and ECID.

Battery charge, health (full-charge capacity over design capacity), cycle count and temperature come from
`pymobiledevice3 diagnostics battery single` (`uv tool install pymobiledevice3`), as do the installed profiles. That goes through usbmux, which only sees
the phone over Wi-Fi while "Show this iPhone when on Wi-Fi" is ticked in Finder, and even then only some of the time
(reliably while it charges). So the last good reading is saved in `state.json` and shown with its time. Every check and
every expand tries again.

## Crash reports

Each app's detail shows its crash reports on the phone: how many, the newest, and whether it came after the last deploy
(orange). They're listed with `devicectl device info files --domain-type systemCrashLogs`, so this works whenever a deploy
could. Reports are matched by executable name (`<executable>-<date>.ips`), which covers the app's extensions and leaves out
resource reports like `Trace.cpu_resource-…`. iOS keeps them for weeks, so the count isn't "since the last deploy".

Open Latest Crash copies the newest report to `~/Library/Logs/Redeploy/Crashes/` once and opens it in Console.

## Notifications

- A deploy succeeded.
- A deploy failed, or the phone wasn't reachable when a deploy was due. Sent once per run of failures; a success resets it.
- A profile is under 24 hours from expiring. Sent once per profile.

`cert-exp` still adds a Google Calendar event after each deploy. That's the backup reminder if this app itself stops running.

## Files

| Path | What |
|------|------|
| `~/Library/Application Support/Redeploy/state.json` | last check, last success, per-app failure state, last phone readings |
| `~/Library/Application Support/Redeploy/installed/` | install records, written by the script |
| `~/Library/Logs/Redeploy/<app>-<time>.log` | script output plus full xcodebuild output, last 10 per app |
| `~/Library/Logs/Redeploy/Crashes/` | crash reports copied off the phone |

## Gotchas

- **It runs inside the GUI session on purpose.** Code signing needs the login keychain, which is only unlocked there. Over SSH the script refuses to run (`REDEPLOY_ALLOW_SSH=1` overrides).
- **The PATH is set by the app.** A GUI app starts with launchd's bare PATH, so `ProcessRunner` adds `~/.local/bin` (uv, for cert-exp) and Homebrew.
- **Pinned phone.** Without `-d`, the script only targets the UDID in `config.json` and fails if that phone isn't reachable. For a new phone, update the UDID (`xcrun devicectl list devices`).
- **The build targets `generic/platform=iOS`, not `id=<udid>`.** The `id=` form waits on device preparation and times out against a locked phone, even when the install would have worked.
- **Install retries 3 times,** because the Wi-Fi tunnel to the phone drops often enough that one failure means nothing.
- **A broken build fails the deploy.** The script builds whatever is checked out in each repo, so leaving one mid-change means that day's redeploy fails until it compiles.
