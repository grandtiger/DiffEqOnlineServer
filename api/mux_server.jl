tic()
using DiffEqBase, OrdinaryDiffEq, ParameterizedFunctions, Plots, Mux, JSON, HttpCommon
println("Package loading took this long: ", toq())

# Handy functions
expr_has_head(s, h) = false
expr_has_head(e::Expr, h::Symbol) = expr_has_head(e, Symbol[h])
function expr_has_head(e::Expr, vh::Vector{Symbol})
    in(e.head, vh) || any(a -> expr_has_head(a, vh), e.args)
end
has_function_def(s::String) = has_function_def(parse(s; raise=false))
has_function_def(e::Expr) = expr_has_head(e, Symbol[:(->), :function])

# Headers -- set Access-Control-Allow-Origin for either dev or prod
function withHeaders(res, req)
    println("Origin: ", get(req[:headers], "Origin", ""))
    headers  = HttpCommon.headers()
    headers["Content-Type"] = "application/json; charset=utf-8"
    if get(req[:headers], "Origin", "") == "http://localhost:4200"
        headers["Access-Control-Allow-Origin"] = "http://localhost:4200"
    else
        headers["Access-Control-Allow-Origin"] = "http://app.juliadiffeq.org"
    end
    println(headers["Access-Control-Allow-Origin"])
    Dict(
       :headers => headers,
       :body=> res
    )
end

# Better error handling
function jsoncatch(app, req)
  try
    app(req)
  catch e
    println("Error occured!")
    io = IOBuffer()
    showerror(io, e, catch_backtrace())
    return withHeaders(JSON.json(Dict("error_msg" => takebuf_string(io), "error" => true)), req)
  end
end

# A debug endpoint
function wakeup()
    return JSON.json(Dict("data" => Dict("awake" => true), "error" => false))
end

# The ODE endpoint
function solveit(req::Dict{Any,Any})
    b64 = convert(String, req[:path][1])
    solveit(b64)
end

function solveit(b64::String)
    tic()
    plotly()
    strObj = String(base64decode(b64))
    obj = JSON.parse(strObj)
    # println(obj)
    # println(" ")

    exstr = string("begin\n", obj["diffEqText"], "\nend")
    if has_function_def(exstr)
        return JSON.json(Dict("data" => false, "error" => "Don't define functions in your system of equations..."))
    end
    ex = parse(exstr)
    # Need a way to make sure the expression only calls "safe" functions here!!!
    println("Diff equ: ", ex)
    name = Symbol(strObj)
    params = [parse(p) for p in obj["parameters"]]
    println("Params: ", params)
    # Make sure these are always floats
    tspan = (Float64(obj["timeSpan"][1]),Float64(obj["timeSpan"][2]))
    println("tspan: ", tspan)
    u0 = [parse(Float64, u) for u in obj["initialConditions"]]
    println("u0: ", u0)
    algstr = obj["solver"]  #Get this from the reqest in the future!
    algs = Dict{Symbol,OrdinaryDiffEq.OrdinaryDiffEqAlgorithm}(
                :Tsit5 => Tsit5(),
                :Vern6 => Vern6(),
                :Vern7 => Vern7(),
                :Feagin14 => Feagin14(),
                :BS3 => BS3(),
                :Rosenbrock23 => Rosenbrock23())
    opts = Dict{Symbol,Bool}(
        :build_tgrad => true,
        :build_jac => true,
        :build_expjac => false,
        :build_invjac => true,
        :build_invW => true,
        :build_hes => false,
        :build_invhes => false,
        :build_dpfuncs => true)
    f = ode_def_opts(name, opts, ex, params...)
    prob = ODEProblem(f,u0,tspan)
    alg = algs[parse(algstr)]
    sol = solve(prob,alg);

    println("did sol")
    numpoints = 1000
    newt = collect(linspace(sol.t[1],sol.t[end],numpoints))
    newu = sol.interp(newt)
    println("did interp")
    p = plot(sol,xlabel="t")
    println("did plot")
    layout = Plots.plotly_layout_json(p)
    series = Plots.plotly_series_json(p)

    # Destroy some methods and objects
    ex = 0
    name = 0
    params = 0

    res = Dict("u" => newu, "t" => newt, "layout" =>layout, "series"=>series)
    println("Done, took this long: ", toq())
    return JSON.json(Dict("data" => res, "error" => false))
end

ourStack = stack(Mux.todict, jsoncatch, Mux.splitquery, Mux.toresponse)

@app test = (
    ourStack,
    page(req -> withHeaders("Nothing to see here...", req)),
    route("/wakeup", req -> withHeaders(wakeup(), req)),
    route("/solveit", req -> withHeaders(solveit(req), req)),
    Mux.notfound()
)

println("About to start the server!")
@sync serve(test, port=parse(Int64, ARGS[1]))
