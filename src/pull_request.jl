# FYI: TagBot (github.com/apps/julia-tagbot) depends on the "Repository", "Version",
# "Commit", and "Release notes" fields. If you're going to change the format here,
# please ping @christopher-dG or open an issue on TagBot!
function pull_request_contents(;
    registration_type::AbstractString,
    package::AbstractString,
    repo::AbstractString,
    user::AbstractString,
    version::VersionNumber,
    commit::AbstractString,
    release_notes::AbstractString,
    subdir::AbstractString="",
    gitref::AbstractString="",
    reviewer::AbstractString="",
    reference::AbstractString="",
    meta::AbstractString="",
    description::AbstractString="",
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
        "- Version: v$version",
        "- Commit: $commit",
    ]

    isempty(subdir) || insert!(lines, 3, "- Subdirectory: $subdir")

    isempty(gitref) || push!(lines, "- Git reference: $gitref")
    isempty(reviewer) || push!(lines, "- Reviewed by: $reviewer")
    isempty(reference) || push!(lines, "- Reference: $reference")
    isempty(description) || push!(lines, "- Description: $description")
    isempty(release_notes) || push!(
        lines,
        "- Release notes:",
        "<!-- BEGIN RELEASE NOTES -->",
        "`````",
        release_notes,
        "`````",
        "<!-- END RELEASE NOTES -->",
        ""
    )
    isempty(meta) || push!(lines, meta)

    return title, strip(join(lines, "\n"))
end
