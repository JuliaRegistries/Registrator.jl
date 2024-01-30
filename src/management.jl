function get_log_level(l)
    log_level_str = lowercase(l)

    (log_level_str == "debug") ? Logging.Debug :
    (log_level_str == "info")  ? Logging.Info  :
    (log_level_str == "warn")  ? Logging.Warn  : Logging.Error
end

function status_monitor(
    wait_and_close::Function,
    stop_file::AbstractString,
    running_check::Function,
)
    while running_check()
        sleep(5)
        flush(stdout); flush(stderr);
        # stop server if stop is requested
        if isfile(stop_file)
            @warn "Server stop requested."
            flush(stdout); flush(stderr)

            # stop accepting new requests
            wait_and_close()

            rm(stop_file; force=true)
        end
    end
end

function status_monitor(stop_file::AbstractString, zsock::MessageSocket)
    status_monitor(() -> close(zsock.sock), stop_file, () -> isopen(zsock.sock))
end

function status_monitor(
    stop_file::AbstractString,
    event_queue::Channel,
    httpsock::Ref{Sockets.TCPServer},
)
    status_monitor(stop_file, () -> isopen(event_queue)) do
        # wait for queued requests to be processed and close queue
        while isready(event_queue)
            @info "Waiting for queued jobs to finish"
            yield()
        end
        close(httpsock[])
        close(event_queue)
    end
end

function recover(
    name::AbstractString, keep_running::Function,
    do_action::Function, handle_exception::Function;
    backoff=0, backoffmax=120, backoffincrement=1,
)
    while keep_running()
        try
            do_action()
            backoff = 0
        catch ex
            exception_action = handle_exception(ex)
            if exception_action === :exit
                @warn("Stopping", name)
                return
            else # exception_action == :continue
                @error "Recovering from unknown exception" name backoff exception = (ex, catch_backtrace())
                sleep(backoff)
                backoff = min(backoffmax, backoff+backoffincrement)
            end
        end
    end
end

function _normalize_username(str::AbstractString)
    new_str = lowercase(strip(strip(strip(str), '@')))
    return new_str
end

function _usernames_match(str_1::AbstractString, str_2::AbstractString)
    return _normalize_username(str_1) == _normalize_username(str_2)
end

function mention(username_to_ping::AbstractString)
    # TODO: Instead of hard-coding the value of `my_bot_username`, read it from the
    # appropriate configuration location.
    my_bot_username = "JuliaRegistrator"
    if _usernames_match(username_to_ping, my_bot_username)
        msg = "I am not allowed to ping myself!"
        @error msg username_to_ping my_bot_username
        throw(ErrorException(msg))
    end
    return "@$(username_to_ping)"
end
