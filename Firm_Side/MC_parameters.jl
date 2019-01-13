mutable struct parMC{T}
    ## Decision Parameters
    pars::parDict{Float64}
    ## MC Parameters
    β_MC::Vector{T}

    ## Risk Cost
    risks::Matrix{T}

    ## Cost without risks
    C_nonrisk::Vector{T}

    ## Total Average Cost, with risks
    C::Vector{T}
    ## HCC Average Cost
    C_HCC::Vector{T}
end

struct MC_Data
    # Matrix of the data (transposed, pre-sorted)
    data::Matrix{Float64}

    # Matrix of Fixed Effects
    fixedEffects::Matrix{Float64}

    # Vector of HCC Prevalence
    anyHCC::Vector{Float64}

    # Parameter Indices
    _baseIndex::Vector{Int}
    _riskIndex::Int
    _feIndex::Vector{Int}

    # Moment Values
    _avgMomentDict::Dict{Int,Array{Int,1}}
    avgMoments::Vector{Float64}

    _ageMomentDict::Dict{Int,Array{Int,1}}
    ageMoments::Vector{Float64}

    riskMoment::Float64
end

function MC_Data(data_choice::DataFrame,
                mom_avg::DataFrame,
                mom_age::DataFrame,
                mom_risk::DataFrame;
        baseSpec=[:Age,:AV],
        fixedEffects=Vector{Symbol}(undef,0))
    # Get the size of the data
    n, k = size(data_choice)

    # Convert everything to an array once for performance
    data = convert(Array{Float64},data_choice[baseSpec])

    println("Create Fixed Effects")
    bigFirm = false
    F, feNames = build_FE(data_choice,fixedEffects,bigFirm = bigFirm)
    F = permutedims(F,(2,1))

    index = Dict{Symbol, Int}()
    for l=1:size(data,2)
        k+=1
        index[baseSpec[l]] = k
    end

    data = permutedims(data,(2,1))

    anyHCC = data_choice[:Any_HCC]

    ## Parameter Specification
    _baseIndex = 1:length(baseSpec)
    _riskIndex = maximum(_baseIndex) + 1
    _feIndex = maximum(_riskIndex) .+ (1:size(F,1))

    ### Moment Dictionaries
    println("Construct Moments")
    _avgMomentDict = Dict{Int,Array{Int64,1}}()
    moments = sort(unique(mom_avg[:M_num]))
    avgMoments = Vector{Float64}(undef,length(moments))
    for m in moments
        _avgMomentDict[m] = mom_avg[:index][findall(mom_avg[:M_num].==m)]
        avgMoments[m] = mom_avg[:logAvgCost][findall(mom_avg[:M_num].==m)][1]
    end

    _ageMomentDict = Dict{Int,Array{Int64,1}}()
    moments = sort(unique(mom_age[:M_num]))
    ageMoments = Vector{Float64}(undef,length(moments))
    for m in moments
        _ageMomentDict[m] = mom_age[:index][findall(mom_age[:M_num].==m)]
        ageMoments[m] = mom_age[:costIndex][findall(mom_age[:M_num].==m)][1]
    end

    riskMoment = mom_risk[:costIndex][2]


    return MC_Data(data,F,anyHCC,_baseIndex,_riskIndex,_feIndex,
                    _avgMomentDict,avgMoments,_ageMomentDict,ageMoments,riskMoment)
end



function parMC(p_MC::Vector{T},par_est::parDict{Float64},d::InsuranceLogit,c::MC_Data) where T

    # individual_shares(d,params)


    # Non Risk Costs
    basepars = p_MC[c._baseIndex]' * c.data
    fepars = p_MC[c._feIndex]' * c.fixedEffects
    C_nonrisk = basepars + fepars
    C_nonrisk = exp.(C_nonrisk[:])

    # Risk Costs
    risks = exp.(d.draws.*p_MC[c._riskIndex])


    ## Total Average Cost, with risks
    C = Vector{T}(undef,length(C_nonrisk))
    ## HCC Average Cost
    C_HCC = Vector{T}(undef,length(C_nonrisk))

    return parMC(par_est,p_MC,risks,C_nonrisk,C,C_HCC)
end


function individual_costs(d::InsuranceLogit,p::parMC{T}) where T
    # Store Parameters
    δ_long = p.pars.δ
    μ_ij_large = p.pars.μ_ij
    risk_long = rInd(d.data)
    cost_nonRisk = p.C_nonrisk
    anyHCC_ind = Float64.(d.draws.>0)
    for idxitr in values(d.data._personDict)
        δ = δ_long[idxitr]
        @inbounds u = μ_ij_large[:,idxitr]
        r_ind = Int.(risk_long[idxitr])
        @inbounds r_scores = p.risks[:,r_ind]
        @inbounds anyHCC_scores = anyHCC_ind[:,r_ind]
        c_nr = cost_nonRisk[idxitr]
        s,c,c_HCC = calc_cost(u,δ,r_scores,c_nr,anyHCC_scores)
        p.pars.s_hat[idxitr] = s
        p.C[idxitr] = c
        p.C_HCC[idxitr] = c_HCC
    end
    return Nothing
end


function calc_cost(μ_ij::Array{Float64},δ::Vector{Float64},r::Matrix{T},c::Vector{T},anyHCC::Matrix{Float64}) where T
    (N,K) = size(μ_ij)
    util = Matrix{Float64}(undef,K,N)
    s_hat = Matrix{Float64}(undef,K,N)
    c_hat = Matrix{T}(undef,K,N)
    c_hat_risk = Matrix{T}(undef,K,N)

    for n in 1:N
        expsum = 1.0
        #r_score = r[n,:]
        for i in 1:K
            @inbounds @fastmath a = μ_ij[n,i]*δ[i]
            @inbounds util[i,n] = a
            expsum += a
        end
        for i in 1:K
            @inbounds @fastmath s = util[i,n]/expsum
            @inbounds s_hat[i,n] = s
            @inbounds @fastmath cost = s*(r[n,i]*c[i])
            @inbounds c_hat[i,n] = cost
            @inbounds @fastmath c_hat_risk[i,n] = cost*(anyHCC[n,i])
        end
    end
    s_mean = mean(s_hat,dims=2)
    s_sum  = sum(s_hat,dims=2)
    c_mean = sum(c_hat,dims=2)./s_sum
    c_mean_risk = sum(c_hat_risk,dims=2)./s_sum
    return s_mean, c_mean, c_mean_risk
end



function costMoments(c::MC_Data,d::InsuranceLogit,p::parMC{T}) where T
    s_hat = p.pars.s_hat
    wgts = weight(d.data)[:]

    wgts_share = wgts.*s_hat
    any_share = wgts_share.*c.anyHCC
    none_share = wgts_share.*(1 .- c.anyHCC)

    c_hat = p.C

    pmom = Vector{T}(undef,length(c.avgMoments))
    amom = Vector{T}(undef,length(c.ageMoments)-1)

    ## Product and Firm Moments
    for (m,m_idx) in c._avgMomentDict
        c_avg = sliceMean_wgt(c_hat,wgts_share,m_idx)
        pmom[m] = log(c_avg) - c.avgMoments[m]
    end

    ## Age Moments
    refval = sliceMean_wgt(c_hat,wgts_share,c._ageMomentDict[1])
    for (m,m_idx) in c._ageMomentDict
        if m==1
            continue
        else
            c_avg = sliceMean_wgt(c_hat,wgts_share,m_idx)
            amom[m-1] = c_avg/refval[1] - c.ageMoments[m]
        end
    end
    all_idx = Int.(1:length(s_hat))
    HCC_avg = sliceMean_wgt(c_hat,any_share,all_idx)
    non_avg = sliceMean_wgt(c_hat,none_share,all_idx)
    rmom = HCC_avg/non_avg - c.riskMoment

    return vcat(pmom,amom,rmom)
end