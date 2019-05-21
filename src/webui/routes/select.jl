# Step 4: Select a package.
function select(::HTTP.Request)
    body = render_from_file(
               SELECT_TPL,
               route_status=ROUTES[:STATUS],
               route_register=ROUTES[:REGISTER],
               enable_release_notes=REGISTRY[].enable_release_notes,
           )
    return html(body)
end
