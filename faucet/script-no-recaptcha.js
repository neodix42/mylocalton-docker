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
            messageElement.textContent = "Wallet version: V3R2\nPrivate Key: " + data.prvKey+"\nPublic Key: "+data.pubKey+"\nWalletId: "+data.walletId+"\nAddress: "+data.rawAddress;
            messageElement.className = "message success";
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