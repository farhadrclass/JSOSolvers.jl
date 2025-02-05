#  Some parts of this code were adapted from
# https://github.com/PythonOptimizers/NLP.py/blob/develop/nlp/optimize/tron.py

export tron, TronSolver

tron(nlp::AbstractNLPModel; variant = :Newton, kwargs...) = tron(Val(variant), nlp; kwargs...)

"""
    tron(nlp; kwargs...)

A pure Julia implementation of a trust-region solver for bound-constrained optimization:
    
        min f(x)    s.t.    ℓ ≦ x ≦ u
    
For advanced usage, first define a `TronSolver` to preallocate the memory used in the algorithm, and then call `solve!`:

    solver = TronSolver(nlp)
    solve!(solver, nlp; kwargs...)

# Arguments
- `nlp::AbstractNLPModel{T, V}` represents the model to solve, see `NLPModels.jl`.
The keyword arguments may include
- `subsolver_logger::AbstractLogger = NullLogger()`: subproblem's logger.
- `x::V = nlp.meta.x0`: the initial guess.
- `μ₀::T = T(1e-2)`: algorithm parameter in (0, 0.5).
- `μ₁::T = one(T)`: algorithm parameter in (0, +∞).
- `σ::T = T(10)`: algorithm parameter in (1, +∞).
- `max_eval::Int = -1`: maximum number of objective function evaluations.
- `max_time::Float64 = 30.0`: maximum time limit in seconds.
- `max_cgiter::Int = 50`: subproblem's iteration limit.
- `use_only_objgrad::Bool = false`: If `true`, the algorithm uses only the function `objgrad` instead of `obj` and `grad`.
- `cgtol::T = T(0.1)`: subproblem tolerance.
- `atol::T = √eps(T)`: absolute tolerance.
- `rtol::T = √eps(T)`: relative tolerance, the algorithm stops when ‖∇f(xᵏ)‖ ≤ atol + rtol * ‖∇f(x⁰)‖.
- `verbose::Int = 0`: if > 0, display iteration details every `verbose` iteration.
- `max_radius::T = min(one(T) / sqrt(2 * eps(T)), T(100))`: maximum trust-region radius in the first-step chosen smaller than SolverTools.TRONTrustRegion `max_radius`.

# Output
The value returned is a `GenericExecutionStats`, see `SolverCore.jl`.

# Callback
The callback is called at each iteration.
The expected signature of the callback is `callback(nlp, solver, stats)`, and its output is ignored.
Changing any of the input arguments will affect the subsequent iterations.
In particular, setting `stats.status = :user` will stop the algorithm.
All relevant information should be available in `nlp` and `solver`.
Notably, you can access, and modify, the following:
- `solver.x`: current iterate;
- `solver.gx`: current gradient;
- `stats`: structure holding the output of the algorithm (`GenericExecutionStats`), which contains, among other things:
  - `stats.dual_feas`: norm of current gradient;
  - `stats.iter`: current iteration counter;
  - `stats.objective`: current objective function value;
  - `stats.status`: current status of the algorithm. Should be `:unknown` unless the algorithm has attained a stopping criterion. Changing this to anything will stop the algorithm, but you should use `:user` to properly indicate the intention.
  - `stats.elapsed_time`: elapsed time in seconds.

# References
TRON is described in

    Chih-Jen Lin and Jorge J. Moré, *Newton's Method for Large Bound-Constrained
    Optimization Problems*, SIAM J. Optim., 9(4), 1100–1127, 1999.
    DOI: 10.1137/S1052623498345075

# Examples
```jldoctest; output = false
using JSOSolvers, ADNLPModels
nlp = ADNLPModel(x -> sum(x), ones(3), zeros(3), 2 * ones(3));
stats = tron(nlp)

# output

"Execution stats: first-order stationary"
```

```jldoctest; output = false
using JSOSolvers, ADNLPModels
nlp = ADNLPModel(x -> sum(x), ones(3), zeros(3), 2 * ones(3));
solver = TronSolver(nlp);
stats = solve!(solver, nlp)

# output

"Execution stats: first-order stationary"
```
"""
mutable struct TronSolver{T, V <: AbstractVector{T}, Op <: AbstractLinearOperator{T}} <:
               AbstractOptimizationSolver
  x::V
  xc::V
  temp::V
  gx::V
  gt::V
  gn::V
  gpx::V
  Hs::V
  H::Op
  tr::TrustRegion{T, V}
end

function TronSolver(nlp::AbstractNLPModel{T, V};) where {T, V <: AbstractVector{T}}
  nvar = nlp.meta.nvar
  x = V(undef, nvar)
  xc = V(undef, nvar)
  temp = V(undef, nvar)
  gx = V(undef, nvar)
  gt = V(undef, nvar)
  gn = isa(nlp, QuasiNewtonModel) ? V(undef, nvar) : V(undef, 0)
  gpx = V(undef, nvar)
  Hs = V(undef, nvar)
  H = hess_op!(nlp, x, Hs)
  Op = typeof(H)
  tr = TrustRegion(gt, one(T))
  return TronSolver{T, V, Op}(x, xc, temp, gx, gt, gn, gpx, Hs, H, tr)
end

function SolverCore.reset!(solver::TronSolver)
  solver.tr.good_grad = false
  solver.tr.radius = solver.tr.initial_radius
  solver
end

function SolverCore.reset!(solver::TronSolver, nlp::AbstractNLPModel)
  @assert (length(solver.gn) == 0) || isa(nlp, QuasiNewtonModel)
  solver.H = hess_op!(nlp, solver.x, solver.Hs)
  solver.tr.good_grad = false
  solver.tr.radius = solver.tr.initial_radius
  solver
end

@doc (@doc TronSolver) function tron(
  ::Val{:Newton},
  nlp::AbstractNLPModel;
  x::V = nlp.meta.x0,
  kwargs...,
) where {V}
  solver = TronSolver(nlp)
  return solve!(solver, nlp; x = x, kwargs...)
end

function SolverCore.solve!(
  solver::TronSolver{T, V},
  nlp::AbstractNLPModel{T, V},
  stats::GenericExecutionStats{T, V};
  callback = (args...) -> nothing,
  subsolver_logger::AbstractLogger = NullLogger(),
  x::V = nlp.meta.x0,
  μ₀::T = T(1e-2),
  μ₁::T = one(T),
  σ::T = T(10),
  max_eval::Int = -1,
  max_time::Float64 = 30.0,
  max_cgiter::Int = 50,
  use_only_objgrad::Bool = false,
  cgtol::T = T(0.1),
  atol::T = √eps(T),
  rtol::T = √eps(T),
  verbose::Int = 0,
  max_radius::T = min(one(T) / sqrt(2 * eps(T)), T(100)),
) where {T, V <: AbstractVector{T}}
  if !(nlp.meta.minimize)
    error("tron only works for minimization problem")
  end
  if !(unconstrained(nlp) || bound_constrained(nlp))
    error("tron should only be called for unconstrained or bound-constrained problems")
  end

  reset!(stats)
  ℓ = nlp.meta.lvar
  u = nlp.meta.uvar
  n = nlp.meta.nvar

  start_time = time()
  set_time!(stats, 0.0)

  solver.x .= x
  x = solver.x
  xc = solver.xc
  temp = solver.temp
  gx = solver.gx
  gt = solver.gt
  gn = solver.gn
  gpx = solver.gpx
  Hs = solver.Hs

  x .= max.(ℓ, min.(x, u))
  fx, _ = objgrad!(nlp, x, gx)
  # gt = use_only_objgrad ? zeros(T, n) : T[]
  num_success_iters = 0

  # Optimality measure
  project_step!(gpx, x, gx, ℓ, u, -one(T))
  πx = nrm2(n, gpx)
  ϵ = atol + rtol * πx
  fmin = min(-one(T), fx) / eps(eltype(x))
  optimal = πx <= ϵ
  unbounded = fx < fmin

  set_iter!(stats, 0)
  set_objective!(stats, fx)
  set_dual_residual!(stats, πx)

  if isa(nlp, QuasiNewtonModel)
    gn .= gx
  end

  αC = one(T)
  tr = TRONTrustRegion(gt, min(max(one(T), πx / 10), max_radius))
  verbose > 0 && @info log_header(
    [:iter, :f, :dual, :radius, :ratio, :cgstatus],
    [Int, T, T, T, T, String],
    hdr_override = Dict(:f => "f(x)", :dual => "π", :radius => "Δ"),
  )

  set_status!(
    stats,
    get_status(
      nlp,
      elapsed_time = stats.elapsed_time,
      optimal = optimal,
      unbounded = unbounded,
      max_eval = max_eval,
      max_time = max_time,
    ),
  )

  callback(nlp, solver, stats)

  done =
    (stats.status == :first_order) ||
    (stats.status == :unbounded) ||
    (stats.status == :max_eval) ||
    (stats.status == :max_time) ||
    (stats.status == :user) ||
    (stats.status == :neg_pred)

  while !done
    # Current iteration
    xc .= x
    fc = fx
    Δ = tr.radius
    H = hess_op!(nlp, xc, temp)

    αC, s, cauchy_status = cauchy(x, H, gx, Δ, αC, ℓ, u, μ₀ = μ₀, μ₁ = μ₁, σ = σ)

    if cauchy_status != :success
      @error "Cauchy step returned: $cauchy_status"
      stats.status = cauchy_status
      done = true
      continue
    end
    s, Hs, cgits, cginfo = with_logger(subsolver_logger) do
      projected_newton!(x, H, gx, Δ, cgtol, s, ℓ, u, max_cgiter = max_cgiter)
    end
    slope = dot(n, gx, s)
    qs = dot(n, s, Hs) / 2 + slope
    fx = if use_only_objgrad
      objgrad!(nlp, x, gt)[1]
    else
      obj(nlp, x)
    end

    ared, pred = aredpred!(tr, nlp, fc, fx, qs, x, s, slope)
    if pred ≥ 0
      stats.status = :neg_pred
      done = true
      continue
    end
    tr.ratio = ared / pred
    verbose > 0 &&
      mod(stats.iter, verbose) == 0 &&
      @info log_row([stats.iter, fx, πx, Δ, tr.ratio, cginfo])

    s_norm = nrm2(n, s)
    if num_success_iters == 0
      tr.radius = min(Δ, s_norm)
    end

    # Update the trust region
    update!(tr, s_norm)

    if acceptable(tr)
      num_success_iters += 1
      if use_only_objgrad
        gx .= gt
      else
        grad!(nlp, x, gx)
      end
      project_step!(gpx, x, gx, ℓ, u, -one(T))
      πx = nrm2(n, gpx)

      if isa(nlp, QuasiNewtonModel)
        gn .-= gx
        gn .*= -1  # gn = ∇f(xₖ₊₁) - ∇f(xₖ)
        push!(nlp, s, gn)
        gn .= gx
      end
    end

    if !acceptable(tr)
      fx = fc
      x .= xc
    end

    optimal = πx <= ϵ
    unbounded = fx < fmin

    set_objective!(stats, fx)
    set_iter!(stats, stats.iter + 1)
    set_time!(stats, time() - start_time)
    set_dual_residual!(stats, πx)

    set_status!(
      stats,
      get_status(
        nlp,
        elapsed_time = stats.elapsed_time,
        optimal = optimal,
        unbounded = unbounded,
        max_eval = max_eval,
        max_time = max_time,
      ),
    )

    callback(nlp, solver, stats)

    done =
      (stats.status == :first_order) ||
      (stats.status == :unbounded) ||
      (stats.status == :max_eval) ||
      (stats.status == :max_time) ||
      (stats.status == :user) ||
      (stats.status == :neg_pred)
  end
  verbose > 0 && @info log_row(Any[stats.iter, fx, πx, tr.radius])

  set_solution!(stats, x)
  stats
end

"""`s = projected_line_search!(x, H, g, d, ℓ, u; μ₀ = 1e-2)`

Performs a projected line search, searching for a step size `t` such that

    0.5sᵀHs + sᵀg ≦ μ₀sᵀg,

where `s = P(x + t * d) - x`, while remaining on the same face as `x + d`.
Backtracking is performed from t = 1.0. `x` is updated in place.
"""
function projected_line_search!(
  x::AbstractVector{T},
  H::Union{AbstractMatrix, AbstractLinearOperator},
  g::AbstractVector{T},
  d::AbstractVector{T},
  ℓ::AbstractVector{T},
  u::AbstractVector{T};
  μ₀::Real = T(1e-2),
) where {T <: Real}
  α = one(T)
  _, brkmin, _ = breakpoints(x, d, ℓ, u)
  nsteps = 0
  n = length(x)

  s = zeros(T, n)
  Hs = zeros(T, n)

  search = true
  while search && α > brkmin
    nsteps += 1
    project_step!(s, x, d, ℓ, u, α)
    slope, qs = compute_Hs_slope_qs!(Hs, H, s, g)
    if qs <= μ₀ * slope
      search = false
    else
      α /= 2
    end
  end
  if α < 1 && α < brkmin
    α = brkmin
    project_step!(s, x, d, ℓ, u, α)
    slope, qs = compute_Hs_slope_qs!(Hs, H, s, g)
  end

  project_step!(s, x, d, ℓ, u, α)
  x .= x .+ s

  return s
end

"""`α, s = cauchy(x, H, g, Δ, ℓ, u; μ₀ = 1e-2, μ₁ = 1.0, σ=10.0)`

Computes a Cauchy step `s = P(x - α g) - x` for

    min  q(s) = ¹/₂sᵀHs + gᵀs     s.t.    ‖s‖ ≦ μ₁Δ,  ℓ ≦ x + s ≦ u,

with the sufficient decrease condition

    q(s) ≦ μ₀sᵀg.
"""
function cauchy(
  x::AbstractVector{T},
  H::Union{AbstractMatrix, AbstractLinearOperator},
  g::AbstractVector{T},
  Δ::Real,
  α::Real,
  ℓ::AbstractVector{T},
  u::AbstractVector{T};
  μ₀::Real = T(1e-2),
  μ₁::Real = one(T),
  σ::Real = T(10),
) where {T <: Real}
  # TODO: Use brkmin to care for g direction
  _, _, brkmax = breakpoints(x, -g, ℓ, u)
  n = length(x)
  s = zeros(T, n)
  Hs = zeros(T, n)

  status = :success

  project_step!(s, x, g, ℓ, u, -α)

  # Interpolate or extrapolate
  s_norm = nrm2(n, s)
  if s_norm > μ₁ * Δ
    interp = true
  else
    slope, qs = compute_Hs_slope_qs!(Hs, H, s, g)
    interp = qs >= μ₀ * slope
  end

  if interp
    search = true
    while search
      α /= σ
      project_step!(s, x, g, ℓ, u, -α)
      s_norm = nrm2(n, s)
      if s_norm <= μ₁ * Δ
        slope, qs = compute_Hs_slope_qs!(Hs, H, s, g)
        search = qs >= μ₀ * slope
      end
      # TODO: Correctly assess why this fails
      if α < sqrt(nextfloat(zero(α)))
        search = false
        status = :small_step
      end
    end
  else
    search = true
    αs = α
    while search && α <= brkmax
      α *= σ
      project_step!(s, x, g, ℓ, u, -α)
      s_norm = nrm2(n, s)
      if s_norm <= μ₁ * Δ
        slope, qs = compute_Hs_slope_qs!(Hs, H, s, g)
        if qs <= μ₀ * slope
          αs = α
        end
      else
        search = false
      end
    end
    # Recover the last successful step
    α = αs
    s = project_step!(s, x, g, ℓ, u, -α)
  end
  return α, s, status
end

"""`projected_newton!(x, H, g, Δ, gctol, s, max_cgiter, ℓ, u)`

Compute an approximate solution `d` for

min q(d) = ¹/₂dᵀHs + dᵀg    s.t.    ℓ ≦ x + d ≦ u,  ‖d‖ ≦ Δ

starting from `s`.  The steps are computed using the conjugate gradient method
projected on the active bounds.
"""
function projected_newton!(
  x::AbstractVector{T},
  H::Union{AbstractMatrix, AbstractLinearOperator},
  g::AbstractVector{T},
  Δ::Real,
  cgtol::Real,
  s::AbstractVector{T},
  ℓ::AbstractVector{T},
  u::AbstractVector{T};
  max_cgiter::Int = 50,
) where {T <: Real}
  n = length(x)
  status = ""

  Hs = H * s

  # Projected Newton Step
  exit_optimal = false
  exit_pcg = false
  exit_itmax = false
  iters = 0
  x .= x .+ s
  project!(x, x, ℓ, u)
  while !(exit_optimal || exit_pcg || exit_itmax)
    ifree = setdiff(1:n, active(x, ℓ, u))
    if length(ifree) == 0
      exit_optimal = true
      continue
    end
    Z = opExtension(ifree, n)
    @views wa = g[ifree]
    @views gfree = Hs[ifree] + wa
    gfnorm = norm(wa)

    ZHZ = Z' * H * Z
    st, stats = Krylov.cg(ZHZ, -gfree, radius = Δ, rtol = cgtol, atol = zero(T))
    iters += 1
    status = stats.status

    # Projected line search
    xfree = @view x[ifree]
    @views w = projected_line_search!(xfree, ZHZ, gfree, st, ℓ[ifree], u[ifree])
    @views s[ifree] .+= w

    Hs .= H * s

    @views gfree .= Hs[ifree] .+ g[ifree]
    if norm(gfree) <= cgtol * gfnorm
      exit_optimal = true
    elseif status == "on trust-region boundary"
      exit_pcg = true
    elseif iters >= max_cgiter
      exit_itmax = true
    end
  end
  status = if exit_optimal
    "stationary point found"
  elseif exit_itmax
    "maximum number of iterations"
  else
    status # on trust-region
  end

  return s, Hs, iters, status
end
