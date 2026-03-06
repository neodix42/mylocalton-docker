const nodesBodyEl = document.getElementById("nodes-body");
const statusBannerEl = document.getElementById("status-banner");
const addNodeBtnEl = document.getElementById("add-node-btn");
const startAllBtnEl = document.getElementById("start-all-btn");
const stopAllBtnEl = document.getElementById("stop-all-btn");
const startOverBtnEl = document.getElementById("start-over-btn");
const cleanupBtnEl = document.getElementById("cleanup-btn");
const cleanupModalEl = document.getElementById("cleanup-modal");
const cleanupConfirmBtnEl = document.getElementById("cleanup-confirm-btn");
const cleanupCancelBtnEl = document.getElementById("cleanup-cancel-btn");
const startOverConfirmModalEl = document.getElementById("start-over-confirm-modal");
const startOverConfirmYesBtnEl = document.getElementById("start-over-confirm-yes-btn");
const startOverConfirmCancelBtnEl = document.getElementById("start-over-confirm-cancel-btn");
const startOverConfigModalEl = document.getElementById("start-over-config-modal");
const startOverConfigBodyEl = document.getElementById("start-over-config-body");
const startOverConfigConfirmBtnEl = document.getElementById("start-over-config-confirm-btn");
const startOverConfigCancelBtnEl = document.getElementById("start-over-config-cancel-btn");
const logsModalEl = document.getElementById("logs-modal");
const logsModalCardEl = document.getElementById("logs-modal-card");
const logsModalTitleEl = document.getElementById("logs-modal-title");
const logsModalContentEl = document.getElementById("logs-modal-content");
const logsModalLoadEarlierEl = document.getElementById("logs-modal-load-earlier");
const logsModalMaximizeEl = document.getElementById("logs-modal-maximize");
const logsModalCloseEl = document.getElementById("logs-modal-close");
const PARENT_BANNER_SOURCE = "ton-blockchain-panel";
const LOGS_PAGE_SIZE = 100;
const LOGS_MAX_LINES = 10000;

const state = {
  nodes: [],
  addInProgress: false,
  logsNodeId: null,
  logsNodeName: "",
  logsTailLines: LOGS_PAGE_SIZE,
  logsLoading: false,
  logsMaximized: false,
  logsBackdropPointerDown: false,
  restartInProgressNodeId: null,
  bulkActionInProgress: false,
  bulkActionType: null,
  cleanupInProgress: false,
  startOverInProgress: false,
  startOverConfigLoading: false,
  startOverVariables: [],
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
    // When embedded in the main admin viewer, parent page already reports fetch issues.
    if (isEmbeddedInViewer()) {
      return;
    }
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
    actionBtn.disabled =
      state.bulkActionInProgress ||
      state.restartInProgressNodeId !== null ||
      state.cleanupInProgress ||
      state.startOverInProgress ||
      state.startOverConfigLoading;

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
      state.bulkActionInProgress ||
      state.cleanupInProgress ||
      state.startOverInProgress ||
      state.startOverConfigLoading;
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
    logsBtn.disabled =
      !node.exists ||
      state.bulkActionInProgress ||
      state.cleanupInProgress ||
      state.startOverInProgress ||
      state.startOverConfigLoading;
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
    state.cleanupInProgress ||
    state.startOverInProgress ||
    state.startOverConfigLoading ||
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
    state.restartInProgressNodeId !== null ||
    state.cleanupInProgress ||
    state.startOverInProgress ||
    state.startOverConfigLoading;

  startAllBtnEl.textContent =
    state.bulkActionInProgress && state.bulkActionType === "start"
      ? "Starting..."
      : "Start all nodes";
  stopAllBtnEl.textContent =
    state.bulkActionInProgress && state.bulkActionType === "stop"
      ? "Stopping..."
      : "Stop all nodes";
  startOverBtnEl.textContent = state.startOverInProgress ? "Starting over..." : "Start over";
  cleanupBtnEl.textContent = state.cleanupInProgress ? "Cleaning..." : "Clean up";

  startAllBtnEl.disabled = locked || stoppedNodesCount === 0;
  stopAllBtnEl.disabled = locked || runningNodesCount === 0;
  startOverBtnEl.disabled = locked;
  cleanupBtnEl.disabled = locked;

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
  state.logsNodeId = nodeId;
  state.logsNodeName = nodeName;
  state.logsTailLines = LOGS_PAGE_SIZE;
  state.logsMaximized = false;
  logsModalCardEl.classList.remove("maximized");
  showLogsModal(nodeName, "Loading logs...");
  await fetchLogsForCurrentNode(false);
}

async function loadEarlierLogs() {
  if (!state.logsNodeId || state.logsLoading) {
    return;
  }

  const nextTail = Math.min(state.logsTailLines + LOGS_PAGE_SIZE, LOGS_MAX_LINES);
  if (nextTail === state.logsTailLines) {
    return;
  }

  state.logsTailLines = nextTail;
  await fetchLogsForCurrentNode(true);
}

async function fetchLogsForCurrentNode(loadingEarlier) {
  if (!state.logsNodeId) {
    return;
  }

  try {
    state.logsLoading = true;
    setLogsModalControls();
    if (loadingEarlier) {
      logsModalLoadEarlierEl.textContent = "Loading...";
    } else {
      logsModalContentEl.textContent = "Loading logs...";
    }

    const response = await fetch(
      `/api/admin/blockchain-nodes/${encodeURIComponent(state.logsNodeId)}/logs?lines=${state.logsTailLines}`,
    );
    const data = await response.json();

    if (!response.ok || !data.success) {
      throw new Error(data.message || `Failed to load logs for ${state.logsNodeId}`);
    }

    logsModalContentEl.textContent = data.logs || "No logs available.";
    if (!loadingEarlier) {
      logsModalContentEl.scrollTop = logsModalContentEl.scrollHeight;
    } else {
      logsModalContentEl.scrollTop = 0;
    }
  } catch (error) {
    logsModalContentEl.textContent = error.message;
  } finally {
    state.logsLoading = false;
    setLogsModalControls();
  }
}

async function cleanUpEnvironment() {
  try {
    closeCleanupModal(true);
    state.cleanupInProgress = true;
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);

    const response = await fetch("/api/admin/blockchain-nodes/cleanup", {
      method: "POST",
    });
    const data = await response.json();

    if (!response.ok || !data.success) {
      throw new Error(data.message || "Cleanup failed");
    }

    const warningsCount = Array.isArray(data.warnings) ? data.warnings.length : 0;
    if (warningsCount > 0) {
      showBanner(`${data.message || "Cleanup finished"} (${warningsCount} warning(s))`, false);
    } else {
      showBanner(data.message || "Cleanup finished", true);
    }

    await fetchBlockchainNodes();
  } catch (error) {
    showBanner(error.message || "Cleanup failed", false);
  } finally {
    state.cleanupInProgress = false;
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);
  }
}

function showStartOverConfirmModal() {
  if (state.cleanupInProgress || state.startOverInProgress || state.startOverConfigLoading) {
    return;
  }

  startOverConfirmModalEl.classList.add("show");
  startOverConfirmModalEl.setAttribute("aria-hidden", "false");
}

function closeStartOverConfirmModal() {
  startOverConfirmModalEl.classList.remove("show");
  startOverConfirmModalEl.setAttribute("aria-hidden", "true");
}

async function openStartOverConfigModal() {
  closeStartOverConfirmModal();
  state.startOverConfigLoading = true;
  updateAddNodeButton(state.nodes);
  updateBulkActionButtons(state.nodes);
  renderNodes(state.nodes);

  startOverConfigBodyEl.innerHTML = "";
  startOverConfigConfirmBtnEl.disabled = true;
  startOverConfigCancelBtnEl.disabled = true;
  const loadingRow = document.createElement("tr");
  const loadingCell = document.createElement("td");
  loadingCell.colSpan = 2;
  loadingCell.textContent = "Loading variables...";
  loadingRow.appendChild(loadingCell);
  startOverConfigBodyEl.appendChild(loadingRow);
  startOverConfigModalEl.classList.add("show");
  startOverConfigModalEl.setAttribute("aria-hidden", "false");

  try {
    const response = await fetch("/api/admin/blockchain-nodes/start-over/variables");
    const data = await response.json();
    if (!response.ok || !data.success) {
      throw new Error(data.message || "Failed to load start-over variables");
    }

    state.startOverVariables = Array.isArray(data.variables) ? data.variables : [];
    renderStartOverConfigRows(state.startOverVariables);
  } catch (error) {
    closeStartOverConfigModal(true);
    showBanner(error.message, false);
  } finally {
    state.startOverConfigLoading = false;
    startOverConfigConfirmBtnEl.disabled = false;
    startOverConfigCancelBtnEl.disabled = false;
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);
  }
}

function renderStartOverConfigRows(variables) {
  startOverConfigBodyEl.innerHTML = "";
  variables.forEach((variable) => {
    const row = document.createElement("tr");

    const nameCell = document.createElement("td");
    nameCell.textContent = variable.name;

    const valueCell = document.createElement("td");
    const input = document.createElement("input");
    input.className = "start-over-config-value-input";
    input.type = "text";
    input.value = variable.value ?? "";
    input.setAttribute("data-var-name", variable.name);
    valueCell.appendChild(input);

    row.appendChild(nameCell);
    row.appendChild(valueCell);
    startOverConfigBodyEl.appendChild(row);
  });
}

function closeStartOverConfigModal(force = false) {
  if (!force && state.startOverInProgress) {
    return;
  }
  startOverConfigModalEl.classList.remove("show");
  startOverConfigModalEl.setAttribute("aria-hidden", "true");
}

function collectStartOverValues() {
  const values = {};
  const inputs = startOverConfigBodyEl.querySelectorAll("input[data-var-name]");
  inputs.forEach((input) => {
    const variableName = input.getAttribute("data-var-name");
    values[variableName] = input.value;
  });
  return values;
}

async function executeStartOver() {
  try {
    state.startOverInProgress = true;
    startOverConfigConfirmBtnEl.disabled = true;
    startOverConfigCancelBtnEl.disabled = true;
    startOverConfigConfirmBtnEl.textContent = "Starting over...";
    closeStartOverConfigModal(true);
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);

    const values = collectStartOverValues();
    const response = await fetch("/api/admin/blockchain-nodes/start-over", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(values),
    });
    const data = await response.json();
    if (!response.ok || !data.success) {
      throw new Error(data.message || "Start over failed");
    }

    const warningsCount = Array.isArray(data.warnings) ? data.warnings.length : 0;
    if (warningsCount > 0) {
      showBanner(`${data.message || "Start over finished"} (${warningsCount} warning(s))`, false);
    } else {
      showBanner(data.message || "Start over finished", true);
    }
    await fetchBlockchainNodes();
  } catch (error) {
    showBanner(error.message || "Start over failed", false);
  } finally {
    state.startOverInProgress = false;
    startOverConfigConfirmBtnEl.disabled = false;
    startOverConfigCancelBtnEl.disabled = false;
    startOverConfigConfirmBtnEl.textContent = "Start over";
    updateAddNodeButton(state.nodes);
    updateBulkActionButtons(state.nodes);
    renderNodes(state.nodes);
  }
}

function showCleanupModal() {
  if (state.cleanupInProgress) {
    return;
  }

  cleanupModalEl.classList.add("show");
  cleanupModalEl.setAttribute("aria-hidden", "false");
}

function closeCleanupModal(force = false) {
  if (!force && state.cleanupInProgress) {
    return;
  }

  cleanupModalEl.classList.remove("show");
  cleanupModalEl.setAttribute("aria-hidden", "true");
}

function showLogsModal(nodeName, content) {
  logsModalTitleEl.textContent = `${nodeName} logs`;
  logsModalContentEl.textContent = content;
  logsModalEl.classList.add("show");
  logsModalEl.setAttribute("aria-hidden", "false");
  setLogsModalControls();
}

function closeLogsModal() {
  state.logsNodeId = null;
  state.logsNodeName = "";
  state.logsTailLines = LOGS_PAGE_SIZE;
  state.logsLoading = false;
  state.logsMaximized = false;
  state.logsBackdropPointerDown = false;
  logsModalCardEl.classList.remove("maximized");
  logsModalEl.classList.remove("show");
  logsModalEl.setAttribute("aria-hidden", "true");
  logsModalContentEl.textContent = "No logs loaded.";
  setLogsModalControls();
}

function toggleLogsModalMaximize() {
  if (!logsModalEl.classList.contains("show")) {
    return;
  }

  state.logsMaximized = !state.logsMaximized;
  logsModalCardEl.classList.toggle("maximized", state.logsMaximized);
  setLogsModalControls();
}

function setLogsModalControls() {
  const hasActiveNode = Boolean(state.logsNodeId);
  const atMaxTail = state.logsTailLines >= LOGS_MAX_LINES;

  logsModalLoadEarlierEl.disabled = !hasActiveNode || state.logsLoading || atMaxTail;
  logsModalLoadEarlierEl.textContent = state.logsLoading ? "Loading..." : "Load earlier logs";
  logsModalLoadEarlierEl.title = atMaxTail ? "Log line limit reached" : "Load 100 more lines from the past";

  logsModalMaximizeEl.disabled = !logsModalEl.classList.contains("show");
  logsModalMaximizeEl.textContent = state.logsMaximized ? "Restore" : "Maximize";
}

function showBanner(message, ok) {
  if (!ok && isEmbeddedInViewer()) {
    notifyParentError(message);
    return;
  }

  statusBannerEl.textContent = message;
  statusBannerEl.className = `status-banner show ${ok ? "ok" : "error"}`;
}

function clearBanner() {
  statusBannerEl.className = "status-banner";
  statusBannerEl.textContent = "";
}

function isEmbeddedInViewer() {
  return window.self !== window.top;
}

function notifyParentError(message) {
  try {
    window.parent.postMessage(
      {
        source: PARENT_BANNER_SOURCE,
        type: "error",
        message,
      },
      "*",
    );
  } catch (_ignored) {
  }
}

function init() {
  addNodeBtnEl.addEventListener("click", addNode);
  startAllBtnEl.addEventListener("click", startAllNodes);
  stopAllBtnEl.addEventListener("click", stopAllNodes);
  startOverBtnEl.addEventListener("click", showStartOverConfirmModal);
  cleanupBtnEl.addEventListener("click", showCleanupModal);
  cleanupConfirmBtnEl.addEventListener("click", cleanUpEnvironment);
  cleanupCancelBtnEl.addEventListener("click", () => closeCleanupModal());
  cleanupModalEl.addEventListener("click", (event) => {
    if (event.target === cleanupModalEl) {
      closeCleanupModal();
    }
  });
  startOverConfirmYesBtnEl.addEventListener("click", openStartOverConfigModal);
  startOverConfirmCancelBtnEl.addEventListener("click", closeStartOverConfirmModal);
  startOverConfirmModalEl.addEventListener("click", (event) => {
    if (event.target === startOverConfirmModalEl) {
      closeStartOverConfirmModal();
    }
  });
  startOverConfigConfirmBtnEl.addEventListener("click", executeStartOver);
  startOverConfigCancelBtnEl.addEventListener("click", () => closeStartOverConfigModal());
  startOverConfigModalEl.addEventListener("click", (event) => {
    if (event.target === startOverConfigModalEl) {
      closeStartOverConfigModal();
    }
  });
  logsModalLoadEarlierEl.addEventListener("click", loadEarlierLogs);
  logsModalMaximizeEl.addEventListener("click", toggleLogsModalMaximize);
  logsModalCloseEl.addEventListener("click", closeLogsModal);
  logsModalEl.addEventListener("pointerdown", (event) => {
    state.logsBackdropPointerDown = event.target === logsModalEl;
  });
  logsModalEl.addEventListener("pointerup", (event) => {
    const shouldClose = state.logsBackdropPointerDown && event.target === logsModalEl;
    state.logsBackdropPointerDown = false;
    if (shouldClose) {
      closeLogsModal();
    }
  });
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") {
      return;
    }

    if (cleanupModalEl.classList.contains("show")) {
      closeCleanupModal();
      return;
    }

    if (startOverConfirmModalEl.classList.contains("show")) {
      closeStartOverConfirmModal();
      return;
    }

    if (startOverConfigModalEl.classList.contains("show")) {
      closeStartOverConfigModal();
      return;
    }

    if (logsModalEl.classList.contains("show")) {
      closeLogsModal();
    }
  });
  setLogsModalControls();
  fetchBlockchainNodes();
  setInterval(fetchBlockchainNodes, 10000);
}

window.addEventListener("load", init);
