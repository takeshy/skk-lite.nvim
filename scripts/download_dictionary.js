#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const zlib = require("node:zlib");

const ROOT = path.resolve(__dirname, "..");
const CONFIG_PATH = path.join(ROOT, "dictionary_sources.json");

function usage() {
  console.log("Usage: node scripts/download_dictionary.js --output <directory>");
}

function parseArguments(argv) {
  const result = { output: null };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") {
      usage();
      process.exit(0);
    }
    if (argument === "--output" || argument === "-o") {
      result.output = argv[index + 1];
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${argument}`);
  }
  if (!result.output) {
    throw new Error("--output is required");
  }
  return result;
}

function loadConfig() {
  const config = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  if (!config || typeof config.sourceBaseUrl !== "string" || !Array.isArray(config.dictionaries)) {
    throw new Error(`Invalid dictionary source configuration: ${CONFIG_PATH}`);
  }
  return config;
}

async function downloadDictionary(baseUrl, name, outputDirectory) {
  if (path.basename(name) !== name) {
    throw new Error(`Invalid dictionary name: ${name}`);
  }
  const url = `${baseUrl.replace(/\/+$/, "")}/${encodeURIComponent(name)}.gz`;
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to fetch ${name}: ${response.status} ${response.statusText}`);
  }
  const archive = Buffer.from(await response.arrayBuffer());
  const dictionary = zlib.gunzipSync(archive);
  const outputPath = path.join(outputDirectory, name);
  fs.writeFileSync(outputPath, dictionary);
  console.log(`Downloaded ${name} (${dictionary.length} bytes)`);
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const config = loadConfig();
  const outputDirectory = path.resolve(options.output);
  fs.mkdirSync(outputDirectory, { recursive: true });
  for (const name of config.dictionaries) {
    await downloadDictionary(config.sourceBaseUrl, name, outputDirectory);
  }
  console.log(`Dictionary sources written to ${outputDirectory}`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
