local function DictLength(Table: { [any]: any })
    local Counter = 0

    for _, _ in pairs(Table) do
        Counter += 1
    end

    return Counter
end
return DictLength
