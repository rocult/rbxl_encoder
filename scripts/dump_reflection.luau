-- // Dependencies
local LuaEncode = require("@pkgs/luaencode")
local Fs = require("@lune/fs")
local Net = require("@lune/net")
local Serde = require("@lune/serde")

-- // Download the API dump
local APIDumpData = Net.request(
    "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/refs/heads/roblox/Mini-API-Dump.json"
)
local APIDump = Serde.decode("json", APIDumpData.body)

-- // Initialise the working data
local FormattedDump = {
    Classes = {},
    Enums = {},
    ClassProperties = {},
    Properties = {},
    ExtraProperties = {},
    Version = APIDump.Version,
}

-- // Convert some arrays to dictionaries
for _, Class in APIDump.Classes do
    FormattedDump.Classes[Class.Name] = Class
end
for _, Enum in APIDump.Enums do
    FormattedDump.Enums[Enum.Name] = Enum
end

-- // Consolidate the properties of each class (DFS over inheritance with memoization)
do
    type PropInfo = { Hidden: boolean?, Type: string? }
    type PropSet = { Map: { [string]: PropInfo }, Index: { [string]: string } }

    local ClassMap = FormattedDump.Classes
    local Memo: { [string]: PropSet } = {}
    local Visiting: { [string]: boolean } = {}

    -- // Check whether `Tags` contain hidden
    local function HasHiddenTag(Tags: { any }?): boolean
        if Tags then
            return table.find(Tags, "Hidden") ~= nil
        end
        return false
    end

    -- // Used to dedupe properties like `className` to `ClassName`
    local function IsLeadingUpper(name: string): boolean
        local Byte = name:byte(1)
        return Byte ~= nil and Byte >= 65 and Byte <= 90
    end

    -- // Initialise a new [PropSet]. Always return fresh tables to avoid shared state.
    local function NewPropSet(): PropSet
        return { Map = {}, Index = {} }
    end

    -- // Insert a new property into the set
    local function AddOrReplaceProp(Set: PropSet, Name: string, Value: PropInfo)
        local LowerName = Name:lower()
        local ExistingKey = Set.Index[LowerName]

        -- // Does not already exist, insert
        if not ExistingKey then
            Set.Map[Name] = Value
            Set.Index[LowerName] = Name
            return
        end

        -- // Is proper casing, overwrite
        if not (IsLeadingUpper(Name) and not IsLeadingUpper(ExistingKey)) then
            Set.Map[ExistingKey] = Value
            return
        end

        -- // Overwrite
        Set.Map[Name] = Value
        Set.Index[LowerName] = Name

        -- // Prefer PascalCase-like names
        if Name ~= ExistingKey then
            Set.Map[ExistingKey] = nil
        end
    end

    -- // Merge two sets together
    local function MergeSets(into: PropSet, from: PropSet)
        for k, v in from.Map do
            AddOrReplaceProp(into, k, v)
        end
    end

    -- // Collect the props of a certain class object
    local function CollectOwnProps(Class: any): PropSet
        local Set = NewPropSet()
        local Members = Class and Class.Members
        local Tags = Class and Class.Tags
        if Members then
            for _, Member in Members do
                if Member.MemberType == "Property" then
                    local ValueType = Member.ValueType
                    local Type: string? = ValueType and ValueType.Name or nil
                    local Hidden = HasHiddenTag(Member.Tags)
                    local Property = if Hidden then { Hidden = true, Type = Type } else { Type = Type }

                    AddOrReplaceProp(Set, Member.Name, Property)
                end
            end
        end
        if Tags :: any then
            if table.find(Tags, "Service") then
                FormattedDump.ExtraProperties[Class.Name] = {
                    IsService = true
                }
            end
        end
        return Set
    end

    -- // DFS + memo to collect all the props for a class
    local function DFS(ClassName: string): PropSet
        -- // Check if we already have the properties for this class
        local Cached = Memo[ClassName]
        if Cached then
            return Cached
        end

        -- // Short-circuit to avoid infinite recursion
        if Visiting[ClassName] then
            return NewPropSet()
        end

        -- // Return empty to avoid errors...
        local Class = ClassMap[ClassName]
        if not Class then
            return NewPropSet()
        end

        -- // Mark this class as in progress
        Visiting[ClassName] = true

        -- // Merge in any superclass properties, if they have been processed
        local Result = NewPropSet()
        local Superclass = Class.Superclass
        if Superclass and Superclass ~= "" and ClassMap[Superclass] then
            local SuperclassProps = DFS(Superclass)
            MergeSets(Result, SuperclassProps)
        end

        -- // Merge the results back together
        MergeSets(Result, CollectOwnProps(Class))

        -- // Done with this class, memorise this
        Visiting[ClassName] = nil
        Memo[ClassName] = Result
        return Result
    end

    -- // DFS to get all properties
    for ClassName, _ in ClassMap do
        local Set = DFS(ClassName)
        local List = {}
        for PropertyName, Data in Set.Map do
            if FormattedDump.Properties[PropertyName] == nil then
                FormattedDump.Properties[PropertyName] = Data
            end
            table.insert(List, PropertyName)
        end
        FormattedDump.ClassProperties[ClassName] = List
    end
end

-- // Simplify the enum structure
local SimpleEnums = {}
for EnumName, Data in FormattedDump.Enums do
    local Map = {}
    local Items = Data.Items
    if not Items then
        SimpleEnums[EnumName] = Map
        continue
    end

    for _, Item in Items do
        Map[Item.Name] = Item.Value

        for _, LegacyName in Item.LegacyNames or {} do
            Map[LegacyName] = Item.Value
        end
    end
    SimpleEnums[EnumName] = Map
end

-- // Build Lua text for ClassProperties as a dict of name -> Properties[name]
local function BuildClassProps(): string
    -- // Build a table with placeholder strings as values, then encode and substitute once
    local Temporary = {}
    for ClassName, Properties in FormattedDump.ClassProperties do
        local Placeholders = table.clone(FormattedDump.ExtraProperties[ClassName] or {})
        Placeholders.Properties = {}
        if Properties then
            for _, PropertyName in Properties do
                Placeholders.Properties[PropertyName] = "___P___(" .. PropertyName .. ")"
            end
        end
        Temporary[ClassName] = Placeholders
    end

    local Encoded = LuaEncode(Temporary, { Prettify = true } :: any)
    return Encoded:gsub('"___P___%((.-)%)"', function(name)
        return ("Properties[" .. string.format("%q", name) .. "]")
    end) :: any
end

-- // Encode and write to file
local EncodedProperties = LuaEncode(FormattedDump.Properties, { Prettify = true } :: any)
local EncodedEnums = LuaEncode(SimpleEnums, { Prettify = true } :: any)
local ClassPropsLua = BuildClassProps()
local OutLua =
    `--!nocheck\n\nlocal Properties = {EncodedProperties}\nlocal Enums = {EncodedEnums}\nlocal ClassProperties = {ClassPropsLua}\nreturn \{\n    Properties = Properties,\n    ClassProperties = ClassProperties,\n    Enums = Enums\n}`
Fs.writeFile("./src/modules/reflection/dump.luau", OutLua)
