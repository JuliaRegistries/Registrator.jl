const DEFAULT_HTTP_PORT = 8090
const DEFAULT_HTTP_IP = "0.0.0.0"
const CYCLE_INTERVAL = 60

const events = ["pull_request", "push", "ping", "pull_request_review"]

const GITHUB_USER="user"
const GITHUB_TOKEN="xxxx"
const GITHUB_SECRET="xxxxxx"
const GITHUB_APP_ID = "xxxx"
const GITHUB_PRIV_PEM = "xxxx"

const DEV_MODE = true
const DO_CI = false

const REGISTRY="https://github.com/JuliaRegistries/General"
const REGISTRY_BASE_BRANCH="master"
const TRIGGER = r"`register\(.*?\)`"
const REGISTRATOR_REPO = "JuliaComputing/Registrator.jl"
