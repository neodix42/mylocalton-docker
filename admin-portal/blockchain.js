const nodesBodyEl = document.getElementById("nodes-body");
const statusBannerEl = document.getElementById("status-banner");

async function fetchBlockchainNodes() {
  try {
    const response = await fetch("/api/admin/blockchain-nodes");
    const data = await response.json();

    if (!response.ok || !data.success) {
      throw new Error(data.message || "Unable to load blockchain nodes");
    }

    renderNodes(data.nodes || []);
    hideError();
  } catch (error) {
    showError(error.message);
  }
}

function renderNodes(nodes) {
  nodesBodyEl.innerHTML = "";

  nodes.forEach((node) => {
    const row = document.createElement("tr");

    const nameCell = document.createElement("td");
    nameCell.textContent = node.name;

    const statusCell = document.createElement("td");
    statusCell.appendChild(createBadge(node.status));

    const healthCell = document.createElement("td");
    healthCell.appendChild(createBadge(node.health));

    const detailsCell = document.createElement("td");
    detailsCell.textContent = node.detail || "";

    row.appendChild(nameCell);
    row.appendChild(statusCell);
    row.appendChild(healthCell);
    row.appendChild(detailsCell);

    nodesBodyEl.appendChild(row);
  });
}

function createBadge(value) {
  const text = value || "n/a";
  const badge = document.createElement("span");
  const normalized = text.toLowerCase().replace(/\s+/g, "-");

  badge.className = `badge ${normalized}`;
  badge.textContent = text;
  return badge;
}

function showError(message) {
  statusBannerEl.textContent = message;
  statusBannerEl.classList.add("show");
}

function hideError() {
  statusBannerEl.classList.remove("show");
}

function init() {
  fetchBlockchainNodes();
  setInterval(fetchBlockchainNodes, 10000);
}

window.addEventListener("load", init);
