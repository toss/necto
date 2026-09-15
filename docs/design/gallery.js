//
//  Copyright (c) 2026 Viva Republica, Inc.
//
// Builds the gallery from the shipped stylesheets. Every surface is assembled from the
// same classes a plugin would use, so this page fails the moment the system does.

const root = document.documentElement;
const switches = Array.from(document.querySelectorAll(".switch button"));

function applyTheme(choice) {
  if (choice === "system") delete root.dataset.theme;
  else root.dataset.theme = choice;
  for (const button of switches) {
    button.setAttribute("aria-pressed", String(button.dataset.set === choice));
  }
}
for (const button of switches) button.addEventListener("click", () => applyTheme(button.dataset.set));
applyTheme("system");

window.addEventListener("load", async () => {
  const { createDetailPane } = await import("../../WebPackages/Bridge/dist/index.js");
  document.querySelectorAll(".necto-detail").forEach((pane, index) => {
    let layout = pane.parentElement;
    const chrome = layout.querySelector(":scope > .win-bar");
    if (chrome) {
      const content = document.createElement("div");
      content.style.cssText = "flex:1; min-height:0";
      content.append(...Array.from(layout.children).filter(child => child !== chrome));
      layout.append(content);
      layout = content;
    }
    layout.classList.add("necto-app");
    layout.style.removeProperty("display");
    if (layout.id === "events") layout.style.height = "420px";
    const list = pane.previousElementSibling;
    list?.classList.add("necto-body");
    pane.removeAttribute("style");
    pane.querySelector(".necto-resize")?.remove();
    const controller = createDetailPane(`necto.gallery.detail.${index}`);
    controller.mount(pane);
  });
});

for (const strip of document.querySelectorAll("[data-ladder]")) {
  const ladder = strip.dataset.ladder;
  strip.innerHTML = ["00","05","10","20","30","40","50","60","70","80","100"]
    .map((step) => `<span style="background: var(--${ladder}-${step})" title="${ladder}-${step}"></span>`)
    .join("");
}

const requests = [
  { tone: "idle", code: "—", method: "PATCH", name: "settings", host: "api.example.com", at: "16:41:07.018", ms: "…", size: "" },
  { tone: "danger", code: "fail", method: "DELETE", name: "current", host: "api.example.com", at: "16:41:05.518", ms: "5.0 s", size: "" },
  { tone: "warning", code: "404", method: "GET", name: "unknown", host: "api.example.com", at: "16:41:04.518", ms: "227 ms", size: "955 B", on: true },
  { tone: "ok", code: "201", method: "POST", name: "transactions?include=merchant&limit=50", host: "api.example.com", at: "16:41:03.518", ms: "1.8 s", size: "24.0 kB" },
  { tone: "ok", code: "200", method: "GET", name: "posts", host: "api.example.com", at: "16:41:02.518", ms: "103 ms", size: "68 B" },
  { tone: "info", code: "304", method: "GET", name: "avatar.png", host: "cdn.example.com", at: "16:41:01.900", ms: "18 ms", size: "0 B" },
  { tone: "danger", code: "500", method: "GET", name: "error", host: "api.example.com", at: "16:41:01.220", ms: "64 ms", size: "61 B" },
];

const toolbar = (lead = "") => `
  <div class="necto-toolbar">
    ${lead}
    <input class="necto-field" type="search" placeholder="Filter" aria-label="Filter" />
    <span class="necto-caption">${requests.length}</span>
    <button type="button" class="necto-button necto-button-quiet necto-button-danger">Clear</button>
  </div>`;

document.getElementById("network").innerHTML = `
  ${toolbar()}
  <table class="necto-table">
    <thead><tr>
      <th style="width:84px">Status</th><th style="width:72px">Method</th><th>URL</th>
      <th class="necto-numeric" style="width:104px">Started</th>
      <th class="necto-numeric" style="width:80px">Duration</th>
      <th class="necto-numeric" style="width:76px">Size</th>
    </tr></thead>
    <tbody>${requests.map((r) => `
      <tr aria-selected="${Boolean(r.on)}">
        <td><span class="necto-status necto-status-${r.tone}">${r.code}</span></td>
        <td>${r.method}</td>
        <td>${r.name}<span class="req-host">${r.host}</span></td>
        <td class="necto-numeric">${r.at}</td>
        <td class="necto-numeric">${r.ms}</td>
        <td class="necto-numeric">${r.size}</td>
      </tr>`).join("")}</tbody>
  </table>`;

const events = [
  ["16:41:07.204", "danger", "error", "Session", "Token refresh failed after 3 attempts"],
  ["16:41:07.018", "warning", "warn", "Cache", "Evicted 240 entries, over budget by 3.2 MB"],
  ["16:41:06.755", "info", "info", "Router", "Presented /accounts/9f8e7d6c/transactions"],
  ["16:41:06.201", "idle", "debug", "Layout", "TransactionList measured in 4.2 ms"],
  ["16:41:05.940", "info", "info", "Auth", "Signed in as demo@example.com"],
  ["16:41:05.518", "idle", "debug", "Store", "Hydrated 1,204 records from disk"],
];

document.getElementById("events").innerHTML = `
  <div class="necto-toolbar">
    <input class="necto-field" type="search" value="cache" aria-label="Search events" style="max-width:360px" />
    <select class="necto-field" aria-label="Filter by level" style="max-width:132px;flex:0 0 132px"><option>All levels</option><option>Debug</option><option>Info</option><option selected>Warning</option><option>Error</option></select>
    <span class="necto-caption">1 / 6</span>
    <button type="button" class="necto-button necto-button-quiet necto-button-danger">Clear</button>
  </div>
  <div class="necto-body"><table class="necto-table">
    <thead><tr>
      <th class="necto-numeric" style="width:104px">Time</th>
      <th style="width:78px">Level</th><th style="width:110px">Tag</th><th>Message</th>
    </tr></thead>
    <tbody>${events.slice(1, 2).map(([at, tone, level, tag, message]) => `
      <tr aria-selected="true">
        <td class="necto-numeric">${at}</td>
        <td><span class="necto-status necto-status-${tone}">${level}</span></td>
        <td><span class="necto-badge">${tag}</span></td>
        <td>${message}</td>
      </tr>`).join("")}</tbody>
  </table></div>
  <aside class="necto-detail" style="--necto-detail-height:180px">
    <div class="necto-resize" role="separator" tabindex="0" aria-orientation="horizontal" aria-label="Resize event detail"></div>
    <div class="necto-detail-title"><span class="necto-status necto-status-warning">warn</span><span class="necto-detail-title-url">Evicted 240 entries, over budget by 3.2 MB</span><button type="button" class="necto-button necto-button-quiet" aria-label="Close">✕</button></div>
    <div class="necto-detail-body"><dl class="necto-pairs"><div><dt>freed</dt><dd>3.2 MB</dd></div><div><dt>count</dt><dd>240</dd></div></dl></div>
  </aside>`;

const spark = (points, colour) => `
  <svg class="necto-spark" viewBox="0 0 100 26" preserveAspectRatio="none" aria-hidden="true">
    <polyline points="${points}" fill="none" stroke="${colour}" stroke-width="1.5" vector-effect="non-scaling-stroke" />
  </svg>`;

document.getElementById("performance").innerHTML = `
  ${toolbar(`<div class="necto-tabs" style="border:0;padding:0">
    <button type="button" class="necto-tab">1 m</button>
    <button type="button" class="necto-tab" aria-selected="true">5 m</button>
    <button type="button" class="necto-tab">1 h</button></div>`)}
  <div class="necto-metrics">
    <div class="necto-metric"><div class="necto-metric-title">Memory</div><div class="necto-metric-value">148<span class="necto-metric-unit"> MB</span></div>
      <div class="necto-metric-note">▲ 12 MB in 5 m</div>${spark("0,22 20,19 40,16 60,12 80,8 100,4", "var(--necto-text-tertiary)")}</div>
    <div class="necto-metric" data-over="true"><div class="necto-metric-title">Frame rate</div><div class="necto-metric-value">48.2<span class="necto-metric-unit"> fps</span></div>
      <div class="necto-metric-note">▼ under 55 fps</div>${spark("0,6 20,8 40,12 60,10 80,16 100,18", "var(--necto-danger)")}</div>
    <div class="necto-metric"><div class="necto-metric-title">CPU</div><div class="necto-metric-value">34<span class="necto-metric-unit"> %</span></div>
      <div class="necto-metric-note">▼ 8 % in 5 m</div>${spark("0,6 20,9 40,12 60,14 80,17 100,19", "var(--necto-text-tertiary)")}</div>
    <div class="necto-metric"><div class="necto-metric-title">Threads</div><div class="necto-metric-value">28<span class="necto-metric-unit"></span></div>
      <div class="necto-metric-note">steady</div>${spark("0,15 20,14 40,16 60,14 80,15 100,15", "var(--necto-text-tertiary)")}</div>
  </div>`;

document.getElementById("components").innerHTML = `
  <div class="demo-row"><span class="demo-label">status</span>
    <span class="necto-status necto-status-ok">200</span>
    <span class="necto-status necto-status-info">304</span>
    <span class="necto-status necto-status-warning">404</span>
    <span class="necto-status necto-status-danger">500</span>
    <span class="necto-status necto-status-idle">—</span></div>
  <div class="demo-row"><span class="demo-label">controls</span>
    <input class="necto-field" style="max-width:200px" placeholder="necto-field" aria-label="Example" />
    <button type="button" class="necto-button">necto-button</button>
    <button type="button" class="necto-button" aria-pressed="true">pressed</button>
    <button type="button" class="necto-button necto-button-quiet">quiet</button>
    <button type="button" class="necto-button necto-button-quiet necto-button-danger">danger</button></div>
  <div class="demo-row"><span class="demo-label">tabs</span>
    <div class="necto-tabs" style="border:0;padding:0">
      <button type="button" class="necto-tab" aria-selected="true">Summary</button>
      <button type="button" class="necto-tab">Request</button>
      <button type="button" class="necto-tab">Response</button></div></div>
  <div class="demo-row"><span class="demo-label">badge</span>
    <span class="necto-badge">Session</span><span class="necto-badge">Router</span></div>
  <div class="demo-row" style="align-items:flex-start"><span class="demo-label">pairs</span>
    <div style="flex:1">
      <h3 class="necto-section-title">Headers</h3>
      <dl class="necto-pairs">
        <div><dt>Method</dt><dd>POST</dd></div>
        <div><dt>Status</dt><dd>201</dd></div></dl></div></div>
  <div class="demo-row" style="align-items:flex-start"><span class="demo-label">empty</span>
    <div class="necto-empty" style="flex:1">
      <p class="necto-empty-title">No requests yet</p>
      <p class="necto-caption">Make a request in the connected app and it appears here.</p></div></div>
  <div class="demo-row" style="align-items:flex-start"><span class="demo-label">code</span>
    <pre class="necto-code" style="flex:1">{
  "id": 1,
  "title": "Post 1"
}</pre></div>
  <div class="demo-row" style="align-items:stretch"><span class="demo-label">JSON editor</span>
    <textarea class="necto-field necto-json-editor" aria-label="JSON editor" spellcheck="false">{
  "status": 200,
  "body": {
    "message": "Hello from Necto"
  }
}</textarea></div>`;

const computed = getComputedStyle(root);
document.getElementById("tokens").innerHTML = [
  ["Semantic", ["bg", "sidebar", "surface", "hover", "selected", "border", "text", "text-secondary", "text-tertiary"]],
  ["Status", ["success", "warning", "danger", "info"]],
  ["Identity", ["accent", "brand"]],
].map(([title, names]) => `
  <div class="token-card"><h3>${title}</h3>
    ${names.map((name) => `
      <div class="token-row">
        <span class="token-chip" style="background: var(--necto-${name})"></span>${name}
        <code>${computed.getPropertyValue(`--necto-${name}`).trim()}</code>
      </div>`).join("")}
  </div>`).join("");

// -- the whole app ----------------------------------------------------------

const phoneIcon = `<svg class="necto-icon" viewBox="0 0 16 16" aria-hidden="true"><rect x="4.5" y="1.5" width="7" height="13" rx="1.6"/><line x1="6.8" y1="3.3" x2="9.2" y2="3.3"/></svg>`;
const simIcon = `<svg class="necto-icon" viewBox="0 0 16 16" aria-hidden="true"><rect x="1.5" y="3.5" width="9" height="7" rx="1.2"/><path d="M1 12.5h10"/><rect x="11" y="6" width="4" height="7.5" rx="1"/></svg>`;
const nectoIconURL = new URL("../images/necto-icon.png", document.currentScript.src).href;
// One glyph per plugin, the way each manifest names its own SF Symbol.
const netIcon = `<svg class="necto-icon" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6"/><path d="M2 8h12"/><path d="M8 2c2.2 2.4 2.2 9.6 0 12M8 2c-2.2 2.4-2.2 9.6 0 12"/></svg>`;
const waveIcon = `<svg class="necto-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M2 9.5c1.4-2.4 2.8-2.4 4.2 0s2.8 2.4 4.2 0 2.4-1.6 3.6-.4"/><path d="M2 5.5c1.4-2.4 2.8-2.4 4.2 0"/></svg>`;
const logIcon = `<svg class="necto-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 4.5h11M2.5 8h11M2.5 11.5h6.5"/></svg>`;
const sampleIcon = `<svg class="necto-icon" viewBox="0 0 16 16" aria-hidden="true"><rect x="2" y="2" width="5" height="5" rx="1.2"/><rect x="9" y="2" width="5" height="5" rx="1.2"/><rect x="2" y="9" width="5" height="5" rx="1.2"/><rect x="9" y="9" width="5" height="5" rx="1.2"/></svg>`;
const gaugeIcon = `<svg class="necto-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M2 11.5a6 6 0 1 1 12 0"/><path d="M8 11.5l3.2-3.6"/></svg>`;

// Sliders rather than a gear: at 15px a cogwheel's teeth turn to mush, and a circle
// with radial lines reads as a sun.
const gearIcon = `<svg class="necto-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M2 5h4.2M9.2 5H14M2 11h1.8M6.8 11H14"/><circle cx="7.7" cy="5" r="1.6"/><circle cx="5.3" cy="11" r="1.6"/></svg>`;

const lights = `<span class="win-lights"><i></i><i></i><i></i></span>`;
const heading = `<span class="win-heading">${netIcon}<span>Network</span></span>`;

const pluginSearchButton = `<button type="button" class="gallery-plugin-search" aria-label="Search plugins" popovertarget="gallery-plugin-search-popover">
  <svg class="necto-icon" viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="4"/><path d="m10 10 4 4"/></svg>
</button>`;

const sidebar = (onSettings = false) => `
  <div class="necto-sidebar">
    <div class="win-bar">${lights}</div>
    <div class="necto-app-head">
      <img class="necto-app-icon" src="${nectoIconURL}" alt="" />
      <div>
        <div class="necto-app-name">Necto Example</div>
        <div class="necto-app-id">im.toss.necto.example</div>
      </div>
    </div>

    <button type="button" class="necto-sidebar-item" aria-selected="true">
      ${phoneIcon}<span>iPhone 15 Pro</span>
      <span class="necto-trailing">iOS 18.6</span><span class="necto-conn necto-conn-on" title="Connected"></span>
    </button>
    <button type="button" class="necto-sidebar-item">
      ${simIcon}<span>iPhone 16 Pro</span>
      <span class="necto-trailing">iOS 18.6</span><span class="necto-conn necto-conn-on" title="Connected"></span>
    </button>
    <button type="button" class="necto-sidebar-item">
      ${phoneIcon}<span>iPad Pro 11"</span>
      <span class="necto-trailing">iOS 27.0</span><span class="necto-conn necto-conn-off" title="Not connected"></span>
    </button>

    <div class="necto-sidebar-group gallery-plugin-group"><span>Device Plugins</span>${pluginSearchButton}</div>
    <button type="button" class="necto-sidebar-item">${sampleIcon}<span>Plugin Sample</span><span class="necto-trailing">1.0.0</span></button>
    <button type="button" class="necto-sidebar-item" aria-selected="${!onSettings}">${netIcon}<span>Network</span><span class="necto-trailing">1.0.0</span></button>
    <button type="button" class="necto-sidebar-item">${logIcon}<span>Events</span><span class="necto-trailing">0.4.1</span></button>
    <button type="button" class="necto-sidebar-item">${gaugeIcon}<span>Performance</span><span class="necto-trailing">0.2.0</span></button>
    <button type="button" class="necto-sidebar-item" style="color:var(--necto-text-tertiary)">${logIcon}<span>Recording</span><span class="necto-trailing">off</span></button>

    <div class="necto-sidebar-group">Desktop Plugins</div>
    <button type="button" class="necto-sidebar-item">${sampleIcon}<span>Target Notes</span><span class="necto-trailing">0.1.0</span></button>
    <button type="button" class="necto-sidebar-item">${gaugeIcon}<span>Host Status</span><span class="necto-trailing">0.1.0</span></button>

    <div class="side-foot">
      <button type="button" class="necto-sidebar-item" aria-selected="${onSettings}">${gearIcon}<span>Settings</span></button>
    </div>
  </div>`;

const pluginSearch = document.createElement("div");
pluginSearch.id = "gallery-plugin-search-popover";
pluginSearch.className = "gallery-plugin-search-popover";
pluginSearch.setAttribute("popover", "auto");
document.body.append(pluginSearch);
document.addEventListener("click", (event) => {
  const trigger = event.target.closest(".gallery-plugin-search");
  if (!trigger) return;
  const groups = Array.from(trigger.closest(".necto-sidebar").querySelectorAll(".necto-sidebar-group"));
  pluginSearch.replaceChildren();
  const input = document.createElement("input");
  input.className = "necto-field";
  input.placeholder = "Search plugins";
  input.setAttribute("aria-label", "Search plugins");
  pluginSearch.append(input);
  const results = document.createElement("div");
  pluginSearch.append(results);
  const render = () => {
    results.replaceChildren();
    for (const group of groups) {
      const rows = [];
      for (let row = group.nextElementSibling; row?.classList.contains("necto-sidebar-item"); row = row.nextElementSibling) {
        if (row.querySelector("span").textContent.toLowerCase().includes(input.value.trim().toLowerCase())) rows.push(row);
      }
      if (rows.length) {
        const heading = document.createElement("div");
        heading.className = "necto-sidebar-group";
        heading.textContent = group.textContent.trim();
        results.append(heading);
      }
      for (const row of rows) {
        const result = row.cloneNode(true);
        result.addEventListener("click", () => {
          trigger.closest(".necto-sidebar").querySelectorAll(".necto-sidebar-item[aria-selected]").forEach(item => item.removeAttribute("aria-selected"));
          row.setAttribute("aria-selected", "true");
          pluginSearch.hidePopover();
        });
        results.append(result);
      }
    }
    if (!results.children.length) results.innerHTML = '<p class="necto-caption">No plugins found</p>';
  };
  input.addEventListener("input", render);
  render();
});
pluginSearch.addEventListener("toggle", (event) => {
  if (event.newState === "open") pluginSearch.querySelector("input").focus();
});

const networkPane = (bar) => `
  <div class="necto-app">
    <div class="win-bar">${bar}</div>
    ${toolbar()}
    <div class="necto-body gallery-network-list">
      <table class="necto-table">
        <thead><tr>
          <th style="width:84px">Status</th><th style="width:72px">Method</th><th>URL</th>
          <th class="necto-numeric" style="width:104px">Started</th>
          <th class="necto-numeric" style="width:80px">Duration</th>
        </tr></thead>
        <tbody>${requests.map((r) => `
          <tr aria-selected="${Boolean(r.on)}">
            <td><span class="necto-status necto-status-${r.tone}">${r.code}</span></td>
            <td>${r.method}</td>
            <td>${r.name}<span class="req-host">${r.host}</span></td>
            <td class="necto-numeric">${r.at}</td>
            <td class="necto-numeric">${r.ms}</td>
          </tr>`).join("")}</tbody>
      </table>
    </div>

    <aside class="necto-detail">
      <div class="necto-resize" role="separator" aria-orientation="horizontal" aria-label="Resize"></div>
      <div class="necto-detail-title">
        <span class="necto-status necto-status-warning">404</span>
        <span>GET</span>
        <span class="necto-detail-title-url">https://api.example.com/v2/merchants/unknown?include=terms</span>
        <button type="button" class="necto-button necto-button-quiet" aria-label="Close">✕</button>
      </div>
      <div class="necto-tabs">
        <button type="button" class="necto-tab">Summary</button>
        <button type="button" class="necto-tab">Request</button>
        <button type="button" class="necto-tab" aria-selected="true">Response</button>
        <button type="button" class="necto-tab">cURL</button>
      </div>
      <div class="necto-detail-body">
        <p class="necto-caption">955 B · application/json</p>
        <pre class="necto-code">{
  "error": "merchant_not_found",
  "message": "No merchant matches the id 'unknown'.",
  "requestId": "9f8e7d6c-4b3a-2910"
}</pre>
      </div>
    </aside>
  </div>`;

/// The window chrome is the shell's, drawn natively. It is here because a plugin is
/// only ever seen inside it: the sidebar is always beside it, and the traffic lights
/// always sit in the sidebar's own title row.
document.getElementById("app").innerHTML =
  `<div class="win">${sidebar()}${networkPane(heading)}</div>`;

// -- type size --------------------------------------------------------------

/// Read at 13px beside Xcode all day, so the choice is worth making by looking rather
/// than by argument. The host sets this from the user's text size preference.
for (const button of document.querySelectorAll(".sizes button")) {
  button.addEventListener("click", () => {
    root.style.setProperty("--necto-font-scale", button.dataset.scale);
    for (const other of document.querySelectorAll(".sizes button")) {
      other.setAttribute("aria-pressed", String(other === button));
    }
  });
}

// -- settings ---------------------------------------------------------------

const desktopPlugins = [
  [sampleIcon, "Target Notes", "0.1.0", "Example Author", true],
  [gaugeIcon, "Host Status", "0.1.0", "Example Author", false],
];


/// The settings panel, built from the same components a plugin gets. Nothing here is
/// bespoke: if a setting needs a widget the system does not have, the system is short a
/// widget.
/// Two columns inside one screen: what you are configuring on the left, the settings
/// themselves on the right. One flat list stopped working the moment plugins arrived —
/// appearance and plugin management have nothing to do with each other.
const settingsNav = (current) => `
  <div class="necto-nav">
    <button type="button" class="necto-nav-item" aria-selected="${current === "general"}">${gearIcon}<span>General</span></button>
    <button type="button" class="necto-nav-item" aria-selected="${current === "shell"}">${logIcon}<span>Shell Access</span></button>
    <button type="button" class="necto-nav-item" aria-selected="${current === "plugins"}">${sampleIcon}<span>Desktop Plugins</span></button>
    <button type="button" class="necto-nav-item" aria-selected="false">${logIcon}<span>Log</span></button>
  </div>`;

const generalPage = () => `
  <div class="necto-body" style="padding: var(--necto-space-3); --necto-font-ui:-apple-system, BlinkMacSystemFont, sans-serif; --necto-font:var(--necto-font-ui)">
    <h3 class="necto-section-title">Appearance</h3>

    <div class="necto-row">
      <div class="necto-row-label">Language
        <p class="necto-row-hint">Changes Necto's native interface. Plugins manage their own language.</p>
      </div>
      <select class="necto-field" style="flex:none; width:190px" aria-label="Language">
        <option selected>System</option>
        <option>English</option>
        <option>한국어</option>
      </select>
    </div>

    <div class="necto-row">
      <div class="necto-row-label">Text size
        <p class="necto-row-hint">Applies to the app and to every plugin. ⌘+ and ⌘- also move it.</p>
      </div>
      <div class="necto-stepper">
        <button type="button" aria-label="Smaller">−</button>
        <input type="text" value="13" aria-label="Text size in points" />
        <span class="necto-stepper-unit">pt</span>
        <button type="button" aria-label="Bigger">+</button>
      </div>
    </div>

    <div class="necto-row">
      <div class="necto-row-label">UI font
        <p class="necto-row-hint">A font family or CSS fallback stack.</p>
      </div>
      <input class="necto-field" style="flex:none; width:190px" value="-apple-system" aria-label="UI font" />
    </div>

    <div class="necto-row">
      <div class="necto-row-label">Code font
        <p class="necto-row-hint">Used for code, values and plugin data.</p>
      </div>
      <input class="necto-field" style="flex:none; width:190px" value="ui-monospace" aria-label="Code font" />
    </div>

    <h3 class="necto-section-title">About</h3>

    <div class="necto-row">
      <div class="necto-row-label">Necto</div>
      <div class="necto-toolbar-group" style="padding: 0">
        <button type="button" class="necto-button necto-button-quiet">Check for updates</button>
        <span class="necto-row-value">0.1.0</span>
      </div>
    </div>
    <div class="necto-row">
      <div class="necto-row-label">Protocol
        <p class="necto-row-hint">The wire version this build speaks.</p>
      </div>
      <span class="necto-row-value">1</span>
    </div>
    <div class="necto-row">
      <div class="necto-row-label">Command line tool
        <p class="necto-row-hint">Adds necto and necto-cli to /usr/local/bin. macOS will ask for administrator approval.</p>
      </div>
      <button type="button" class="necto-button necto-button-quiet">Install CLI</button>
    </div>
    <h3 class="necto-section-title">Agent skills</h3>
    <div class="necto-row">
      <div class="necto-row-label">Codex
        <p class="necto-row-hint">Use Necto from Codex.</p>
      </div>
      <button type="button" class="necto-button necto-button-quiet">Update</button>
    </div>
    <div class="necto-row">
      <div class="necto-row-label">Claude Code
        <p class="necto-row-hint">Use Necto from Claude Code.</p>
      </div>
      <button type="button" class="necto-button necto-button-quiet">Add</button>
    </div>
  </div>`;

const pluginsPage = () => `
  <div class="necto-body" style="padding: var(--necto-space-3)">
    <h3 class="necto-section-title">Installed</h3>
    <table class="necto-table">
      <thead><tr>
        <th style="width:44px">On</th><th>Name</th>
        <th style="width:72px">Version</th><th style="width:110px">Source</th>
        <th class="necto-numeric" style="width:80px"></th>
      </tr></thead>
      <tbody>
        ${desktopPlugins.map(([icon, name, version, author, on]) => `
          <tr>
            <td><button type="button" class="necto-switch" role="switch" aria-checked="${on}" aria-label="Enable ${name}"></button></td>
            <td><span class="named">${icon}${name}</span></td>
            <td>${version}</td>
            <td>${author}</td>
            <td><div class="row-actions"><button type="button" class="necto-button necto-button-quiet necto-button-danger">Remove</button></div></td>
          </tr>`).join("")}
      </tbody>
    </table>

    <h3 class="necto-section-title">Add and edit</h3>

    <div class="necto-row">
      <div class="necto-row-label">Install
        <p class="necto-row-hint">Install a built desktop plugin from a folder or zip file. Necto does not verify the source or check for updates for file installs. Device plugins must be included in the app's Swift package.</p>
      </div>
      <div class="necto-toolbar-group" style="padding: 0">
        <button type="button" class="necto-button">Choose…</button>
      </div>
    </div>

    <div class="necto-row">
      <div class="necto-row-label">Plugins folder
        <p class="necto-row-hint">After adding or changing a plugin folder, reload and approve the plugin. Deleting its folder also removes its permissions.</p>
      </div>
      <div class="necto-toolbar-group" style="padding: 0">
        <button type="button" class="necto-button necto-button-quiet">Open</button>
        <button type="button" class="necto-button necto-button-quiet">Reload</button>
      </div>
    </div>
  </div>`;

const shellCallers = [
  [sampleIcon, "Plugin Sample", "Protected"],
  [netIcon, "Web Inspector", "Command approval · 2 commands"],
  [sampleIcon, "Target Notes", "Command approval · 3 commands"],
  [gaugeIcon, "Host Status", "Full access"],
];

const shellAccessPage = () => `
  <div class="necto-body" style="padding: var(--necto-space-3)">
    <div class="necto-empty" style="height:auto;align-items:flex-start;padding:0;text-align:left">
      <p class="necto-empty-title">Shell access</p>
      <p class="necto-caption">Control which plugins may run shell commands on this Mac.</p>
    </div>
    <h3 class="necto-section-title">Global override</h3>
    <div class="necto-row">
      <div class="necto-row-label">Full Access<p class="necto-row-hint">Allow every plugin and CLI request without confirmation.</p></div>
      <button type="button" class="necto-switch" role="switch" aria-checked="false" aria-label="Full Access"></button>
    </div>
    <h3 class="necto-section-title">Plugin access</h3>
    ${shellCallers.map(([icon, name, access]) => `
      <button type="button" class="necto-row" style="width:100%;border:0;background:none;color:inherit;text-align:left">
        <span class="named">${icon}${name}</span><span class="necto-row-value">${access} ›</span>
      </button>`).join("")}
    <h3 class="necto-section-title">CLI access</h3>
    <button type="button" class="necto-row" style="width:100%;border:0;background:none;color:inherit;text-align:left">
      <span class="named">${logIcon}necto-cli</span><span class="necto-row-value">Command approval · 1 command ›</span>
    </button>
  </div>`;

const shellDetailPage = () => `
  <div class="necto-body" style="padding: var(--necto-space-3)">
    <button type="button" class="necto-button necto-button-quiet">‹ Shell access</button>
    <div class="necto-empty" style="height:auto;align-items:flex-start;padding:var(--necto-space-3) 0 0;text-align:left">
      <p class="necto-empty-title">Target Notes</p>
      <p class="necto-caption">0.1.0 by Example Author · Desktop plugin</p>
    </div>
    <h3 class="necto-section-title">Access for this plugin</h3>
    ${[
      ["Protected", "Reject every shell request from this plugin.", false],
      ["Command approval", "Run only the exact commands listed below.", true],
      ["Full access", "Run any shell command from this plugin without confirmation.", false],
    ].map(([name, hint, selected]) => `
      <button type="button" class="necto-row" style="width:100%;border:0;background:none;color:inherit;text-align:left">
        <span class="necto-status necto-status-${selected ? "info" : "idle"}">${selected ? "on" : "—"}</span>
        <span class="necto-row-label" style="margin-left:var(--necto-space-3)">${name}<p class="necto-row-hint">${hint}</p></span>
      </button>`).join("")}
    <div class="necto-toolbar-group" style="justify-content:space-between;padding-top:var(--necto-space-5)">
      <h3 class="necto-section-title" style="margin:0">Approved commands</h3>
      <button type="button" class="necto-button">Add command…</button>
    </div>
    <table class="necto-table">
      <tbody>
        ${["/usr/bin/xcrun simctl list devices", "/usr/bin/git status --short", "/usr/bin/open -a Simulator"].map((command) => `
          <tr><td><code>${command}</code></td><td class="necto-numeric" style="width:90px"><button type="button" class="necto-button necto-button-quiet necto-button-danger">Remove</button></td></tr>`).join("")}
      </tbody>
    </table>
  </div>`;

const settingsPane = (page = "general") => `
  <div class="necto-app">
    <div class="win-bar"><span class="win-heading">${gearIcon}<span>Settings</span></span></div>
    <div style="display: flex; min-height: 0; flex: 1; padding-left: var(--necto-space-3)">
      ${settingsNav(page)}
      ${page === "general" ? generalPage() : page === "plugins" ? pluginsPage() : page === "shell-detail" ? shellDetailPage() : shellAccessPage()}
    </div>
  </div>`;

document.getElementById("settings").innerHTML = `<div class="win">${sidebar(true)}${settingsPane("general")}</div>`;
document.getElementById("settings-plugins").innerHTML = `<div class="win">${sidebar(true)}${settingsPane("plugins")}</div>`;
document.getElementById("settings-shell").innerHTML = `<div class="win">${sidebar(true)}${settingsPane("shell")}</div>`;
document.getElementById("settings-shell-detail").innerHTML = `<div class="win">${sidebar(true)}${settingsPane("shell-detail")}</div>`;

// -- plugin sample ----------------------------------------------------------

/// Each section is one thing an author has to be able to do, shown working rather than
/// described. The bridge panel is first because a plugin that cannot talk to the host
/// has nothing to style.
const samplePane = () => `
  <div class="necto-app">
    <div class="win-bar"><span class="win-heading">${sampleIcon}<span>Plugin Sample</span></span></div>
    <div class="necto-tabs">
      <button type="button" class="necto-tab" aria-selected="true">Bridge</button>
      <button type="button" class="necto-tab">Components</button>
      <button type="button" class="necto-tab">Table</button>
      <button type="button" class="necto-tab">States</button>
    </div>
    <div class="necto-body" style="padding: var(--necto-space-3)">
      <h3 class="necto-section-title">Context</h3>
      <dl class="necto-pairs">
        <div><dt>pluginID</dt><dd>plugin-sample</dd></div>
        <div><dt>protocolVersion</dt><dd>1</dd></div>
        <div><dt>operations</dt><dd>host.info, host.ticks</dd></div>
        <div><dt>target</dt><dd>im.toss.necto.example</dd></div>
      </dl>

      <h3 class="necto-section-title">Query · host.info</h3>
      <div class="necto-toolbar-group">
        <button type="button" class="necto-button">Run</button>
        <span class="necto-status necto-status-ok">ok</span>
        <span class="necto-caption">4 ms</span>
      </div>
      <div class="necto-code-block">
        <pre class="necto-code">{
  "nectoVersion": "0.4.2",
  "protocolVersion": 1
}</pre>
      </div>

      <h3 class="necto-section-title">Stream · host.ticks</h3>
      <div class="necto-toolbar-group">
        <button type="button" class="necto-button">Start</button>
        <button type="button" class="necto-button necto-button-quiet">Stop</button>
        <span class="necto-badge">48 events</span>
      </div>
      <dl class="necto-pairs">
        <div><dt>sequence</dt><dd>48</dd></div>
        <div><dt>timestamp</dt><dd>00:11:30</dd></div>
      </dl>

      <h3 class="necto-section-title">When it fails</h3>
      <div class="necto-notice necto-notice-danger">
        <div>
          <span class="necto-notice-title">OPERATION_NOT_FOUND</span>
          <p>This plugin's manifest declares no operation bound to <code>necto.device.network-records.list</code>, so the call was refused before it reached a provider.</p>
        </div>
      </div>
    </div>
  </div>`;

document.getElementById("plugin-sample").innerHTML = `<div class="win">${sidebar()}${samplePane()}</div>`;

// -- installing a plugin ----------------------------------------------------


/// What the user is actually deciding. Grouped by how far each permission reaches, so
/// the answer does not depend on counting rows.
const grants = [
  ["necto.desktop.info", "Necto", "Which version of Necto is running."],
  ["necto.desktop.storage.get", "Necto", "Reads settings it stored itself, in a space only it can read."],
  ["necto.desktop.storage.set", "Necto", "Stores its own settings, in a space only it can read."],
  ["necto.desktop.targets.list", "Necto", "Which apps and devices are connected."],
];

const approvePane = () => `
  <div class="necto-app">
    <div class="win-bar"><span class="win-heading">${gearIcon}<span>Settings</span></span></div>
    <div class="necto-dialog-scrim">
      <div class="necto-dialog" role="dialog" aria-modal="true" aria-labelledby="grant-title">
        <div class="necto-dialog-head">
          <div class="necto-dialog-title" id="grant-title">Update Target Notes?</div>
          <p class="necto-caption">
            0.1.0 by Example Author · web assets only, no native code
          </p>
        </div>

        <div class="necto-dialog-body">
          <div class="necto-notice necto-notice-danger" style="margin-bottom: var(--necto-space-3)">
            <div>
              <span class="necto-notice-title">Update Target Notes</span>
              <p>The ID matches, but Necto cannot verify the author of local files.
              Only update if you trust their source. This keeps existing permissions
              and settings, including Shell Access.</p>
            </div>
          </div>

          <p class="necto-caption" style="margin: 0 0 var(--necto-space-2)">com.example.target-notes</p>
          <p class="necto-caption" style="margin: 0 0 var(--necto-space-2)">/Users/me/Downloads/target-notes.zip</p>

          ${grants.map(([name, owner, what]) => `
            <div class="necto-grant">
              <span class="necto-caption">${owner}</span>
              <span class="necto-grant-key">${name}<p class="necto-grant-what">${what}</p></span>
            </div>`).join("")}

          <p class="necto-caption" style="margin: var(--necto-space-3) 0">
            Installing is the agreement. Declining installs nothing, and an update that
            binds to something new asks again.
          </p>
        </div>

        <div class="necto-dialog-actions">
          <button type="button" class="necto-button necto-button-quiet">Cancel</button>
          <button type="button" class="necto-button necto-button-primary">Update</button>
        </div>
      </div>
    </div>
  </div>`;

const failedPane = () => `
  <div class="necto-app">
    <div class="win-bar"><span class="win-heading">${gearIcon}<span>Settings</span></span></div>
    <div class="necto-body" style="padding: var(--necto-space-3); display: grid; gap: var(--necto-space-2)">
      <div class="necto-notice necto-notice-danger">
        <div>
          <span class="necto-notice-title">Could not install Events</span>
          <p>This plugin binds to <code>necto.device.events.list</code>, which a connected app answers. A plugin that needs the app rides in the app: add its Swift package there, and it appears here on its own.</p>
        </div>
      </div>

      <div class="necto-notice necto-notice-danger">
        <div>
          <span class="necto-notice-title">manifest.json could not be read</span>
          <p><code>operations</code> is missing. The folder was left where it was so it can be fixed in place.</p>
        </div>
      </div>

      <div class="necto-notice">
        <div>
          <span class="necto-notice-title">Host Status is installed but off</span>
          <p>Turned off in Settings. Nothing it declared has changed, so turning it back on asks nothing.</p>
        </div>
      </div>
    </div>
  </div>`;

document.getElementById("plugins-manage").innerHTML = `<div class="win">${sidebar(true)}${settingsPane("plugins")}</div>`;
document.getElementById("plugins-approve").innerHTML = `<div class="win">${sidebar(true)}${approvePane()}</div>`;
document.getElementById("plugins-failed").innerHTML = `<div class="win">${sidebar(true)}${failedPane()}</div>`;

// -- copy buttons on code blocks -------------------------------------------

/// `navigator.clipboard` is the right API and is not always available: it needs a
/// secure context, user activation, and in a WKWebView a permission the host may not
/// have granted. The selection route works wherever the document does.
async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const field = document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    field.style.cssText = "position:fixed;top:-1000px;opacity:0";
    document.body.append(field);
    field.select();
    const copied = document.execCommand("copy");
    field.remove();
    return copied;
  }
}

for (const block of document.querySelectorAll(".necto-code")) {
  const wrapper = document.createElement("div");
  wrapper.className = "necto-code-block";
  block.parentNode.insertBefore(wrapper, block);
  wrapper.append(block);

  const button = document.createElement("button");
  button.type = "button";
  button.className = "necto-code-copy";
  button.textContent = "copy";
  wrapper.append(button);

  button.addEventListener("click", async () => {
    // A button that silently does nothing is worse than one that says it failed.
    if (await copyText(block.textContent)) {
      button.textContent = "copied";
      button.dataset.copied = "true";
    } else {
      button.textContent = "failed";
    }
    // Back to its resting state, so the next copy still reads as a confirmation.
    setTimeout(() => {
      button.textContent = "copy";
      delete button.dataset.copied;
    }, 1400);
  });
}

// -- proposed panels ---------------------------------------------------------

/// Shipped and external feature shapes stay rendered here so component changes are
/// checked against real panel layouts rather than isolated controls.

const defaults = [
  { key: "com.example.session.token", type: "String", value: "EXAMPLE_TOKEN_NOT_VALID", on: true },
  { key: "com.example.onboarding.seen", type: "Bool", value: "true" },
  { key: "com.example.feature.newCheckout", type: "Bool", value: "false" },
  { key: "com.example.cart.items", type: "Array", value: "3 items" },
  { key: "com.example.lastSync", type: "Date", value: "2026-07-29 16:38:02" },
  { key: "com.example.launchCount", type: "Int", value: "47" },
  { key: "AppleLanguages", type: "Array", value: "[\"en\", \"ko\"]" },
];

document.getElementById("preferences").innerHTML = `
  <div class="necto-toolbar">
    <input class="necto-field" type="search" placeholder="Filter keys" aria-label="Filter keys" value="com.example" />
    <span class="necto-caption">6 of 214</span>
    <button type="button" class="necto-button">Add key</button>
  </div>
  <div style="display:flex; height:420px">
    <div style="flex:1; overflow:auto">
      <table class="necto-table">
        <thead><tr><th>Key</th><th style="width:76px">Type</th><th style="width:200px">Value</th></tr></thead>
        <tbody>${defaults.map((d) => `
          <tr aria-selected="${Boolean(d.on)}">
            <td>${d.key}</td>
            <td><span class="necto-badge">${d.type}</span></td>
            <td>${d.value}</td>
          </tr>`).join("")}</tbody>
      </table>
    </div>

    <aside class="necto-detail" style="width:300px; border-top:0; border-left:1px solid var(--necto-border)">
      <div class="necto-detail-title">
        <span class="necto-detail-title-url">com.example.session.token</span>
        <button type="button" class="necto-button necto-button-quiet" aria-label="Close">✕</button>
      </div>
      <div class="necto-detail-body">
        <dl class="necto-pairs">
          <div><dt>Type</dt><dd>String</dd></div>
          <div><dt>Suite</dt><dd>standard</dd></div>
          <div><dt>Size</dt><dd>412 B</dd></div>
        </dl>
        <p class="necto-section-title">Value</p>
        <pre class="necto-code">EXAMPLE_TOKEN_NOT_VALID</pre>
        <div class="necto-toolbar" style="padding-left:0; padding-right:0; border:0">
          <button type="button" class="necto-button necto-button-primary">Save</button>
          <button type="button" class="necto-button">Copy</button>
          <button type="button" class="necto-button necto-button-quiet necto-button-danger" style="margin-left:auto">Delete</button>
        </div>
        <p class="necto-caption">Writing a key changes a running app. Necto asks before it does.</p>
      </div>
    </aside>
  </div>`;

/// One row per stored type: the badge, the key it came from, and the editor that
/// type gets. The switch and the fields are the shipped components.
const editorRows = [
  ["Bool", "example.onboarding.seen",
    `<button type="button" class="necto-switch" role="switch" aria-checked="true" aria-label="Value"></button>`],
  ["Int", "example.launchCount",
    `<input class="necto-field" style="flex:none; width:140px; text-align:right; font-family:var(--necto-font-mono)" value="47" aria-label="Value" />`],
  ["Double", "example.playbackRate",
    `<input class="necto-field" style="flex:none; width:140px; text-align:right; font-family:var(--necto-font-mono)" value="1.25" aria-label="Value" />`],
  ["String", "example.theme",
    `<input class="necto-field" style="flex:none; width:280px; font-family:var(--necto-font-mono)" value="dark" aria-label="Value" />`],
  ["Date", "example.lastSync",
    `<input class="necto-field" style="flex:none; width:280px; font-family:var(--necto-font-mono)" value="2026-07-29T16:38:02Z" aria-label="Value" />`],
  ["Array", "example.interests",
    `<div style="display:flex; flex-direction:column; gap:6px; width:280px">
      <div style="display:flex; gap:6px">
        <input class="necto-field" style="flex:1; font-family:var(--necto-font-mono)" value="swift" aria-label="Item 1" />
        <button type="button" class="necto-button necto-button-quiet" aria-label="Remove item">✕</button>
      </div>
      <div style="display:flex; gap:6px">
        <input class="necto-field" style="flex:1; font-family:var(--necto-font-mono)" value="debugging" aria-label="Item 2" />
        <button type="button" class="necto-button necto-button-quiet" aria-label="Remove item">✕</button>
      </div>
      <button type="button" class="necto-button necto-button-quiet" style="align-self:flex-start">+ Add item</button>
    </div>`],
  ["Dictionary", "example.flags",
    `<div style="display:flex; flex-direction:column; gap:6px; width:380px">
      <div style="display:flex; gap:6px">
        <input class="necto-field" style="flex:none; width:150px; font-family:var(--necto-font-mono)" value="newCheckout" aria-label="Key" />
        <input class="necto-field" style="flex:1; font-family:var(--necto-font-mono)" value="false" aria-label="Value" />
        <button type="button" class="necto-button necto-button-quiet" aria-label="Remove pair">✕</button>
      </div>
      <div style="display:flex; gap:6px">
        <input class="necto-field" style="flex:none; width:150px; font-family:var(--necto-font-mono)" value="maxRetries" aria-label="Key" />
        <input class="necto-field" style="flex:1; font-family:var(--necto-font-mono)" value="3" aria-label="Value" />
        <button type="button" class="necto-button necto-button-quiet" aria-label="Remove pair">✕</button>
      </div>
      <button type="button" class="necto-button necto-button-quiet" style="align-self:flex-start">+ Add pair</button>
    </div>`],
  ["Data", "example.pushToken",
    `<span class="necto-caption">412 B of binary &mdash; not editable</span>
     <button type="button" class="necto-button">Copy as base64</button>`],
];

document.getElementById("preferences-editors").innerHTML = `
  <div class="necto-body" style="padding: var(--necto-space-4); display:flex; flex-direction:column; gap: var(--necto-space-3)">
    ${editorRows.map(([type, key, editor]) => `
      <div style="display:flex; align-items:center; gap: var(--necto-space-3)">
        <span class="necto-badge" style="width:56px; text-align:center">${type}</span>
        <span class="necto-caption" style="width:200px; font-family:var(--necto-font-mono)">${key}</span>
        ${editor}
      </div>`).join("")}
  </div>`;

const files = [
  { depth: 0, twist: "▾", name: "Documents", meta: "4 items", dir: true },
  { depth: 1, twist: "", name: "cache.sqlite", meta: "2.4 MB" },
  { depth: 1, twist: "", name: "cache.sqlite-wal", meta: "88 kB" },
  { depth: 1, twist: "▾", name: "receipts", meta: "2 items", dir: true },
  { depth: 2, twist: "", name: "2026-07-28.json", meta: "1.1 kB", on: true },
  { depth: 2, twist: "", name: "2026-07-29.json", meta: "980 B" },
  { depth: 0, twist: "▸", name: "Library", meta: "6 items", dir: true },
  { depth: 0, twist: "▾", name: "tmp", meta: "1 item", dir: true },
  { depth: 1, twist: "", name: "upload-9f8e.part", meta: "14.2 MB" },
];

document.getElementById("files").innerHTML = `
  <div class="necto-toolbar">
    <div class="necto-segmented">
      <button type="button" aria-selected="true">Container</button>
      <button type="button">Group</button>
    </div>
    <input class="necto-field" type="search" placeholder="Filter" aria-label="Filter" />
    <span class="necto-caption">18.7 MB</span>
  </div>
  <div style="display:flex; height:320px">
    <div style="flex:1; overflow:auto">
      <div class="necto-tree">${files.map((f) => `
        <button type="button" class="necto-tree-row" aria-selected="${Boolean(f.on)}" style="padding-left:calc(${f.depth} * 16px + var(--necto-space-3))">
          <span class="necto-tree-twist">${f.twist}</span>
          <span class="necto-tree-name">${f.name}${f.dir ? "<em>/</em>" : ""}</span>
          <span class="necto-tree-meta">${f.meta}</span>
        </button>`).join("")}</div>
    </div>

    <aside class="necto-detail" style="width:300px; border-top:0; border-left:1px solid var(--necto-border)">
      <div class="necto-detail-title">
        <span class="necto-detail-title-url">2026-07-29.json</span>
        <button type="button" class="necto-button necto-button-quiet" aria-label="Close">✕</button>
      </div>
      <div class="necto-detail-body">
        <dl class="necto-pairs">
          <div><dt>Path</dt><dd>Documents/receipts/2026-07-29.json</dd></div>
          <div><dt>Size</dt><dd>980 B</dd></div>
          <div><dt>Modified</dt><dd>2026-07-29 16:38:02</dd></div>
        </dl>
        <p class="necto-section-title">Preview</p>
        <pre class="necto-code">{
  "id": "rcpt_9f8e7d",
  "total": 24900,
  "currency": "KRW"
}</pre>
        <div class="necto-toolbar" style="padding-left:0; padding-right:0; border:0">
          <button type="button" class="necto-button">Save to Mac…</button>
          <button type="button" class="necto-button necto-button-quiet necto-button-danger" style="margin-left:auto">Delete</button>
        </div>
      </div>
    </aside>
  </div>`;

const views = [
  { depth: 0, twist: "▾", name: "UIWindow", meta: "393 × 852" },
  { depth: 1, twist: "▾", name: "UINavigationController", meta: "" },
  { depth: 2, twist: "▾", name: "CheckoutViewController", meta: "" },
  { depth: 3, twist: "▾", name: "UIScrollView", meta: "393 × 704" },
  { depth: 4, twist: "▾", name: "UIStackView", meta: "361 × 528" },
  { depth: 5, twist: "", name: "UILabel <em>“Order total”</em>", meta: "112 × 20" },
  { depth: 5, twist: "", name: "CartSummaryView", meta: "361 × 148", on: true },
  { depth: 5, twist: "▸", name: "UIButton <em>“Pay”</em>", meta: "361 × 52" },
  { depth: 3, twist: "", name: "UIVisualEffectView", meta: "393 × 96" },
];

document.getElementById("views").innerHTML = `
  <div class="necto-toolbar">
    <button type="button" class="necto-button">Refresh</button>
    <div class="necto-segmented">
      <button type="button" aria-selected="true">Tree</button>
      <button type="button">Snapshot</button>
    </div>
    <input class="necto-field" type="search" placeholder="Filter by class" aria-label="Filter by class" />
  </div>
  <div style="display:flex; height:420px">
    <div style="flex:1; overflow:auto">
      <div class="necto-tree">${views.map((v) => `
        <button type="button" class="necto-tree-row" aria-selected="${Boolean(v.on)}" style="padding-left:calc(${v.depth} * 14px + var(--necto-space-3))">
          <span class="necto-tree-twist">${v.twist}</span>
          <span class="necto-tree-name">${v.name}</span>
          <span class="necto-tree-meta">${v.meta}</span>
        </button>`).join("")}</div>
    </div>

    <aside class="necto-detail" style="width:320px; border-top:0; border-left:1px solid var(--necto-border)">
      <div class="necto-detail-title">
        <span class="necto-detail-title-url">CartSummaryView</span>
        <button type="button" class="necto-button necto-button-quiet" aria-label="Close">✕</button>
      </div>
      <div class="necto-tabs">
        <button type="button" class="necto-tab" aria-selected="true">Layout</button>
        <button type="button" class="necto-tab">Properties</button>
        <button type="button" class="necto-tab">Constraints</button>
      </div>
      <div class="necto-detail-body">
        <dl class="necto-pairs">
          <div><dt>Frame</dt><dd>16, 248, 361 × 148</dd></div>
          <div><dt>Bounds</dt><dd>0, 0, 361 × 148</dd></div>
          <div><dt>Safe area</dt><dd>0, 0, 0, 0</dd></div>
          <div><dt>Alpha</dt><dd>1.0</dd></div>
          <div><dt>Hidden</dt><dd>false</dd></div>
          <div><dt>Background</dt><dd>systemBackground</dd></div>
        </dl>
        <p class="necto-section-title">Tap or drag on screen</p>
        <div role="button" tabindex="0" aria-label="Tap or drag on screen" style="height:132px; cursor:crosshair; border:1px solid var(--necto-border); border-radius:var(--necto-radius-control); background:var(--necto-base-05); position:relative">
          <div style="position:absolute; left:14%; top:22%; right:14%; height:44%; border:1px solid var(--necto-accent); background:color-mix(in srgb, var(--necto-accent) 12%, transparent)"></div>
        </div>
        <div style="display:flex; flex-wrap:wrap; gap:var(--necto-space-1); margin-top:var(--necto-space-2)">
          <button type="button" class="necto-button necto-button-quiet">Highlight</button>
          <button type="button" class="necto-button necto-button-quiet">Tap</button>
          <button type="button" class="necto-button necto-button-quiet">Hold</button>
          <button type="button" class="necto-button necto-button-quiet">↑</button>
          <button type="button" class="necto-button necto-button-quiet">↓</button>
          <button type="button" class="necto-button necto-button-quiet">←</button>
          <button type="button" class="necto-button necto-button-quiet">→</button>
        </div>
        <div style="display:flex; gap:var(--necto-space-1); margin-top:var(--necto-space-2)">
          <input class="necto-field" type="text" placeholder="Text to enter" aria-label="Text to enter" style="min-width:0" />
          <button type="button" class="necto-button necto-button-quiet">Enter</button>
        </div>
      </div>
    </aside>
  </div>`;

const rules = [
  { on: true, method: "GET", pattern: "api.example.com/v2/cart", status: "200", delay: "0 ms", hits: "12", tone: "ok" },
  { on: true, method: "POST", pattern: "api.example.com/v2/pay", status: "500", delay: "1.2 s", hits: "3", tone: "danger", sel: true },
  { on: false, method: "GET", pattern: "api.example.com/v2/merchants/*", status: "404", delay: "0 ms", hits: "0", tone: "warning" },
  { on: false, method: "ANY", pattern: "cdn.example.com/**", status: "—", delay: "5.0 s", hits: "0", tone: "idle" },
];

document.getElementById("mocks").innerHTML = `
  <div class="necto-toolbar">
    <button type="button" class="necto-switch" role="switch" aria-checked="true" aria-label="Intercept"></button>
    <span class="necto-caption">Intercept</span>
    <input class="necto-field" type="search" placeholder="Filter rules" aria-label="Filter rules" />
    <span class="necto-caption">2 active</span>
    <button type="button" class="necto-button">New rule</button>
  </div>
  <div style="display:flex; height:340px">
    <div style="flex:1; overflow:auto">
      <table class="necto-table">
        <thead><tr>
          <th style="width:52px">On</th><th style="width:64px">Method</th><th>Matches</th>
          <th style="width:64px">Status</th>
          <th class="necto-numeric" style="width:70px">Delay</th>
          <th class="necto-numeric" style="width:56px">Hits</th>
        </tr></thead>
        <tbody>${rules.map((r) => `
          <tr aria-selected="${Boolean(r.sel)}">
            <td><button type="button" class="necto-switch" role="switch" aria-checked="${r.on}" aria-label="Enabled"></button></td>
            <td>${r.method}</td>
            <td>${r.pattern}</td>
            <td><span class="necto-status necto-status-${r.tone}">${r.status}</span></td>
            <td class="necto-numeric">${r.delay}</td>
            <td class="necto-numeric">${r.hits}</td>
          </tr>`).join("")}</tbody>
      </table>
    </div>

    <aside class="necto-detail" style="width:320px; border-top:0; border-left:1px solid var(--necto-border)">
      <div class="necto-detail-title">
        <span class="necto-status necto-status-danger">500</span>
        <span class="necto-detail-title-url">POST api.example.com/v2/pay</span>
        <button type="button" class="necto-button necto-button-quiet" aria-label="Close">✕</button>
      </div>
      <div class="necto-tabs">
        <button type="button" class="necto-tab">Match</button>
        <button type="button" class="necto-tab" aria-selected="true">Response</button>
      </div>
      <div class="necto-detail-body">
        <dl class="necto-pairs">
          <div><dt>Status</dt><dd>500</dd></div>
          <div><dt>Delay</dt><dd><span class="necto-stepper">1200<span class="necto-stepper-unit">ms</span></span></dd></div>
          <div><dt>Content-Type</dt><dd>application/json</dd></div>
        </dl>
        <p class="necto-section-title">Body</p>
        <pre class="necto-code">{
  "error": "card_declined",
  "message": "The card was declined."
}</pre>
        <p class="necto-caption">Enabled rules replace matching responses in the connected app.</p>
      </div>
    </aside>
  </div>`;

document.getElementById("webviews").innerHTML = `
  <div class="necto-toolbar">
    <div class="necto-segmented">
      <button type="button" aria-selected="true">checkout.example.com</button>
      <button type="button">help.example.com</button>
    </div>
    <span class="necto-caption">2 open</span>
    <button type="button" class="necto-button">Reload</button>
  </div>
  <div class="necto-body" style="height:340px; display:flex; flex-direction:column">
    <dl class="necto-pairs" style="padding:var(--necto-space-3)">
      <div><dt>URL</dt><dd>https://checkout.example.com/pay?order=9f8e7d</dd></div>
      <div><dt>Title</dt><dd>Complete your order</dd></div>
      <div><dt>Class</dt><dd>WKWebView · CheckoutWebViewController</dd></div>
      <div><dt>Cookies</dt><dd>4 for this host</dd></div>
    </dl>

    <div style="flex:1; overflow:auto; border-top:1px solid var(--necto-border); padding:var(--necto-space-3); display:flex; flex-direction:column; gap:var(--necto-space-2)">
      <pre class="necto-code">&gt; document.querySelectorAll('[data-testid]').length</pre>
      <pre class="necto-code">7</pre>
      <pre class="necto-code">&gt; window.__CHECKOUT_STATE__.step</pre>
      <pre class="necto-code">"confirm"</pre>
    </div>

    <div class="necto-toolbar" style="border-top:1px solid var(--necto-border); border-bottom:0">
      <input class="necto-field" type="text" aria-label="Evaluate JavaScript" value="window.__CHECKOUT_STATE__.step" style="font-family:var(--necto-font-mono)" />
      <button type="button" class="necto-button necto-button-primary">Run</button>
    </div>
  </div>`;

document.getElementById("device").innerHTML = `
  <div class="necto-body" style="height:340px; padding:var(--necto-space-4); display:flex; flex-direction:column; gap:var(--necto-space-5)">
    <div>
      <p class="necto-section-title">Open a link</p>
      <div style="display:flex; gap:var(--necto-space-2)">
        <input class="necto-field" type="text" aria-label="URL" value="necto-example://checkout?order=9f8e7d" style="flex:1; font-family:var(--necto-font-mono)" />
        <button type="button" class="necto-button necto-button-primary">Open</button>
      </div>
      <p class="necto-caption" style="margin-top:var(--necto-space-2)">Recent: necto-example://logs · necto-example://files</p>
    </div>

    <div>
      <p class="necto-section-title">Screen</p>
      <div style="display:flex; gap:var(--necto-space-2); align-items:center">
        <button type="button" class="necto-button">Take screenshot</button>
        <button type="button" class="necto-button necto-button-danger">Record</button>
        <span class="necto-caption">Saved to ~/Desktop</span>
      </div>
      <p class="necto-caption" style="margin-top:var(--necto-space-2)">Recording is a simulator only capability. A connected device offers the screenshot alone.</p>
    </div>

    <div class="necto-notice">
      <div>
        <span class="necto-notice-title">These act on the device, not on Necto</span>
        <p>Each one is an operation the app declares, so an app that does not want to be driven simply does not declare it.</p>
      </div>
    </div>
  </div>`;
