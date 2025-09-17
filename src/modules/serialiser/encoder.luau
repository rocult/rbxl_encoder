--[[
    The encoder is a raw serializer with minimal checks and utility.
]]

-- // Dependencies
local CursorObject = require("@modules/cursor")
local DictLength = require("@functions/dict_length")

-- // Types
export type FileHeader = {
    UniqueClassCount: number, -- u32
    InstanceCount: number, -- u32
}
export type MetaChunk = {
    [string]: string,
}
export type SharedStringChunk = {
    MD5: string, -- 16 bytes
    SharedString: string,
}
export type InstChunk = {
    ClassId: number, -- u32
    ClassName: string,
    ObjectFormat: boolean, -- true = service
}
export type InstChunkReferent = {
    Id: number,
    Service: boolean,
}
export type PrntSubChunk = {
    Id: number,
    Parent: number,
}
export type PropChunk = {
    ClassId: number, -- u32
    Name: string,
    TypeId: number, -- u8
}

-- Small helper type for Color3uint8-style inputs
export type Color3u8 = { R: number, G: number, B: number }

export type RbxlEncoderData = {
    Cursor: CursorObject.Cursor,
}

-- // Handles the creation of `.rbxl` files
local RbxlEncoder = {}
RbxlEncoder.__index = RbxlEncoder
export type RbxlEncoder = typeof(setmetatable({} :: RbxlEncoderData, RbxlEncoder))
do
    -- // Helpers (encoding/packing)

    -- ZigZag transform for signed 32-bit -> unsigned 32-bit
    local function zigzag32(n: number): number
        n = math.floor(n)
        if n >= 0 then
            return n * 2
        else
            return -n * 2 - 1
        end
    end

    -- Convert Lua number (double) to IEEE-754 float32 bits (unsigned 32-bit)
    local function f32_ieee_bits(x: number): number
        if x ~= x then -- NaN
            return 0x7FC00000
        end
        if x == math.huge then
            return 0x7F800000
        elseif x == -math.huge then
            return 0xFF800000
        end

        if x == 0 then
            return 0
        end

        local sign = 0
        if x < 0 then
            sign = 1
            x = -x
        end

        -- frexp: x = m * 2^e with 0.5 <= m < 1
        local m, e = math.frexp(x)
        -- Normalized exponent (bias 127) for float where real = e-1
        local exp = e + 126

        if exp <= 0 then
            -- Subnormal number: exponent = 0, mantissa = round(x * 2^149)
            local mant = math.floor(x * (2 ^ 149) + 0.5)
            if mant >= 0x800000 then
                mant = 0x7FFFFF
            end
            return bit32.bor(bit32.lshift(sign, 31), mant)
        end

        if exp >= 0xFF then
            -- Overflow to infinity
            return bit32.bor(bit32.lshift(sign, 31), 0x7F800000)
        end

        -- Mantissa: remove the implicit leading 1
        local frac = m * 2 - 1 -- now in [0,1)
        local mant = math.floor(frac * (2 ^ 23) + 0.5)
        if mant >= 0x800000 then
            mant = 0
            exp += 1
            if exp >= 0xFF then
                return bit32.bor(bit32.lshift(sign, 31), 0x7F800000)
            end
        end

        return bit32.bor(bit32.lshift(sign, 31), bit32.lshift(exp, 23), mant)
    end

    -- Convert IEEE float32 bits to Roblox float format bits (big-endian when written)
    local function f32_roblox_bits(x: number): number
        local ieee = f32_ieee_bits(x)
        local signBit = bit32.rshift(ieee, 31) -- 0 or 1
        local expBits = bit32.band(bit32.rshift(ieee, 23), 0xFF)
        local mantBits = bit32.band(ieee, 0x7FFFFF)
        -- Roblox layout: [exp:8][mant:23][sign:1]
        local out = bit32.bor(bit32.lshift(expBits, 24), bit32.lshift(mantBits, 1), signBit)
        return out
    end

    -- Write a u32 to buffer in big-endian order at given offset
    local function write_be_u32(buf: buffer, off: number, val: number)
        buffer.writeu8(buf, off + 0, bit32.band(bit32.rshift(val, 24), 0xFF))
        buffer.writeu8(buf, off + 1, bit32.band(bit32.rshift(val, 16), 0xFF))
        buffer.writeu8(buf, off + 2, bit32.band(bit32.rshift(val, 8), 0xFF))
        buffer.writeu8(buf, off + 3, bit32.band(val, 0xFF))
    end

    local function _write_le_u32(buf: buffer, off: number, val: number)
        buffer.writeu8(buf, off + 0, bit32.band(val, 0xFF))
        buffer.writeu8(buf, off + 1, bit32.band(bit32.rshift(val, 8), 0xFF))
        buffer.writeu8(buf, off + 2, bit32.band(bit32.rshift(val, 16), 0xFF))
        buffer.writeu8(buf, off + 3, bit32.band(bit32.rshift(val, 24), 0xFF))
    end

    RbxlEncoder.META = 0x4d_45_54_41
    RbxlEncoder.SSTR = 0x53_53_54_52
    RbxlEncoder.INST = 0x49_4e_53_54
    RbxlEncoder.PROP = 0x50_52_4f_50
    RbxlEncoder.PRNT = 0x50_52_4e_54
    RbxlEncoder.END = 0x45_4e_44_00

    RbxlEncoder.StringTypeId = 0x1
    RbxlEncoder.BoolTypeId = 0x2
    RbxlEncoder.Int32TypeId = 0x3
    RbxlEncoder.Float32TypeId = 0x4
    RbxlEncoder.Float64TypeId = 0x5
    RbxlEncoder.UDimTypeId = 0x6
    RbxlEncoder.UDim2TypeId = 0x7
    RbxlEncoder.RayTypeId = 0x8
    RbxlEncoder.FacesTypeId = 0x9
    RbxlEncoder.AxesTypeId = 0xA
    RbxlEncoder.BrickColorTypeId = 0xB
    RbxlEncoder.Color3TypeId = 0xC
    RbxlEncoder.Vector2TypeId = 0xD
    RbxlEncoder.Vector3TypeId = 0xE
    RbxlEncoder.CFrameTypeId = 0x10
    RbxlEncoder.EnumTypeId = 0x12
    RbxlEncoder.ReferentTypeId = 0x13
    RbxlEncoder.Vector3int16TypeId = 0x14
    RbxlEncoder.NumberSequenceTypeId = 0x15
    RbxlEncoder.ColorSequenceTypeId = 0x16
    RbxlEncoder.NumberRangeTypeId = 0x17
    RbxlEncoder.RectTypeId = 0x18
    RbxlEncoder.PhysicalPropertiesTypeId = 0x19
    RbxlEncoder.Color3uint8TypeId = 0x1A
    RbxlEncoder.Int64TypeId = 0x1B
    RbxlEncoder.SharedStringTypeId = 0x1C
    RbxlEncoder.BytecodeTypeId = 0x1D
    RbxlEncoder.OptionalCoordinateFrameTypeId = 0x1E
    RbxlEncoder.UniqueIdTypeId = 0x1F
    RbxlEncoder.FontTypeId = 0x20
    RbxlEncoder.ContentTypeId = 0x22

    function RbxlEncoder.new(): RbxlEncoder
        -- // Create the object
        local self = setmetatable({}, RbxlEncoder)

        -- // Initialise data
        self.Cursor = CursorObject.new(16)

        -- // Return the object
        return self
    end

    function RbxlEncoder.InitaliseHeader(self: RbxlEncoder, Data: FileHeader)
        local Cursor = self.Cursor

        -- // A constant header (magic number, signature, version)
        Cursor:writestring("<roblox!")
        Cursor:writeu32(0x_89_FF_0D_0A)
        Cursor:writeu32(0x1A_0A_00_00)

        -- // Counts
        Cursor:writeu32(Data.UniqueClassCount)
        Cursor:writeu32(Data.InstanceCount)
        Cursor:fill(0, 8)
    end

    function RbxlEncoder.WriteChunk(
        self: RbxlEncoder,
        HeaderName: number --[[u32]],
        Data: buffer
    )
        local Cursor = self.Cursor
        local CompressedData = lz4compress(buffer.tostring(Data))

        -- // The chunk's header
        Cursor:writeu32(HeaderName)
        Cursor:writeu32(#CompressedData)
        Cursor:writeu32(buffer.len(Data))
        Cursor:fill(0, 4)

        -- // Then the actual data
        Cursor:copy(Data)
    end

    function RbxlEncoder.WriteString(self: RbxlEncoder, String: string)
        local Cursor = self.Cursor
        Cursor:writeu32(#String)
        Cursor:writestring(String)
    end

    function RbxlEncoder.WriteMetaChunk(self: RbxlEncoder, Data: MetaChunk)
        local Length = DictLength(Data)
        local Cursor = CursorObject.new(Length * 3)

        Cursor:writeu32(Length)
        for i, v in Data do
            self:WriteString(i)
            self:WriteString(v)
        end

        self:WriteChunk(RbxlEncoder.META, Cursor:BufferToPosition())
    end

    function RbxlEncoder.WriteSharedStringChunk(self: RbxlEncoder, Data: { SharedStringChunk })
        local Cursor = CursorObject.new(#Data * 16 + 1)

        Cursor:writeu32(0)
        Cursor:writeu32(#Data)

        for _, v in Data do
            Cursor:writestring(v.MD5, 16)
            self:WriteString(v.SharedString)
        end

        self:WriteChunk(RbxlEncoder.SSTR, Cursor:BufferToPosition())
    end

    function RbxlEncoder.WriteInstChunk(self: RbxlEncoder, Header: InstChunk, Data: { InstChunkReferent })
        local Count = #Data
        local Cursor = self.Cursor
        local Referents = table.create(Count, 0)
        local ServiceMarkers = table.create(Count, false) :: { boolean }

        for i, v in Data do
            Referents[i] = v.Id
            ServiceMarkers[i] = v.Service
        end

        Cursor:writeu32(Header.ClassId)
        self:WriteString(Header.ClassName)
        Cursor:writebool(Header.ObjectFormat)
        Cursor:writeu32(Count)

        Cursor:WriteInterleavedI32(Referents)

        for _, v in ServiceMarkers do
            Cursor:writebool(v)
        end
    end

    function RbxlEncoder.WritePropChunk(self: RbxlEncoder, Data: PropChunk, Values: buffer)
        local Cursor = self.Cursor

        Cursor:writeu32(Data.ClassId)
        self:WriteString(Data.Name)
        Cursor:writeu8(Data.TypeId)

        Cursor:copy(Values)
    end

    function RbxlEncoder.WritePrntChunk(self: RbxlEncoder, Data: { PrntSubChunk })
        local Cursor = self.Cursor

        local Count = #Data
        local Children = table.create(Count) :: { number }
        local Parents = table.create(Count) :: { number }
        for i, v in Data do
            Children[i] = v.Id
            Parents[i] = v.Parent
        end

        Cursor:writeu8(0)
        Cursor:writeu32(Count)
        Cursor:WriteInterleavedI32(Children)
        Cursor:WriteInterleavedI32(Parents)
    end

    function RbxlEncoder.WriteEndChunk(self: RbxlEncoder)
        self:WriteChunk(RbxlEncoder.END, buffer.fromstring("</roblox>"))
    end

    function RbxlEncoder.CreateString(Value: string): buffer
        local Length = #Value
        local Buffer = buffer.create(4 + Length)
        buffer.writeu32(Buffer, 0, Length)
        buffer.writestring(Buffer, 4, Value)
        return Buffer
    end

    function RbxlEncoder.CreateBool(Value: boolean): buffer
        local Buffer = buffer.create(1)
        buffer.writeu8(Buffer, 0, Value and 1 or 0)
        return Buffer
    end

    function RbxlEncoder.CreateInt32(Value: number): buffer
        local t = zigzag32(Value)
        local Buffer = buffer.create(4)
        write_be_u32(Buffer, 0, t)
        return Buffer
    end

    function RbxlEncoder.CreateFloat32(Value: number): buffer
        local bits = f32_roblox_bits(Value)
        local Buffer = buffer.create(4)
        write_be_u32(Buffer, 0, bits)
        return Buffer
    end

    -- UDim: { Scale: number, Offset: number }
    function RbxlEncoder.CreateUDim(Value: UDim): buffer
        local Buffer = buffer.create(8)
        write_be_u32(Buffer, 0, f32_roblox_bits(Value.Scale))
        write_be_u32(Buffer, 4, zigzag32(Value.Offset))
        return Buffer
    end

    -- UDim2: { X: {Scale, Offset}, Y: {Scale, Offset} }
    function RbxlEncoder.CreateUDim2(Value: UDim2): buffer
        local Buffer = buffer.create(16)
        -- Order for a single value: X.Scale, Y.Scale, X.Offset, Y.Offset
        write_be_u32(Buffer, 0, f32_roblox_bits(Value.X.Scale))
        write_be_u32(Buffer, 4, f32_roblox_bits(Value.Y.Scale))
        write_be_u32(Buffer, 8, zigzag32(Value.X.Offset))
        write_be_u32(Buffer, 12, zigzag32(Value.Y.Offset))
        return Buffer
    end

    -- Vector2: { X: number, Y: number }
    function RbxlEncoder.CreateVector2(Value: Vector2): buffer
        local Buffer = buffer.create(8)
        write_be_u32(Buffer, 0, f32_roblox_bits(Value.X))
        write_be_u32(Buffer, 4, f32_roblox_bits(Value.Y))
        return Buffer
    end

    -- Vector3: { X: number, Y: number, Z: number }
    function RbxlEncoder.CreateVector3(Value: Vector3): buffer
        local Buffer = buffer.create(12)
        write_be_u32(Buffer, 0, f32_roblox_bits(Value.X))
        write_be_u32(Buffer, 4, f32_roblox_bits(Value.Y))
        write_be_u32(Buffer, 8, f32_roblox_bits(Value.Z))
        return Buffer
    end

    -- Color3: { R: number, G: number, B: number } components 0..1
    function RbxlEncoder.CreateColor3(Value: Color3): buffer
        local Buffer = buffer.create(12)
        write_be_u32(Buffer, 0, f32_roblox_bits(Value.R))
        write_be_u32(Buffer, 4, f32_roblox_bits(Value.G))
        write_be_u32(Buffer, 8, f32_roblox_bits(Value.B))
        return Buffer
    end

    -- Color3uint8: { R: number, G: number, B: number } components 0..255
    function RbxlEncoder.CreateColor3uint8(Value: Color3u8): buffer
        local Buffer = buffer.create(3)
        buffer.writeu8(Buffer, 0, Value.R)
        buffer.writeu8(Buffer, 1, Value.G)
        buffer.writeu8(Buffer, 2, Value.B)
        return Buffer
    end

    -- BrickColor: Number (u32, big-endian)
    function RbxlEncoder.CreateBrickColor(Colour: BrickColor): buffer
        local Buffer = buffer.create(4)
        write_be_u32(Buffer, 0, Colour.Number)
        return Buffer
    end

    -- Enum: Unsigned 32-bit big-endian
    function RbxlEncoder.CreateEnum(Value: EnumItem): buffer
        local Buffer = buffer.create(4)
        write_be_u32(Buffer, 0, Value.Value)
        return Buffer
    end

    -- Faces/Axes: byte bitfield
    function RbxlEncoder.CreateFaces(Faces: Faces): buffer
        local bits = 0
        if Faces.Front then
            bits = bit32.bor(bits, 0x01)
        end
        if Faces.Bottom then
            bits = bit32.bor(bits, 0x02)
        end
        if Faces.Left then
            bits = bit32.bor(bits, 0x04)
        end
        if Faces.Back then
            bits = bit32.bor(bits, 0x08)
        end
        if Faces.Top then
            bits = bit32.bor(bits, 0x10)
        end
        if Faces.Right then
            bits = bit32.bor(bits, 0x20)
        end
        local Buffer = buffer.create(1)
        buffer.writeu8(Buffer, 0, bits)
        return Buffer
    end

    function RbxlEncoder.CreateAxes(Axes: Axes): buffer
        local bits = 0
        if Axes.X then
            bits = bit32.bor(bits, 0x01)
        end
        if Axes.Y then
            bits = bit32.bor(bits, 0x02)
        end
        if Axes.Z then
            bits = bit32.bor(bits, 0x04)
        end
        local Buffer = buffer.create(1)
        buffer.writeu8(Buffer, 0, bits)
        return Buffer
    end

    -- Referent: Int32 transformed big-endian (single value; arrays use accumulation when reading)
    function RbxlEncoder.CreateReferent(id: number): buffer
        local Buffer = buffer.create(4)
        write_be_u32(Buffer, 0, zigzag32(id))
        return Buffer
    end

    -- Vector3int16: three little-endian i16 values
    function RbxlEncoder.CreateVector3int16(Value: Vector3int16): buffer
        local Buffer = buffer.create(6)
        buffer.writei16(Buffer, 0, Value.X)
        buffer.writei16(Buffer, 2, Value.Y)
        buffer.writei16(Buffer, 4, Value.Z)
        return Buffer
    end

    -- Ray: 6 little-endian IEEE-754 f32 (Origin XYZ, Direction XYZ)
    function RbxlEncoder.CreateRay(Value: Ray): buffer
        local o = Value.Origin
        local d = Value.Direction
        local Buffer = buffer.create(24)
        _write_le_u32(Buffer, 0, f32_ieee_bits(o.X))
        _write_le_u32(Buffer, 4, f32_ieee_bits(o.Y))
        _write_le_u32(Buffer, 8, f32_ieee_bits(o.Z))
        _write_le_u32(Buffer, 12, f32_ieee_bits(d.X))
        _write_le_u32(Buffer, 16, f32_ieee_bits(d.Y))
        _write_le_u32(Buffer, 20, f32_ieee_bits(d.Z))
        return Buffer
    end

    -- NumberRange: two little-endian IEEE-754 f32 {Min, Max}
    function RbxlEncoder.CreateNumberRange(Value: NumberRange): buffer
        local Buffer = buffer.create(8)
        _write_le_u32(Buffer, 0, f32_ieee_bits(Value.Min))
        _write_le_u32(Buffer, 4, f32_ieee_bits(Value.Max))
        return Buffer
    end

    -- Rect: four Roblox Float32 (big-endian) in order Min.X, Min.Y, Max.X, Max.Y
    function RbxlEncoder.CreateRect(Value: Rect): buffer
        local Buffer = buffer.create(16)
        write_be_u32(Buffer, 0, f32_roblox_bits(Value.Min.X))
        write_be_u32(Buffer, 4, f32_roblox_bits(Value.Min.Y))
        write_be_u32(Buffer, 8, f32_roblox_bits(Value.Max.X))
        write_be_u32(Buffer, 12, f32_roblox_bits(Value.Max.Y))
        return Buffer
    end

    -- PhysicalProperties: 0x00 or 0x01 + 5 little-endian f32
    function RbxlEncoder.CreatePhysicalProperties(Value: PhysicalProperties): buffer
        local Buffer = buffer.create(1 + 20)
        buffer.writeu8(Buffer, 0, 1)
        _write_le_u32(Buffer, 1, f32_ieee_bits(Value.Density))
        _write_le_u32(Buffer, 5, f32_ieee_bits(Value.Friction))
        _write_le_u32(Buffer, 9, f32_ieee_bits(Value.Elasticity))
        _write_le_u32(Buffer, 13, f32_ieee_bits(Value.FrictionWeight))
        _write_le_u32(Buffer, 17, f32_ieee_bits(Value.ElasticityWeight))
        return Buffer
    end

    -- SharedString index (into SSTR table): big-endian u32
    function RbxlEncoder.CreateSharedStringIndex(Index: number): buffer
        local Buffer = buffer.create(4)
        write_be_u32(Buffer, 0, math.floor(Index))
        return Buffer
    end

    -- Bytecode: same shape as String
    function RbxlEncoder.CreateBytecode(bytes: string): buffer
        return RbxlEncoder.CreateString(bytes)
    end

    -- Font: { Family: string, Weight: number, Style: number, CachedFaceId: string }
    function RbxlEncoder.CreateFont(Value: Font): buffer
        local family = Value.Family
        local cached = ""
        local weight = Value.Weight.Value
        local style = Value.Style.Value

        local famBuf = RbxlEncoder.CreateString(family)
        local cacBuf = RbxlEncoder.CreateString(cached)
        local total = buffer.len(famBuf) + 2 + 1 + buffer.len(cacBuf)
        local Buffer = buffer.create(total)
        local pos = 0
        buffer.copy(Buffer, pos, famBuf, 0, buffer.len(famBuf))
        pos += buffer.len(famBuf)
        buffer.writeu16(Buffer, pos, weight)
        pos += 2
        buffer.writeu8(Buffer, pos, style)
        pos += 1
        buffer.copy(Buffer, pos, cacBuf, 0, buffer.len(cacBuf))
        return Buffer
    end

    -- NumberSequence: u32 count + repeated (time,value,envelope) as little-endian f32
    function RbxlEncoder.CreateNumberSequence(Value: NumberSequence): buffer
        local keypoints = Value.Keypoints
        local count: number = #keypoints
        local Buffer = buffer.create(4 + count * 12)
        buffer.writeu32(Buffer, 0, count)
        local pos = 4
        for i = 1, count do
            local kp = keypoints[i]
            _write_le_u32(Buffer, pos + 0, f32_ieee_bits(kp.Time))
            _write_le_u32(Buffer, pos + 4, f32_ieee_bits(kp.Value))
            _write_le_u32(Buffer, pos + 8, f32_ieee_bits(kp.Envelope))
            pos += 12
        end
        return Buffer
    end

    -- ColorSequence: u32 count + repeated (time, r, g, b, envelope) as little-endian f32
    function RbxlEncoder.CreateColorSequence(Value: ColorSequence): buffer
        local keypoints = Value.Keypoints
        local count: number = #keypoints
        local Buffer = buffer.create(4 + count * 20)
        buffer.writeu32(Buffer, 0, count)
        local pos = 4
        for i = 1, count do
            local kp = keypoints[i]
            local c: Color3 = kp.Value
            _write_le_u32(Buffer, pos + 0, f32_ieee_bits(kp.Time))
            _write_le_u32(Buffer, pos + 4, f32_ieee_bits(c.R))
            _write_le_u32(Buffer, pos + 8, f32_ieee_bits(c.G))
            _write_le_u32(Buffer, pos + 12, f32_ieee_bits(c.B))
            _write_le_u32(Buffer, pos + 16, f32_ieee_bits(0))
            pos += 20
        end
        return Buffer
    end
end
return RbxlEncoder
