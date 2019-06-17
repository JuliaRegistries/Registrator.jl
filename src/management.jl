get_backtrace(ex) = sprint(Base.showerror, ex, catch_backtrace())

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
                @error("Recovering from unknown exception", name, backoff)
                println(get_backtrace(ex))
                sleep(backoff)
                backoff = min(backoffmax, backoff+backoffincrement)
            end
        end
    end
end
