<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Registrator</title>
    <style>
      body {
        background-color: #ddd;
        text-align: center;
        margin: auto;
        max-width: 50em;
        font-family: Helvetica, sans-serif;
        line-height: 1.8;
        color: #333;
      }
      a {
        color: inherit;
      }
      h3, h4 {
        color: #555;
      }
    </style>
  </head>
  <body>
    <h1><a href="{{{:route_index}}}">Registrator</a></h1>
    <h4>Registry URL: <a href="{{{:registry_url}}}" target="_blank">{{{:registry_url}}}</a></h4>
    <h3>Click <a href="{{{:docs_url}}}" target="_blank">here</a> for usage instructions</h3>
    <br>
    {{{:body}}}
  </body>
</html>
