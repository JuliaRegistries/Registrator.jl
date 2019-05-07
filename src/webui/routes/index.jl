# Step 1: Home page prompts login.
function index(::HTTP.Request)
    links = map(collect(PROVIDERS)) do p
        link = p.first
        name = p.second.name
        """<a href="$(ROUTES[:AUTH])?provider=$link">Log in to $name</a>"""
    end
    return html(join(links, "<br>"))
end
