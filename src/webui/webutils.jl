# Get the callback URL with the provider parameter.
callback_url(p::AbstractString) =
    string(CONFIG["server_url"], ROUTES[:CALLBACK], "?provider=", HTTP.escapeuri(p))

# Get a query string parameter from a request.
getquery(r::HTTP.Request, key::AbstractString, default="") =
    get(HTTP.queryparams(HTTP.URI(r.target)), key, default)

# Get a cookie from a request.
function getcookie(r::HTTP.Request, key::AbstractString, default="")
    cookies = HTTP.cookies(r)
    ind = findfirst(c -> c.name == key, cookies)
    return ind === nothing ? default : cookies[ind].value
end

# Return an HTML response.
html(body::AbstractString) = html(200, body)
function html(status::Int, body::AbstractString)
    registry = REGISTRY[].url
    doc = """
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
            <h1><a href="$(ROUTES[:INDEX])">Registrator</a></h1>
            <h4>Registry URL: <a href="$registry" target="_blank">$registry</a></h3>
            <h3>Click <a href="$DOCS" target="_blank">here</a> for usage instructions</h3>
            <br>
            $body
          </body>
        </html>
        """
    return HTTP.Response(status, ["Content-Type" => "text/html"]; body=doc)
end

json(; kwargs...) = json(200; kwargs...)
json(status::Int; kwargs...) = HTTP.Response(status, ["Content-Type" => "text/json"]; body=JSON.json(kwargs))

# Parse an HTML form.
function parseform(s::AbstractString)
    # In forms, '+' represents a space.
    pairs = split(replace(s, "+" => " "), "&")
    return Dict(map(p -> map(strip ∘ HTTP.unescapeuri, split(p, "=")), pairs))
end
