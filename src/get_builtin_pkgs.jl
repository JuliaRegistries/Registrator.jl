import Pkg: TOML

all_pkgs = Dict()
reg_pkgs = Dict()
regpath = joinpath("/home", "registrator", ".julia", "registries", "General")
cd(regpath)
isvaliddir(d) = isdir(d) && !startswith(d, ".")
for d in readdir()
    if isvaliddir(d)
        for f in readdir(d)
            if isvaliddir(joinpath(d, f))
                pkgfile = joinpath(d, f, "Package.toml")
                if isfile(pkgfile)
                    t = TOML.parsefile(pkgfile)
                    reg_pkgs[f] = t["uuid"]
                else
                    @info("Package file not found for $f")
                end
                depsfile = joinpath(d, f, "Deps.toml")
                if isfile(depsfile)
                    deps = TOML.parsefile(depsfile)
                    for (k, v) in deps
                        for (i, j) in v
                            if !haskey(all_pkgs, i)
                                all_pkgs[i] = j
                            end
                        end
                    end
                end
            end
        end
    end
end

builtin_pkg_names = setdiff(Set(keys(all_pkgs)),Set(keys(reg_pkgs)))
builtin_pkgs = Dict(k=>all_pkgs[k] for k in builtin_pkg_names)
println(builtin_pkgs)
