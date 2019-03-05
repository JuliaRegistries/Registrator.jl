CREATE TABLE register_requests (
request_type VARCHAR(20),      -- pull_request, issue, commit_comment
trigger_phrase VARCHAR(255),   -- The phrase used to trigger
pkg_trigger_url VARCHAR(255),  -- URL of what triggered the registration: Link to PR, issue or commit
target_registry VARCHAR(255),  -- URL of registry to which registration is to be made
registry_pr_url VARCHAR(255),  -- URL of the PR on the registry
pkg_repo_name VARCHAR(160),    -- Full repo name of the package
trigger_id VARCHAR(255),       -- The PR or issue number or commit id of the request
creator VARCHAR(50),           -- The user who made the PR or issue
reviewer VARCHAR(50),          -- The user who typed `register()`
sha VARCHAR(255),              -- The SHA on the registerd branch
tree_sha VARCHAR(255),         -- The SHA of the tree object that goes into Versions.toml
cloneurl VARCHAR(255),         -- The url from which to clone the repo
branch VARCHAR(50),            -- Branch of the repo that was registered
version VARCHAR(20),           -- Package version being registered
reg_branch VARCHAR(50),        -- Branch name for PR on registry
time VARCHAR(25)
);

CREATE TABLE approval_requests (
src_registry VARCHAR(255),     -- URL of registry from where approval request came
registry_pr_url VARCHAR(255),  -- URL of the PR from where approval was triggered
time VARCHAR(25)
);
