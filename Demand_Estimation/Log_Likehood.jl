using NLopt
using ForwardDiff

# Calculate Log Likelihood
function log_likelihood{T}(d::InsuranceLogit,p::parDict{T})
    ll = 0.0
    Pop = 0.0
    #α = p.α[1]
    # Calculate μ_ij, which depends only on parameters
    individual_values!(d,p)
    individual_shares(d,p)
    for app in eachperson(d.data)
    #app = next(eachperson(d.data),100)[1]
        ind = person(app)[1]
        S_ij = transpose(choice(app))
        wgt = transpose(weight(app))
        urate = transpose(unins(app))
        idxitr = d.data._personDict[ind]


        # Get Market Shares
        s_hat = p.s_hat[idxitr]
        s_insured = sum(s_hat)

        # Fix possible computational error
        if s_insured>=1
            s_insured= 1 - 1e-5
        end

        for i in eachindex(idxitr)
            ll+=wgt[i]*S_ij[i]*(log(s_hat[i]) -urate[i]*(log(s_insured)-log(1-s_insured)))
            #ll+=wgt[i]*S_ij[i]*(log(s_hat[i]))
            Pop+=wgt[i]*S_ij[i]
        end
        # if isnan(ll)
        #     println(ind)
        #     break
        # end
    end
    return ll/Pop
end

function log_likelihood!{T}(grad::Vector{Float64},d::InsuranceLogit,p::parDict{T})
    Q = d.parLength[:All]
    N = size(d.draws,1)
    grad[:] = 0.0
    ll = 0.0
    Pop =sum(weight(d.data).*choice(d.data))

    # Calculate μ_ij, which depends only on parameters
    individual_values!(d,p)
    individual_shares(d,p)

    shell_full = zeros(Q,N,38)
    for app in eachperson(d.data)
        K = length(person(app))
        # if K>k_max
        #     k_max = K
        # end
        shell = shell_full[:,:,1:K]
        ll_obs,grad_obs = ll_obs_gradient(app,d,p,shell)

        ll+=ll_obs
        for q in 1:Q
            grad[q]+=grad_obs[q]/Pop
        end
    end
    #println(k_max)
    return ll/Pop
end




function log_likelihood{T}(d::InsuranceLogit,p::Array{T})
    params = parDict(d,p)
    ll = log_likelihood(d,params)
    convert_δ!(d)
    return ll
end

function log_likelihood!{T}(grad::Vector{Float64},d::InsuranceLogit,p::Array{T})
    params = parDict(d,p)
    ll = log_likelihood!(grad,d,params)
    convert_δ!(d)
    return ll
end

#
# function ll_gradient!{T}(grad::Vector{Float64},d::InsuranceLogit,p::Array{T})
#     params = parDict(d,p)
#     grad = ll_gradient!(grad,d,params)
#     convert_δ!(d)
#     return grad
# end

function GMM_objective{T}(d::InsuranceLogit,p::Array{T})
    grad = ll_gradient(d,p)
    println("gradient equals $grad")
    obj = vecdot(grad,grad)
    return obj
end


function evaluate_iteration{T}(d::InsuranceLogit,p::parDict{T};update::Bool=true)
    contraction!(d,p,update=update)
    ll = log_likelihood(d,p)
    convert_δ!(d)
    return ll
end

function evaluate_iteration!{T}(d::InsuranceLogit, x::Array{T,1};update::Bool=true)
    # Create Parameter Types
    parameters = parDict(d,x)
    return evaluate_iteration(d,parameters,update=update)
end
