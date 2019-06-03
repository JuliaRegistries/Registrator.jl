# Step 1: Home page prompts login.
function index(::HTTP.Request)
    links = map(collect(PROVIDERS)) do p
        link = p.first
        name = p.second.name
        """<div class="text-center"><a href="$(ROUTES[:AUTH])?provider=$link" class="cust-btn-style">Log in to $name</a></div>"""
    end
    return html(join(links, "<br>"))
end
