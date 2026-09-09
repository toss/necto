//
//  Copyright (c) 2026 Viva Republica, Inc.
//
// Renders a built plugin and fails on the layout faults that a type checker cannot
// see: a table wider than its container, text clipped to a couple of characters,
// controls sitting on top of each other.
//
//   node script/check-plugin-layout.mjs
//   node script/check-plugin-layout.mjs network-logger
//
// Requires a headless browser. Missing browser support is a failure because this is
// an explicit smoke test, not part of the default unit-test path.

import { spawn } from "node:child_process";
import { resolve } from "node:path";
import assert from "node:assert/strict";
import { installDetailFixture } from "./tests/detail-pane-fixture.mjs";

const ROOT = resolve(import.meta.dirname, "..");
const PROFILES = [
  { id: "network-logger", ready: "tbody tr", detail: true },
  { id: "view-inspector", ready: ".necto-tree-row", detail: true },
  { id: "event-log", ready: "tbody tr", detail: true, fixture: true },
  { id: "preferences", ready: "tbody tr", detail: true, fixture: true },
  { id: "files", ready: ".necto-tree-row", detail: true, fixture: true },
  { id: "performance-monitor", ready: ".necto-metric" },
  { id: "shell-demo", ready: "#shell-command" },
];
const VIEWPORTS = [
  { name: "narrow", width: 480, height: 760 },
  { name: "wide", width: 1100, height: 760 },
];
const requested = process.argv.slice(2);
const profiles = requested.length
  ? requested.map((id) => {
      const profile = PROFILES.find((candidate) => candidate.id === id);
      if (!profile) throw new Error(`unknown plugin '${id}'`);
      return profile;
    })
  : PROFILES;

/// The dev server, because the mock host only exists in development: shipping it in
/// the built plugin would put fake data one query parameter away from a real user.
function serve(plugin, port) {
  const server = spawn(
    "yarn",
    ["workspace", `@necto-plugin/${plugin}`, "dev", "--port", String(port), "--strictPort"],
    { cwd: ROOT, stdio: "ignore" },
  );

  return new Promise((done, fail) => {
    const deadline = Date.now() + 30_000;
    const poll = setInterval(async () => {
      try {
        await fetch(`http://localhost:${port}/`);
        clearInterval(poll);
        done(server);
      } catch {
        if (Date.now() > deadline) {
          clearInterval(poll);
          server.kill();
          fail(new Error("the dev server did not start"));
        }
      }
    }, 250);
  });
}

/// Runs in the page. Returns a list of complaints, empty when the layout holds.
function audit(readySelector) {
  const problems = [];
  const root = document.documentElement;

  if (root.scrollWidth > root.clientWidth + 1) {
    problems.push(`page scrolls horizontally (${root.scrollWidth} > ${root.clientWidth})`);
  }

  // A header clipped to "S." means the column width never took effect.
  for (const cell of document.querySelectorAll("th")) {
    const text = cell.innerText.trim();
    if (text && cell.scrollWidth > cell.clientWidth + 1) {
      problems.push(`header "${text}" is clipped`);
    }
  }

  // Check control geometry as well as text clipping.
  const controls = [...document.querySelectorAll("button")].map((element) => ({
    text: element.innerText.trim(),
    box: element.getBoundingClientRect(),
  }));
  for (let i = 0; i < controls.length; i += 1) {
    for (let j = i + 1; j < controls.length; j += 1) {
      const a = controls[i].box;
      const b = controls[j].box;
      const overlaps =
        a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
      if (overlaps && a.width && b.width) {
        problems.push(`"${controls[i].text}" overlaps "${controls[j].text}"`);
      }
    }
  }

  if (!document.querySelector(readySelector)) {
    problems.push(`no content rendered for '${readySelector}': the mock host did not answer`);
  }
  return problems;
}

async function main() {
  let puppeteerModule;
  try {
    puppeteerModule = await import("puppeteer");
  } catch (error) {
    throw new Error("puppeteer is required; run yarn install before this check", { cause: error });
  }

  const browser = await puppeteerModule.launch();
  try {
    for (const [index, profile] of profiles.entries()) {
      const port = 5199 + index;
      const server = await serve(profile.id, port);
      try {
        for (const viewport of VIEWPORTS) {
          const page = await browser.newPage();
          try {
            await page.setViewport(viewport);
            if (profile.fixture) await page.evaluateOnNewDocument(installDetailFixture);
            await page.goto(`http://localhost:${port}/`, { waitUntil: "networkidle0" });
            await page.evaluate(() => localStorage.clear());
            await page.reload({ waitUntil: "networkidle0" });
            await page.waitForSelector(profile.ready, { timeout: 5000 }).catch(() => undefined);

            const problems = await page.evaluate(audit, profile.ready);
            if (profile.detail) {
              await page.click(profile.ready);
              await page.waitForSelector(".necto-resize");
              // Wait for the asynchronous detail reply to replace the loading pane.
              await page.waitForNetworkIdle();
              const position = viewport.width <= 640 ? "bottom" : "right";
              assert.equal(await page.$eval(".necto-app", el => el.dataset.detailPosition), position);
              assert.equal(await page.$(".necto-dock-select"), null);
              problems.push(...await page.evaluate(audit, profile.ready));
              const axis = position === "right" ? "ArrowLeft" : "ArrowUp";
              await page.focus(".necto-resize");
              const before = Number(await page.$eval(".necto-resize", el => el.getAttribute("aria-valuenow")));
              await page.keyboard.press(axis);
              assert.equal(Number(await page.$eval(".necto-resize", el => el.getAttribute("aria-valuenow"))), before + 24);
              await page.evaluate(() => {
                for (const key of Object.keys(localStorage).filter(key => key.endsWith(".detail"))) {
                  const sizes = JSON.parse(localStorage.getItem(key));
                  localStorage.setItem(key, JSON.stringify({ ...sizes, position: "bottom" }));
                }
              });
              await page.reload({ waitUntil: "networkidle0" });
              await page.waitForSelector(profile.ready);
              await page.click(profile.ready);
              await page.waitForSelector(".necto-resize");
              await page.waitForNetworkIdle();
              assert.equal(await page.$(".necto-dock-select"), null);
              assert.equal(await page.$eval(".necto-app", el => el.dataset.detailPosition), position);
              assert.equal(Number(await page.$eval(".necto-resize", el => el.getAttribute("aria-valuenow"))), before + 24);
              if (viewport.width > 640) {
                assert.equal(Number(await page.$eval(".necto-resize", el => el.getAttribute("aria-valuenow"))), before + 24);
                await page.setViewport({ width: 480, height: 760 });
                await page.waitForFunction(() => document.querySelector(".necto-app").dataset.detailPosition === "bottom");
                await page.setViewport(viewport);
                await page.waitForFunction(() => document.querySelector(".necto-app").dataset.detailPosition === "right");
              }
              const handle = await page.$(".necto-resize");
              const box = await handle.boundingBox();
              const startSize = Number(await page.$eval(".necto-resize", el => el.getAttribute("aria-valuenow")));
              await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
              await page.mouse.down();
              await page.mouse.move(box.x + box.width / 2 - (position === "right" ? 30 : 0), box.y + box.height / 2 - (position === "bottom" ? 30 : 0));
              await page.mouse.up();
              assert.equal(Number(await page.$eval(".necto-resize", el => el.getAttribute("aria-valuenow"))), startSize + 30);
              await page.click(".necto-detail-title > button:last-child");
              assert.equal(await page.$(".necto-detail"), null);
              await page.click(profile.ready);
              await page.waitForSelector(".necto-resize");
              assert.equal(Number(await page.$eval(".necto-resize", el => el.getAttribute("aria-valuenow"))), startSize + 30);
            }
            if (profile.id === "files") {
              await page.waitForNetworkIdle();
              await page.evaluate(() => {
                [...document.querySelectorAll(".file-actions button")]
                  .find(button => button.textContent === "Edit").click();
              });
              await page.waitForSelector(".file-edit-body textarea");
              const editor = await page.$eval(".file-edit-body textarea", element => {
                const style = getComputedStyle(element);
                const body = element.parentElement;
                return {
                  height: element.getBoundingClientRect().height,
                  minimum: parseFloat(style.minHeight),
                  bodyHeight: body.clientHeight,
                  bodyScrollHeight: body.scrollHeight,
                  fillsSpace: style.flexGrow === "1",
                  horizontalOverflow: body.scrollWidth > body.clientWidth + 1,
                };
              });
              assert.ok(editor.height >= editor.minimum, "file editor retains its minimum height");
              assert.ok(editor.fillsSpace, "file editor uses remaining panel space");
              assert.equal(editor.horizontalOverflow, false, "file editor stays within the panel");
              if (viewport.name === "wide") {
                assert.ok(editor.height > editor.minimum, "file editor expands beyond its minimum");
                assert.ok(editor.bodyScrollHeight <= editor.bodyHeight + 1, "wide editor needs no outer scrolling");
              }
              problems.push(...await page.evaluate(audit, profile.ready));
            }
            if (problems.length) {
              console.log(`FAIL: ${profile.id} at ${viewport.name} (${viewport.width}x${viewport.height})`);
              for (const problem of problems) console.log(`  - ${problem}`);
              process.exitCode = 1;
            } else {
              console.log(`OK: ${profile.id} at ${viewport.name} (${viewport.width}x${viewport.height})`);
            }
          } finally {
            await page.close();
          }
        }
      } finally {
        server.kill();
      }
    }
  } finally {
    await browser.close();
  }
}

await main();
