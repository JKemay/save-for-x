import http from "node:http";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs";

const execFileAsync = promisify(execFile);
const port = Number(process.env.PORT || 8787);
const host = process.env.HOST || "0.0.0.0";
const maxBodyBytes = 16 * 1024;
// yt-dlp will sit on an unresponsive host indefinitely; without a ceiling a
// few such requests pile up child processes that never exit.
const resolveTimeoutMs = Number(process.env.RESOLVE_TIMEOUT_MS || 30_000);

// X only serves the media for gated posts (sensitive/age-restricted) to a
// signed-in session; an anonymous yt-dlp request gets the video stripped and
// looks exactly like "no video found". This lets the operator optionally
// hand yt-dlp their own X session so those posts resolve too. It's off by
// default, and the iOS app never supplies or even knows about credentials
// (see AGENTS.md — the client stays credential-free). A cookies file (or a
// browser's cookie store) is a live credential for that X account: keeping
// one on a LAN/Tailscale-only resolver is reasonable, but it must never be
// deployed to a resolver reachable from the public internet — anyone who can
// reach the service, or read the file, can act as that account.
const allowedCookieBrowsers = ["safari", "chrome", "chromium", "firefox", "edge", "brave", "opera", "vivaldi"];
let cookieArgs = [];
let cookieAuthDescription = "disabled";

if (process.env.X_COOKIES_FILE) {
  const cookiesFile = process.env.X_COOKIES_FILE;
  try {
    fs.accessSync(cookiesFile, fs.constants.R_OK);
  } catch {
    console.error(`X_COOKIES_FILE points at a path that does not exist or is not readable: ${cookiesFile}`);
    process.exit(1);
  }
  if (process.env.X_COOKIES_FROM_BROWSER) {
    console.log("Both X_COOKIES_FILE and X_COOKIES_FROM_BROWSER are set; X_COOKIES_FILE takes precedence.");
  }
  cookieArgs = ["--cookies", cookiesFile];
  cookieAuthDescription = "cookies file";
} else if (process.env.X_COOKIES_FROM_BROWSER) {
  const browser = process.env.X_COOKIES_FROM_BROWSER.toLowerCase();
  if (!allowedCookieBrowsers.includes(browser)) {
    console.error(
      `X_COOKIES_FROM_BROWSER must be one of: ${allowedCookieBrowsers.join(", ")} (got "${process.env.X_COOKIES_FROM_BROWSER}")`
    );
    process.exit(1);
  }
  cookieArgs = ["--cookies-from-browser", browser];
  cookieAuthDescription = `browser cookies (${browser})`;
}

console.log(`Cookie auth: ${cookieAuthDescription}`);

/** A client sent something malformed — distinct from the resolver failing. */
class BadRequest extends Error {}

/**
 * The request itself was fine and the post may well exist, but yt-dlp still
 * couldn't produce a video from it — most commonly because the post is
 * gated behind a signed-in X session the resolver doesn't have, or because
 * the post itself is gone/suspended/protected. Distinct from a resolver-side
 * failure: retrying an Unresolvable post won't help without credentials.
 */
class Unresolvable extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const badRequestMessages = {
  invalid_json: "That request wasn't valid JSON.",
  invalid_x_url: "Enter a public x.com or twitter.com post link, like https://x.com/user/status/123."
};

function json(response, status, body) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*"
  });
  response.end(JSON.stringify(body));
}

function isAllowedXURL(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:") return false;
    if (!["x.com", "www.x.com", "twitter.com", "www.twitter.com"]
      .includes(url.hostname.toLowerCase())) return false;
    // Require an actual post. A bare profile or homepage URL used to pass here
    // and then spend a full yt-dlp invocation only to fail.
    return /^\/[^/]+\/status\/\d+/.test(url.pathname);
  } catch {
    return false;
  }
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.on("data", (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body) > maxBodyBytes) {
        reject(new Error("request too large"));
        request.destroy();
      }
    });
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });
}

async function resolveVideo(postURL) {
  // yt-dlp must be installed on the resolver host. The single-file format
  // keeps the first client version simple: the phone receives one MP4 URL.
  let stdout;
  try {
    ({ stdout } = await execFileAsync("yt-dlp", [
      "--no-playlist",
      "--no-warnings",
      "--get-url",
      "--format", "b[ext=mp4]/b",
      ...cookieArgs,
      postURL
    ], { maxBuffer: 512 * 1024, timeout: resolveTimeoutMs, killSignal: "SIGKILL" }));
  } catch (error) {
    const stderr = error.stderr || "";

    if (/No video could be found|Video #\d+ is unavailable|No video could be found in this tweet/i.test(stderr)) {
      throw new Unresolvable("no_video", "No video in this post, or it needs a signed-in X account.");
    }

    if (/not found|has been suspended|protected|does not exist|Unable to extract/i.test(stderr)) {
      throw new Unresolvable("post_unavailable", "That post is unavailable.");
    }

    if (error.killed === true || error.signal) {
      const timeoutError = new Error("The resolver timed out on that post.");
      timeoutError.code = "resolve_timeout";
      throw timeoutError;
    }

    if (/rate limit|429|Too Many Requests/i.test(stderr)) {
      const rateLimitedError = new Error("X is rate limiting requests right now. Try again shortly.");
      rateLimitedError.code = "upstream_rate_limited";
      throw rateLimitedError;
    }

    throw error;
  }

  const downloadURL = stdout.trim().split("\n")[0];
  if (!downloadURL || !downloadURL.startsWith("https://")) {
    throw new Unresolvable("no_video", "No video in this post, or it needs a signed-in X account.");
  }

  const post = new URL(postURL);
  const statusID = post.pathname.match(/status\/(\d+)/)?.[1] || "video";
  return {
    download_url: downloadURL,
    filename: `x-${statusID}.mp4`
  };
}

const server = http.createServer(async (request, response) => {
  if (request.method === "OPTIONS") {
    response.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "POST, OPTIONS",
      "access-control-allow-headers": "content-type"
    });
    response.end();
    return;
  }

  if (request.method === "GET" && request.url === "/health") {
    json(response, 200, { ok: true });
    return;
  }

  if (request.method !== "POST" || request.url !== "/v1/resolve") {
    json(response, 404, { error: "not_found", message: "No such endpoint." });
    return;
  }

  try {
    let body;
    try {
      body = JSON.parse(await readBody(request));
    } catch {
      throw new BadRequest("invalid_json");
    }
    if (body === null || typeof body !== "object") {
      throw new BadRequest("invalid_json");
    }
    if (!isAllowedXURL(body.url)) {
      throw new BadRequest("invalid_x_url");
    }

    const result = await resolveVideo(body.url);
    json(response, 200, result);
  } catch (error) {
    // A bad request is the caller's fault; reporting it as 502 told the phone
    // the resolver was broken and invited a pointless retry.
    if (error instanceof BadRequest) {
      json(response, 400, {
        error: error.message,
        message: badRequestMessages[error.message] || "That request was invalid."
      });
      return;
    }

    // Logged since this was how gated-post and rate-limit failures were
    // originally diagnosed — but never log cookie paths or cookie contents.
    console.error(error.message);

    if (error instanceof Unresolvable) {
      json(response, 422, { error: error.code, message: error.message });
      return;
    }

    if (error.code === "resolve_timeout") {
      json(response, 502, { error: "resolve_timeout", message: error.message });
      return;
    }

    if (error.code === "upstream_rate_limited") {
      json(response, 502, { error: "upstream_rate_limited", message: error.message });
      return;
    }

    json(response, 502, { error: "resolver_failed", message: "The resolver couldn't process that post right now." });
  }
});

server.listen(port, host, () => {
  console.log(`Save for X resolver listening on http://${host}:${port}`);
});
