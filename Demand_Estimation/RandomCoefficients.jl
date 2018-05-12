import Base.getindex, Base.setindex!, Base.show
using NLopt
using ForwardDiff


########
# Parameter Structure
#########


type parDict{T}
    # Parameters
    γ_0::T
    γ::Vector{T}
    β_0::Vector{T}
    β::Matrix{T}
    σ::Vector{T}
    FE::Matrix{T}
    #Random Coefficients stored (function of σ and draws)
    randCoeffs::Array{T,2}
    # δ values for (ij) pairs
    δ::Vector{T}
    # Non-delta utility for (ij) pairs and draws
    μ_ij::Matrix{T}
    # Shares for (ij) pairs
    s_hat::Vector{T}
end

function parDict{T}(m::InsuranceLogit,x::Array{T})
    # Parameter Lengths from model
    γlen = 1 + m.parLength[:γ]
    β0len = γlen + m.parLength[:β]
    βlen = β0len + m.parLength[:γ]
    σlen = βlen + (m.parLength[:σ])
    FElen = σlen + m.parLength[:FE]

    # Distribute Parameters
    γ_0 = x[1]
    γ = x[2:γlen]
    β_0 = x[(γlen+1):β0len]
    β_vec = x[(β0len+1):βlen]
    σ = x[(βlen+1):σlen]
    FE_vec = x[(σlen+1):FElen]

    # Store FE as row Vector
    FE = Matrix{T}(1,length(FE_vec))
    FE[1,:] = FE_vec

    # Stack Beta into a matrix
    K = m.parLength[:β]
    N = m.parLength[:γ]
    β = Matrix{T}(K,N)

    ind = 0
    for i in 1:N, j in 1:K
        if j==1
            ind+=1
            β[j,i] = β_vec[ind]
        else
            β[j,i] = 0
        end
    end

    #Calculate Random Coefficients matrix
    (S,R) = size(m.draws)
    randCoeffs = Array{T,2}(S,m.parLength[:σ])
    calcRC!(randCoeffs,σ,m.draws)

    #Initialize (ij) pairs of deltas
    L, M = size(m.data.data)
    δ = Vector{T}(M)
    μ_ij = Matrix{T}(S,M)
    s_hat = Vector{T}(M)
    unpack_δ!(δ,m)

    return parDict{T}(γ_0,γ,β_0,β,σ,FE,randCoeffs,δ,μ_ij,s_hat)
end

function calcRC!{T,S}(randCoeffs::Array{S},σ::Array{T},draws::Array{Float64,2})
    (N,K) = size(randCoeffs)
    randCoeffs[:,1] = draws[:,1].*σ[1]
    #Skip Price Coefficient
    for k in 2:K,n in 1:N
        randCoeffs[n,k] = draws[n,2]*σ[k]
    end
    return Void
end


###########
# Calculating Preferences
###########

function calc_indCoeffs{T}(p::parDict{T},β::Array{T,1},d::T)
    Q = length(β)
    (N,K) = size(p.randCoeffs)
    β_i = Array{T,2}(N,Q)
    γ_i = d + p.randCoeffs[:,1]
    β_i[:,1] = β[1]

    for k in 2:Q, n in 1:N
        β_i[n,k] = β[k] + p.randCoeffs[n,k]
    end

    β_i = permutedims(β_i,(2,1))
    return β_i, γ_i
end

function individual_values!{T}(d::InsuranceLogit,p::parDict{T})
    # Calculate μ_ij, which depends only on parameters
    for app in eachperson(d.data)
        util_value!(app,p)
    end
    return Void
end

function util_value!{T}(app::ChoiceData,p::parDict{T})
    γ_0 = p.γ_0
    γ = p.γ
    β_0= p.β_0
    β = p.β
    fe = p.FE

    ind = person(app)[1]
    X = permutedims(prodchars(app),(2,1))
    Z = demoRaw(app)[:,1]
    F = fixedEffects(app)

    β_z = β*Z
    demos = γ_0 + vecdot(γ,Z)
    β_i, γ_i = calc_indCoeffs(p,β_z,demos)

    chars = X*β_i
    chars_0 = X*β_0

    # This is a row Vector
    controls = fe*F

    (K,N) = size(chars)
    idxitr = app._personDict[ind]
    for k = 1:K,n = 1:N
        u = exp(chars[k,n] + chars_0[k] + controls[k] + γ_i[n])
        p.μ_ij[n,idxitr[k]] = u
    end

    return Void
end

function calc_shares{T}(μ_ij::Array{T},δ::Vector{T})
    (N,K) = size(μ_ij)
    util = Matrix{T}(K,N)
    s_hat = Matrix{T}(K,N)

    for n in 1:N
        expsum = 1.0
        for i in 1:K
            a = μ_ij[n,i]*δ[i]
            util[i,n] = a
            expsum += a
        end
        for i in 1:K
            s_hat[i,n] = util[i,n]/expsum
        end
    end
    return mean(s_hat,2)
end

function individual_shares{T}(d::InsuranceLogit,p::parDict{T})
    # Store Parameters
    δ_long = p.δ
    μ_ij_large = p.μ_ij
    for idxitr in values(d.data._personDict)
        δ = δ_long[idxitr]
        u = μ_ij_large[:,idxitr]
        s = calc_shares(u,δ)
        p.s_hat[idxitr] = s
    end
    return Void
end


function gradient_char(app::ChoiceData,d::InsuranceLogit,char_deriv::Array{Float64,3})
    ## Model Information on Parameters Location in Parameter Vector
    γlen = 1 + d.parLength[:γ]
    β0len = γlen + d.parLength[:β]
    βlen = β0len + d.parLength[:γ]
    σlen = βlen + d.parLength[:σ]
    FElen = σlen + d.parLength[:FE]

    # Person Data
    X_t = prodchars(app)
    Z = demoRaw(app)[:,1]
    F_t = fixedEffects(app)

    fe_pars = σlen + find(maximum(F_t,2).>0)

    # Dimensions of Derivative Matrix - check
    K = size(X_t,2)
    N = size(d.draws,1)
    Q = d.parLength[:All]

    # Fill in Matrix
    #char_deriv = Array{Float64,3}(Q,N,K)
    # char_deriv = zeros(Q,N,K)

    for k in 1:K,n in 1:N
        for q in 1:σlen
            if q==1
                # Constant
                char_deriv[q,n,k] = 1
            elseif q<=γlen
                # Base Demographics
                char_deriv[q,n,k] = Z[q-1]
            elseif q<=β0len
                char_deriv[q,n,k] = X_t[q-γlen,k]
            elseif q<=βlen
                char_deriv[q,n,k] = X_t[1,k]*Z[q-β0len]
            elseif q<=(βlen+1)
                #Insurance Random Effect
                char_deriv[q,n,k] = d.draws[n,1]
            elseif q<=σlen
                #Quality Random Effect
                char_deriv[q,n,k] = d.draws[n,2]*X_t[1+q-(βlen+1),k]
            # else
            #     char_deriv[q,n,k] = 0.0
            end
        end
        for q in fe_pars
            char_deriv[q,n,k] = F_t[q-σlen,k]
        end
        #char_deriv[(σlen+1):FElen,n,k] = F_t[q-σlen,k]
    end

    return char_deriv
end

function util_gradient{T}(app::ChoiceData,d::InsuranceLogit,p::parDict{T},
                                shell::Array{Float64,3})

    # Person Data
    ind = person(app)[1]
    idxitr = app._personDict[ind]

    μ_ij = p.μ_ij[:,idxitr]
    δ    = p.δ[idxitr]
    #CharDerivs
    char_deriv = gradient_char(app,d,shell)

    #Fill the Gradient
    #grad = similar(char_deriv)
    calc_gradient!(char_deriv,μ_ij,δ)

    return μ_ij,δ,char_deriv
end

function calc_gradient!{T}(char_deriv::Array{Float64},
                            μ_ij::Array{T,2},δ::Vector{T})
    Q = size(char_deriv,1)
    (N,K) = size(μ_ij)
    #grad[:] = char_deriv
    for k in 1:K, n in 1:N, q in 1:Q
        char_deriv[q,n,k]*=μ_ij[n,k]*δ[k]
    end
    # for k = 1:K,n = 1:N,q in 1:Q
    #         grad[q,n,k] = char_deriv[q,n,k]*μ_ij[n,k]*δ[k]
    # end
    return Void
end


function ll_obs_gradient{T}(app::ChoiceData,d::InsuranceLogit,p::parDict{T},
                                shell::Array{Float64,3})
        ind = person(app)[1]
        S_ij = transpose(choice(app))
        wgt = transpose(weight(app))
        urate = transpose(unins(app))
        idxitr = d.data._personDict[ind]

        # Get Utility and derivative of Utility
        μ_ij, δ, dμ_ij = util_gradient(app,d,p,shell)

        #Get Market Shares
        s_hat = p.s_hat[idxitr]
        s_insured = sum(s_hat)
        # Fix possible computational error
        if s_insured>=1
            s_insured= 1 - 1e-5
        end

        # Initialize Gradient
        #(Q,N,K) = size(dμ_ij)
        Q = d.parLength[:All]
        (N,K) = size(μ_ij)
        grad_obs = zeros(Q)
        ll_obs = 0.0

        # Pre-Calculate Squares
        μ_ij_sums = 1.+μ_ij*δ
        μ_ij_sums_sq = (μ_ij_sums).^2

        # dμ_ij_sums = zeros(Q,N)
        # for q in 1:Q,n in 1:N,k in 1:K
        #     dμ_ij_sums[q,n]+=dμ_ij[q,n,k]
        # end
        dμ_ij_sums = sum(dμ_ij,3)[:,:,1]

        # Parameters that this observatoin affects
        anyPar = find(maximum(abs.(dμ_ij_sums),2).>0)

        # Calculate Likelihood and Gradient of this observation
        for k = 1:K
            # log likelihood
            ll_obs+=wgt[k]*S_ij[k]*(log(s_hat[k]) -urate[k]*(log(s_insured)-log(1-s_insured)))

            for q in anyPar
                #Gradient of Likelihood
                t1 = 0.0
                t2 = 0.0
                t3 = 0.0
                for n in 1:N
                    t1= t1 + dμ_ij[q,n,k]/μ_ij_sums[n]
                    t2= t2 + dμ_ij_sums[q,n]*μ_ij[n,k]*δ[k]/μ_ij_sums_sq[n]
                    t3= t3 + dμ_ij_sums[q,n]/μ_ij_sums_sq[n]
                end
                t1= t1/N
                t2= t2/N
                t3= t3/N

                grad_obs[q] += wgt[k]*S_ij[k]*( (1/s_hat[k])*(t1 - t2) -
                    urate[k]*( t3 )*(1/(s_insured) + 1/(1-s_insured) ) )
            end
        end
    return ll_obs, grad_obs
end
