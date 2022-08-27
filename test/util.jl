function start_server(
        port::Integer,
        logger::Logging.AbstractLogger = Logging.current_logger(),
    )
    # Start the server.
    # TODO: Stop the server when the corresponding test set is done.
    server_task = @async begin
        Logging.with_logger(logger) do
            UI.start_server(Sockets.localhost, port)
        end
    end
    if Base.VERSION >= v"1.7-"
        errormonitor(server_task)
    end
    @info "Starting the server..."
    sleep(10)
    return server_task
end
