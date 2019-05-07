abstract type RequestTrigger end
abstract type RegisterTrigger <: RequestTrigger end

struct PullRequestTrigger <: RegisterTrigger
    prid::Int
end

struct IssueTrigger <: RegisterTrigger
    branch::String
end

struct CommitCommentTrigger <: RegisterTrigger
end

struct ApprovalTrigger <: RequestTrigger
    prid::Int
end

struct EmptyTrigger <: RequestTrigger
end
