--[[
    TODO: the buffer size is fixed and needs to be reallocated
]]

-- // Types
export type CursorData = {
    Buffer: buffer,
    Position: number,
}

-- // A simple cursor object
-- NOTE: providing a number larger than expected will result in the number being trimmed from the left (i.e. smaller).
local Cursor = {}
Cursor.__index = Cursor
export type Cursor = typeof(setmetatable({} :: CursorData, Cursor))
do
    function Cursor.new(Size: number?, Position: number?): Cursor
        -- // Create the object
        local self = setmetatable({}, Cursor)

        -- // Initialise the data
        self.Buffer = buffer.create(Size or 0)
        self.Position = Position or 0

        -- // Return the cursor
        return self
    end

    function Cursor.writebool(self: Cursor, Value: boolean)
        buffer.writeu8(self.Buffer, self.Position, Value and 1 or 0)
        self.Position += 1
    end

    function Cursor.writeu8(self: Cursor, Value: number)
        buffer.writeu8(self.Buffer, self.Position, Value)
        self.Position += 1
    end

    function Cursor.writeu32(self: Cursor, Value: number)
        buffer.writeu32(self.Buffer, self.Position, Value)
        self.Position += 4
    end

    function Cursor.writestring(self: Cursor, Value: string, Count: number?)
        buffer.writestring(self.Buffer, self.Position, Value, Count)
        self.Position += (Count or #Value)
    end

    function Cursor.copy(self: Cursor, Source: buffer, From: number?, Count: number?)
        buffer.copy(self.Buffer, self.Position, Source, From, Count)
        self.Position += (Count or buffer.len(Source))
    end

    function Cursor.fill(self: Cursor, Value: number, Count: number?)
        buffer.fill(self.Buffer, self.Position, Value, Count)
        self.Position += (Count or 1)
    end

    function Cursor.WriteInterleavedI32(self: Cursor, Values: {number})
        -- // Write an array of int32 values in interleaved byte order
        local Count = #Values
        if Count == 0 then return end

        -- // Prepare bytes
        local Bytes = {}
        for Index = 1, Count do
            local Value = Values[Index]
            Bytes[Index] = {
                bit32.band(bit32.rshift(Value, 24), 0xFF),
                bit32.band(bit32.rshift(Value, 16), 0xFF),
                bit32.band(bit32.rshift(Value, 8), 0xFF),
                bit32.band(Value, 0xFF)
            }
        end

        -- // Write interleaved
        for Byte = 1, 4 do
            for Index = 1, Count do
                self:writeu8(Bytes[Index][Byte])
            end
        end
    end

    function Cursor.BufferToPosition(self: Cursor)
        local Buffer = buffer.create(self.Position)
        buffer.copy(Buffer, 0, self.Buffer, 0, self.Position)
        return Buffer
    end
end
return Cursor
