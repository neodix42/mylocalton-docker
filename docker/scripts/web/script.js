document.getElementById("submit-btn").addEventListener("click", function () {
    const userAddress = document.getElementById("userAddress1").value;
    const captchaResponse = grecaptcha.getResponse(0);
    fetch("/requestTons", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            token: captchaResponse,
            userAddress1: userAddress
        }),
    })
    .then((response) => response.json())
    .then((data) => {
        if (data.success) {
            alert(data.message);
        } else {
            alert(data.message);
        }
    })
    .catch((error) => {
        console.error("Error:", error);
        alert("Something went wrong.");
    });
});

document.getElementById("getBalanceBtn").addEventListener("click", function () {
    const userAddress = document.getElementById("userAddress2").value;

    fetch("/getBalance", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({ userAddress2: userAddress }),
    })
    .then((response) => response.json())
    .then((data) => {
        alert("Balance: " + data.balance);
    })
    .catch((error) => console.error("Error:", error));
});


document.getElementById("generateWalletBtn").addEventListener("click", function () {
    const captchaResponse = grecaptcha.getResponse(1);
    fetch("/generateWallet", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            token: captchaResponse
        }),
    })
    .then((response) => response.json())
    .then((data) => {
        if (data.success) {
            alert(data.prvKey);
        } else {
            alert(data.message);
        }
    })
    .catch((error) => {
        console.error("Error:", error);
        alert("Something went wrong.");
    });
});