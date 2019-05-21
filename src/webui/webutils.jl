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

tplpath(tpl::AbstractString) = joinpath(@__DIR__, "templates", tpl)
const INDEX_TPL = tplpath("index.tpl")
const SELECT_TPL = tplpath("select.tpl")

# Return an HTML response.
html(body::AbstractString) = html(200, body)
function html(status::Int, body::AbstractString)
    registry = REGISTRY[].url
    doc = render_from_file(
              INDEX_TPL,
              route_index=ROUTES[:INDEX],
              registry_url=registry,
              docs_url=DOCS,
              body=body,
          )
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
