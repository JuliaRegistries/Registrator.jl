using Pkg

stdlibs = Pkg.Types.stdlib()

const BUILTIN_PKGS = Dict(v=>string(k) for (k, v) in stdlibs)
