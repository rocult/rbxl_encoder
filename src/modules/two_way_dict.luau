-- // Types
export type TwoWayDictData<T, U> = {
    Count: number,
    Forward: { [T]: U },
    Backward: { [U]: T },
}

-- //
local TwoWayDict = {}
TwoWayDict.__index = TwoWayDict
export type TwoWayDict<T, U> = typeof(setmetatable({} :: TwoWayDictData<T, U>, TwoWayDict))
do
    function TwoWayDict.new<T, U>(): TwoWayDict<T, U>
        -- // Create the object
        local self = setmetatable({}, TwoWayDict)

        -- // Initialise the properties
        self.Count = 0
        self.Forward = {}
        self.Backward = {}

        -- // Return the object
        return self
    end

    function TwoWayDict.Set<T, U>(self: TwoWayDict<T, U>, Key: T, Value: U)
        assert((Key :: any) ~= nil and (Value :: any) ~= nil, "key and value cannot be nil")
        self.Forward[Key] = Value
        self.Backward[Value] = Key
        self.Count += 1
    end

    function TwoWayDict.GetKey<T, U>(self: TwoWayDict<T, U>, Value: U): T?
        return self.Backward[Value]
    end

    function TwoWayDict.GetValue<T, U>(self: TwoWayDict<T, U>, Key: T): U?
        return self.Forward[Key]
    end

    function TwoWayDict.RemoveKey<T, U>(self: TwoWayDict<T, U>, Value: U)
        local Key = self.Backward[Value]
        if Key then
            self.Forward[Key] = nil
            self.Backward[Value] = nil
            self.Count -= 1
        end
    end

    function TwoWayDict.RemoveValue<T, U>(self: TwoWayDict<T, U>, Key: T)
        local Value = self.Forward[Key]
        if Value then
            self.Forward[Key] = nil
            self.Backward[Value] = nil
            self.Count -= 1
        end
    end
end
return TwoWayDict
