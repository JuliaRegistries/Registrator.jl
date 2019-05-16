# Step 4: Select a package.
function select(::HTTP.Request)
    body = """
        <script>
        function poll_status(id) {
          var xhr = new XMLHttpRequest();
          xhr.open('GET', '$(ROUTES[:STATUS])?id='+encodeURIComponent(id));
          xhr.setRequestHeader('Content-Type', 'text/json');
          xhr.onload = function() {
            data = JSON.parse(xhr.responseText);
            div = document.getElementById("reg-form");

            var text = ""
            if (xhr.status === 200) {
              st = data["state"];
              if (st == "success") {
                console.log("Registration is done");
                text = data["message"];
              } else if (st == "errored") {
                console.log("Registration errored");
                text = "ERROR: " + data["message"];
              } else if (st == "pending") {
                console.log("Registration pending");
                text = data["message"];
                setTimeout(function () {poll_status(id);}, 5000);
              } else {
                console.log("Registration unknown state");
                text = "Unknown state returned";
              }
            } else {
              text = "ERROR: " + data["error"];
            }
            div.innerHTML = "<h4>" + text + "</h4>";
          };
          xhr.send();
        }

        /* Call /register and poll for status */
        function do_register() {
          var package = document.getElementById("package").value;
          var ref = document.getElementById("ref").value;
          var notes = document.getElementById("notes").value;
          var button = document.getElementById("submitButton");
          button.disabled = true;
          button.value = "Please wait...";

          var xhr = new XMLHttpRequest();
          xhr.open('POST', '$(ROUTES[:REGISTER])');
          xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
          xhr.onload = function() {
            data = JSON.parse(xhr.responseText);
            div = document.getElementById("reg-form");

            if (xhr.status === 200) {
              console.log("Success sending registration request. Polling for status");
              div.innerHTML = "<h4>" + data["message"] + "</h4>";
              poll_status(data["id"]);
            } else {
              console.log("Error occured while making registration request");
              div.innerHTML = "<h4>ERROR: " + data["error"] + "</h4>";
            }
          };
          xhr.send('package='+encodeURIComponent(package)+'&ref='+ref+'&notes='+encodeURIComponent(notes));
        }
        </script>
        <div id="reg-form">
        URL of package to register: <input type="text" size="50" id="package">
        <br>
        Git reference (branch/tag/commit): <input type="text" size="20" id="ref" value="master">
        <br>
        """

    if REGISTRY[].enable_patch_notes
        body *= """
            Patch notes (optional):
            <br>
            <textarea cols="80" rows="10" id="notes"></textarea>
            <br>
            """
    end

    body *= """
        <button id="submitButton" onclick="do_register()">Submit</button>
        </div>
        """

    return html(body)
end
