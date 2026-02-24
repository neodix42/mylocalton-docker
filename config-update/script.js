const paramSelect = document.getElementById("paramSelect");
const loadParamBtn = document.getElementById("loadParamBtn");
const submitBtn = document.getElementById("submitBtn");
const editor = document.getElementById("editor");
const statusBox = document.getElementById("status");
const meta = document.getElementById("meta");

let currentParamId = null;
let currentSchema = null;
let currentValue = null;

const api = {
  params: "/api/config/params",
  param: (id) => `/api/config/${id}`,
};

window.addEventListener("load", async () => {
  await loadParamList();
  if (paramSelect.options.length > 0) {
    const param0Option = Array.from(paramSelect.options).find((opt) => opt.value === "0");
    if (param0Option) {
      paramSelect.value = "0";
    } else {
      paramSelect.selectedIndex = 0;
    }
    await loadSelectedParam();
  }
});

loadParamBtn.addEventListener("click", loadSelectedParam);
paramSelect.addEventListener("change", loadSelectedParam);
submitBtn.addEventListener("click", submitUpdate);

async function loadParamList() {
  setStatus("Loading parameters...");
  try {
    const response = await fetch(api.params);
    const data = await response.json();
    if (!data.success) {
      throw new Error(data.message || "Cannot load params");
    }

    paramSelect.innerHTML = "";
    for (const item of data.params) {
      const option = document.createElement("option");
      option.value = String(item.id);
      const paramName = item.name || `ConfigParam${item.id}`;
      const description = item.description ? ` (${item.description})` : "";
      option.textContent = `${item.id} - ${paramName}${description}`;
      paramSelect.appendChild(option);
    }

    setStatus("Parameters loaded.", false);
  } catch (error) {
    setStatus(error.message || String(error), true);
  }
}

async function loadSelectedParam() {
  const id = Number(paramSelect.value);
  if (Number.isNaN(id)) {
    return;
  }

  setStatus(`Loading ConfigParam ${id}...`);
  try {
    const response = await fetch(api.param(id));
    const data = await response.json();
    if (!data.success) {
      throw new Error(data.message || "Cannot load parameter details");
    }

    currentParamId = data.param.id;
    currentSchema = data.param.schema;
    currentValue = data.param.value ?? createDefaultValue(currentSchema);

    meta.textContent = data.param.title;
    renderEditor();
    setStatus(`ConfigParam ${id} loaded.`, false);
  } catch (error) {
    setStatus(error.message || String(error), true);
  }
}

async function submitUpdate() {
  if (currentParamId === null || !currentSchema) {
    return;
  }

  submitBtn.disabled = true;
  setStatus(`Sending update for ConfigParam ${currentParamId}...`);

  try {
    const response = await fetch(api.param(currentParamId), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ value: currentValue }),
    });

    const data = await response.json();
    if (!data.success) {
      throw new Error(data.message || "Update failed");
    }

    const msg = [
      data.message,
      `seqno: ${data.seqno}`,
      `response: ${data.sendResponse}`,
    ].join("\n");
    setStatus(msg, false);
  } catch (error) {
    setStatus(error.message || String(error), true);
  } finally {
    submitBtn.disabled = false;
  }
}

function renderEditor() {
  editor.innerHTML = "";
  if (!currentSchema) {
    return;
  }

  const root = document.createElement("div");
  root.className = "node root-node";
  renderSchema(root, currentSchema, [], null, false);
  editor.appendChild(root);
}

function renderSchema(container, schema, path, label, optional) {
  const value = getAtPath(path);

  const wrapper = document.createElement("div");
  wrapper.className = `node kind-${schema.kind}`;

  if (label) {
    const heading = document.createElement("div");
    heading.className = "field-label";
    heading.textContent = label;
    wrapper.appendChild(heading);
  }

  if (optional) {
    const controls = document.createElement("div");
    controls.className = "optional-controls";

    if (value === null || value === undefined) {
      const addBtn = document.createElement("button");
      addBtn.type = "button";
      addBtn.className = "small-btn";
      addBtn.textContent = "Add";
      addBtn.addEventListener("click", () => {
        setAtPath(path, createDefaultValue(schema));
        renderEditor();
      });
      controls.appendChild(addBtn);
      wrapper.appendChild(controls);
      container.appendChild(wrapper);
      return;
    }

    const removeBtn = document.createElement("button");
    removeBtn.type = "button";
    removeBtn.className = "small-btn danger";
    removeBtn.textContent = "Remove";
    removeBtn.addEventListener("click", () => {
      setAtPath(path, null);
      renderEditor();
    });
    controls.appendChild(removeBtn);
    wrapper.appendChild(controls);
  }

  switch (schema.kind) {
    case "bigint":
    case "long":
    case "int": {
      const input = document.createElement("input");
      input.type = "text";
      input.value = value ?? "";
      input.addEventListener("input", (event) => {
        setAtPath(path, event.target.value);
      });
      wrapper.appendChild(input);
      break;
    }

    case "boolean": {
      const checkboxWrap = document.createElement("label");
      checkboxWrap.className = "checkbox-wrap";
      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = Boolean(value);
      checkbox.addEventListener("change", (event) => {
        setAtPath(path, event.target.checked);
      });
      checkboxWrap.appendChild(checkbox);
      const text = document.createElement("span");
      text.textContent = "enabled";
      checkboxWrap.appendChild(text);
      wrapper.appendChild(checkboxWrap);
      break;
    }

    case "unit": {
      const unitText = document.createElement("span");
      unitText.className = "unit-text";
      unitText.textContent = "true";
      wrapper.appendChild(unitText);
      break;
    }

    case "object": {
      const objectValue = ensureObjectAtPath(path, schema);

      for (const field of schema.fields || []) {
        renderSchema(
          wrapper,
          field.schema,
          path.concat(field.name),
          field.label || field.name,
          Boolean(field.optional),
        );
      }
      if (!objectValue._type) {
        objectValue._type = schema.typeName;
      }
      break;
    }

    case "choice": {
      const selected = ensureChoiceAtPath(path, schema);

      const selector = document.createElement("select");
      selector.className = "type-selector";
      for (const option of schema.options || []) {
        const opt = document.createElement("option");
        opt.value = option.typeName;
        opt.textContent = option.typeName;
        selector.appendChild(opt);
      }

      const selectedType = selected?._type || schema.options?.[0]?.typeName;
      selector.value = selectedType;

      selector.addEventListener("change", (event) => {
        const nextOption = (schema.options || []).find(
          (opt) => opt.typeName === event.target.value,
        );
        if (!nextOption) {
          return;
        }
        setAtPath(path, createDefaultValue(nextOption));
        renderEditor();
      });

      wrapper.appendChild(selector);

      const optionSchema = (schema.options || []).find(
        (opt) => opt.typeName === selectedType,
      );
      if (optionSchema) {
        const nested = document.createElement("div");
        nested.className = "nested-choice";
        renderSchema(nested, optionSchema, path, null, false);
        wrapper.appendChild(nested);
      }
      break;
    }

    case "dict": {
      const entries = ensureArrayAtPath(path);

      const list = document.createElement("div");
      list.className = "dict-list";

      entries.forEach((entry, index) => {
        const row = document.createElement("div");
        row.className = "dict-row";

        const keyWrap = document.createElement("div");
        keyWrap.className = "dict-key";
        const keyLabel = document.createElement("div");
        keyLabel.className = "dict-key-label";
        keyLabel.textContent = "key";
        keyWrap.appendChild(keyLabel);

        const keyInput = document.createElement("input");
        keyInput.type = "text";
        keyInput.value = entry.key ?? "";
        keyInput.addEventListener("input", (event) => {
          entry.key = event.target.value;
        });
        keyWrap.appendChild(keyInput);
        row.appendChild(keyWrap);

        if (!schema.unitValue) {
          const valueWrap = document.createElement("div");
          valueWrap.className = "dict-value";
          renderSchema(
            valueWrap,
            schema.value,
            path.concat(index, "value"),
            "value",
            false,
          );
          row.appendChild(valueWrap);
        } else {
          const unitWrap = document.createElement("div");
          unitWrap.className = "dict-value";
          unitWrap.textContent = "value = true";
          row.appendChild(unitWrap);
        }

        const removeBtn = document.createElement("button");
        removeBtn.type = "button";
        removeBtn.className = "small-btn danger";
        removeBtn.textContent = "Remove entry";
        removeBtn.addEventListener("click", () => {
          entries.splice(index, 1);
          renderEditor();
        });
        row.appendChild(removeBtn);

        list.appendChild(row);
      });

      wrapper.appendChild(list);

      const addBtn = document.createElement("button");
      addBtn.type = "button";
      addBtn.className = "small-btn";
      addBtn.textContent = "Add entry";
      addBtn.addEventListener("click", () => {
        entries.push({
          key: "",
          value: schema.unitValue ? true : createDefaultValue(schema.value),
        });
        renderEditor();
      });
      wrapper.appendChild(addBtn);
      break;
    }

    default:
      break;
  }

  container.appendChild(wrapper);
}

function createDefaultValue(schema) {
  switch (schema.kind) {
    case "bigint":
    case "long":
    case "int":
      return "";
    case "boolean":
      return false;
    case "unit":
      return true;
    case "dict":
      return [];
    case "object": {
      const out = { _type: schema.typeName };
      for (const field of schema.fields || []) {
        out[field.name] = field.optional ? null : createDefaultValue(field.schema);
      }
      return out;
    }
    case "choice": {
      const first = (schema.options || [])[0];
      return first ? createDefaultValue(first) : null;
    }
    default:
      return null;
  }
}

function ensureChoiceAtPath(path, schema) {
  let value = getAtPath(path);
  if (!value || typeof value !== "object") {
    value = createDefaultValue(schema);
    setAtPath(path, value);
    return value;
  }

  const selectedType = value._type;
  if (!selectedType && schema.options?.length) {
    value._type = schema.options[0].typeName;
  }
  return value;
}

function ensureObjectAtPath(path, schema) {
  let value = getAtPath(path);
  if (!value || typeof value !== "object") {
    value = createDefaultValue(schema);
    setAtPath(path, value);
  }
  return value;
}

function ensureArrayAtPath(path) {
  let value = getAtPath(path);
  if (!Array.isArray(value)) {
    value = [];
    setAtPath(path, value);
  }
  return value;
}

function getAtPath(path) {
  if (!path || path.length === 0) {
    return currentValue;
  }

  let ref = currentValue;
  for (const part of path) {
    if (ref === null || ref === undefined) {
      return undefined;
    }
    ref = ref[part];
  }
  return ref;
}

function setAtPath(path, value) {
  if (!path || path.length === 0) {
    currentValue = value;
    return;
  }

  let ref = currentValue;
  for (let i = 0; i < path.length - 1; i += 1) {
    const part = path[i];
    if (ref[part] === undefined || ref[part] === null) {
      ref[part] = typeof path[i + 1] === "number" ? [] : {};
    }
    ref = ref[part];
  }

  ref[path[path.length - 1]] = value;
}

function setStatus(message, isError = false) {
  statusBox.textContent = message;
  statusBox.className = isError ? "status error" : "status success";
}
