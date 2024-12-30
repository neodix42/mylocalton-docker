document.getElementById("submit-btn").addEventListener("click", function () {
    const userInput = document.getElementById("user-input").value;
    getCaptchaResponse()
    .then(function (token) {
        console.log('Received Token:', token);
            fetch("/validateCaptcha", {
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                },
                body: JSON.stringify({
                    token: token, // captchaResponse
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
    })
    .catch(function (error) {
        console.error('Failed to get reCAPTCHA token:', error);
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