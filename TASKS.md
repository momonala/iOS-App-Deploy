# iOS-App-Deploy build

- [x] config.json (device UDID, threshold, apps)
- [x] scripts/deploy-ios.sh: shared deploy script (from Trace's jq version), default device, installed record
- [x] Trace + USC deploy.sh -> thin wrappers; README updates
- [x] cert-exp: remove Telegram (code, deps, env, README)
- [x] Swift package: RedeployCore + tests
- [x] Swift app: model, runner, device probe, notifications, triggers, UI
- [x] build.sh: bundle, sign, install to ~/Applications, launch
- [x] verify: swift test, build, app-driven deploy of both apps, unreachable-phone path
- [x] phone details + battery
- [x] crash reports (devicectl) + installed profiles (pymobiledevice3), effective expiry = later of the two
- [x] Trace: fix 0x8BADF00D termination deadlock in LocationManager.handleAppTermination
- [x] Trace: keep background audio alive (mixWithOthers, interruption handling)
- [x] versioning: Trace 1.0.1, USC 1.0.0, build number = commit count, version shown from install record
- [x] rename directory Redeploy -> iOS-App-Deploy
- [ ] user: verify Trace fixes (podcast + lock 5 min, swipe-kill, crash count unchanged)
- [ ] user: eyeball the popover, allow notifications, commit
