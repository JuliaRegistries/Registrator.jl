module Messaging

using Serialization, Base64, ZMQ, FileWatching

export sendrecv, recvsend, MessageSocket, RequestSocket, ReplySocket

function send2zmq(sock::Socket, obj)
    buff = IOBuffer()
    serialize(buff, obj)
    data = copy(buff.data)
    send(sock, base64encode(data))
    nothing
end

function recvfromzmq(sock::Socket)
    data = recv(sock, String)
    buff = IOBuffer(base64decode(data))
    deserialize(buff)
end

function request_socket(ep)
    sock = Socket(REQ)
    connect(sock, ep)
    return sock
end

function reply_socket(ep)
    sock = Socket(REP)
    bind(sock, ep)
    return sock
end

abstract type MessageSocket end

"""
A socket for making requests to a ZMQ service.

Parameters:
- `ep="tcp://localhost:5555"`: The endpoint to connect to
"""
mutable struct RequestSocket <: MessageSocket
    sock::Socket
    ep::String

    RequestSocket(ep="tcp://localhost:5555") = new(request_socket(ep), ep)
end

"""
A socket for serving replies to ZMQ clients.

Parameters:
- `ep="tcp://*:5555"`: The endpoint to connect to
"""
mutable struct ReplySocket <: MessageSocket
    sock::Socket
    ep::String

    ReplySocket(ep="tcp://*:5555") = new(reply_socket(ep), ep)
end

function reconnect!(sock::RequestSocket)
    close(sock.sock)
    sock.sock = request_socket(sock.ep)
    nothing
end

function reconnect!(sock::ReplySocket)
    close(sock.sock)
    sock.sock = reply_socket(sock.ep)
    nothing
end

"""
    sendrecv(sock::RequestSocket, obj; timeout::Real=60.0, nretry::Number=Inf)
Send an `::Any` object and wait for reply.

Parameters:
- `sock::RequestSocket`
- `obj::Any`: The object to be sent

Keyword Arguments:
- `timeout::Real=60.0`: Time in seconds to wait for reply
- `nretry::Number=Inf`: Number of retries after timeout

Returns: Returns `nothing` if `nretry`s are up else returns received `::Any` object
"""
function sendrecv(sock::RequestSocket, obj; timeout::Real=60.0, nretry::Number=Inf)
    send2zmq(sock.sock, obj)

    while nretry > 0
        rawfd = RawFD(sock.sock.fd)
        istimedout = false
        try
            event = FileWatching.poll_fd(rawfd, timeout; readable=true)
            istimedout = event.timedout
        catch ex
            @debug "Socket was closed when waiting for reply"
            ex isa EOFError && return nothing
        end

        if istimedout
            @debug "Timeout waiting for reply. Reconnecting..."
            reconnect!(sock)
            send2zmq(sock.sock, obj)
        else
            return recvfromzmq(sock.sock)
        end
        nretry -= 1
    end
    nothing
end

"""
    recvsend(f::Function, sock::ReplySocket)
Receive an ::Any object from a socket, process it and send a reply.

Example:
```
recvsend(repsock) do obj
    obj.x += 5
    obj
end
```

Parameters:
- `f::Function`: A function that accepts the received object and returns the object to send
- `sock::ReplySocket`

Returns:
- `true`: If send was successful after receive
- `false`: If socket was closed during receive
"""
function recvsend(f::Function, sock::ReplySocket)
    # TODO: This should be done in a better way. Reasons why this was not done in a better way:
    # 1) FileWatching.poll_fd does not poll reliable when waiting for a request.
    # 2) zmq_poll hangs the julia process so no other tasks can run
    while isopen(sock.sock) && sock.sock.events & ZMQ.POLLIN != ZMQ.POLLIN
        sleep(5)
    end
    !isopen(sock.sock) && return false
    obj = recvfromzmq(sock.sock)
    sobj = f(obj)
    send2zmq(sock.sock, sobj)
    true
end

end
