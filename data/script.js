window.addEventListener("load", function () {
    const messageElement1 = document.getElementById("message1");
    const messageElement2 = document.getElementById("message2");
    const messageElement3 = document.getElementById("message3");

    fetch("/getTps", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({}),
    })
    .then((response) => response.json())
    .then((data) => {
        if (data.success) {
            messageElement1.textContent = data.message;
            messageElement1.className = "message success";
        } else {
            console.error(data.message);
            messageElement1.textContent = data.message;
            messageElement1.className = "message error";
        }
    })
    .catch((error) => {
        console.error("Error:", error);
        messageElement1.textContent = "Something went wrong";
        messageElement1.className = "message error";
    });

    fetch("/getTps1", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({}),
    })
    .then((response) => response.json())
    .then((data) => {
        if (data.success) {
            messageElement2.textContent = data.message;
            messageElement2.className = "message success";
        } else {
            console.error(data.message);
            messageElement2.textContent = data.message;
            messageElement2.className = "message error";
        }
    })
    .catch((error) => {
        console.error("Error:", error);
        messageElement2.textContent = "Something went wrong";
        messageElement2.className = "message error";
    });


    fetch("/getTps5", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({}),
    })
    .then((response) => response.json())
    .then((data) => {
        if (data.success) {
            messageElement3.textContent = data.message;
            messageElement3.className = "message success";
        } else {
            console.error(data.message);
            messageElement3.textContent = data.message;
            messageElement3.className = "message error";
        }
    })
    .catch((error) => {
        console.error("Error:", error);
        messageElement3.textContent = "Something went wrong";
        messageElement3.className = "message error";
    });
});
