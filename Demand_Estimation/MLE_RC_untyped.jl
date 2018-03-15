import Base.getindex, Base.setindex!, Base.show
using NLopt
using ForwardDiff

abstract type LogitModel end

type InsuranceLogit <: LogitModel
    # Dictionary of Parameters and implied lengths
    parLength::Dict{Symbol, Int}
    # ChoiceData struct
    data::ChoiceData

    #Store Halton Draws
    draws::Array{Float64,2}

    # Store shares predictions for every (ij) pair
    s_hat

    # Product Level Data
    # Separate vectors, all sorted by product
    prods
    shares
    #Unique firm-level deltas
    deltas
end

type parDict{T}
    # Parameters
    α::Vector{T}
    γ::Vector{T}
    β::Matrix{T}
    σ::Vector{T}
    #Random Coefficients stored (function of σ and draws)
    randCoeffs::Array{T,2}
    # δ values for (ij) pairs
    δ::Vector{T}
end

function parDict{T}(m::InsuranceLogit,x::Array{T})
    # Parameter Lengths from model
    αlen = 1
    γlen = αlen + m.parLength[:γ]
    βlen = γlen + m.parLength[:β]*m.parLength[:γ]
    σlen = βlen + m.parLength[:σ]

    #Distribute Parameters
    α = x[1:αlen]
    γ = x[(αlen+1):γlen]
    β_vec = x[(γlen+1):βlen]
    σ = x[βlen+1:σlen]

    # Stack Beta into a matrix
    K = m.parLength[:β]
    N = m.parLength[:γ]
    β = Matrix{T}(K,N)
    ind = 0
    for i in 1:N, j in 1:K
        ind+=1
        β[j,i] = β_vec[ind]
    end

    #Calculate Random Coefficients matrix
    (R,S) = size(m.draws)
    randCoeffs = Array{T,2}(m.parLength[:σ],S)
    calcRC!(randCoeffs,σ,m.draws)

    #Initialize (ij) pairs of deltas
    L, M = size(m.data.data)
    δ = Vector{T}(M)
    unpack_δ!(δ,m)

    return parDict{T}(α,γ,β,σ,randCoeffs,δ)
end

function calcRC!{T,S}(randCoeffs::Array{S},σ::Array{T},draws::Array{Float64,2})
    (K, N) = size(randCoeffs)
    for k in 1:K,n in 1:N
        l = min(k,3)
        randCoeffs[k,n] = draws[l,n]*σ[k]
    end
    return Void
end


function InsuranceLogit(data::ChoiceData,haltonDim::Int)
    # Construct the model instance

    # Get Parameter Lengths
    γlen = size(demoRaw(data),1)
    βlen = size(prodchars(data),1)
    σlen = βlen+1

    parLength = Dict(:γ=>γlen,:β=>βlen,:σ=>σlen)

    # Initialize Halton Draws
    # These are the same across all individuals
    draws = permutedims(MVHaltonNormal(haltonDim,3),(2,1))

    # Initialize Empty value prediction objects
    n, k = size(c.data)
    s_hat = Vector{Real}(k)

    # Copy Firm Level Data for Changing in Estimation
    pmat = c.pdata
    pmat[:delta] = 0.0
    sort!(pmat)

    d = InsuranceLogit(parLength,data,
                        draws,
                        s_hat,
                        pmat[:Product],pmat[:Share],pmat[:delta])
    return d
end



function calc_indCoeffs{T}(p::parDict{T},β::Array{T,1},γ::T)
    Q = length(β)
    (K,N) = size(p.randCoeffs)
    β_i = Array{T,2}(Q,N)
    γ_i = Array{T,1}(N)
    for n in 1:N
        γ_i[n] = γ + p.randCoeffs[1,n]
        for k in 1:Q
            β_i[k,n] = β[k] + p.randCoeffs[k+1,n]
        end
    end
    return β_i, γ_i
end

function calc_indCoeffs{T}(randCoeffs::Array{T,2},β::Array{T,1},γ::T)
    Q = length(β)
    (K,N) = size(randCoeffs)
    β_i = Array{T,2}(Q,N)
    γ_i = Array{T,1}(N)
    for n in 1:N
        γ_i[n] = γ + randCoeffs[1,n]
        for k in 1:Q
            β_i[k,n] = β[k] + randCoeffs[k+1,n]
        end
    end
    return β_i, γ_i
end

function individual_values!{T}(d::InsuranceLogit,p::parDict{T})
    # Store Parameters
    γ = p.γ
    β = p.β
    α = p.α[1]
    δ_long = p.δ
    # Calculate μ_ij, which depends only on parameters
    for app in eachperson(d.data)
        ind = person(app)[1]
        X = permutedims(prodchars(app),(2,1))
        price = X[:,1]
        Z = demoRaw(app)[:,1]
        β_z = β*Z
        demos = vecdot(γ,Z)
        β_i, γ_i = calc_indCoeffs(p,β_z,demos)
        chars = X*β_i

        (K,N) = size(chars)
        μ_ij = chars
        for n = 1:N,k = 1:K
            μ_ij[k,n] += α*price[k] + γ_i[n]
        end
        idxitr = d.data._personDict[ind]
        δ = δ_long[idxitr]
        d.s_hat[idxitr] = individual_shares_RC(μ_ij,δ)
    end
    return Void
end

function per_val_calc{T}(app::ChoiceData,p::parDict{T})
    # Store Parameters
    γ = p.γ
    β = p.β
    α = p.α[1]
    δ_long = p.δ

    #ind, X, price, Z, idxitr

    # Caculate shares mean shares for individual i
    ind = person(app)[1]
    X = permutedims(prodchars(app),(2,1))
    price = X[:,1]
    Z = demoRaw(app)[:,1]
    β_z = β*Z
    demos = vecdot(γ,Z)
    β_i, γ_i = calc_indCoeffs(p,β_z,demos)
    chars = X*β_i

    (K,N) = size(chars)
    μ_ij = chars
    for n = 1:N,k = 1:K
        μ_ij[k,n] += α*price[k] + γ_i[n]
    end

    idxitr = app._personDict[ind]
    δ = δ_long[idxitr]
    s_hat = individual_shares_RC(μ_ij,δ)

    return s_hat, ind
end

function per_val_calc(inputTuple::Tuple)
    # Store Parameters
    appData = inputTuple[1]
    α       = inputTuple[2]
    γ       = inputTuple[3]
    β       = inputTuple[4]
    δ       = inputTuple[5]
    RCs     = inputTuple[6]

    # Caculate shares mean shares for individual i
    ind = appData[1,1]
    X = permutedims(appData[2:5,:],(2,1))
    price = X[:,1]
    Z = appData[7:9,1]
    β_z = β*Z
    demos = vecdot(γ,Z)
    β_i, γ_i = calc_indCoeffs(RCs,β_z,demos)
    chars = X*β_i

    (K,N) = size(chars)
    μ_ij = chars
    for n = 1:N,k = 1:K
        μ_ij[k,n] += α*price[k] + γ_i[n]
    end

    s_hat = individual_shares_RC(μ_ij,δ)

    return s_hat, ind
end

function per_val_calc{T}(idxitr::UnitRange,p::parDict{T},c::ChoiceData)
    # Store Parameters
    appData = c.data[:,idxitr]
    α       = p.α[1]
    γ       = p.γ
    β       = p.β
    δ       = p.δ[idxitr]
    RCs     = p.randCoeffs

    # Caculate shares mean shares for individual i
    ind = appData[1,1]
    X = permutedims(appData[2:5,:],(2,1))
    price = X[:,1]
    Z = appData[7:9,1]
    β_z = β*Z
    demos = vecdot(γ,Z)
    β_i, γ_i = calc_indCoeffs(RCs,β_z,demos)
    chars = X*β_i

    (K,N) = size(chars)
    μ_ij = chars
    for n = 1:N,k = 1:K
        μ_ij[k,n] += α*price[k] + γ_i[n]
    end

    s_hat = individual_shares_RC(μ_ij,δ)

    return s_hat, idxitr
end

function parallel_values!{T}(d::InsuranceLogit,p::parDict{T})
    #Collection of individual datasets
    idList = Set(eachperson(d.data))
    #Collection of Parameters
    parList =[p]
    while length(parList)<length(idList)
        parList = vcat(parList,[p])
    end
    #Function for parallel caculations
    res = pmap(per_val_calc,idList,parList)

    #Combine Results
    for (s,ind) in res
            idxitr = d.data._personDict[ind]
            d.s_hat[idxitr] = s
    end
    return Void
end


function individual_shares_RC{T}(μ_ij::Array{T},δ;inside::Bool=false)
    (K,N) = size(μ_ij)
    util = Matrix{T}(K,N)
    s_hat = Matrix{T}(K,N)
    s_mean = Vector{T}(K)
    out = 1.0
    if inside
        out = 0.0
    end
    for n in 1:N
        expsum = out
        for i in 1:K
            a = exp(μ_ij[i,n] + δ[i])
            util[i,n] = a
            expsum += a
        end
        for i in 1:K
            s_hat[i,n] = util[i,n]/expsum
        end
    end
    for i in 1:K
        s_mean[i] = mean(s_hat[i,:])
    end
    return s_mean
end

# Calculate Log Likelihood
function log_likelihood{T}(d::InsuranceLogit,p::parDict{T})
    ll = 0.0
    γ = p.γ
    β = p.β
    α = p.α[1]
    # Calculate μ_ij, which depends only on parameters
    for app in eachperson(d.data)
        ind = person(app)[1]
        X = permutedims(prodchars(app),(2,1))
        price = X[:,1]
        Z = demoRaw(app)[:,1]
        Y = transpose(choice(app))
        urate = transpose(unins(app))

        β_z = β*Z
        demos = vecdot(γ,Z)
        β_i, γ_i = calc_indCoeffs(p,β_z,demos)
        chars = X*β_i

        (K,N) = size(chars)
        μ_ij = similar(chars)
        for n = 1:N,k = 1:K
            μ_ij[k,n] = chars[k,n] + α*price[k] + γ_i[n]
        end

        idxitr = d.data._personDict[ind]
        δ = p.δ[idxitr]
        s_hat = individual_shares_RC(μ_ij,δ;inside=false)
        s_insured = sum(s_hat)

        for i in eachindex(idxitr)
            ll+=Y[i]*(log(s_hat[i])-urate[i]*(log(s_insured)-log(1-s_insured)))
        end
    end
    return ll
end

function log_likelihood{T}(d::InsuranceLogit,p::Array{T})
    params = parDict(d,p)
    ll = log_likelihood(d,params)
    convert_δ!(d)
    return ll
end


function unpack_δ!{T}(δ::Vector{T},d::InsuranceLogit)
    for j in d.prods
        idx_j = d.data._productDict[j]
        for idx in idx_j
            δ[idx] = d.deltas[j]
        end
    end
    return Void
end

function convert_δ!(d::InsuranceLogit)
    J = length(d.deltas)
    deltas_new = Array{Float64}(J)
    for j in d.prods
        if isnan(d.deltas[j])
            deltas_new[j] = 0.0
        else
            deltas_new[j] = ForwardDiff.value(d.deltas[j])
        end
    end
    d.deltas = deltas_new
    return Void
end


# Update δ
@views sliceMean{T}(x::Vector{T},idx::Array{Int64,1}) = mean(x[idx])
function δ_update!{T}(d::InsuranceLogit,p::parDict{T};update=true)
    # Calculate overall marketshares and update δ_j
    eps = 0.0
    J = length(d.deltas)
    δ_new = Array{T,1}(J)
    for j in d.prods
        j_index_all = d.data._productDict[j]
        #s_hat_j= mean(d.s_hat[j_index_all])
        s_hat_j= sliceMean(d.s_hat,j_index_all)
        s_j = d.shares[j]
        chg = log(s_j) - log(s_hat_j)
        #d.deltas[j] += chg
        δ_new[j] = d.deltas[j] + chg
        # if abs(chg)>eps
        #     j_high = j
        # end
        eps = max(eps,abs(chg))
    end
    if update
        d.deltas = δ_new
    end
    return eps
end

function contraction!{T}(d::InsuranceLogit,p::parDict{T};update=true)
    # Contraction...
    rnd = 0
    eps = 1
    tol = 1e-6
    while (eps>tol) & (rnd<501)
        rnd+=1
        if rnd>1
            update = true
        end
        #Unpack δ_j into estimator data
        individual_values!(d,p)
        if !update & rnd==1
            eps = δ_update!(d,p,update=false)
        else
            eps = δ_update!(d,p)
        end
        unpack_δ!(p.δ,d)
        # println("Contraction Error")
        println(eps)
    end
end

function contraction!{T}(d::InsuranceLogit,p_vec::Array{T,1};update=true)
    p = parDict(d,p_vec)
    return contraction!(d,p,update=update)
end


function evaluate_iteration{T}(d::InsuranceLogit,p::parDict{T};update=true)
    contraction!(d,p,update=update)
    ll = log_likelihood(d,p)
    convert_δ!(d)
    return ll
end

function evaluate_iteration!{T}(d::InsuranceLogit, x::Array{T,1};update=true)
    # Create Parameter Types
    parameters = parDict(d,x)
    return evaluate_iteration(d,parameters,update=update)
end


function estimate!(d::InsuranceLogit, p0)
    # Set up the optimization
    #opt = Opt(:LD_MMA, length(p0))
    opt = Opt(:LN_NELDERMEAD, length(p0))
    #opt = Opt(:LD_TNEWTON_PRECOND_RESTART,length(p0))
    #opt = Opt(:LD_TNEWTON,length(p0))
    #opt = Opt(:LN_SBPLX, length(p0))
    xtol_rel!(opt, 1e-4)
    maxeval!(opt, 2000)
    #upper_bounds!(opt, ones(length(p0))/10)
    initial_step!(opt,5e-2)

    # Objective Function
    #ll(x) = evaluate_iteration!(d, x)
    ll(x) = log_likelihood(d,x)
    #δ_cont(x) = contraction!(d,x,update=false)
    δ_cont(x) = contraction!(d,x)
    count = 0
    function ll(x, grad)
        count +=1
        println("Iteration $count at $x")
        #Store Gradient
        println("Step 1")
        δ_cont(x)
        # println("Step 2")
        # ForwardDiff.gradient!(grad, ll, x)
        # println("Gradient: $grad")
        likelihood = ll(x)
        println("likelihood equals $likelihood at $x on iteration $count")
        return likelihood
    end

    # Set Objective
    max_objective!(opt, ll)

    # Run Optimization
    minf, minx, ret = optimize(opt, p0)
    println("got $minf at $minx after $count iterations (returned $ret)")

    # Return the object
    return ret, minf, minx
end

function gradient_ascent(d,p0;init_step=1e-7,max_itr=2000)
    ## Initialize Parameter Vector
    p_vec = p0
    # Step Size
    #max_step = 1e-7
    step = init_step
    # Likelihood Functions
    ll(x) = log_likelihood(d,x)
    #ll(x) = evaluate_iteration!(d,x,update=false)
    # Tracking Variables
    count = 0
    err = 1
    tol = .01
    # # Initialize δ
    param_dict = parDict(d,p_vec)
    contraction!(d,param_dict)
    # Maximize by Gradient Ascent
    while (err>tol) & (count<max_itr)
        count+=1
        # Compute δ with Contraction
        if count % 2 == 0
            println("Update δ")
            param_dict = parDict(d,p_vec)
            contraction!(d,param_dict)
        end
        # Evaluate Likelihood
        f_eval = ll(p_vec)
        println("likelihood equals $f_eval on iteration $count")

        # Compute Gradient, holding δ fixed
        grad_new = similar(p_vec)
        ForwardDiff.gradient!(grad_new, ll, p_vec)
        println("Gradient is $grad_new")

        # Update Parameters
        p_vec += step.*grad_new
        println("Update Parameters to $p_vec")

        # New Step Size
        if count>1
            grad_diff = (grad_new-grad_old)
            step = abs(vecdot(step.*grad_new,grad_diff)/vecdot(grad_diff,grad_diff))
            grad_old = copy(grad_new)
            println("New optimal step size: $step")
        end
        #Update step size, gradient memory
        grad_old = copy(grad_new)
        #step = min(step,max_step)
    end
    return p_vec
end