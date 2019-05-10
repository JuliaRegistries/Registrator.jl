# FYI: TagBot (github.com/apps/julia-tagbot) depends on the "Repository", "Version",
# "Commit", and "Patch notes" fields. If you're going to change the format here,
# please ping @christopher-dG or open an issue on TagBot!
function pull_request_contents(;
    registration_type::AbstractString,
    package::AbstractString,
    repo::AbstractString,
    user::AbstractString,
    gitref::AbstractString,
    version::VersionNumber,
    commit::AbstractString,
    patch_notes::AbstractString,
    reviewer::AbstractString="",
    reference::AbstractString="",
    meta::AbstractString="",
)
    title = if isempty(registration_type)
        "Registering: $package v$version"
    else
        "$registration_type: $package v$version"
    end

    # Build the PR body one line at a time.
    lines = [
        "- Registering package: $package",
        "- Repository: $repo",
        "- Created by: $user",
        "- Git reference: $gitref",
        "- Version: v$version",
        "- Commit: $commit",
    ]

    isempty(reviewer) || push!(lines, "- Reviewed by: $reviewer")
    isempty(reference) || push!(lines, "- Reference: $reference")
    isempty(patch_notes) || push!(
        lines,
        "- Patch notes:",
        "<!-- BEGIN PATCH NOTES -->",
        patch_notes,
        "<!-- END PATCH NOTES -->",
        ""
    )
    isempty(meta) || push!(lines, meta)

    return title, strip(join(lines, "\n"))
end
