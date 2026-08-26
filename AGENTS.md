# Save for X agent guide

## Project goal

Save for X is an iPhone-first app that receives a public X post URL through the iOS Share Sheet, asks a resolver service for a downloadable video URL, and saves the result to Photos.

## Repository map

- `SaveForX/` — SwiftUI host app and download/Photos flow
- `SaveForXShare/` — iOS Share Extension that receives X links
- `resolver/` — small Node.js resolver service
- `project.yml` — XcodeGen source of truth for the Xcode project
- `SaveForX.xcodeproj/` — generated project; regenerate it instead of hand-editing the project file

## Collaboration rules

1. Start with `git status --short --branch` and inspect the relevant diff before editing.
2. Preserve existing user or agent changes. Do not reset, checkout, or overwrite unrelated work.
3. Keep changes focused. One agent should own a feature or file set at a time.
4. Use a `codex/<short-description>` branch for isolated feature work when multiple agents are active.
5. Do not commit secrets, Xcode signing certificates, provisioning profiles, downloaded media, or resolver credentials.
6. Change `project.yml` for project configuration, then run `xcodegen generate`; do not hand-edit `project.pbxproj`.
7. Keep the iOS client independent of X credentials. Never add password or session-cookie collection.
8. Resolver changes must accept only supported public X URLs, avoid permanent media storage, and include sensible abuse/rate-limit controls before deployment.

## Verification

For a local iPhoneOS build, use a workspace-local derived-data directory:

```sh
xcodegen generate
xcodebuild -project SaveForX.xcodeproj -scheme SaveForX -sdk iphoneos -configuration Debug -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build
```

For resolver syntax validation:

```sh
node --check resolver/server.js
```

Physical-device testing is required for the complete Share Sheet flow. The iOS Simulator can verify the host app UI but does not provide the real X app.

## Handoff notes

When handing work to another agent, report:

- What changed
- Files touched
- Tests or build commands run
- Known blockers or follow-up work
