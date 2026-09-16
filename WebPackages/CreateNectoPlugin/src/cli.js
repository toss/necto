//
// Copyright (c) 2026 Viva Republica, Inc.
//

import { createProject } from "./create-project.js";

const usage = `Usage: create-necto-plugin <name> --type device|desktop

Creates a standalone Necto plugin project in a new directory.

Options:
  --type <type>  Required. Either device or desktop.
  --help         Show this help.`;

export async function run(arguments_) {
  const parsed = parseArguments(arguments_);
  if (parsed.help) {
    console.log(usage);
    return;
  }

  if (!parsed.name) throw new Error(usage);
  if (!parsed.type) throw new Error("--type is required. Use --type device or --type desktop.");
  const result = await createProject({ name: parsed.name, type: parsed.type });

  console.log(`Created ${result.type} plugin at ${result.directory}`);
  console.log("");
  console.log("Next:");
  console.log(`  cd ${result.relativeDirectory}`);
  console.log("  npm install");
  console.log("  npm run build");
  if (result.type === "device") console.log("  open *.xcodeproj");
}

function parseArguments(arguments_) {
  let name;
  let type;
  let help = false;

  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--help" || argument === "-h") {
      help = true;
    } else if (argument === "--type") {
      type = arguments_[index + 1];
      index += 1;
    } else if (argument.startsWith("--type=")) {
      type = argument.slice("--type=".length);
    } else if (argument.startsWith("-")) {
      throw new Error(`Unknown option: ${argument}`);
    } else if (!name) {
      name = argument;
    } else {
      throw new Error(`Unexpected argument: ${argument}`);
    }
  }

  if (type !== undefined && type !== "device" && type !== "desktop") {
    throw new Error(`Unknown plugin type: ${type}. Use device or desktop.`);
  }
  return { help, name, type };
}
