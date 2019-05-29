"""
    parse_comment(text::AbstractString) -> (String, Dict{Symbol, String})

Parse a trigger comment with keyword arguments, and return (`name`, `keywords`).
Positional arguments are ignored.

If the input is invalid `(nothing, nothing)` is returned.

Valid input would look like this:

```
<action> key1=val1 key2=val2
--- anything here and below ---
```

The old syntax `action(key1=val1)` is supported for backwards compatibility.
"""
function parse_comment(text::AbstractString)
    # Handling leading ( is easy, but not capturing the closing one is a bit harder.
    text = replace(text, r"[\)\s]+$"m => "")

    captures = match(r"(\w+)\(?\s*(.*)", text)
    if captures === nothing
        @debug "Invalid trigger" text
        return nothing, nothing
    end

    # The first capture is the action.
    action = string(captures[1])

    # The second capture is keyword arguments.
    kwargs = Dict{Symbol, String}()
    foreach(eachmatch(r"([a-zA-Z_]\w*)\s*=\s*([^\s,]+)", captures[2])) do c
        # If the value is a literal string, remove the quotes.
        key = Symbol(c[1])
        val = strip(c[2], [' ', '"'])
        kwargs[key] = val
    end

    # Check that there are no duplicates or other oddities.
    if length(kwargs) != count(isequal('='), captures[2])
        @debug "Invalid trigger arguments" text args=captures[2]
        return nothing, nothing
    end

    return action, kwargs
end
