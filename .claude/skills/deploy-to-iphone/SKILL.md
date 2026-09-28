---
name: deploy-to-iphone
description: Build, sign, and install Save for X onto the paired iPhone, refreshing the 7-day provisioning profile. Use when the app or its share-sheet entry says "Save for X is no longer available", when launching fails with "invalid code signature", or on the weekly profile refresh.
---

# Deploy Save for X to the iPhone

## When you need this

The signing team (`HJ7M4JPHB3`, set in `project.yml`) is a **free/personal
Apple account**, so provisioning profiles last **7 days**. When one lapses:

- Tapping **Save for X** in the X share sheet says *"Save for X is no longer available."*
- The app icon does nothing, or shows an untrusted-developer alert.
- `devicectl ... process launch` fails with:
  `Unable to launch com.saveforx.app because it has an invalid code signature,
  inadequate entitlements or its profile has not been explicitly trusted by the user.`

None of that means the code or the resolver is broken. The profile just expired.
Rebuilding re-mints it for another 7 days.

The signing **certificate** is separate and valid until **Aug 2027** — don't go
chasing the cert when the profile is the thing that died.

## Steps

### 1. Find the paired device

```sh
xcrun devicectl list devices
```

Known device: `Janti's iPhone` — `46D30715-72F8-5C04-BDC2-3BED7A63B872`.
Grab the identifier dynamically so a re-pair doesn't break this:

```sh
DEV=$(xcrun devicectl list devices 2>/dev/null | grep -i iphone \
  | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
echo "$DEV"
```

### 2. Regenerate the project

`project.pbxproj` is generated. Never hand-edit it.

```sh
xcodegen generate
```

`project.yml` carries `DEVELOPMENT_TEAM: HJ7M4JPHB3` specifically so regenerating
preserves device signing — if a device build suddenly can't sign, check that key
survived.

### 3. Build with provisioning updates

`-allowProvisioningUpdates` is the flag that issues the fresh profile. Without it
the build fails on the expired one.

```sh
xcodebuild -project SaveForX.xcodeproj -scheme SaveForX \
  -destination "id=$DEV" \
  -configuration Debug -derivedDataPath .derivedData \
  -allowProvisioningUpdates build 2>&1 | xcbeautify | tail -30
```

Expect `Build Succeeded` plus `Signing SaveForX.app` and `Signing SaveForXShare.appex`.
The `All interface orientations must be supported` warning is pre-existing; ignore it.

### 4. Confirm the new profile window

```sh
security cms -D -i .derivedData/Build/Products/Debug-iphoneos/SaveForX.app/embedded.mobileprovision > /tmp/pp.plist
/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' /tmp/pp.plist
```

Should be ~7 days out. **Note that date — this breaks again when it passes.**

### 5. Install and launch

```sh
xcrun devicectl device install app --device "$DEV" \
  .derivedData/Build/Products/Debug-iphoneos/SaveForX.app

xcrun devicectl device process launch --device "$DEV" com.saveforx.app
```

`Launched application with com.saveforx.app bundle identifier.` means it worked.
Anything mentioning `Security` / `RequestDenied` means signing still failed — do
not report success.

An install over the same bundle ID **preserves the data container**, so the
resolver endpoint and download queue survive.

## Then check the resolver endpoint

The endpoint lives in each install's own `UserDefaults`, so the phone and the
simulator hold separate values, and the default is a dead placeholder
(`https://resolver.saveforx.example/v1/resolve`, `DownloadManager.swift:137`).

On the phone, the **Resolver endpoint** field needs the Mac's **current** LAN IP:

```sh
ipconfig getifaddr en0    # was 192.168.4.27 — DHCP, so re-check it
```

→ `http://<mac-lan-ip>:8787/v1/resolve`

Plain HTTP to the LAN is allowed: `project.yml` sets
`NSAppTransportSecurity.NSAllowsLocalNetworking: true`. Both devices must be on
the same Wi-Fi.

Verify the resolver is up and reachable before blaming the app:

```sh
ps aux | grep -v grep | grep resolver/server.js     # is it running?
curl -s -m 5 http://$(ipconfig getifaddr en0):8787/health   # → {"ok":true}
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
```

Start it if needed: `cd resolver && npm start` (needs `yt-dlp` on the Mac).
Logs: `~/Library/Logs/saveforx-resolver.log`.

## Simulator instead of the phone

No signing needed, so no expiry problem:

```sh
xcrun simctl boot 4CCF2D10-920E-4484-9C9D-0313EDA5A598   # iPhone 17 Pro
open -a Simulator
xcodebuild -project SaveForX.xcodeproj -scheme SaveForX \
  -destination 'id=4CCF2D10-920E-4484-9C9D-0313EDA5A598' \
  -configuration Debug -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | xcbeautify | tail -20
xcrun simctl install booted .derivedData/Build/Products/Debug-iphonesimulator/SaveForX.app
xcrun simctl launch booted com.saveforx.app
xcrun simctl io booted screenshot /tmp/saveforx.png
```

The simulator reaches the resolver at `http://127.0.0.1:8787/v1/resolve`. It
cannot test the real share-sheet flow — there's no X app — so device testing
stays required for that.

## Permanent fix

A paid Apple Developer account ($99/yr) issues 1-year profiles and retires this
skill's main reason for existing.
