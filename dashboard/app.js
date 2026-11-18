"use strict";

const TYPES = ["tcp", "udp", "http", "https", "stcp", "sudp", "xtcp", "tcpmux"];
const INTERVAL = 5000;
const WINDOW = 5 * 60 * 1000;
const SVG_NS = "http://www.w3.org/2000/svg";
const $ = (id) => document.getElementById(id);
const state = { proxies: [], clients: [], samples: [], baseline: null, lastUpdate: null,
  paused: false, fetching: false, hasData: false, selected: null, detailRequest: 0 };

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function svgElement(tag, attributes, text) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, String(value));
  if (text !== undefined) node.textContent = text;
  return node;
}

function number(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function count(value) {
  return number(value) === null ? "—" : value.toLocaleString();
}

function bytes(value) {
  if (number(value) === null) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  const unit = value > 0 ? Math.max(0, Math.min(Math.floor(Math.log(value) / Math.log(1024)), units.length - 1)) : 0;
  return `${(value / 1024 ** unit).toLocaleString(undefined, { maximumFractionDigits: unit ? 1 : 0 })} ${units[unit]}`;
}

function time(value) {
  if (!value) return "—";
  const date = new Date(value * 1000);
  return Number.isNaN(date.getTime()) ? "—" : date.toLocaleString();
}

function badge(status) {
  const normalized = status === "online" ? "online" : status === "offline" ? "offline" : "neutral";
  const node = element("span", `status-badge ${normalized}`);
  node.append(element("span", "small-dot"), document.createTextNode(normalized === "neutral" ? "Unknown" : normalized === "online" ? "Online" : "Offline"));
  return node;
}

function setConnection(label, kind) {
  $("connection-label").textContent = label;
  $("connection-badge").className = `status-badge ${kind}`;
}

function setByteStat(id, value) {
  const formatted = bytes(value);
  const [amount, unit] = formatted.split(" ");
  $(id).replaceChildren(document.createTextNode(amount));
  if (unit) $(id).append(element("small", "", unit));
}

function details(container, entries) {
  container.replaceChildren();
  for (const [label, value] of entries) {
    const row = element("div");
    row.append(element("dt", "", label), element("dd", "", value === undefined || value === null || value === "" ? "—" : String(value)));
    container.append(row);
  }
}

async function getJSON(path) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch(path, { credentials: "same-origin", cache: "no-store", signal: controller.signal });
    if (!response.ok) {
      if (response.status === 401) throw new Error("Authentication required. Reload the page and sign in with your dashboard credentials.");
      throw new Error(`Server request failed (HTTP ${response.status}).`);
    }
    return await response.json();
  } catch (error) {
    if (error.name === "AbortError") throw new Error("The server did not respond within 10 seconds.");
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function publicEndpoint(proxy) {
  const config = proxy.conf;
  if (!config) return "Unavailable while offline";
  if (config.remotePort) return `:${config.remotePort}`;
  const domains = Array.isArray(config.customDomains) ? [...config.customDomains] : [];
  if (config.subdomain) domains.push(`${config.subdomain}.${state.subdomainHost || "<server subdomain>"}`);
  if (domains.length) return domains.join(", ");
  if (["stcp", "sudp", "xtcp"].includes(proxy.type)) return "Private visitor access";
  return "—";
}

function renderServer(server) {
  $("stat-clients").textContent = count(server.clientCounts);
  $("stat-connections").textContent = count(server.curConns);
  setByteStat("stat-in", server.totalTrafficIn);
  setByteStat("stat-out", server.totalTrafficOut);
  details($("server-details"), [
    ["FRP version", server.version], ["Tunnel port", server.bindPort],
    ["Heartbeat timeout", number(server.heartbeatTimeout) === null ? "—" : server.heartbeatTimeout <= 0 ? "Disabled" : `${server.heartbeatTimeout} seconds`],
    ["Connection pool limit", server.maxPoolCount],
    ["TLS required", typeof server.tlsForce === "boolean" ? (server.tlsForce ? "Enabled" : "Disabled") : "—"],
  ]);
}

function updateRates(server, now) {
  const incoming = number(server.totalTrafficIn);
  const outgoing = number(server.totalTrafficOut);
  const previous = state.baseline;
  let rateIn = null;
  let rateOut = null;
  // Counter resets and gaps start a new baseline rather than inventing a rate.
  if (previous && incoming !== null && outgoing !== null && now - previous.time <= INTERVAL * 3 && incoming >= previous.incoming && outgoing >= previous.outgoing) {
    const seconds = (now - previous.time) / 1000;
    if (seconds > 0) {
      rateIn = (incoming - previous.incoming) / seconds;
      rateOut = (outgoing - previous.outgoing) / seconds;
    }
  }
  state.baseline = incoming !== null && outgoing !== null ? { time: now, incoming, outgoing } : null;
  state.samples.push({ time: now, incoming: rateIn, outgoing: rateOut });
  state.samples = state.samples.filter((sample) => now - sample.time <= WINDOW);
  $("rate-in").textContent = rateIn === null ? "—" : `${bytes(rateIn)}/s`;
  $("rate-out").textContent = rateOut === null ? "—" : `${bytes(rateOut)}/s`;
  renderRateChart(now);
}

function grid(svg, width, height, maxValue, suffix = "") {
  const left = 65, top = 15, right = width - 16, bottom = height - 30;
  for (let index = 0; index <= 3; index++) {
    const y = top + (bottom - top) * index / 3;
    svg.append(svgElement("line", { x1: left, y1: y, x2: right, y2: y, class: "chart-grid" }));
    svg.append(svgElement("text", { x: left - 10, y: y + 3, "text-anchor": "end", class: "chart-label" }, `${bytes(maxValue * (1 - index / 3))}${suffix}`));
  }
  return { left, top, right, bottom };
}

function renderRateChart(now) {
  const svg = $("rate-chart");
  svg.replaceChildren();
  const valid = state.samples.filter((sample) => sample.incoming !== null);
  const peak = Math.max(1024, ...valid.flatMap((sample) => [sample.incoming, sample.outgoing])) * 1.2;
  const { left, top, right, bottom } = grid(svg, 760, 220, peak, "/s");
  for (let index = 0; index <= 5; index++) {
    const x = left + (right - left) * index / 5;
    svg.append(svgElement("text", { x, y: bottom + 21, "text-anchor": index === 0 ? "start" : index === 5 ? "end" : "middle", class: "chart-label" }, index === 5 ? "Now" : `${5 - index} min ago`));
  }
  for (const [key, color] of [["incoming", "#0d9488"], ["outgoing", "#6487dc"]]) {
    let path = "";
    let segment = false;
    for (const sample of state.samples) {
      if (sample[key] === null) { segment = false; continue; }
      const x = left + (sample.time - now + WINDOW) / WINDOW * (right - left);
      const y = bottom - sample[key] / peak * (bottom - top);
      path += `${segment ? " L" : " M"}${x.toFixed(2)},${y.toFixed(2)}`;
      segment = true;
    }
    if (path) svg.append(svgElement("path", { d: path, stroke: color, class: "chart-line" }));
  }
  $("rate-empty").hidden = valid.length >= 2;
}

function renderProxies() {
  const query = $("proxy-search").value.trim().toLowerCase();
  const status = $("status-filter").value;
  const type = $("type-filter").value;
  const filtered = state.proxies.filter((proxy) =>
    (status === "all" || proxy.status === status) && (type === "all" || proxy.type === type) &&
    `${proxy.name} ${publicEndpoint(proxy)} ${proxy.user || ""} ${proxy.clientID || ""}`.toLowerCase().includes(query));
  const rows = document.createDocumentFragment();
  for (const proxy of filtered) {
    const row = element("tr");
    const name = element("td");
    const label = element("span", "proxy-name", proxy.name);
    label.title = proxy.name;
    name.append(label, element("span", "proxy-meta", proxy.type.toUpperCase()));
    const statusCell = element("td");
    statusCell.append(badge(proxy.status));
    const endpoint = element("td");
    const endpointLabel = element("span", "endpoint", publicEndpoint(proxy));
    endpointLabel.title = publicEndpoint(proxy);
    endpoint.append(endpointLabel);
    const connections = element("td", "number-column", count(proxy.curConns));
    const traffic = element("td", "number-column traffic-pair");
    traffic.append(document.createTextNode(bytes(proxy.todayTrafficIn)), element("span", "", "/"), document.createTextNode(bytes(proxy.todayTrafficOut)));
    const action = element("td");
    const button = element("button", "detail-button", "→");
    button.type = "button";
    button.setAttribute("aria-label", `View details for ${proxy.name}`);
    button.addEventListener("click", () => openDetails(proxy));
    action.append(button);
    row.append(name, statusCell, endpoint, connections, traffic, action);
    rows.append(row);
  }
  $("proxy-rows").replaceChildren(rows);
  $("proxy-count").textContent = count(state.proxies.length);
  $("nav-proxy-count").textContent = count(state.proxies.length);
  const online = state.proxies.filter((proxy) => proxy.status === "online").length;
  $("proxy-health").textContent = `${online} online · ${state.proxies.length - online} offline`;
  $("proxy-empty").hidden = filtered.length > 0;
  $("empty-title").textContent = state.proxies.length ? "No matching tunnels" : "No proxies registered yet";
  $("empty-description").textContent = state.proxies.length ? "Try a different search or clear your filters." : "Start an FRP client and register a proxy to see its connection and traffic information here.";
  $("filtered-count").textContent = `Showing ${filtered.length} of ${state.proxies.length} proxies`;
}

function renderClients() {
  const rows = document.createDocumentFragment();
  const clients = [...state.clients].sort((a, b) => Number(b.online) - Number(a.online) || (b.lastConnectedAt || 0) - (a.lastConnectedAt || 0));
  for (const client of clients) {
    const row = element("tr");
    const identity = element("td");
    identity.append(element("span", "proxy-name", client.hostname || client.clientID || client.user || "Unnamed client"));
    const secondary = [client.user, client.clientID].filter(Boolean).join(" / ");
    if (secondary) identity.append(element("span", "client-identity", secondary));
    const statusCell = element("td");
    statusCell.append(badge(client.online ? "online" : "offline"));
    row.append(identity, statusCell, element("td", "client-address", client.clientIP || "—"), element("td", "", client.version || "—"), element("td", "", time(client.lastConnectedAt)));
    rows.append(row);
  }
  $("client-rows").replaceChildren(rows);
  $("client-record-count").textContent = count(clients.length);
  $("clients-empty").hidden = clients.length > 0;
  $("clients-empty").textContent = "No client connection records yet. Connect an FRP client to get started.";
}

async function refresh() {
  if (state.fetching) return;
  state.fetching = true;
  $("refresh-button").disabled = true;
  try {
    const [server, clients, ...responses] = await Promise.all([
      getJSON("/api/serverinfo"), getJSON("/api/clients"),
      ...TYPES.map((type) => getJSON(`/api/proxy/${type}`)),
    ]);
    if (!Array.isArray(clients) || responses.some((response) => response.proxies != null && !Array.isArray(response.proxies))) throw new Error("The server returned an unsupported dashboard response.");
    state.subdomainHost = server.subdomainHost;
    state.clients = clients;
    state.proxies = responses.flatMap((response, index) => (response.proxies || []).map((proxy) => ({ ...proxy, type: TYPES[index] })));
    state.proxies.sort((a, b) => (a.status === b.status ? a.name.localeCompare(b.name) : a.status === "online" ? -1 : 1));
    const now = Date.now();
    state.lastUpdate = now;
    state.hasData = true;
    document.body.dataset.stale = "false";
    renderServer(server);
    renderProxies();
    renderClients();
    updateRates(server, now);
    $("error-banner").hidden = true;
    $("last-updated").textContent = `Updated ${new Date(now).toLocaleTimeString()}`;
    setConnection(state.paused ? "Updates paused" : "Connected", state.paused ? "neutral" : "online");
    if ($("proxy-dialog").open && state.selected) {
      const selected = state.proxies.find((proxy) => proxy.name === state.selected.name && proxy.type === state.selected.type);
      if (selected) renderProxyDetails(selected);
      else $("detail-status").replaceChildren(element("span", "status-badge neutral", "No longer reported by the server"));
    }
  } catch (error) {
    state.baseline = null;
    document.body.dataset.stale = "true";
    setConnection(state.hasData ? "Data stale" : "Unavailable", "offline");
    $("error-banner").textContent = `${error.message} ${state.hasData ? "Showing the last successful snapshot; displayed values are not current." : "Check the FRP service, dashboard credentials, and network connection."}`;
    $("error-banner").hidden = false;
    $("rate-in").textContent = "—";
    $("rate-out").textContent = "—";
    if (!state.hasData) {
      $("empty-title").textContent = "Unable to load tunnels";
      $("empty-description").textContent = "Proxy information will appear after the connection is restored.";
      $("clients-empty").textContent = "Client information is unavailable while disconnected.";
    }
  } finally {
    state.fetching = false;
    $("refresh-button").disabled = false;
  }
}

function renderProxyDetails(proxy) {
  $("detail-title").textContent = proxy.name;
  $("detail-status").replaceChildren(badge(proxy.status), element("span", "", proxy.type.toUpperCase()));
  const entries = [
    ["Public endpoint", publicEndpoint(proxy)], ["Active connections", count(proxy.curConns)],
    ["Traffic in today", bytes(proxy.todayTrafficIn)], ["Traffic out today", bytes(proxy.todayTrafficOut)],
    ["Last started", proxy.lastStartTime], ["Last closed", proxy.lastCloseTime],
  ];
  if (proxy.user) entries.push(["User", proxy.user]);
  if (proxy.clientID) entries.push(["Client ID", proxy.clientID]);
  details($("proxy-details"), entries);
}

function renderHistory(history) {
  const svg = $("history-chart");
  svg.replaceChildren();
  const peak = Math.max(1024, ...history.flatMap((day) => [day.trafficIn, day.trafficOut])) * 1.15;
  const { left, top, right, bottom } = grid(svg, 560, 240, peak);
  const step = (right - left) / Math.max(1, history.length);
  history.forEach((day, index) => {
    const center = left + step * (index + 0.5);
    for (const [key, offset, color] of [["trafficIn", -11, "#0d9488"], ["trafficOut", 2, "#6487dc"]]) {
      const height = day[key] / peak * (bottom - top);
      const bar = svgElement("rect", { x: center + offset, y: bottom - height, width: 9, height, rx: 2, fill: color, stroke: "none" });
      bar.append(svgElement("title", {}, `${day.date}: ${bytes(day[key])}`));
      svg.append(bar);
    }
    svg.append(svgElement("text", { x: center, y: bottom + 20, "text-anchor": "middle", class: "chart-label" }, day.date.slice(5)));
  });
  const table = element("table");
  const header = element("tr");
  for (const label of ["Server date", "Traffic in", "Traffic out"]) {
    const cell = element("th", "", label);
    cell.scope = "col";
    header.append(cell);
  }
  const head = element("thead");
  head.append(header);
  const body = element("tbody");
  for (const day of [...history].reverse()) {
    const row = element("tr");
    row.append(element("td", "", day.date), element("td", "", bytes(day.trafficIn)), element("td", "", bytes(day.trafficOut)));
    body.append(row);
  }
  table.append(head, body);
  $("history-table").replaceChildren(table);
  $("history-message").hidden = history.length > 0;
  $("history-message").textContent = "No traffic history is available yet.";
}

async function openDetails(proxy) {
  state.selected = proxy;
  const request = ++state.detailRequest;
  renderProxyDetails(proxy);
  $("history-chart").replaceChildren();
  $("history-table").replaceChildren();
  $("history-timestamp").textContent = "";
  $("history-message").textContent = "Loading traffic history…";
  $("history-message").hidden = false;
  if (!$("proxy-dialog").open) $("proxy-dialog").showModal();
  try {
    const response = await getJSON(`/api/v2/proxies/${encodeURIComponent(proxy.name)}/traffic`);
    if (request !== state.detailRequest || !$("proxy-dialog").open) return;
    if (response.code !== 200 || !Array.isArray(response.data?.history)) throw new Error("Traffic history is unavailable for this proxy.");
    renderHistory(response.data.history);
    $("history-timestamp").textContent = `History snapshot at ${new Date().toLocaleTimeString()}. Reopen this panel to update.`;
  } catch (error) {
    if (request !== state.detailRequest) return;
    $("history-message").textContent = error.message;
  }
}

for (const type of TYPES) {
  const option = element("option", "", type.toUpperCase());
  option.value = type;
  $("type-filter").append(option);
}
for (const id of ["proxy-search", "status-filter", "type-filter"]) {
  $(id).addEventListener(id === "proxy-search" ? "input" : "change", () => { if (state.hasData) renderProxies(); });
}
$("refresh-button").addEventListener("click", refresh);
$("pause-button").addEventListener("click", () => {
  state.paused = !state.paused;
  state.baseline = null;
  $("pause-button").setAttribute("aria-pressed", String(state.paused));
  $("pause-label").textContent = state.paused ? "Resume updates" : "Pause updates";
  $("refresh-note").textContent = state.paused ? "Automatic updates paused" : "Updates every 5 seconds";
  if (state.paused) setConnection("Updates paused", "neutral");
  else refresh();
});
$("close-dialog").addEventListener("click", () => $("proxy-dialog").close());
$("proxy-dialog").addEventListener("close", () => { state.selected = null; state.detailRequest++; });
$("proxy-dialog").addEventListener("click", (event) => {
  if (event.target === $("proxy-dialog") && event.clientX < $("proxy-dialog").getBoundingClientRect().left) $("proxy-dialog").close();
});
for (const link of document.querySelectorAll(".nav-link")) {
  link.addEventListener("click", () => {
    document.querySelectorAll(".nav-link").forEach((item) => item.classList.toggle("active", item === link));
  });
}
document.addEventListener("visibilitychange", () => {
  state.baseline = null;
  if (!document.hidden && !state.paused) refresh();
});
renderRateChart(Date.now());
refresh();
setInterval(() => { if (!state.paused && !document.hidden) refresh(); }, INTERVAL);
