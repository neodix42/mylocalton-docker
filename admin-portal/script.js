const serviceListEl = document.getElementById("service-list");
const viewerTitleEl = document.getElementById("viewer-title");
const viewerSubtitleEl = document.getElementById("viewer-subtitle");
const statusBannerEl = document.getElementById("status-banner");
const placeholderEl = document.getElementById("viewer-placeholder");
const frameEl = document.getElementById("service-frame");
const externalLinkEl = document.getElementById("open-external");

const BLOCKCHAIN_MENU_ITEM = {
  id: "ton-blockchain",
  name: "TON Blockchain",
  composeService: "core",
  containerName: "genesis + validators",
  url: "/blockchain.html",
  running: true,
  endpointUp: true,
  exists: true,
  special: true,
};

const SERVICE_DESCRIPTIONS = {
  "file-server":
    "Shared docker volume across all services, exposes file http server on port 8000",
  "data-generator":
    "This service runs various scenarios that generate random load on a blockchain. More info on wiki https://github.com/neodix42/mylocalton-docker/wiki/Data-(traffic-generation)-container",
  "ton-blockchain":
    "TON is a fully decentralized layer-1 blockchain designed by Telegram to onboard billions of users.",
  faucet:
    "This service allows generating a new wallet and top it up with test toncoins.",
  "blockchain-explorer": "Native TON blockchain explorer",
  "time-machine":
    "This service allows taking the snapshots of your local TON blockchain and navigating between them as you like.",
  "config-update":
    "This service allows you to change TON blockchain system parameters in real-time.",
  "ton-center-v2":
    "This is a TonCenter TON HTTP API service provided by the TON Core team. In the Mainnet it is accessible via https://toncenter.com/api/v2/",
  "ton-center-v3":
    "This is a TonCenter TON Indexer V3 service provided by the TON Core team. In the Mainnet it is accessible via https://toncenter.com/api/v3/index.html",
};

const CLICKABLE_SUBTITLE_LINKS = [
  "https://github.com/neodix42/mylocalton-docker/wiki/Data-(traffic-generation)-container",
  "https://toncenter.com/api/v2/",
  "https://toncenter.com/api/v3/index.html",
];
const BOTTOM_MENU_SERVICE_IDS = new Set(["data-generator", "faucet"]);

const state = {
  services: [],
  selectedServiceId: null,
  refreshHandle: null,
  seqnoRefreshHandle: null,
  blockchainActive: false,
  blockchainGenesisRunning: false,
  blockchainSeqnoSubtitle: null,
  seqnoFetchInProgress: false,
  serviceActionInProgress: {},
};

const BLOCKCHAIN_IFRAME_SOURCE = "ton-blockchain-panel";

const PLAY_ICON_SVG =
  '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><polygon points="7,5 19,12 7,19" fill="#22c55e"></polygon></svg>';
const STOP_ICON_SVG =
  '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="6.5" y="6.5" width="11" height="11" rx="1.5" fill="#ef4444"></rect></svg>';

async function fetchServices() {
  try {
    const [servicesResponse, blockchainNodesResponse] = await Promise.all([
      fetch("/api/admin/services"),
      fetch("/api/admin/blockchain-nodes"),
    ]);
    const data = await servicesResponse.json();

    if (!servicesResponse.ok || !data.success) {
      throw new Error(data.message || "Unable to load services");
    }

    state.blockchainActive = false;
    state.blockchainGenesisRunning = false;
    if (blockchainNodesResponse.ok) {
      try {
        const blockchainData = await blockchainNodesResponse.json();
        const nodes = blockchainData.nodes || [];
        state.blockchainActive = nodes.some((node) => node.running);
        state.blockchainGenesisRunning = nodes.some((node) => node.id === "genesis" && node.running);
      } catch (_ignored) {
      }
    }

    if (!state.blockchainGenesisRunning) {
      state.blockchainSeqnoSubtitle = null;
    }

    state.services = orderServicesForMenu([
      { ...BLOCKCHAIN_MENU_ITEM, endpointUp: state.blockchainActive },
      ...(data.services || []),
    ]);
    if (!state.selectedServiceId && state.services.length > 0) {
      state.selectedServiceId = state.services[0].id;
    }

    renderServices();
    renderViewer();
    void fetchTonBlockchainSeqnoSubtitle();
  } catch (error) {
    showBanner(error.message, false);
  }
}

function orderServicesForMenu(services) {
  const top = [];
  const middle = [];
  const bottom = [];

  services.forEach((service) => {
    if (service.id === BLOCKCHAIN_MENU_ITEM.id) {
      top.push(service);
      return;
    }
    if (BOTTOM_MENU_SERVICE_IDS.has(service.id)) {
      bottom.push(service);
      return;
    }
    middle.push(service);
  });

  return [...top, ...middle, ...bottom];
}

async function fetchTonBlockchainSeqnoSubtitle() {
  if (
    !state.blockchainGenesisRunning
    || state.seqnoFetchInProgress
  ) {
    return;
  }

  try {
    state.seqnoFetchInProgress = true;
    const response = await fetch("/api/admin/blockchain-nodes/genesis/latest-seqno");
    const data = await response.json();
    if (!response.ok || !data.success || !data.available || !data.subtitle) {
      if (state.blockchainSeqnoSubtitle !== null) {
        state.blockchainSeqnoSubtitle = null;
        renderServices();
      }
      return;
    }

    if (state.blockchainSeqnoSubtitle !== data.subtitle) {
      state.blockchainSeqnoSubtitle = data.subtitle;
      renderServices();
    }
  } catch (_error) {
    if (state.blockchainSeqnoSubtitle !== null) {
      state.blockchainSeqnoSubtitle = null;
      renderServices();
    }
  } finally {
    state.seqnoFetchInProgress = false;
  }
}

function renderServices() {
  serviceListEl.innerHTML = "";

  state.services.forEach((service) => {
    const item = document.createElement("div");
    item.className = "service-item";
    if (!service.endpointUp && !service.special) {
      item.classList.add("down");
    }
    if (service.special) {
      item.classList.add("special");
    }
    if (service.id === state.selectedServiceId) {
      item.classList.add("active");
    }
    item.addEventListener("click", () => {
      state.selectedServiceId = service.id;
      renderServices();
      renderViewer();
    });

    const nameButton = document.createElement("div");
    nameButton.className = "service-name";
    nameButton.textContent = service.name;

    const statusIcon = document.createElement("span");
    statusIcon.className = "service-status-icon";
    statusIcon.classList.add(service.endpointUp ? "active" : "inactive");
    statusIcon.title = service.endpointUp ? "active" : "inactive";

    item.appendChild(statusIcon);
    item.appendChild(nameButton);

    if (service.id === BLOCKCHAIN_MENU_ITEM.id && state.blockchainSeqnoSubtitle) {
      const subtitle = document.createElement("div");
      subtitle.className = "service-subtitle";
      subtitle.textContent = state.blockchainSeqnoSubtitle;
      item.appendChild(subtitle);
    }

    if (!service.special) {
      const controls = document.createElement("div");
      controls.className = "service-controls";
      const pendingAction = state.serviceActionInProgress[service.id] || null;
      const actionInProgress = pendingAction !== null;

      const startButton = document.createElement("button");
      startButton.className = "control-btn start";
      startButton.innerHTML = PLAY_ICON_SVG;
      startButton.type = "button";
      startButton.classList.toggle("loading", pendingAction === "start");
      startButton.title = pendingAction === "start" ? "Starting..." : "Start";
      startButton.setAttribute(
        "aria-label",
        pendingAction === "start" ? "Starting..." : "Start",
      );
      startButton.disabled = actionInProgress || service.endpointUp;
      startButton.addEventListener("click", async (event) => {
        event.stopPropagation();
        await controlService(service.id, "start");
      });

      const stopButton = document.createElement("button");
      stopButton.className = "control-btn stop";
      stopButton.innerHTML = STOP_ICON_SVG;
      stopButton.type = "button";
      stopButton.classList.toggle("loading", pendingAction === "stop");
      stopButton.title = pendingAction === "stop" ? "Stoping..." : "Stop";
      stopButton.setAttribute(
        "aria-label",
        pendingAction === "stop" ? "Stoping..." : "Stop",
      );
      stopButton.disabled = actionInProgress || !service.running;
      stopButton.addEventListener("click", async (event) => {
        event.stopPropagation();
        await controlService(service.id, "stop");
      });

      controls.appendChild(startButton);
      controls.appendChild(stopButton);
      item.appendChild(controls);
    }

    serviceListEl.appendChild(item);
  });
}

function renderViewer() {
  const selected = state.services.find((service) => service.id === state.selectedServiceId);

  if (!selected) {
    viewerTitleEl.textContent = "Select a service";
    viewerSubtitleEl.textContent = "Choose a service from the menu to open its main page.";
    frameEl.classList.remove("show");
    placeholderEl.style.display = "grid";
    placeholderEl.textContent = "Select a running service to preview it here.";
    externalLinkEl.classList.add("hidden");
    return;
  }

  viewerTitleEl.textContent = selected.name;
  const subtitleText =
    SERVICE_DESCRIPTIONS[selected.id] ||
    `${selected.containerName} (${selected.composeService})`;
  renderViewerSubtitle(subtitleText);
  if (selected.id === BLOCKCHAIN_MENU_ITEM.id) {
    externalLinkEl.classList.add("hidden");
  } else {
    externalLinkEl.href = selected.url;
    externalLinkEl.classList.remove("hidden");
  }

  // TON Blockchain page must always be available, even when genesis/validators are down.
  if (selected.id === BLOCKCHAIN_MENU_ITEM.id) {
    if (frameEl.getAttribute("src") !== selected.url) {
      frameEl.setAttribute("src", selected.url);
    }
    placeholderEl.style.display = "none";
    frameEl.classList.add("show");
    return;
  }

  if (!selected.endpointUp) {
    frameEl.classList.remove("show");
    frameEl.removeAttribute("src");
    placeholderEl.style.display = "grid";
    placeholderEl.textContent = `${selected.name} is not up. Click Start in the left menu.`;
    return;
  }

  if (frameEl.getAttribute("src") !== selected.url) {
    frameEl.setAttribute("src", selected.url);
  }

  placeholderEl.style.display = "none";
  frameEl.classList.add("show");
}

function renderViewerSubtitle(text) {
  viewerSubtitleEl.textContent = "";
  if (!text) {
    return;
  }

  const fragment = document.createDocumentFragment();
  let remaining = text;

  while (remaining.length > 0) {
    let matchUrl = null;
    let matchIndex = -1;

    CLICKABLE_SUBTITLE_LINKS.forEach((url) => {
      const index = remaining.indexOf(url);
      if (index !== -1 && (matchIndex === -1 || index < matchIndex)) {
        matchUrl = url;
        matchIndex = index;
      }
    });

    if (!matchUrl || matchIndex === -1) {
      fragment.appendChild(document.createTextNode(remaining));
      break;
    }

    if (matchIndex > 0) {
      fragment.appendChild(document.createTextNode(remaining.slice(0, matchIndex)));
    }

    const anchor = document.createElement("a");
    anchor.href = matchUrl;
    anchor.textContent = matchUrl;
    anchor.target = "_blank";
    anchor.rel = "noopener noreferrer";
    anchor.className = "viewer-subtitle-link";
    fragment.appendChild(anchor);

    remaining = remaining.slice(matchIndex + matchUrl.length);
  }

  viewerSubtitleEl.appendChild(fragment);
}

async function controlService(serviceId, action) {
  try {
    state.serviceActionInProgress[serviceId] = action;
    renderServices();

    const response = await fetch(`/api/admin/services/${serviceId}/${action}`, {
      method: "POST",
    });
    const data = await response.json();

    if (!response.ok || !data.success) {
      throw new Error(data.message || `Failed to ${action} service`);
    }

    showBanner(data.message || `Service ${action}ed`, true);
    await fetchServices();
  } catch (error) {
    showBanner(error.message, false);
  } finally {
    delete state.serviceActionInProgress[serviceId];
    renderServices();
  }
}

function showBanner(message, ok) {
  statusBannerEl.textContent = message;
  statusBannerEl.className = "status-banner show";
  statusBannerEl.classList.add(ok ? "ok" : "error");

  setTimeout(() => {
    statusBannerEl.className = "status-banner";
  }, 4000);
}

function init() {
  fetchServices();
  state.refreshHandle = setInterval(fetchServices, 10000);
  state.seqnoRefreshHandle = setInterval(fetchTonBlockchainSeqnoSubtitle, 3000);
  window.addEventListener("message", (event) => {
    const data = event.data;
    if (!data || typeof data !== "object") {
      return;
    }
    if (data.source !== BLOCKCHAIN_IFRAME_SOURCE || data.type !== "error") {
      return;
    }
    if (typeof data.message !== "string" || data.message.trim().length === 0) {
      return;
    }
    showBanner(data.message, false);
  });
}

window.addEventListener("load", init);
