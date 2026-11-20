const DEFAULT_TIMEOUT = 60.0
const STARTUP_TIMEOUT = 120.0
const DEFAULT_JULIA_ARGS = ["--threads=auto"]
const PKG_PATTERN = r"\bPkg\."
const TEMP_SESSION_KEY = "__temp__"
const INIT_ERROR_MARKER = "__JULIA_MCP_INIT_ERROR__"

mutable struct JuliaSession
    env_dir::String
    sentinel::String
    is_temp::Bool
    is_test::Bool
    julia_args::Vector{String}
    julia_cmd::Union{Nothing, String}
    child::Union{Nothing, ChildProcess}
    lock::ReentrantLock
    log::Union{Nothing, IOStream}
end

function JuliaSession(
    env_dir::String, sentinel::String;
    is_temp::Bool = false, is_test::Bool = false,
    julia_args::Vector{String} = DEFAULT_JULIA_ARGS,
    julia_cmd::Union{Nothing, String} = nothing,
    log::Union{Nothing, IOStream} = nothing,
)
    return JuliaSession(env_dir, sentinel, is_temp, is_test, julia_args, julia_cmd, nothing, ReentrantLock(), log)
end

new_sentinel() = "__JULIA_MCP_" * bytes2hex(rand(UInt8, 16)) * "__"

project_path(s::JuliaSession) = s.is_test ? dirname(s.env_dir) : s.env_dir

init_code(s::JuliaSession) = s.is_test ? "using TestEnv; TestEnv.activate()" : nothing

is_alive(s::JuliaSession) = s.child !== nothing && is_running(s.child::ChildProcess)

function shell_split(s::String)
    words = String[]
    current = IOBuffer()
    in_word = false
    quote_char = '\0'
    chars = collect(s)
    i = 1
    while i <= length(chars)
        c = chars[i]
        if quote_char == '\''
            c == '\'' ? (quote_char = '\0') : print(current, c)
        elseif quote_char == '"'
            if c == '"'
                quote_char = '\0'
            elseif c == '\\' && i < length(chars) && chars[i+1] in ('"', '\\', '$', '`')
                i += 1
                print(current, chars[i])
            else
                print(current, c)
            end
        elseif c == '\'' || c == '"'
            quote_char = c
            in_word = true
        elseif c == '\\' && i < length(chars)
            i += 1
            print(current, chars[i])
            in_word = true
        elseif isspace(c)
            in_word && push!(words, String(take!(current)))
            in_word = false
        else
            print(current, c)
            in_word = true
        end
        i += 1
    end
    quote_char == '\0' || throw(SessionError("unbalanced quotes in julia_cmd: " * s))
    in_word && push!(words, String(take!(current)))
    return words
end

function julia_command(s::JuliaSession)
    parts = s.julia_cmd === nothing ? ["julia"] : shell_split(s.julia_cmd::String)
    isempty(parts) && throw(SessionError("julia_cmd is empty"))
    executable = parts[1]
    remaining = parts[2:end]
    has_channel = !isempty(remaining) && startswith(remaining[1], "+")
    channel_args = has_channel ? remaining[1:1] : String[]
    extra_flags = has_channel ? remaining[2:end] : remaining

    if !isabspath(executable)
        resolved = Sys.which(executable)
        resolved === nothing && throw(SessionError(
            "'$executable' not found in PATH. Install Julia from https://julialang.org/downloads/"))
        executable = resolved
    end
    return [executable; channel_args; s.julia_args; extra_flags; "--project=" * project_path(s)]
end

function start!(s::JuliaSession)
    s.child = spawn_merged(julia_command(s), s.env_dir)
    execute_raw(s, "", STARTUP_TIMEOUT)
    execute_raw(s, "try; using Revise; catch; end", STARTUP_TIMEOUT)

    code = init_code(s)
    if code !== nothing
        wrapped = "try; $code; catch __e; print(\"$INIT_ERROR_MARKER\"); showerror(stdout, __e); end"
        out = execute_raw(s, wrapped, nothing)
        if occursin(INIT_ERROR_MARKER, out)
            kill!(s)
            throw(SessionError(string(
                "Failed to initialize environment '", s.env_dir, "' (init code '", code, "'):\n",
                strip(replace(out, INIT_ERROR_MARKER => "")))))
        end
    end
    return s
end

function wrap_user_code(code::String)
    hex = bytes2hex(codeunits(code))
    return "try; Revise.revise(); catch; end;include_string(Main, String(hex2bytes(\"$hex\")));nothing"
end

function clock_time()
    tm = Libc.TmStruct(time())
    return join((string(x; pad = 2) for x in (tm.hour, tm.min, tm.sec)), ':')
end

function log_entry(s::JuliaSession, text::String)
    log = s.log
    log === nothing && return
    write(log, text)
    flush(log)
    return
end

function execute(s::JuliaSession, code::String, timeout::Union{Nothing, Float64})
    lock(s.lock) do
        is_alive(s) || throw(SessionError("Julia session has died unexpectedly"))
        log_entry(s, string("[", clock_time(), "] julia> ", code, "\n"))
        output = execute_raw(s, wrap_user_code(code), timeout)
        isempty(output) || log_entry(s, output * "\n\n")
        output
    end
end

function watchdog(child::ChildProcess, timer::Timer, timed_out::Base.RefValue{Bool})
    try
        wait(timer)
    catch
        return
    end
    timed_out[] = true
    is_running(child) && kill(child.process, Base.SIGKILL)
    close(child.stdout)
    return
end

function sentinel_command(sentinel::String)
    return "flush(stderr); write(stdout, \"\\n\"); println(stdout, \"$sentinel\"); flush(stdout)"
end

function read_until_sentinel(child::ChildProcess, sentinel::String, lines::Vector{String})
    while true
        line = readline_fd(child.stdout)
        line === nothing && return false
        line == sentinel && return true
        push!(lines, line)
    end
end

function execute_raw(s::JuliaSession, code::String, timeout::Union{Nothing, Float64})
    child = s.child
    child === nothing && throw(SessionError("Julia session has not been started"))
    write_fd(child.stdin, string(code, "\n", sentinel_command(s.sentinel), "\n"))

    lines = String[]
    timed_out = Ref(false)
    timer = timeout === nothing ? nothing : Timer(timeout)
    timer === nothing || @async watchdog(child, timer, timed_out)
    found = try
        read_until_sentinel(child, s.sentinel, lines)
    finally
        timer === nothing || close(timer)
    end

    if found
        !isempty(lines) && isempty(lines[end]) && pop!(lines)
        return join(lines, "\n")
    end

    partial = join(lines, "\n")
    kill_child(child)
    if timed_out[]
        msg = "Execution timed out after $(timeout)s. Session killed; it will restart on next call."
        isempty(partial) || (msg *= "\n\nOutput before timeout:\n" * partial)
        throw(SessionError(msg))
    end
    throw(SessionError("Julia process died during execution.\nOutput before death:\n" * partial))
end

function kill!(s::JuliaSession)
    child = s.child
    child === nothing || kill_child(child)
    s.is_temp && isdir(s.env_dir) && rm(s.env_dir; recursive = true, force = true)
    return
end

resolve_path(path::String) = ispath(path) ? realpath(path) : normpath(abspath(path))

struct LogFile
    path::String
    io::IOStream
end

mutable struct SessionManager
    julia_args::Vector{String}
    sessions::Dict{String, JuliaSession}
    create_locks::Dict{String, ReentrantLock}
    log_dir::String
    log_files::Dict{String, LogFile}
end

function SessionManager(julia_args::Vector{String} = DEFAULT_JULIA_ARGS)
    log_dir = mktempdir(; prefix = "julia-mcp-logs-", cleanup = false)
    return SessionManager(julia_args, Dict{String, JuliaSession}(), Dict{String, ReentrantLock}(), log_dir, Dict{String, LogFile}())
end

session_key(env_path::Union{Nothing, String}) = env_path === nothing ? TEMP_SESSION_KEY : resolve_path(env_path)

function log_file!(m::SessionManager, key::String)
    get!(m.log_files, key) do
        safe_name = strip(replace(key, "/" => "_", "\\" => "_"), '_')
        path = joinpath(m.log_dir, (isempty(safe_name) ? "temp" : safe_name) * ".log")
        LogFile(path, open(path, "a"))
    end
end

function reusable_session(m::SessionManager, key::String, julia_cmd::Union{Nothing, String})
    session = get(m.sessions, key, nothing)
    session === nothing && return nothing
    is_alive(session) && session.julia_cmd == julia_cmd && return session
    kill!(session)
    delete!(m.sessions, key)
    return nothing
end

function get_or_create!(m::SessionManager, env_path::Union{Nothing, String}; julia_cmd::Union{Nothing, String} = nothing)
    key = session_key(env_path)
    create_lock = get!(ReentrantLock, m.create_locks, key)
    lock(create_lock) do
        existing = reusable_session(m, key, julia_cmd)
        existing === nothing || return existing

        is_temp = env_path === nothing
        env_dir = is_temp ? mktempdir(; prefix = "julia-mcp-", cleanup = false) : key
        session = JuliaSession(env_dir, new_sentinel();
            is_temp, is_test = !is_temp && basename(env_dir) == "test",
            julia_args = m.julia_args, julia_cmd, log = log_file!(m, key).io)
        try
            start!(session)
        catch
            kill!(session)
            rethrow()
        end
        m.sessions[key] = session
        session
    end
end

function restart!(m::SessionManager, env_path::Union{Nothing, String})
    key = session_key(env_path)
    session = get(m.sessions, key, nothing)
    session === nothing && return false
    kill!(session)
    delete!(m.sessions, key)
    return true
end

function drop_dead_session!(m::SessionManager, env_path::Union{Nothing, String})
    key = session_key(env_path)
    session = get(m.sessions, key, nothing)
    if session !== nothing && !is_alive(session)
        kill!(session)
        delete!(m.sessions, key)
    end
    return
end

struct SessionInfo
    env_path::String
    alive::Bool
    temp::Bool
    julia_cmd::Union{Nothing, String}
    log_file::Union{Nothing, String}
end

function list_sessions(m::SessionManager)
    return [
        SessionInfo(s.env_dir, is_alive(s), s.is_temp, s.julia_cmd,
            haskey(m.log_files, key) ? m.log_files[key].path : nothing)
        for (key, s) in sort!(collect(m.sessions); by = first)
    ]
end

function shutdown!(m::SessionManager)
    foreach(kill!, values(m.sessions))
    empty!(m.sessions)
    foreach(f -> close(f.io), values(m.log_files))
    empty!(m.log_files)
    rm(m.log_dir; recursive = true, force = true)
    return
end

