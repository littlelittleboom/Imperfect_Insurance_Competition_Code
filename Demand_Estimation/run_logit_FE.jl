using BenchmarkTools
using JLD
using CSV

# Data Structure
include("InsChoiceData.jl")

#Halton Draws
include("Halton.jl")

# Random Coefficients MLE
include("BasicLogit.jl")
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
    fixedEffects=[:Firm,:Market])

# Fit into model
m = InsuranceLogit(c,1)


γ0start = 0.0
γstart = Array{Float64}([0.1,0.1,0.1,0.1,0.1])/100
#γstart = Array{Float64}([0,0,0,0,0,0,0])/100
β0start = [-1.0,1.0]
βstart = [0.01,0,0,0,0.01]
FEstart = zeros(length(c._fixedEffects))


#p0 = vcat(γstart,β0start,βstart,σstart)
p0 = vcat(γ0start,γstart,β0start,βstart,FEstart)
parStart0 = parDict(m,p0)

#parStart1 = parDict(m,p1)
println("Data Loaded")

println("Gradient Test")
# f_ll(x) = log_likelihood(m,x)
# grad_1 = Vector{Float64}(length(p0))
# grad_2 = Vector{Float64}(length(p0))
#
# fval = log_likelihood(m,p0)
# ForwardDiff.gradient!(grad_1,f_ll, p0)
# ll_gradient!(grad_2,m,p0)
#
# println(maximum(abs.(grad_1-grad_2)))

## Estimate
est_res = estimate!(m, p0)


rundate = Dates.today()
file = "$(homedir())/Documents/Research/Imperfect_Insurance_Competition/Estimation_Output/estimationresults_fe_$rundate.jld"
save(file,"est_res",est_res)

flag, fval, p_est = est_res

#p_est = rand(length(p0))-.5
println("Gradient Test")
f_ll(x) = log_likelihood(m,x)
# grad_1 = Vector{Float64}(length(p0))
# grad_2 = Vector{Float64}(length(p0))
#
# fval = log_likelihood(m,p_est)
# ForwardDiff.gradient!(grad_1,f_ll, p_est)
# ll_gradient!(grad_2,m,p_est)
#
# maximum(abs.(grad_1-grad_2))


println("Calculate Hessian")
Pop = sum(weight(m.data).*choice(m.data))
hess_exp = Matrix{Float64}(length(p_est),length(p_est))
#cfg2 = ForwardDiff.HessianConfig(ll, p_est, ForwardDiff.Chunk{3}());
hess_exp = ForwardDiff.hessian!(hess_exp,ll, p_est) #,cfg2)


Var = -inv(hess_exp)
stderr = sqrt.(diag(Var))
