const DEFAULT_TIMEOUT = 60.0
const DEFAULT_IDLE_TIMEOUT = 72 * 3600.0
const DEFAULT_REAP_INTERVAL = 3600.0
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
    name::Union{Nothing, String}
    cmd::Union{Nothing, Vector{String}}
    child::Union{Nothing, ChildProcess}
    lock::ReentrantLock
    log::Union{Nothing, IOStream}
    last_used::Float64
    revise_loaded::Bool
    pending_notice::Union{Nothing, String}
end

function JuliaSession(
    env_dir::String, sentinel::String;
    is_temp::Bool = false, is_test::Bool = false,
    julia_args::Vector{String} = DEFAULT_JULIA_ARGS,
    julia_cmd::Union{Nothing, String} = nothing,
    name::Union{Nothing, String} = nothing,
    log::Union{Nothing, IOStream} = nothing,
)
    return JuliaSession(env_dir, sentinel, is_temp, is_test, julia_args, julia_cmd, name, nothing, nothing, ReentrantLock(), log, time(), false, nothing)
end

new_sentinel() = "__JULIA_MCP_" * bytes2hex(rand(UInt8, 16)) * "__"

project_path(s::JuliaSession) = s.is_test ? dirname(s.env_dir) : s.env_dir

init_code(s::JuliaSession) = s.is_test ? "using TestEnv; TestEnv.activate()" : nothing

is_alive(s::JuliaSession) = s.child !== nothing && is_running(s.child::ChildProcess)

is_idle(s::JuliaSession, idle_timeout::Float64) = !islocked(s.lock) && time() - s.last_used > idle_timeout

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

shell_quote(word::String) =
    isempty(word) ? "''" : occursin(r"^[A-Za-z0-9@%+=:,./_-]+$", word) ? word : "'" * replace(word, "'" => "'\"'\"'") * "'"

shell_join(words::Vector{String}) = join(map(shell_quote, words), ' ')

normalize_julia_cmd(julia_cmd::Union{Nothing, String}) =
    julia_cmd === nothing || isempty(julia_cmd) ? nothing : shell_join(shell_split(julia_cmd))

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
    cmd = julia_command(s)
    s.cmd = cmd
    s.child = spawn_merged(cmd, s.env_dir)
    execute_raw(s, "import REPL", STARTUP_TIMEOUT)
    load_revise!(s)

    code = init_code(s)
    if code !== nothing
        failure = init_failure(execute_raw(s, guarded(code), nothing))
        if failure !== nothing
            kill!(s)
            throw(SessionError(string(
                "Failed to initialize environment '", s.env_dir, "' (init code '", code, "'):\n", failure)))
        end
    end
    return s
end

guarded(code::String) = "try; $code; catch __e; print(\"$INIT_ERROR_MARKER\"); showerror(stdout, __e); end"

init_failure(out::String) = occursin(INIT_ERROR_MARKER, out) ? String(strip(replace(out, INIT_ERROR_MARKER => ""))) : nothing

function load_revise!(s::JuliaSession)
    failure = init_failure(execute_raw(s, guarded("using Revise"), STARTUP_TIMEOUT))
    s.revise_loaded = failure === nothing
    s.revise_loaded || (s.pending_notice = string(
        "Note: Revise failed to load, so edits to source files are not picked up in this session:\n", failure, "\n\n"))
    return
end

function take_notice!(s::JuliaSession)
    notice = something(s.pending_notice, "")
    s.pending_notice = nothing
    return notice
end

function wrap_user_code(code::String)
    hex = bytes2hex(codeunits(code))
    return string(
        "try; Revise.revise(); catch; end;",
        "let code = String(hex2bytes(\"$hex\")), value = include_string(Main, code);",
        "value === nothing || REPL.ends_with_semicolon(code) || ",
        "(Base.invokelatest(show, IOContext(stdout, :limit => true), MIME\"text/plain\"(), value); println()); end;nothing")
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
        output = try
            execute_raw(s, wrap_user_code(code), timeout)
        finally
            s.last_used = time()
        end
        isempty(output) || log_entry(s, output * "\n\n")
        notice = take_notice!(s)
        isempty(output) ? notice : notice * output
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

struct SessionKey
    env::String
    julia_cmd::Union{Nothing, String}
end

mutable struct SessionManager
    julia_args::Vector{String}
    idle_timeout::Float64
    reap_interval::Float64
    reap_timer::Union{Nothing, Timer}
    sessions::Dict{SessionKey, JuliaSession}
    names::Dict{String, SessionKey}
    create_locks::Dict{SessionKey, ReentrantLock}
    log_dir::String
    log_files::Dict{SessionKey, LogFile}
end

function SessionManager(
    julia_args::Vector{String} = DEFAULT_JULIA_ARGS;
    idle_timeout::Float64 = DEFAULT_IDLE_TIMEOUT,
    reap_interval::Float64 = DEFAULT_REAP_INTERVAL,
)
    log_dir = mktempdir(; prefix = "julia-mcp-logs-", cleanup = false)
    return SessionManager(julia_args, idle_timeout, reap_interval, nothing,
        Dict{SessionKey, JuliaSession}(), Dict{String, SessionKey}(), Dict{SessionKey, ReentrantLock}(),
        log_dir, Dict{SessionKey, LogFile}())
end

session_key(env_path::Union{Nothing, String}, julia_cmd::Union{Nothing, String}) =
    SessionKey(env_path === nothing ? TEMP_SESSION_KEY : resolve_path(env_path), normalize_julia_cmd(julia_cmd))

function log_file!(m::SessionManager, key::SessionKey)
    get!(m.log_files, key) do
        env, julia_cmd = key.env, key.julia_cmd
        safe_name = strip(replace(env, "/" => "_", "\\" => "_"), '_')
        safe_name = isempty(safe_name) ? "temp" : String(safe_name)
        if julia_cmd !== nothing
            safe_name *= "_" * strip(replace(julia_cmd, r"[^A-Za-z0-9.+-]+" => "_"), '_')
        end
        path = joinpath(m.log_dir, safe_name * ".log")
        LogFile(path, open(path, "a"))
    end
end

python_repr(s::String) = occursin('\'', s) && !occursin('"', s) ? "\"" * s * "\"" : "'" * replace(s, "'" => "\\'") * "'"
python_list_repr(items::Vector{String}) = "[" * join(map(python_repr, items), ", ") * "]"

function forget!(m::SessionManager, key::SessionKey)
    delete!(m.sessions, key)
    filter!(p -> last(p) != key, m.names)
    return
end

env_label(env::String) = env == TEMP_SESSION_KEY ? "The temporary environment" : env

function describe(key::SessionKey)
    env, julia_cmd = key.env, key.julia_cmd
    return julia_cmd === nothing ? env_label(env) : string(env_label(env), " with julia_cmd=", python_repr(julia_cmd))
end

sessions_on(m::SessionManager, env::String) = [(k, s) for (k, s) in m.sessions if k.env == env]

function checked_name(name::String)
    stripped = String(strip(name))
    isempty(stripped) && throw(SessionError("Session name must not be empty."))
    return stripped
end

function known_names_hint(m::SessionManager)
    isempty(m.names) && return ""
    return " Known names: " * python_list_repr(sort!(collect(keys(m.names)))) * "."
end

function resolve_key(m::SessionManager, env_path::Union{Nothing, String}, julia_cmd::Union{Nothing, String},
        name::Union{Nothing, String})::SessionKey
    if name !== nothing
        name = checked_name(name)
        haskey(m.names, name) || throw(SessionError("Unknown session name $(python_repr(name))." * known_names_hint(m)))
        return m.names[name]
    end

    key = session_key(env_path, julia_cmd)
    (julia_cmd !== nothing || haskey(m.sessions, key)) && return key
    on_env = sessions_on(m, key.env)
    length(on_env) == 1 && return first(only(on_env))
    if !isempty(on_env)
        described = sort!([describe(k) for (k, _) in on_env])
        throw(SessionError(string(env_label(key.env), " has several sessions ", python_list_repr(described),
            ". Pass name or julia_cmd to pick one.")))
    end
    return key
end

function plan(m::SessionManager, env_path::Union{Nothing, String}, julia_cmd::Union{Nothing, String},
        name::Union{Nothing, String})::Tuple{SessionKey, Vector{SessionKey}}
    if name === nothing
        key = session_key(env_path, julia_cmd)
        haskey(m.sessions, key) && return key, SessionKey[]
        unnamed = SessionKey[k for (k, s) in sessions_on(m, key.env) if s.name === nothing]
        isempty(unnamed) || return key, unnamed
        named = sort!(String[something(s.name) for (_, s) in sessions_on(m, key.env)])
        isempty(named) || throw(SessionError(string(env_label(key.env), " already has named session(s) ",
            python_list_repr(named), " with different settings, which are never replaced automatically. ",
            "Pass the name of one to restart it with these settings, or a new name to run alongside it.")))
        return key, SessionKey[]
    end

    name = checked_name(name)
    if env_path === nothing
        julia_cmd === nothing || throw(SessionError(
            "Cannot name a temporary session: pass env_path together with name=$(python_repr(name))."))
        haskey(m.names, name) || throw(SessionError(
            "Unknown session name $(python_repr(name)). Pass env_path to create it." * known_names_hint(m)))
        return m.names[name], SessionKey[]
    end

    key = session_key(env_path, julia_cmd)
    existing = get(m.sessions, key, nothing)
    if existing !== nothing && existing.name !== nothing && existing.name != name
        owner = python_repr(something(existing.name))
        throw(SessionError(string(describe(key), " already belongs to session ", owner, ". Use name=", owner,
            " instead of ", python_repr(name), ".")))
    end
    claimed = get(m.names, name, nothing)
    claimed !== nothing && claimed != key && return key, SessionKey[claimed]
    return key, SessionKey[]
end

function adopt!(m::SessionManager, session::JuliaSession, key::SessionKey, name::Union{Nothing, String})
    if name !== nothing
        session.name = name
        m.names[name] = key
    end
    return session
end

function reap_idle!(m::SessionManager)
    for (key, session) in collect(m.sessions)
        if is_idle(session, m.idle_timeout)
            forget!(m, key)
            kill!(session)
        end
    end
    return
end

function reap_periodically(m::SessionManager, timer::Timer)
    while true
        try
            wait(timer)
        catch
            return
        end
        reap_idle!(m)
    end
end

function ensure_reaper!(m::SessionManager)
    m.reap_timer === nothing || return
    timer = Timer(m.reap_interval; interval = m.reap_interval)
    m.reap_timer = timer
    @async reap_periodically(m, timer)
    return
end

function live_session(m::SessionManager, key::SessionKey, name::Union{Nothing, String})
    existing = get(m.sessions, key, nothing)
    (existing === nothing || !is_alive(existing)) && return nothing
    return adopt!(m, existing, key, name)
end

function get_or_create!(m::SessionManager, env_path::Union{Nothing, String} = nothing;
        julia_cmd::Union{Nothing, String} = nothing, name::Union{Nothing, String} = nothing)
    ensure_reaper!(m)
    key, doomed = plan(m, env_path, julia_cmd, name)
    name = name === nothing ? nothing : checked_name(name)
    if isempty(doomed)
        existing = live_session(m, key, name)
        existing === nothing || return existing
    end

    create_lock = get!(ReentrantLock, m.create_locks, key)
    lock(create_lock)
    try
        return replace_or_create!(m, env_path, julia_cmd, name)
    finally
        unlock(create_lock)
    end
end

function replace_or_create!(m::SessionManager, env_path::Union{Nothing, String}, julia_cmd::Union{Nothing, String},
        name::Union{Nothing, String})
    key, doomed = plan(m, env_path, julia_cmd, name)
    for doomed_key in doomed
        kill!(m.sessions[doomed_key])
        forget!(m, doomed_key)
    end

    existing = live_session(m, key, name)
    existing === nothing || return existing
    if haskey(m.sessions, key)
        kill!(m.sessions[key])
        forget!(m, key)
    end

    env, normalized_cmd = key.env, key.julia_cmd
    is_temp = env == TEMP_SESSION_KEY
    env_dir = is_temp ? mktempdir(; prefix = "julia-mcp-", cleanup = false) : env
    session = JuliaSession(env_dir, new_sentinel();
        is_temp, is_test = !is_temp && basename(env_dir) == "test",
        julia_args = m.julia_args, julia_cmd = normalized_cmd, name, log = log_file!(m, key).io)
    try
        start!(session)
    catch
        kill!(session)
        rethrow()
    end
    m.sessions[key] = session
    name === nothing || (m.names[name] = key)
    return session
end

function stop!(m::SessionManager, env_path::Union{Nothing, String} = nothing;
        julia_cmd::Union{Nothing, String} = nothing, name::Union{Nothing, String} = nothing)
    key = resolve_key(m, env_path, julia_cmd, name)
    session = get(m.sessions, key, nothing)
    session === nothing && return false
    kill!(session)
    forget!(m, key)
    return true
end

function drop_dead_sessions!(m::SessionManager)
    for (key, session) in collect(m.sessions)
        if !is_alive(session)
            kill!(session)
            forget!(m, key)
        end
    end
    return
end

struct SessionInfo
    env_path::String
    alive::Bool
    temp::Bool
    name::Union{Nothing, String}
    julia_cmd::Union{Nothing, String}
    revise_loaded::Bool
    cmd::Union{Nothing, String}
    log_file::Union{Nothing, String}
end

sort_key(entry::Pair{SessionKey, JuliaSession}) = (entry.first.env, something(entry.first.julia_cmd, ""))

function list_sessions(m::SessionManager)
    return [
        SessionInfo(s.env_dir, is_alive(s), s.is_temp, s.name, s.julia_cmd, s.revise_loaded,
            s.cmd === nothing ? nothing : shell_join(something(s.cmd)),
            haskey(m.log_files, key) ? m.log_files[key].path : nothing)
        for (key, s) in sort!(collect(m.sessions); by = sort_key)
    ]
end

function shutdown!(m::SessionManager)
    timer = m.reap_timer
    timer === nothing || close(timer)
    m.reap_timer = nothing
    foreach(kill!, values(m.sessions))
    empty!(m.sessions)
    empty!(m.names)
    foreach(f -> close(f.io), values(m.log_files))
    empty!(m.log_files)
    rm(m.log_dir; recursive = true, force = true)
    return
end
