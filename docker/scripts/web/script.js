document.getElementById("submit-btn").addEventListener("click", function () {
    const userInput = document.getElementById("user-input").value;
    const captchaResponse = grecaptcha.getResponse();

    fetch("/validateCaptcha", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            token: captchaResponse,
            userInput: userInput
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
    const userAddress = document.getElementById("userAddress").value;

    fetch("/getBalance", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({ userAddress: userAddress }),
    })
        .then((response) => response.json())
        .then((data) => {
            console.log("Balance:", data.balance);
            alert("Balance: " + data.balance);
        })
        .catch((error) => console.error("Error:", error));
});