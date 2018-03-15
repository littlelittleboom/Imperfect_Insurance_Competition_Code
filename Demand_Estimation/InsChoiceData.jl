using DataFrames
import Base.start, Base.next, Base.done, Base.getindex, Base.setindex!

abstract type
    ModelData
end


# Make a type to interface with the data for discrete choice models
struct ChoiceData <: ModelData
    # Matrix of the data (transposed, pre-sorted)
    data::Matrix{Float64}
    # Matrix of the product level data (pre-sorted)
    pdata
    # Identifiers
    person      # Application ID
    product     # Firm offerings in each market
    firm       # Firm ID
    market      # Rating Area - Metal Level
    # Index of the data column names
    index
    # Names of rows (columns of input data)
    prodchars   # Product Characteristics
    choice      # Binary choice indicator
    demoRaw    # Household Demographics - raw
    wgt     # Number of People in each type
    unins     # Outside Option Share
    # Precomputed Indices
    _person::Array{Int,1}
    _prodchars::Array{Int,1}
    _choice::Array{Int,1}
    _demoRaw::Array{Int,1}
    _wgt::Array{Int,1}
    _unins::Array{Int,1}

    # ID Lookup Mappings
    _personIDs::Array{Float64,1}
    _personDict::Dict{Int, UnitRange{Int}}
    _productDict::Dict{Int, Array{Int,1}}
end

function ChoiceData(data_choice::DataFrame,data_market::DataFrame;
        person=[:Person],
        firm=[:Firm],
        market=[:Market],
        product=[:Product],
        prodchars=[:Price,:MedDeduct,:MedOOP,:High],
        choice=[:S_ij],
        demoRaw=[:Age,:Family,:LowIncome],
        wgt=[:N],
        unins=[:unins_rate])

    # Get the size of the data
    n, k = size(data_choice)

    # Convert everything to an array once for performance
    i = hcat(Array{Float64}(data_choice[person]))
    f = hcat(Array(data_choice[firm]))
    m = hcat(Array(data_choice[market]))
    j = hcat(Array(data_choice[product]))
    X = hcat(Array{Float64}(data_choice[prodchars]))
    y = hcat(Array{Float64}(data_choice[choice]))
    Z = hcat(Array{Float64}(data_choice[demoRaw]))
    w = hcat(Array{Float64}(data_choice[wgt]))
    s0= hcat(Array{Float64}(data_choice[unins]))

    index = Dict{Symbol, Int}()
    dmat = Matrix{Float64}(n,0)

    # Create a data matrix, only including person id
    k = 0
    for (d, var) in zip([i,X, y, Z, w, s0], [person,prodchars,
        choice, demoRaw,wgt,unins])
        for l=1:size(d,2)
            k+=1
            dmat = hcat(dmat, d[:,l])
            index[var[l]] = k
        end
    end

    #Transpose data to store as rows
    dmat = permutedims(dmat,(2,1))
    i = permutedims(i,(2,1))
    j = permutedims(j,(2,1))

    # Precompute the row indices
    _person = getindex.(index,person)
    _prodchars = getindex.(index, prodchars)
    _choice = getindex.(index, choice)
    _demoRaw = getindex.(index, demoRaw)
    _wgt = getindex.(index, wgt)
    _unins = getindex.(index, unins)

    # Get Person ID Dictionary Mapping for Easy Subsets
    _personDict = Dict{Real, UnitRange{Int}}()
    allids = dmat[_person,:][1,:]
    uniqids = sort(unique(allids))

    for id in uniqids
        idx1 = searchsortedfirst(allids,id)
        idxJ = searchsortedlast(allids,id)
        _personDict[id] = idx1:idxJ
    end


    #Create Product Dictionary
    allprods = sort(unique(j))
    _productDict = Dict{Real, Array{Int}}()
    for id in allprods
        _productDict[id] = findin(j,id)
    end

    # Make the data object
    m = ChoiceData(dmat,data_market, i, j, f, m, index, prodchars, choice, demoRaw,
            wgt, unins, _person, _prodchars, _choice, _demoRaw,
            _wgt, _unins,uniqids,_personDict,_productDict)
    return m
end

# Defining Indexing Methods on ChoiceData
Symbols = Union{Symbol, Vector{Symbol}}
getindex(m::ChoiceData, idx) = m.data[idx,:]
getindex(m::ChoiceData, idx, cols) = m.data[idx, cols]
getindex(m::ChoiceData, idx::Array{Int,1}) = m.data[idx,:]
getindex(m::ChoiceData, idx::Array{Int,1}, cols::Array{Int,1}) = m.data[idx, cols]
getindex(m::ChoiceData, idx::Symbols) = m.data[getindex.(m.index, idx),:]
getindex(m::ChoiceData, idx::Symbols, cols) = m.data[getindex.(m.index, idx),cols]

# Define other retrieval methods on ChoiceData
person(m::ChoiceData)      = m[m._person]
prodchars(m::ChoiceData)   = m[m._prodchars]
choice(m::ChoiceData)      = m[m._choice]
demoRaw(m::ChoiceData)     = m[m._demoRaw]
weight(m::ChoiceData)      = m[m._wgt]
unins(m::ChoiceData)       = m[m._unins]

########################################################################
#################### Iterating over People ############################
########################################################################

# Quickly Generate Subsets on People
function subset{T<:ModelData}(d::T, idx)
    data = d.data[:,idx]
#    people = data[d._person,:]
    people = d.person
    products = d.product

    # Don't subset any other fields for now...
    return T(data,d.pdata, people,products,
    d.firm,    # Firm ID
    d.market,      # Rating Area - Metal Level
    # Index of the column names
    d.index,
    # Names of rows (columns of input data)
    d.prodchars,   # Product Characteristics
    d.choice,      # Binary choice indicator
    d.demoRaw,    # Household Demographics - raw
    d.wgt,     # Demographic Fixed Effects
    d.unins,    # Outside Option Share
    # Precomputed Indices
    d._person,
    d._prodchars,
    d._choice,
    d._demoRaw,
    d._wgt,
    d._unins,
    d._personIDs,
    d._personDict,
    d._productDict)
end

########## People Iterator ###############
# Define an Iterator Type
type PersonIterator
    data
    id
end

# Construct an iterator to loop over people
function eachperson(m::ChoiceData)
    #ids = sort(unique(person(m)))
    ids = m._personIDs
    return PersonIterator(m, ids)
end

# Make it actually iterable
start(itr::PersonIterator) = 1
function next(itr::PersonIterator, state)
    # Get the current market
    id = itr.id[state]

    # Find which indices to use
    idx = itr.data._personDict[id]

    # Subset the data to just look at the current market
    submod = subset(itr.data, idx)

    return submod, state + 1
end
done(itr::PersonIterator, state) = state > length(itr.id)