function copyTextToClipboard(value, buttonElement) {
    if (!value) {
        return;
    }

    const finalize = function () {
        if (!buttonElement) {
            return;
        }
        buttonElement.classList.add("copied");
        const originalTitle = buttonElement.title;
        buttonElement.title = "Copied";
        setTimeout(function () {
            buttonElement.classList.remove("copied");
            buttonElement.title = originalTitle;
        }, 1200);
    };

    if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(value).then(finalize).catch(function () {
            const helper = document.createElement("textarea");
            helper.value = value;
            document.body.appendChild(helper);
            helper.select();
            document.execCommand("copy");
            document.body.removeChild(helper);
            finalize();
        });
        return;
    }

    const helper = document.createElement("textarea");
    helper.value = value;
    document.body.appendChild(helper);
    helper.select();
    document.execCommand("copy");
    document.body.removeChild(helper);
    finalize();
}

function appendWalletRow(container, label, value, withCopyButton) {
    const row = document.createElement("div");
    row.className = "wallet-result-row";

    const labelEl = document.createElement("span");
    labelEl.className = "wallet-result-label";
    labelEl.textContent = label + ":";
    row.appendChild(labelEl);

    const valueEl = document.createElement("div");
    valueEl.className = "wallet-result-value";

    const valueContentEl = document.createElement("div");
    valueContentEl.className = "wallet-result-value-content";

    const valueInputEl = document.createElement("input");
    valueInputEl.type = "text";
    valueInputEl.className = "wallet-result-input";
    valueInputEl.readOnly = true;
    valueInputEl.value = value || "";
    valueContentEl.appendChild(valueInputEl);

    if (withCopyButton) {
        const copyBtn = document.createElement("button");
        copyBtn.type = "button";
        copyBtn.className = "copy-value-btn";
        copyBtn.title = "Copy " + label;
        copyBtn.setAttribute("aria-label", "Copy " + label);
        copyBtn.style.width = "28px";
        copyBtn.style.minWidth = "28px";
        copyBtn.style.height = "28px";
        copyBtn.style.padding = "0";
        copyBtn.style.display = "inline-flex";
        copyBtn.style.alignItems = "center";
        copyBtn.style.justifyContent = "center";
        copyBtn.style.flex = "0 0 28px";
        copyBtn.style.background = "#ffffff";
        copyBtn.style.border = "1px solid #c7d2e0";
        copyBtn.style.borderRadius = "4px";
        copyBtn.style.fontSize = "0";
        copyBtn.style.lineHeight = "0";
        copyBtn.innerHTML = "<svg width=\"12\" height=\"12\" viewBox=\"0 0 24 24\" fill=\"currentColor\" aria-hidden=\"true\"><path d=\"M16 1H6a2 2 0 0 0-2 2v12h2V3h10V1zm3 4H10a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2zm0 16H10V7h9v14z\"/></svg>";
        copyBtn.addEventListener("click", function () {
            copyTextToClipboard(value, copyBtn);
        });
        valueContentEl.appendChild(copyBtn);
    } else {
        const spacer = document.createElement("span");
        spacer.className = "copy-value-spacer";
        valueContentEl.appendChild(spacer);
    }

    valueEl.appendChild(valueContentEl);
    row.appendChild(valueEl);

    container.appendChild(row);
}

function renderGeneratedWalletResult(messageElement, data) {
    messageElement.className = "message success wallet-result";
    messageElement.innerHTML = "";

    appendWalletRow(messageElement, "Wallet version", "V3R2", false);
    appendWalletRow(messageElement, "Private Key", data.prvKey, true);
    appendWalletRow(messageElement, "Public Key", data.pubKey, true);
    appendWalletRow(messageElement, "WalletId", String(data.walletId || ""), false);
    appendWalletRow(messageElement, "Address", data.rawAddress, true);
}

document.getElementById("submit-btn").addEventListener("click", function () {
    const userAddress = document.getElementById("userAddress1").value;
    const messageElement = document.getElementById("message1");
    fetch("/requestTons", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            userAddress1: userAddress
        }),
    })
    .then((response) => response.json())
    .then((data) => {
        if (data.success) {
            messageElement.textContent = data.message;
            messageElement.className = "message success";
        } else {
            messageElement.textContent = data.message;
            messageElement.className = "message error";
        }
    })
    .catch((error) => {
        console.error("Error:", error);
        messageElement.textContent = "Something went wrong";
        messageElement.className = "message error";
    });
});

document.getElementById("getBalanceBtn").addEventListener("click", function () {
    const userAddress = document.getElementById("userAddress2").value;
    const messageElement = document.getElementById("message2");

    fetch("/getBalance", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({ userAddress2: userAddress }),
    })
    .then((response) => response.json())
    .then((data) => {
        if (data.success) {
            messageElement.textContent = "Balance: " + data.message;
            messageElement.className = "message success";
        } else {
            console.error(data.message);
            messageElement.textContent = data.message;
            messageElement.className = "message error";
        }
    })
    .catch((error) => {
        console.error("Error:", error);
        messageElement.textContent = "Something went wrong";
        messageElement.className = "message error";
    });
});


document.getElementById("generateWalletBtn").addEventListener("click", function () {
    const messageElement = document.getElementById("message3");

    fetch("/generateWallet", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({}),
    })
    .then((response) => response.json())
    .then((data) => {
        if (data.success) {
            renderGeneratedWalletResult(messageElement, data);
        } else {
            messageElement.textContent = data.message;
            messageElement.className = "message error";
        }
    })
    .catch((error) => {
        console.error("Error:", error);
        messageElement.textContent = "Something went wrong.";
        messageElement.className = "message error";
    });
});
