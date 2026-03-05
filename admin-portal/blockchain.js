const nodesBodyEl = document.getElementById("nodes-body");
const statusBannerEl = document.getElementById("status-banner");
const addNodeBtnEl = document.getElementById("add-node-btn");
const startAllBtnEl = document.getElementById("start-all-btn");
const stopAllBtnEl = document.getElementById("stop-all-btn");
const logsModalEl = document.getElementById("logs-modal");
const logsModalTitleEl = document.getElementById("logs-modal-title");
const logsModalContentEl = document.getElementById("logs-modal-content");
const logsModalCloseEl = document.getElementById("logs-modal-close");

const state = {
  nodes: [],
  addInProgress: false,
  logsNodeId: null,
  restartInProgressNodeId: null,
  bulkActionInProgress: false,
  bulkActionType: null,
};

async function fetchBlockchainNodes() {
  try {
    const response = await fetch("/api/admin/blockchain-nodes");
    const data = await response.json();

    if (!response.ok || !data.success) {
      throw new Error(data.message || "Unable to load blockchain nodes");
    }

    state.nodes = data.nodes || [];
    renderNodes(state.nodes);
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    clearBanner();
  } catch (error) {
    showBanner(error.message, false);
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
    detailsCell.title = node.detail || "";

    const actionCell = document.createElement("td");
    const actionsWrapper = document.createElement("div");
    actionsWrapper.className = "action-buttons";

    const startStopSlot = document.createElement("div");
    startStopSlot.className = "action-slot";
    const actionBtn = document.createElement("button");
    actionBtn.className = "action-btn";
    actionBtn.type = "button";
    actionBtn.disabled = state.bulkActionInProgress || state.restartInProgressNodeId !== null;

    if (node.running) {
      actionBtn.textContent = "Stop validator";
      actionBtn.addEventListener("click", async () => {
        await stopValidator(node.id);
      });
    } else {
      actionBtn.textContent = "Start validator";
      actionBtn.classList.add("start");
      actionBtn.addEventListener("click", async () => {
        await startValidator(node.id);
      });
    }

    startStopSlot.appendChild(actionBtn);
    actionsWrapper.appendChild(startStopSlot);

    const restartSlot = document.createElement("div");
    restartSlot.className = "action-slot";
    const restartBtn = document.createElement("button");
    restartBtn.className = "action-btn restart";
    restartBtn.type = "button";
    restartBtn.textContent =
      state.restartInProgressNodeId === node.id ? "Restarting..." : "Restart";
    restartBtn.disabled =
      !node.exists ||
      state.restartInProgressNodeId !== null ||
      state.bulkActionInProgress;
    restartBtn.title = node.exists
      ? "Recreate with verbosity=3"
      : "Container not created";
    restartBtn.addEventListener("click", async () => {
      await restartNode(node.id);
    });
    restartSlot.appendChild(restartBtn);
    actionsWrapper.appendChild(restartSlot);

    const logsSlot = document.createElement("div");
    logsSlot.className = "action-slot";
    const logsBtn = document.createElement("button");
    logsBtn.className = "action-btn logs";
    logsBtn.type = "button";
    logsBtn.textContent = "Show logs";
    logsBtn.disabled = !node.exists || state.bulkActionInProgress;
    logsBtn.title = node.exists ? "Show last 100 lines" : "Container not created";
    logsBtn.addEventListener("click", async () => {
      await openLogs(node.id, node.name);
    });

    logsSlot.appendChild(logsBtn);
    actionsWrapper.appendChild(logsSlot);
    actionCell.appendChild(actionsWrapper);

    row.appendChild(nameCell);
    row.appendChild(statusCell);
    row.appendChild(healthCell);
    row.appendChild(detailsCell);
    row.appendChild(actionCell);

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

function updateAddNodeButton(nodes) {
  const genesisNode = nodes.find((node) => node.id === "genesis");
  const runningValidators = nodes.filter(
    (node) => node.id.startsWith("validator-") && node.running,
  ).length;

  const canAdd = Boolean(genesisNode?.running) && runningValidators < 5;

  addNodeBtnEl.disabled =
    state.addInProgress ||
    state.bulkActionInProgress ||
    state.restartInProgressNodeId !== null ||
    !canAdd;

  if (!genesisNode?.running) {
    addNodeBtnEl.title = "Genesis must be running";
  } else if (runningValidators >= 5) {
    addNodeBtnEl.title = "Maximum validators reached";
  } else {
    addNodeBtnEl.title = "";
  }
}

function updateBulkActionButtons(nodes) {
  const runningNodesCount = nodes.filter((node) => node.running).length;
  const stoppedNodesCount = nodes.filter((node) => !node.running).length;

  const locked =
    state.bulkActionInProgress ||
    state.addInProgress ||
    state.restartInProgressNodeId !== null;

  startAllBtnEl.textContent =
    state.bulkActionInProgress && state.bulkActionType === "start"
      ? "Starting..."
      : "Start all nodes";
  stopAllBtnEl.textContent =
    state.bulkActionInProgress && state.bulkActionType === "stop"
      ? "Stopping..."
      : "Stop all nodes";

  startAllBtnEl.disabled = locked || stoppedNodesCount === 0;
  stopAllBtnEl.disabled = locked || runningNodesCount === 0;

  if (stoppedNodesCount === 0) {
    startAllBtnEl.title = "All nodes are already running";
  } else {
    startAllBtnEl.title = "";
  }

  if (runningNodesCount === 0) {
    stopAllBtnEl.title = "All nodes are already stopped";
  } else {
    stopAllBtnEl.title = "";
  }
}

async function addNode() {
  try {
    state.addInProgress = true;
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);

    const response = await fetch("/api/admin/blockchain-nodes/add-validator", {
      method: "POST",
    });
    const data = await response.json();

    if (!response.ok || !data.success) {
      throw new Error(data.message || "Failed to add validator");
    }

    showBanner(data.message || "Validator added", true);
    await fetchBlockchainNodes();
  } catch (error) {
    showBanner(error.message, false);
  } finally {
    state.addInProgress = false;
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
  }
}

async function stopValidator(nodeId) {
  try {
    const data = await requestStopNode(nodeId);

    showBanner(data.message || "Node stopped", true);
    await fetchBlockchainNodes();
  } catch (error) {
    showBanner(error.message, false);
  }
}

async function startValidator(nodeId) {
  try {
    const data = await requestStartNode(nodeId);

    showBanner(data.message || "Node started", true);
    await fetchBlockchainNodes();
  } catch (error) {
    showBanner(error.message, false);
  }
}

async function restartNode(nodeId) {
  try {
    state.restartInProgressNodeId = nodeId;
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);

    const response = await fetch(`/api/admin/blockchain-nodes/${encodeURIComponent(nodeId)}/restart`, {
      method: "POST",
    });
    const data = await response.json();

    if (!response.ok || !data.success) {
      throw new Error(data.message || `Failed to restart ${nodeId}`);
    }

    showBanner(data.message || "Node restarted", true);
    await fetchBlockchainNodes();
  } catch (error) {
    showBanner(error.message, false);
  } finally {
    state.restartInProgressNodeId = null;
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);
  }
}

async function requestStartNode(nodeId) {
  const response = await fetch(`/api/admin/blockchain-nodes/${encodeURIComponent(nodeId)}/start-validator`, {
    method: "POST",
  });
  const data = await response.json();

  if (!response.ok || !data.success) {
    throw new Error(data.message || `Failed to start ${nodeId}`);
  }
  return data;
}

async function requestStopNode(nodeId) {
  const response = await fetch(
    `/api/admin/blockchain-nodes/${encodeURIComponent(nodeId)}/remove-validator`,
    {
      method: "POST",
    },
  );
  const data = await response.json();

  if (!response.ok || !data.success) {
    throw new Error(data.message || `Failed to stop ${nodeId}`);
  }
  return data;
}

function extractNodeIndex(nodeId) {
  if (nodeId === "genesis") {
    return 0;
  }

  const validatorMatch = /^validator-(\d+)$/.exec(nodeId);
  if (!validatorMatch) {
    return Number.MAX_SAFE_INTEGER;
  }
  return Number.parseInt(validatorMatch[1], 10);
}

async function startAllNodes() {
  try {
    state.bulkActionInProgress = true;
    state.bulkActionType = "start";
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);

    const nodesToStart = state.nodes
      .filter((node) => !node.running)
      .sort((left, right) => extractNodeIndex(left.id) - extractNodeIndex(right.id));

    const startResults = await Promise.allSettled(
      nodesToStart.map((node) => requestStartNode(node.id)),
    );

    const failedStarts = startResults.filter((result) => result.status === "rejected");
    if (failedStarts.length > 0) {
      throw new Error(`${failedStarts.length} node(s) failed to start`);
    }

    showBanner(`Started ${nodesToStart.length} node(s)`, true);
    await fetchBlockchainNodes();
  } catch (error) {
    showBanner(`Failed to start all nodes: ${error.message}`, false);
  } finally {
    state.bulkActionInProgress = false;
    state.bulkActionType = null;
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);
  }
}

async function stopAllNodes() {
  try {
    state.bulkActionInProgress = true;
    state.bulkActionType = "stop";
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);

    const nodesToStop = state.nodes
      .filter((node) => node.running)
      .sort((left, right) => {
        if (left.id === "genesis") {
          return 1;
        }
        if (right.id === "genesis") {
          return -1;
        }
        return extractNodeIndex(right.id) - extractNodeIndex(left.id);
      });

    const stopResults = await Promise.allSettled(
      nodesToStop.map((node) => requestStopNode(node.id)),
    );

    const failedStops = stopResults.filter((result) => result.status === "rejected");
    if (failedStops.length > 0) {
      throw new Error(`${failedStops.length} node(s) failed to stop`);
    }

    showBanner(`Stopped ${nodesToStop.length} node(s)`, true);
    await fetchBlockchainNodes();
  } catch (error) {
    showBanner(`Failed to stop all nodes: ${error.message}`, false);
  } finally {
    state.bulkActionInProgress = false;
    state.bulkActionType = null;
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);
  }
}

async function openLogs(nodeId, nodeName) {
  try {
    state.logsNodeId = nodeId;
    showLogsModal(nodeName, "Loading logs...");

    const response = await fetch(`/api/admin/blockchain-nodes/${encodeURIComponent(nodeId)}/logs`);
    const data = await response.json();

    if (!response.ok || !data.success) {
      throw new Error(data.message || `Failed to load logs for ${nodeId}`);
    }

    logsModalContentEl.textContent = data.logs || "No logs available.";
  } catch (error) {
    logsModalContentEl.textContent = error.message;
  }
}

function showLogsModal(nodeName, content) {
  logsModalTitleEl.textContent = `${nodeName} logs`;
  logsModalContentEl.textContent = content;
  logsModalEl.classList.add("show");
  logsModalEl.setAttribute("aria-hidden", "false");
}

function closeLogsModal() {
  state.logsNodeId = null;
  logsModalEl.classList.remove("show");
  logsModalEl.setAttribute("aria-hidden", "true");
}

function showBanner(message, ok) {
  statusBannerEl.textContent = message;
  statusBannerEl.className = `status-banner show ${ok ? "ok" : "error"}`;
}

function clearBanner() {
  statusBannerEl.className = "status-banner";
  statusBannerEl.textContent = "";
}

function init() {
  addNodeBtnEl.addEventListener("click", addNode);
  startAllBtnEl.addEventListener("click", startAllNodes);
  stopAllBtnEl.addEventListener("click", stopAllNodes);
  logsModalCloseEl.addEventListener("click", closeLogsModal);
  logsModalEl.addEventListener("click", (event) => {
    if (event.target === logsModalEl) {
      closeLogsModal();
    }
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && logsModalEl.classList.contains("show")) {
      closeLogsModal();
    }
  });
  fetchBlockchainNodes();
  setInterval(fetchBlockchainNodes, 10000);
}

window.addEventListener("load", init);
