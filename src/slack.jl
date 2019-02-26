import HTTP.URIs: escapeuri

function post_on_slack_channel(msg, token, channel)
    try
        HTTP.get("https://slack.com/api/chat.postMessage?token=$token&channel=$channel&as_user=true&text=$(escapeuri(msg))")
    catch ex
        @info("Error while posting to slack channel: $(get_backtrace(ex))")
    end
end
