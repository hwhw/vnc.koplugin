--[[--
KOReader key names / typed characters -> X11 keysyms (RFC 6143 Appendix A).

@module vncviewer.keysyms
]]

local Keysyms = {}

--- Special keys, indexed by KOReader's `Key.key` string.
--- `Sym`/`ScreenKB` are deliberately absent, and so is `" "` (space arrives via TextInput).
Keysyms.special = {
    Backspace = 0xFF08,
    Tab       = 0xFF09,
    Press     = 0xFF0D,
    Back      = 0xFF1B,
    Del       = 0xFFFF,
    Insert    = 0xFF63,
    Home      = 0xFF50,
    End       = 0xFF57,
    Left      = 0xFF51,
    Up        = 0xFF52,
    Right     = 0xFF53,
    Down      = 0xFF54,
    LPgBack   = 0xFF55,
    LPgFwd    = 0xFF55,
    RPgBack   = 0xFF56,
    RPgFwd    = 0xFF56,
    Shift     = 0xFFE1,
    Ctrl      = 0xFFE3,
    Alt       = 0xFFE9,
    AA        = 0xFFEA,
    Win       = 0xFFEB,
    Menu      = 0xFF67,
}

for i = 1, 12 do
    Keysyms.special["F" .. i] = 0xFFBE + (i - 1)
end

--- Decodes the first UTF-8 character of `ch` into a Unicode codepoint.
--- @treturn number|nil codepoint
function Keysyms.codepoint(ch)
    if not ch or ch == "" then return nil end
    local b1 = ch:byte(1)
    if b1 < 0x80 then return b1 end
    local b2 = ch:byte(2)
    if not b2 then return b1 end
    if b1 >= 0xC0 and b1 < 0xE0 then
        return (b1 - 0xC0) * 0x40 + (b2 - 0x80)
    end
    local b3 = ch:byte(3)
    if not b3 then return b1 end
    if b1 >= 0xE0 and b1 < 0xF0 then
        return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
    end
    local b4 = ch:byte(4)
    if not b4 then return b1 end
    return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80)
end

--- Maps one typed character to its X11 keysym (Latin-1 keysyms are the codepoint itself;
--- anything else uses the Unicode keysym range 0x01000000 + codepoint).
--- @treturn number|nil keysym
function Keysyms.from_char(ch)
    local cp = Keysyms.codepoint(ch)
    if not cp then return nil end
    if cp >= 0x20 and cp <= 0x7E then return cp end
    if cp >= 0xA0 and cp <= 0xFF then return cp end
    return 0x01000000 + cp
end

return Keysyms
