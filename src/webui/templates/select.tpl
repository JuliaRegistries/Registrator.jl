<div id="reg-form">
  <div class="form-group row">
    <label class="col-sm-4 col-form-label">URL of package to register:</label>
    <div class="col-sm-8">
      <input type="text" size="50" id="package" class="form-control">
    </div>
  </div>
  <div class="form-group row">
    <label class="col-sm-4 col-form-label">Git reference (branch/tag/commit):</label>
    <div class="col-sm-8">
      <input type="text" size="20" id="ref" value="master" class="form-control">
    </div>
  </div>
  {{#:enable_release_notes}}
  <div class="form-group row">
    <label class="col-sm-4 col-form-label">Release notes (optional):</label>
    <div class="col-sm-8">
      <textarea cols="80" rows="7" id="notes" class="form-control"></textarea>
    </div>
  </div>
  {{/:enable_release_notes}}
  <button class="btn btn-fresh btn-sm" id="submitButton" onclick="do_register()">Submit</button>
</div>
<script>
  function poll_status(id) {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '{{{:route_status}}}?id='+encodeURIComponent(id));
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
      div.innerHTML = "<div class='text-center'><h4 class='txt-danger'>" + text + "</h4></div>";
    };
    xhr.send();
  }

  /* Call /register and poll for status */
  function do_register() {
    var package = document.getElementById("package").value;
    var ref = document.getElementById("ref").value;
    var elNotes = document.getElementById("notes");
    var notes = elNotes == null ? "" : elNotes.value;
    var button = document.getElementById("submitButton");
    button.disabled = true;
    button.innerHTML = "Please wait...";

    var xhr = new XMLHttpRequest();
    xhr.open('POST', '{{{:route_register}}}');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onload = function() {
      data = JSON.parse(xhr.responseText);
      div = document.getElementById("reg-form");

      if (xhr.status === 200) {
        console.log("Success sending registration request. Polling for status");
        div.innerHTML = "<div class='text-center'><h4>" + data["message"] + "</h4></div>";
        poll_status(data["id"]);
      } else {
        console.log("Error occured while making registration request");
        div.innerHTML = "<div class='text-center'><h4 class='txt-danger'>ERROR: " + data["error"] + "</h4></div>";
      }
    };
    xhr.send('package='+encodeURIComponent(package)+'&ref='+ref+'&notes='+encodeURIComponent(notes));
  }
</script>
