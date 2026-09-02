import http from "node:http";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const port = Number(process.env.PORT || 8787);
const host = process.env.HOST || "0.0.0.0";
const maxBodyBytes = 16 * 1024;
// yt-dlp will sit on an unresponsive host indefinitely; without a ceiling a
// few such requests pile up child processes that never exit.
const resolveTimeoutMs = Number(process.env.RESOLVE_TIMEOUT_MS || 30_000);

/** A client sent something malformed — distinct from the resolver failing. */
class BadRequest extends Error {}

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
  const { stdout } = await execFileAsync("yt-dlp", [
    "--no-playlist",
    "--no-warnings",
    "--get-url",
    "--format", "b[ext=mp4]/b",
    postURL
  ], { maxBuffer: 512 * 1024, timeout: resolveTimeoutMs, killSignal: "SIGKILL" });

  const downloadURL = stdout.trim().split("\n")[0];
  if (!downloadURL || !downloadURL.startsWith("https://")) {
    throw new Error("no downloadable MP4 was found");
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
    json(response, 404, { error: "not_found" });
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
      json(response, 400, { error: error.message });
      return;
    }
    console.error(error.message);
    json(response, 502, { error: "resolver_failed" });
  }
});

server.listen(port, host, () => {
  console.log(`Save for X resolver listening on http://${host}:${port}`);
});
