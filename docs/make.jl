using Documenter
using Registrator

makedocs(modules=[Registrator],
         sitename="Registrator.jl",
         pages=["Home" => "index.md",
                "Hosting Your Own" => "hosting.md",
                "Using Docker" => "docker.md",
                "Comment Bot" => "commentbot.md",
                "Web UI" => "webui.md"])

deploydocs(repo="github.com/JuliaRegistries/Registrator.jl.git")
