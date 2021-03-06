addprocs(20)
using JLD
using CSV

@everywhere cd("$(homedir())/Documents/Research/Imperfect_Insurance_Competition/Code/Demand_Estimation")
# Data Structure
@everywhere include("InsChoiceData.jl")

#Halton Draws
@everywhere include("Halton.jl")

# Random Coefficients MLE
@everywhere include("NestedLogit_Basic.jl")
@everywhere include("Contraction.jl")
@everywhere include("Estimate_MLE_Basic.jl")
println("Code Loaded")


@everywhere include("load_ARCOLA_parallel.jl")
println("Data Loaded")
## Function to Execute Estimation
# Takes a starting point as an argument
@everywhere function estimate_parallel(p0::Vector{Float64})
    parStart0 = parDict(m,p0)
    # Estimate the Model
    est_ret,est_f,est_x = estimate!(m, p0)
    return est_ret,est_f,est_x
end

# Initial Parameters
p_list = []
for i in 1:20
    γ0start = -1
    γstart = (rand(4)*2 - 1)/100
    β0start = rand(6)*2 - 1
    βstart = (rand(6*3+4)*2 - 1)/2
    σstart = rand()
    p0 = vcat(γ0start,γstart,β0start,βstart,σstart)
    p_list = vcat(p_list,[p0])
end

res = pmap(estimate_parallel,p_list)

run = Dates.today()
file = "$(homedir())/Documents/Research/ARCOLA/Detailed Demand Estimation/estimationresults_pb_$run.jld"
save(file,"p_est",res)
