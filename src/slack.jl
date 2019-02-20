import HTTP.URIs: escapeuri

function post_on_slack_channel(msg)
    try
        HTTP.get("https://slack.com/api/chat.postMessage?token=$SLACK_TOKEN&channel=$SLACK_CHANNEL&as_user=true&text=$(escapeuri(msg))")
    catch ex
        @info("Error while posting to slack channel: $(get_backtrace(ex))")
    end
end
