-- // Dependencies
local Dump = require("@modules/reflection/dump_typed")

-- // Get all of the properties of an instance
local function GetPropertiesOfInstance(Object: Instance): { [string]: any }
    local Properties = {}
    local DumpClass = Dump.ClassProperties.Properties[Object.ClassName]
    if not DumpClass then
        return Properties
    end

    for Property, Data in DumpClass do
        if Data.Hidden then
            Properties[Property] = gethiddenproperty(Object, Property)
        else
            Properties[Property] = (Object :: any)[Property]
        end
    end

    return Properties
end

-- // Return
return {
    Dump = Dump,
    GetPropertiesOfInstance = GetPropertiesOfInstance
}