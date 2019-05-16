const accept_regex = "([^\\r\\n]*)(\\n|\\r)*.*"

function parse_comment(fncall)
    argind = findfirst(isequal('('), fncall)
    name = fncall[1:(argind - 1)]
    parsed_args = Meta.parse(replace(fncall[argind:end], ";" => ","))
    args, kwargs = Vector{String}(), Dict{Symbol,String}()
    if isa(parsed_args, Expr) && parsed_args.head == :tuple
        started_kwargs = false
        for x in parsed_args.args
            if isa(x, Expr) && (x.head == :kw || x.head == :(=)) && isa(x.args[1], Symbol)
                @assert !haskey(kwargs, x.args[1]) "kwargs must all be unique"
                kwargs[x.args[1]] = string(x.args[2])
                started_kwargs = true
            else
                @assert !started_kwargs "kwargs must come after other args"
                push!(args, string(x))
            end
        end
    elseif isa(parsed_args, Expr) && parsed_args.head == :(=) && isa(parsed_args.args[1], Symbol)
        kwargs[parsed_args.args[1]] = string(parsed_args.args[2])
    else
        push!(args, string(parsed_args))
    end
    return name, args, kwargs
end
