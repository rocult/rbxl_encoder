-- // Dependencies
local RbxlEncoder = require("@modules/serialiser/encoder")
local TwoWayDict = require("@modules/two_way_dict")
local Reflection = require("@modules/reflection")

-- // Types
export type RbxlSerialiserData = {
    Encoder: RbxlEncoder.RbxlEncoder,
    Dom: TwoWayDict.TwoWayDict<number, Instance>
}

-- // Vars
local I_MIN = -9007199254740991
local I_MAX = 9007199254740991

-- //
local RbxlSerialiser = {}
RbxlSerialiser.__index = RbxlSerialiser
export type RbxlSerialiser = typeof(setmetatable({} :: RbxlSerialiserData, RbxlSerialiser))
do
    local Rng = Random.new()

    function RbxlSerialiser.new(): RbxlSerialiser
        -- // Create the object
        local self = setmetatable({}, RbxlSerialiser)

        -- // Initialise properties
        self.Encoder = RbxlEncoder.new()
        self.Dom = TwoWayDict.new() :: TwoWayDict.TwoWayDict<number, Instance>

        -- // Return the object
        return self
    end

    -- // Simply collect all instances and add them to the internal DOM
    function RbxlSerialiser.AddInstances(self: RbxlSerialiser, Instances: { Instance })
        local Current = table.remove(Instances)
        while Current do
            for _, Child in Current:GetChildren() do
                table.insert(Instances, Child)
            end

            local Key = Rng:NextInteger(I_MIN, I_MAX)
            if not self.Dom:GetKey(Current) then
                self.Dom:Set(Key, Current)
            end

            Current = table.remove(Instances)
        end
    end

    -- // Grab all of the unique types
    function RbxlSerialiser.CollectTypeInfo(self: RbxlSerialiser, Instance: Instance)
        local Properties = Reflection.GetPropertiesOfInstance(Instance)
        for PropertyName, Value in Properties do
            local PropertyData = Reflection.Dump.Properties[PropertyName]
            if PropertyData.Type == "SharedString" then
                
            end
        end
    end
end
return RbxlSerialiser
