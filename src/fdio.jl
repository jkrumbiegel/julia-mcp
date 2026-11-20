struct SessionError <: Exception
    msg::String
end

Base.showerror(io::IO, e::SessionError) = print(io, e.msg)

close_fd(fd::RawFD) = ccall(:close, Cint, (Cint,), Base.cconvert(Cint, fd))

mutable struct FDReader
    fd::RawFD
    watcher::FDWatcher
    chunk::Vector{UInt8}
    buffer::Vector{UInt8}
    closed::Bool
end

FDReader(fd::RawFD) = FDReader(fd, FDWatcher(fd, true, false), Vector{UInt8}(undef, 65536), UInt8[], false)

function Base.close(r::FDReader)
    r.closed && return
    r.closed = true
    close(r.watcher)
    close_fd(r.fd)
    return
end

function wait_readable(r::FDReader)
    try
        wait(r.watcher)
        return true
    catch
        return false
    end
end

function read_available!(r::FDReader)
    while !r.closed && wait_readable(r)
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), Base.cconvert(Cint, r.fd), r.chunk, length(r.chunk))
        if n > 0
            append!(r.buffer, view(r.chunk, 1:n))
            return true
        end
        (n == 0 || !(Libc.errno() in (Libc.EAGAIN, Libc.EINTR))) && return false
    end
    return false
end

chomp_cr(line::String) = endswith(line, '\r') ? String(chop(line)) : line

function take_line!(buffer::Vector{UInt8}, len::Int, skip::Int)
    line = String(buffer[1:len])
    deleteat!(buffer, 1:len+skip)
    return chomp_cr(line)
end

function readline_fd(r::FDReader)::Union{Nothing, String}
    while true
        i = findfirst(==(UInt8('\n')), r.buffer)
        i === nothing || return take_line!(r.buffer, i - 1, 1)
        if !read_available!(r)
            return isempty(r.buffer) ? nothing : take_line!(r.buffer, length(r.buffer), 0)
        end
    end
end

function write_fd(fd::RawFD, data::Vector{UInt8})
    offset = 0
    while offset < length(data)
        n = GC.@preserve data ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
            Base.cconvert(Cint, fd), pointer(data, offset + 1), length(data) - offset)
        if n < 0
            Libc.errno() == Libc.EINTR && continue
            throw(SessionError("write failed: " * Libc.strerror(Libc.errno())))
        end
        offset += n
    end
    return
end

write_fd(fd::RawFD, s::String) = write_fd(fd, Vector{UInt8}(codeunits(s)))

mutable struct ChildProcess
    process::Base.Process
    stdin::RawFD
    stdout::FDReader
    reaper::Base.Process
    reaper_pipe::RawFD
    closed::Bool
end

function spawn_merged(argv::Vector{String}, dir::String)
    child_stdin, parent_stdin = Base.link_pipe(false, false)
    parent_stdout, child_stdout = Base.link_pipe(true, false)
    process = try
        spawn_raw(argv, dir, [fd_handle(child_stdin), fd_handle(child_stdout), fd_handle(child_stdout)])
    catch
        close_fd(parent_stdin)
        close_fd(parent_stdout)
        rethrow()
    finally
        close_fd(child_stdin)
        close_fd(child_stdout)
    end
    reaper, reaper_pipe = spawn_orphan_reaper(getpid(process))
    return ChildProcess(process, parent_stdin, FDReader(parent_stdout), reaper, reaper_pipe, false)
end

# The trimmed runtime skips atexit hooks on signals, so a watcher outside the server kills the child
# once the server is gone for any reason; it sees EOF on a pipe only the server holds open.
function spawn_orphan_reaper(child_pid::Integer)
    reaper_stdin, reaper_pipe = Base.link_pipe(false, false)
    script = "while read -r _; do :; done; kill -9 $child_pid 2>/dev/null"
    reaper = try
        spawn_raw(["/bin/sh", "-c", script], "/", [fd_handle(reaper_stdin), IGNORED_HANDLE, IGNORED_HANDLE])
    finally
        close_fd(reaper_stdin)
    end
    return reaper, reaper_pipe
end

fd_handle(fd::RawFD) = (Cint(0x02), UInt(Base.cconvert(Cint, fd)))
const IGNORED_HANDLE = (Cint(0x00), UInt(0))

# Trimmed-down Base._spawn_primitive, which fails --trim=safe (rawhandle on an abstract union, repr in the error path).
function spawn_raw(argv::Vector{String}, dir::String, iohandles::Vector{Tuple{Cint, UInt}})
    cmd = Cmd(Cmd(argv); dir)
    exec = cmd.exec
    GC.@preserve cmd exec iohandles begin
        handle = Libc.malloc(Base._sizeof_uv_process)
        Base.disassociate_julia_struct(handle)
        flags = cmd.flags ⊻ Base.UV_PROCESS_WINDOWS_DISABLE_EXACT_NAME
        Base.iolock_begin()
        err = ccall(:jl_spawn, Int32,
            (Cstring, Ptr{Cstring}, Ptr{Cvoid}, Ptr{Cvoid},
             Ptr{Tuple{Cint, UInt}}, Int,
             UInt32, Ptr{Cstring}, Cstring, Ptr{Bool}, Csize_t,
             UInt32, UInt32, Ptr{Cvoid}),
            exec[1], exec, Base.eventloop(), handle,
            iohandles, length(iohandles),
            flags, C_NULL, dir, C_NULL, 0,
            typemax(UInt32), typemax(UInt32),
            @cfunction(Base.uv_return_spawn, Cvoid, (Ptr{Cvoid}, Int64, Int32)))
        if err != 0
            ccall(:jl_forceclose_uv, Cvoid, (Ptr{Cvoid},), handle)
            Base.iolock_end()
            throw(SessionError(string("could not spawn ", join(argv, ' '), ": ", Base.struverror(err))))
        end
        process = Base.Process(cmd, handle, Task[])
        Base.associate_julia_struct(handle, process)
        Base.iolock_end()
        return process
    end
end

is_running(c::ChildProcess) = process_running(c.process)

function kill_process(p::Base.Process)
    process_running(p) && kill(p, Base.SIGKILL)
    wait(p)
    return
end

function kill_child(c::ChildProcess)
    kill_process(c.process)
    close(c.stdout)
    c.closed && return
    c.closed = true
    kill_process(c.reaper)
    close_fd(c.reaper_pipe)
    close_fd(c.stdin)
    return
end
