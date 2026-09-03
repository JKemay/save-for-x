# Save for X

An iPhone-first MVP for receiving a public X post link from the iOS Share Sheet and saving the resolved video to Photos.

## Current flow

1. Open an X post.
2. Tap Share and choose **Save for X**.
3. The Share Extension validates the link and opens the host app.
4. The host app asks the resolver service for a downloadable video URL.
5. The app downloads the file and saves it to Photos.

## Project setup

This repository uses XcodeGen. Generate the Xcode project with:

```sh
xcodegen generate
```

Then open `SaveForX.xcodeproj` in Xcode.

The app lets you configure the resolver URL on its main screen. For local testing, run the resolver below and use your Mac's LAN IP in the app, for example `http://192.168.1.10:8787/v1/resolve`.

## Local resolver

The included Node service requires `yt-dlp` on the machine running it:

```sh
cd resolver
npm start
```

It exposes `GET /health` and `POST /v1/resolve`. The service accepts only HTTPS links on X/Twitter hosts and returns a single downloadable MP4 URL. For a production deployment, add authentication, rate limiting, HTTPS, logging controls, and a maintained media-resolution strategy.

## Resolver API contract

The app currently posts to the placeholder endpoint in `SaveForX/DownloadManager.swift`:

```http
POST /v1/resolve
Content-Type: application/json

{"url":"https://x.com/example/status/123"}
```

Expected success response:

```json
{
  "download_url": "https://cdn.example/video.mp4",
  "filename": "example_123.mp4"
}
```

On failure the resolver returns a JSON body with a stable machine-readable `error` code and a `message` sentence that's safe to show a user:

```json
{
  "error": "no_video",
  "message": "No video in this post, or it needs a signed-in X account."
}
```

| Status | `error`                | Meaning |
| ------ | ---------------------- | ------- |
| 400    | `invalid_json`         | The request body wasn't valid JSON. |
| 400    | `invalid_x_url`        | Not a public `x.com`/`twitter.com` post link (e.g. a profile URL). |
| 422    | `no_video`             | The post has no video yt-dlp could see — often gated/sensitive content that needs a signed-in X session. Retrying won't help. |
| 422    | `post_unavailable`     | The post is gone, suspended, or protected. Retrying won't help. |
| 502    | `resolve_timeout`      | yt-dlp didn't finish before the resolver's timeout. |
| 502    | `upstream_rate_limited`| X is rate-limiting the resolver. |
| 502    | `resolver_failed`      | Some other resolver-side failure. |

A 422 means the request was fine and the post just can't be resolved — the client should show the message rather than retry. A 502/504 means the resolver itself had trouble and a retry may succeed.

The resolver should only handle public media that the user is authorized to save. It should not collect X passwords, private session cookies, or permanently retain downloaded media. The iOS app itself never collects or sends X credentials.

### Optional: authenticated resolution

X only serves the video for gated posts (sensitive/age-restricted content) to a signed-in session. Run anonymously, the resolver gets the media stripped out and reports `no_video` for every one of those links, even though nothing is actually broken. If you want those posts to resolve, you can point the resolver at your own X session — this is entirely opt-in and off by default:

- `X_COOKIES_FILE` — path to a Netscape-format `cookies.txt` exported from a logged-in browser session. Passed to yt-dlp as `--cookies <path>`.
- `X_COOKIES_FROM_BROWSER` — the name of a browser yt-dlp should pull cookies from directly (`safari`, `chrome`, `chromium`, `firefox`, `edge`, `brave`, `opera`, or `vivaldi`). Passed to yt-dlp as `--cookies-from-browser <value>`.

If both are set, `X_COOKIES_FILE` wins. If `X_COOKIES_FROM_BROWSER` is set to anything outside that list, or `X_COOKIES_FILE` points at a path that doesn't exist or can't be read, the resolver refuses to start rather than silently ignoring it. On startup it logs one line saying whether cookie auth is active and how — never the file's path contents or any cookie values.

Using your personal session cookies with an automated tool is against X's terms of service and risks the account (up to a suspension), so use a throwaway/secondary X account for this, not your main one. A cookies file (or a browser's cookie store) is a live credential for that account: it's reasonable to keep on a resolver that's only reachable over your LAN or a private network like Tailscale, but it must never be deployed to a resolver reachable from the public internet.
