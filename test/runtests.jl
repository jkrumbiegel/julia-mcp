using Test
using JuliaMCP
using JSON
using JuliaMCP: handle_message, SessionManager, shutdown!, shell_split, list_sessions, effective_timeout,
    JuliaSession, session_key, normalize_julia_cmd, plan, resolve_key, get_or_create!, execute, is_alive, kill!,
    stop!, reap_idle!

function rpc(m, method, params = "{}"; id = 1)
    reply = handle_message(m, """{"jsonrpc":"2.0","id":$id,"method":"$method","params":$params}""")
    return reply === nothing ? nothing : JSON.parse(reply)
end

function call_tool(m, name, args = "{}")
    result = rpc(m, "tools/call", """{"name":"$name","arguments":$args}""")["result"]
    return result["content"][1]["text"], result["isError"]
end

tool_text(m, name, args = "{}") = first(call_tool(m, name, args))

function make_pkg_with_test_dir()
    pkg_dir = realpath(mktempdir())
    write(joinpath(pkg_dir, "Project.toml"), """
        name = "TestPkg"
        uuid = "87654321-4321-4321-4321-cba987654321"
        version = "0.1.0"
        """)
    mkpath(joinpath(pkg_dir, "src"))
    write(joinpath(pkg_dir, "src", "TestPkg.jl"), "module TestPkg\nend\n")
    mkpath(joinpath(pkg_dir, "test"))
    return pkg_dir, joinpath(pkg_dir, "test")
end

function stub_session!(m, env_path, julia_cmd = nothing, name = nothing)
    key = session_key(env_path, julia_cmd)
    m.sessions[key] = JuliaSession(key.env, "sentinel"; julia_cmd = key.julia_cmd, name)
    name === nothing || (m.names[name] = key)
    return key
end

function with_manager(f)
    m = SessionManager()
    try
        f(m)
    finally
        shutdown!(m)
    end
end

@testset "JuliaMCP" begin
    @testset "shell_split" begin
        @test shell_split("julia +1.11 --check-bounds=yes") == ["julia", "+1.11", "--check-bounds=yes"]
        @test shell_split("\"/path with/julia\" -e 'a b' x\\ y") == ["/path with/julia", "-e", "a b", "x y"]
    end

    @testset "normalize_julia_cmd" begin
        @test normalize_julia_cmd("julia   '+1.10'  \"a b\" \"it's\"") == "julia +1.10 'a b' 'it'\"'\"'s'"
        @test normalize_julia_cmd("") === nothing
    end

    @testset "session name planning" begin
        pkg = "/some/pkg"
        k(cmd = nothing) = JuliaMCP.SessionKey(pkg, cmd)
        planned(m; env_path = nothing, julia_cmd = nothing, name = nothing) = plan(m, env_path, julia_cmd, name)

        with_manager() do m
            stub_session!(m, pkg, "julia +1.10", "v10")
            @test planned(m; name = "v10") == (k("julia +1.10"), [])
            @test_throws "Unknown session name 'v11'. Pass env_path to create it. Known names: ['v10']." planned(m; name = "v11")
            @test_throws "already has named session(s) ['v10'] with different settings" planned(m; env_path = pkg, julia_cmd = "julia +1.11")
            @test planned(m; env_path = pkg, julia_cmd = "julia +1.11", name = "v10") == (k("julia +1.11"), [k("julia +1.10")])
            @test_throws "/some/pkg with julia_cmd='julia +1.10' already belongs to session 'v10'. Use name='v10' instead of 'ten'." planned(m; env_path = pkg, julia_cmd = "julia +1.10", name = "ten")
            @test planned(m; env_path = pkg, julia_cmd = "julia  +1.10") == (k("julia +1.10"), [])
            @test resolve_key(m, pkg, nothing, nothing) == k("julia +1.10")

            stub_session!(m, pkg, "julia +1.11", "v11")
            @test_throws """/some/pkg has several sessions ["/some/pkg with julia_cmd='julia +1.10'", "/some/pkg with julia_cmd='julia +1.11'"]. Pass name or julia_cmd to pick one.""" resolve_key(m, pkg, nothing, nothing)
        end

        with_manager() do m
            @test_throws "Unknown session name 'v10'. Pass env_path to create it." planned(m; name = "v10")
            @test_throws "Cannot name a temporary session: pass env_path together with name='v10'." planned(m; julia_cmd = "julia +1.10", name = "v10")
            @test_throws "Session name must not be empty." planned(m; env_path = pkg, name = "  ")
        end

        with_manager() do m
            stub_session!(m, pkg, "julia +1.10")
            @test planned(m; env_path = pkg, julia_cmd = "julia +1.11") == (k("julia +1.11"), [k("julia +1.10")])
            @test planned(m; env_path = pkg, julia_cmd = "julia +1.11", name = "v11") == (k("julia +1.11"), [])
            @test planned(m; env_path = pkg, julia_cmd = "julia +1.10", name = "v10") == (k("julia +1.10"), [])
        end
    end

    @testset "effective_timeout" begin
        @test effective_timeout("1+1", nothing) == 60.0
        @test effective_timeout("using Pkg; Pkg.add(\"X\")", nothing) === nothing
        @test effective_timeout("MyPkg.f()", nothing) == 60.0
        @test effective_timeout("1", 0.0) === nothing
        @test effective_timeout("1", 5.0) == 5.0
    end

    @testset "protocol" begin
        with_manager() do m
            init = rpc(m, "initialize", """{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}""")
            @test init["result"]["protocolVersion"] == "2025-03-26"
            @test init["result"]["serverInfo"] == Dict("name" => "julia", "version" => "0.1.0")
            @test rpc(m, "initialize", """{"protocolVersion":"1999-01-01"}""")["result"]["protocolVersion"] == "2025-06-18"

            tools = rpc(m, "tools/list")["result"]["tools"]
            @test [t["name"] for t in tools] == ["julia_eval", "julia_stop", "julia_list_sessions"]
            nullable_string = Dict("anyOf" => [Dict("type" => "string"), Dict("type" => "null")], "default" => nothing)
            @test tools[2]["inputSchema"] == Dict("type" => "object", "properties" => Dict(
                "env_path" => nullable_string, "julia_cmd" => nullable_string, "name" => nullable_string))
            @test tools[3]["inputSchema"] == Dict("type" => "object", "properties" => Dict())

            @test handle_message(m, """{"jsonrpc":"2.0","id":"abc","method":"ping"}""") == """{"jsonrpc":"2.0","id":"abc","result":{}}"""
            @test handle_message(m, """{"jsonrpc":"2.0","method":"notifications/initialized"}""") === nothing
            @test handle_message(m, """{"jsonrpc":"2.0","id":5,"result":{}}""") === nothing
            @test rpc(m, "nope")["error"] == Dict("code" => -32601, "message" => "Method not found: nope")
            @test handle_message(m, "{oops") == """{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"""
            @test handle_message(m, "[1]") == """{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}"""

            @test call_tool(m, "nope") == ("Unknown tool: nope", true)
            @test call_tool(m, "julia_eval", "{}") == ("missing required argument 'code'", true)
            @test call_tool(m, "julia_eval", """{"code":"1","timeout":"x"}""") == ("argument 'timeout' must be a number or null", true)
            @test tool_text(m, "julia_list_sessions") == "No active Julia sessions.\nJulia args applied to every session: --threads=auto"
            @test tool_text(m, "julia_stop") == "No active session for temporary, nothing to stop."
        end
    end

    @testset "sessions" begin
        with_manager() do m
            eval_code(code, extra...) = tool_text(m, "julia_eval", JSON.json(Dict("code" => code, extra...)))

            @test eval_code("x = 21; println(2x)") == "42"
            @test eval_code("println(x + 1); println(stderr, \"err\")") == "22\nerr"
            @test eval_code("y = 1") == "1"
            @test eval_code("y + 1;") == "(no output)"
            @test eval_code("y + 1 # comment;") == "2"
            @test eval_code("println(\"printed\"); [y, 2y]") == "printed\n2-element Vector{Int64}:\n 1\n 2"
            @test eval_code("struct Foo end; Base.show(io::IO, ::MIME\"text/plain\", ::Foo) = print(io, \"custom\"); Foo()") == "custom"
            @test occursin("⋮", eval_code("collect(1:1000)"))
            @test eval_code("using Printf; @printf(\"%.2f\\n\", 1.234)") == "1.23"
            @test startswith(eval_code("error(\"boom\")"), "ERROR: LoadError: boom")
            @test eval_code("println(\"é😀\")") == "é😀"
            @test length(eval_code("print(repeat(\"a\", 2_000_000))")) == 2_000_000

            temp_dir = only(list_sessions(m)).env_path
            @test isdir(temp_dir)
            @test tool_text(m, "julia_list_sessions") ==
                "Active Julia sessions:\n  $temp_dir (temp): alive log=$(only(values(m.log_files)).path)\n" *
                "      cmd: $(Sys.which("julia")) --threads=auto --project=$temp_dir\n" *
                "Julia args applied to every session: --threads=auto"

            @test eval_code("println(\"before\"); flush(stdout); sleep(30)", "timeout" => 1.5) ==
                "Error: Execution timed out after 1.5s. Session killed; it will restart on next call.\n\nOutput before timeout:\nbefore"
            @test isempty(list_sessions(m))
            @test !isdir(temp_dir)
            @test eval_code("sleep(30)", "timeout" => 1) ==
                "Error: Execution timed out after 1.0s. Session killed; it will restart on next call."

            @test eval_code("println(\"bye\"); flush(stdout); exit(3)") == "Error: Julia process died during execution.\nOutput before death:\nbye"
            @test isempty(list_sessions(m))
            @test eval_code("println(@isdefined(x))") == "false"

            @test tool_text(m, "julia_stop") == "Session stopped (temporary)."
            @test isempty(list_sessions(m))
        end
    end

    @testset "env paths, julia_cmd and shutdown" begin
        pkg_dir, test_dir = make_pkg_with_test_dir()
        m = SessionManager()
        eval_in(env, code, extra...) = tool_text(m, "julia_eval", JSON.json(Dict("code" => code, "env_path" => env, extra...)))

        @test eval_in(pkg_dir, "println(pwd()); println(Base.active_project())") == "$pkg_dir\n$pkg_dir/Project.toml"
        @test eval_in(test_dir, "println(pwd())") == test_dir
        @test [s.env_path for s in list_sessions(m)] == sort([pkg_dir, test_dir])

        @test tool_text(m, "julia_stop", JSON.json(Dict("env_path" => "/nonexistent"))) ==
            "No active session for /nonexistent, nothing to stop. Active sessions: " *
            "['$(min(pkg_dir, test_dir))', '$(max(pkg_dir, test_dir))']"

        @test eval_in(pkg_dir, "a = 1; println(Threads.nthreads() > 1)") == "true"
        @test eval_in(pkg_dir, "println(@isdefined(a), Threads.nthreads())", "julia_cmd" => "julia --threads=1") == "false1"
        @test occursin("julia_cmd=julia --threads=1", tool_text(m, "julia_list_sessions"))
        @test startswith(eval_in(pkg_dir, "1", "julia_cmd" => "nonexistent-julia-binary"),
            "Error: 'nonexistent-julia-binary' not found in PATH.")

        pids = [Int(getpid(p)) for s in values(m.sessions) for p in (s.child.process, s.child.reaper)]
        @test !isempty(pids)
        log_dir = m.log_dir
        shutdown!(m)
        @test all(pid -> ccall(:kill, Cint, (Cint, Cint), pid, 0) != 0, pids)
        @test !isdir(log_dir)
        rm(pkg_dir; recursive = true)
    end

    @testset "named sessions" begin
        with_manager() do m
            dir = realpath(mktempdir())
            eval_tool(args...) = tool_text(m, "julia_eval", JSON.json(Dict(args...)))

            unnamed = get_or_create!(m, dir)
            @test get_or_create!(m, dir; name = "pkg") === unnamed
            @test eval_tool("code" => "x_marker = 42; println(x_marker)", "name" => "pkg") == "42"

            two = get_or_create!(m, dir; julia_cmd = "julia --threads=2", name = "t2")
            @test two !== unnamed && is_alive(unnamed) && is_alive(two)
            @test eval_tool("code" => "println(Threads.nthreads())", "name" => "t2") == "2"
            listing = tool_text(m, "julia_list_sessions")
            @test occursin("  [pkg] $dir: alive", listing) && occursin("  [t2] $dir: alive julia_cmd=julia --threads=2", listing)

            @test eval_tool("code" => "1", "name" => "typo") ==
                "Error: Unknown session name 'typo'. Pass env_path to create it. Known names: ['pkg', 't2']."
            @test eval_tool("code" => "1", "env_path" => dir, "name" => "other") ==
                "Error: $dir already belongs to session 'pkg'. Use name='pkg' instead of 'other'."

            @test tool_text(m, "julia_stop", JSON.json(Dict("name" => "t2"))) == "Session stopped (t2)."
            @test !is_alive(two)
            @test_throws "Unknown session name 't2'." stop!(m; name = "t2")

            kill!(unnamed)
            recreated = get_or_create!(m; name = "pkg")
            @test recreated !== unnamed
            @test (recreated.env_dir, recreated.is_temp, recreated.name) == (dir, false, "pkg")
            rm(dir; recursive = true)
        end
    end

    @testset "Revise failing to load" begin
        withenv("JULIA_LOAD_PATH" => "@:@stdlib") do
            with_manager() do m
                eval_code(code) = tool_text(m, "julia_eval", JSON.json(Dict("code" => code)))
                first_result = eval_code("println(42)")
                @test startswith(first_result, "Note: Revise failed to load, so edits to source files are not picked up " *
                    "in this session:\nArgumentError: Package Revise not found")
                @test endswith(first_result, "\n\n42")
                @test eval_code("println(42)") == "42"
                @test occursin("(temp): alive (Revise not loaded)", tool_text(m, "julia_list_sessions"))
            end
        end
    end

    @testset "idle reaping" begin
        long_ago = time() - 365 * 24 * 3600
        with_manager() do m
            @test m.idle_timeout == 72 * 3600
        end

        m = SessionManager(; idle_timeout = 3600.0)
        dir = realpath(mktempdir())
        try
            stale = get_or_create!(m)
            fresh = get_or_create!(m, dir; name = "pkg")
            stale.last_used = long_ago
            fresh.last_used = long_ago
            execute(fresh, "1", 30.0)
            reap_idle!(m)
            @test !is_alive(stale) && is_alive(fresh)
            @test [s.env_path for s in list_sessions(m)] == [dir]

            running = @async execute(fresh, "sleep(2); println(\"done\")", 30.0)
            sleep(0.5)
            fresh.last_used = long_ago
            reap_idle!(m)
            @test fetch(running) == "done"
            @test is_alive(fresh)

            fresh.last_used = long_ago
            reap_idle!(m)
            @test !is_alive(fresh)
            @test_throws "Unknown session name 'pkg'." stop!(m; name = "pkg")
        finally
            shutdown!(m)
            rm(dir; recursive = true)
        end

        m = SessionManager(; idle_timeout = 0.0, reap_interval = 0.1)
        try
            session = get_or_create!(m)
            sleep(1.0)
            @test !is_alive(session)
            @test isempty(list_sessions(m))
        finally
            shutdown!(m)
        end
    end

    @testset "sessions die with a killed server" begin
        project = dirname(@__DIR__)
        server = open(`$(Base.julia_cmd()) --startup-file=no --project=$project -e 'using JuliaMCP; JuliaMCP.main(String[])'`, "r+")
        request(timeout) = JSON.json((jsonrpc = "2.0", id = 1, method = "tools/call", params = (name = "julia_eval",
            arguments = (code = "println(getpid()); flush(stdout); sleep(1000)", timeout = timeout))))
        println(server, request(4))
        reply = JSON.parse(readline(server))
        child_pid = parse(Int, split(reply["result"]["content"][1]["text"], "\n")[end])
        @test ccall(:kill, Cint, (Cint, Cint), child_pid, 0) != 0

        println(server, request(0))
        sleep(15)
        child_pids = parse.(Int, split(readchomp(`pgrep -P $(getpid(server))`)))
        kill(server, Base.SIGKILL)
        wait(server)
        sleep(3)
        @test !isempty(child_pids)
        @test all(pid -> ccall(:kill, Cint, (Cint, Cint), pid, 0) != 0, child_pids)
    end
end
