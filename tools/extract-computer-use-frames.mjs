#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

function usage() {
  console.error(
    "usage: extract-computer-use-frames.mjs --out <dir> [--session <jsonl>] [--app <text>] [--limit <n>]"
  );
  process.exit(2);
}

function redactHome(value) {
  return String(value).replaceAll(os.homedir(), "$HOME");
}

function parseArgs(argv) {
  const options = { limit: Infinity };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === "--out" && next) {
      options.out = next;
      i += 1;
    } else if (arg === "--session" && next) {
      options.session = next;
      i += 1;
    } else if (arg === "--app" && next) {
      options.app = next.toLowerCase();
      i += 1;
    } else if (arg === "--limit" && next) {
      options.limit = Number.parseInt(next, 10);
      i += 1;
    } else {
      usage();
    }
  }
  if (!options.out || !Number.isFinite(options.limit) && options.limit !== Infinity) {
    usage();
  }
  return options;
}

function newestSessionFile() {
  const root = path.join(os.homedir(), ".codex", "sessions");
  const files = [];
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(fullPath);
      } else if (entry.name.endsWith(".jsonl")) {
        files.push(fullPath);
      }
    }
  }
  walk(root);
  files.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  if (!files[0]) {
    throw new Error(`No Codex session logs found in ${redactHome(root)}`);
  }
  return files[0];
}

function matchesApp(invocation, result, appFilter) {
  if (!appFilter) return true;
  const arg = String(invocation?.arguments?.app ?? "").toLowerCase();
  const target = String(result?._meta?.["codex/telemetry"]?.span?.target_id ?? "").toLowerCase();
  return arg.includes(appFilter) || target.includes(appFilter);
}

function extensionFor(mimeType) {
  if (mimeType === "image/png") return "png";
  if (mimeType === "image/jpeg" || mimeType === "image/jpg") return "jpg";
  return "img";
}

async function main() {
  const options = parseArgs(process.argv);
  const session = options.session ?? newestSessionFile();
  fs.mkdirSync(options.out, { recursive: true });

  const manifest = {
    session: redactHome(session),
    appFilter: options.app ?? null,
    frames: [],
  };

  const rl = readline.createInterface({
    input: fs.createReadStream(session),
    crlfDelay: Infinity,
  });

  let lineNumber = 0;
  let frameNumber = 0;
  for await (const line of rl) {
    lineNumber += 1;
    if (!line.includes('"tool":"get_app_state"')) continue;

    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }

    const payload = record.payload ?? {};
    const invocation = payload.invocation ?? {};
    const result = payload.result?.Ok;
    if (payload.type !== "mcp_tool_call_end") continue;
    if (invocation.server !== "computer-use" || invocation.tool !== "get_app_state") continue;
    if (!result || result.isError) continue;
    if (!matchesApp(invocation, result, options.app)) continue;

    const image = (result.content ?? []).find((item) => item.type === "image" && item.data);
    if (!image) continue;

    frameNumber += 1;
    const ext = extensionFor(image.mimeType);
    const filename = `frame-${String(frameNumber).padStart(4, "0")}.${ext}`;
    const outputPath = path.join(options.out, filename);
    fs.writeFileSync(outputPath, Buffer.from(image.data, "base64"));
    manifest.frames.push({
      filename,
      timestamp: record.timestamp,
      lineNumber,
      mimeType: image.mimeType,
      app: invocation.arguments?.app ?? null,
      targetId: result._meta?.["codex/telemetry"]?.span?.target_id ?? null,
    });

    if (frameNumber >= options.limit) break;
  }

  fs.writeFileSync(path.join(options.out, "manifest.json"), JSON.stringify(manifest, null, 2));
  console.log(`Extracted ${frameNumber} frame(s) from ${redactHome(session)} into ${redactHome(options.out)}`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
