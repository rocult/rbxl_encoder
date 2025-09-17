--[[
    The types for the API dump.

    Needed to make the LSP's job easier...
]]

export type DumpRoot = {
    Properties: DumpProperties,
    ClassProperties: DumpClassProperties,
    Enums: DumpEnums
}

export type DumpProperties = {
    [string]: DumpProperty 
}

export type DumpClassProperties = {
    IsService: boolean,
    Properties: { [string]: DumpClass }
}

export type DumpEnums = {
    [string]: DumpEnum
}

export type DumpClass = {
    [string]: DumpProperty
}

export type DumpEnum = {
    [string]: number
}

export type DumpProperty = {
    Hidden: boolean,
    Type: string,
}

return require("./dump") :: DumpRoot
