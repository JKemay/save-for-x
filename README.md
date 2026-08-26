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

The resolver should only handle public media that the user is authorized to save. It should not collect X passwords, private session cookies, or permanently retain downloaded media.
