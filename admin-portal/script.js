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

const state = {
  services: [],
  selectedServiceId: null,
  refreshHandle: null,
};

async function fetchServices() {
  try {
    const response = await fetch("/api/admin/services");
    const data = await response.json();

    if (!response.ok || !data.success) {
      throw new Error(data.message || "Unable to load services");
    }

    state.services = [{ ...BLOCKCHAIN_MENU_ITEM }, ...(data.services || [])];
    if (!state.selectedServiceId && state.services.length > 0) {
      state.selectedServiceId = state.services[0].id;
    }

    renderServices();
    renderViewer();
  } catch (error) {
    showBanner(error.message, false);
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
    item.appendChild(nameButton);

    if (!service.special) {
      const controls = document.createElement("div");
      controls.className = "service-controls";

      const startButton = document.createElement("button");
      startButton.className = "control-btn start";
      startButton.textContent = "Start";
      startButton.type = "button";
      startButton.disabled = service.endpointUp;
      startButton.addEventListener("click", async (event) => {
        event.stopPropagation();
        await controlService(service.id, "start");
      });

      const stopButton = document.createElement("button");
      stopButton.className = "control-btn stop";
      stopButton.textContent = "Stop";
      stopButton.type = "button";
      stopButton.disabled = !service.running;
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
  viewerSubtitleEl.textContent = `${selected.containerName} (${selected.composeService})`;
  externalLinkEl.href = selected.url;
  externalLinkEl.classList.remove("hidden");

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

async function controlService(serviceId, action) {
  try {
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
}

window.addEventListener("load", init);
