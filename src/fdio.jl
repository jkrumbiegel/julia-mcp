struct SessionError <: Exception
    msg::String
end

mutable struct FDReader
    fd::RawFD
    watcher::Union{Nothing, FDWatcher}
    buffer::Vector{UInt8}
    closed::Bool
end

FDReader(fd::RawFD; watch::Bool = true) =
    FDReader(fd, watch ? FDWatcher(fd, true, false) : nothing, UInt8[], false)

function Base.close(r::FDReader)
    r.closed && return
    r.closed = true
    r.watcher === nothing || close(r.watcher)
    ccall(:close, Cint, (Cint,), Base.cconvert(Cint, r.fd))
    return
end

function wait_readable(r::FDReader)
    watcher = r.watcher
    watcher === nothing && return true
    try
        wait(watcher)
        return true
    catch
        return false
    end
end

const RETRY_ERRNOS = (Libc.EAGAIN, Libc.EINTR)

function read_available!(r::FDReader)
    chunk = Vector{UInt8}(undef, 65536)
    while true
        r.closed && return false
        wait_readable(r) || return false
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), Base.cconvert(Cint, r.fd), chunk, length(chunk))
        if n > 0
            append!(r.buffer, view(chunk, 1:n))
            return true
        elseif n == 0 || !(Libc.errno() in RETRY_ERRNOS)
            return false
        end
    end
end

function readline_fd(r::FDReader)::Union{Nothing, String}
    while true
        i = findfirst(==(UInt8('\n')), r.buffer)
        if i !== nothing
            line = String(r.buffer[1:i-1])
            deleteat!(r.buffer, 1:i)
            return chomp_cr(line)
        end
        if !read_available!(r)
            isempty(r.buffer) && return nothing
            line = String(copy(r.buffer))
            empty!(r.buffer)
            return chomp_cr(line)
        end
    end
end

chomp_cr(line::String) = endswith(line, '\r') ? String(chop(line)) : line

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

close_fd(fd::RawFD) = ccall(:close, Cint, (Cint,), Base.cconvert(Cint, fd))

mutable struct ChildProcess
    process::Base.Process
    stdin::RawFD
    stdout::FDReader
    stdin_closed::Bool
end

function spawn_merged(argv::Vector{String}, dir::String)
    child_stdin, parent_stdin = Base.link_pipe(false, false)
    parent_stdout, child_stdout = Base.link_pipe(true, false)
    process = try
        spawn_raw(argv, dir, child_stdin, child_stdout)
    catch
        close_fd(parent_stdin)
        close_fd(parent_stdout)
        rethrow()
    finally
        close_fd(child_stdin)
        close_fd(child_stdout)
    end
    spawn_orphan_reaper(getpid(process))
    return ChildProcess(process, parent_stdin, FDReader(parent_stdout), false)
end

function spawn_orphan_reaper(child_pid::Integer)
    script = "while kill -0 $(getpid()); do kill -0 $child_pid || exit 0; sleep 1; done 2>/dev/null; kill -9 $child_pid"
    reaper = spawn_raw(["/bin/sh", "-c", script], "/", [IGNORED_HANDLE, IGNORED_HANDLE, IGNORED_HANDLE])
    @async wait(reaper)
    return
end

fd_handle(fd::RawFD) = (Cint(0x02), UInt(Base.cconvert(Cint, fd)))
const IGNORED_HANDLE = (Cint(0x00), UInt(0))

function spawn_raw(argv::Vector{String}, dir::String, stdin_fd::RawFD, stdout_fd::RawFD)
    return spawn_raw(argv, dir, [fd_handle(stdin_fd), fd_handle(stdout_fd), fd_handle(stdout_fd)])
end

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

function kill_child(c::ChildProcess)
    process_running(c.process) && kill(c.process, Base.SIGKILL)
    wait(c.process)
    close(c.stdout)
    if !c.stdin_closed
        c.stdin_closed = true
        close_fd(c.stdin)
    end
    return
end
