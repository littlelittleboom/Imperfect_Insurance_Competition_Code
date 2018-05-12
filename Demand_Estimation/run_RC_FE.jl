using BenchmarkTools
using JLD
using CSV

# Data Structure
include("InsChoiceData.jl")

#Halton Draws
include("Halton.jl")

# Random Coefficients MLE
include("RandomCoefficients.jl")
include("Contraction.jl")
include("Log_Likehood.jl")
include("Estimate_Basic.jl")
println("Code Loaded")

# Load the Data
include("load.jl")
# Structre the data
c = ChoiceData(df,df_mkt;
    demoRaw=[:AgeFE_31_40,
            :AgeFE_41_50,
            :AgeFE_51_64,
            :Family,
            :LowIncome],
    prodchars=[:Price,:AV],
    prodchars_0=[],
    fixedEffects=[:Firm])

# Fit into model
m = InsuranceLogit(c,500)
println("Data Loaded")

γ0start = 0.0
γstart = Array{Float64}([0.1,0.1,0.1,0.1,0.1])/100
β0start = [-1.0,1.0]
βstart = [0.02,0,0,0,0.02]
σstart = [.01,.01]
FEstart = zeros(size(c.fixedEffects,1))


p0 = vcat(γ0start,γstart,β0start,βstart,σstart,FEstart)
parStart0 = parDict(m,p0)


## Estimate
est_res = estimate!(m, p0)


rundate = Dates.today()
file = "$(homedir())/Documents/Research/Imperfect_Insurance_Competition/Estimation_Output/estimationresults_fe_rc_$rundate.jld"
save(file,"est_res",est_res)

flag, fval, p_est = est_res



# #parStart1 = parDict(m,p1)

#
# println("Gradient Test")
# f_ll(x) = log_likelihood(m,x)
# grad_1 = Vector{Float64}(length(p0))
# grad_2 = Vector{Float64}(length(p0))
# fval = log_likelihood!(grad_2,m,parStart0)
#
#
# fval_old = log_likelihood(m,p0)
# ForwardDiff.gradient!(grad_1,f_ll, p0)

#ll_gradient!(grad_2,m,p0)
#
# println(maximum(abs.(grad_1-grad_2)))
#
#
# app = next(eachperson(m.data),200)[1]
# @benchmark util_gradient(m,app,parStart0)
#
# grad = util_gradient(m,app,parStart0)
#
# println("Profiler")
# Profile.init()
# Profile.clear()
# Juno.@profile log_likelihood_new(grad_2,m,parStart0)
# Juno.profiletree()
# Juno.profiler()
#
