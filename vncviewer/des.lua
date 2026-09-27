--[[--
DES-ECB, used only for the RFB 3.8 "VNC Authentication" security type.

Hand-rolled because the OpenSSL 1.x `DES_*` symbols are deprecated (and absent from
KOReader's `ffi/crypto.lua` wrapper), and because exactly 32 bytes are ever encrypted per
connection, so throughput is irrelevant: a plain bit-array Feistel implementation is used
for obvious correctness over speed.

The algorithm is the standard FIPS PUB 46-3 DES (see RFC 6143 §7.2.2).

@module vncviewer.des
]]

local bit = require("bit")

local lshift, rshift = bit.lshift, bit.rshift

local Des = {}

-- Permutation tables, 1-based bit positions (bit 1 = MSB of the first byte).
local IP = {
    58, 50, 42, 34, 26, 18, 10, 2,
    60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6,
    64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9, 1,
    59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5,
    63, 55, 47, 39, 31, 23, 15, 7,
}

local FP = {
    40, 8, 48, 16, 56, 24, 64, 32,
    39, 7, 47, 15, 55, 23, 63, 31,
    38, 6, 46, 14, 54, 22, 62, 30,
    37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28,
    35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26,
    33, 1, 41, 9, 49, 17, 57, 25,
}

local E = {
    32, 1, 2, 3, 4, 5,
    4, 5, 6, 7, 8, 9,
    8, 9, 10, 11, 12, 13,
    12, 13, 14, 15, 16, 17,
    16, 17, 18, 19, 20, 21,
    20, 21, 22, 23, 24, 25,
    24, 25, 26, 27, 28, 29,
    28, 29, 30, 31, 32, 1,
}

local P = {
    16, 7, 20, 21, 29, 12, 28, 17,
    1, 15, 23, 26, 5, 18, 31, 10,
    2, 8, 24, 14, 32, 27, 3, 9,
    19, 13, 30, 6, 22, 11, 4, 25,
}

local PC1 = {
    57, 49, 41, 33, 25, 17, 9,
    1, 58, 50, 42, 34, 26, 18,
    10, 2, 59, 51, 43, 35, 27,
    19, 11, 3, 60, 52, 44, 36,
    63, 55, 47, 39, 31, 23, 15,
    7, 62, 54, 46, 38, 30, 22,
    14, 6, 61, 53, 45, 37, 29,
    21, 13, 5, 28, 20, 12, 4,
}

local PC2 = {
    14, 17, 11, 24, 1, 5,
    3, 28, 15, 6, 21, 10,
    23, 19, 12, 4, 26, 8,
    16, 7, 27, 20, 13, 2,
    41, 52, 31, 37, 47, 55,
    30, 40, 51, 45, 33, 48,
    44, 49, 39, 56, 34, 53,
    46, 42, 50, 36, 29, 32,
}

local SHIFTS = { 1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1 }

local SBOX = {
    { -- S1
        14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
        0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
        4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
        15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
    },
    { -- S2
        15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
        3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
        0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
        13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
    },
    { -- S3
        10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
        13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
        13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
        1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
    },
    { -- S4
        7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
        13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
        10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
        3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
    },
    { -- S5
        2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
        14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
        4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
        11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
    },
    { -- S6
        12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
        10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
        9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
        4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
    },
    { -- S7
        4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
        13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
        1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
        6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
    },
    { -- S8
        13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
        1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
        7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
        2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
    },
}

--- Reverse the bits of a byte (`0x01 -> 0x80`). VNC Authentication bit-reverses each key byte.
--- @treturn number
function Des.reverse_bits(b)
    local r = 0
    for i = 0, 7 do
        if bit.band(b, lshift(1, i)) ~= 0 then
            r = r + lshift(1, 7 - i)
        end
    end
    return r
end

local function bytes_to_bits(s)
    local bits = {}
    local n = #s
    for i = 1, n do
        local b = s:byte(i)
        for j = 7, 0, -1 do
            bits[#bits + 1] = bit.band(b, lshift(1, j)) ~= 0 and 1 or 0
        end
    end
    return bits
end

local function bits_to_bytes(bits, nbytes)
    local out = {}
    for i = 0, nbytes - 1 do
        local v = 0
        for j = 0, 7 do
            v = v * 2 + bits[i * 8 + j + 1]
        end
        out[#out + 1] = string.char(v)
    end
    return table.concat(out)
end

local function permute(input, tbl)
    local out = {}
    for i = 1, #tbl do
        out[i] = input[tbl[i]]
    end
    return out
end

local function xor_into(a, b)
    for i = 1, #a do
        a[i] = a[i] ~= b[i] and 1 or 0
    end
    return a
end

local function rotl28(arr, n)
    local out = {}
    for i = 1, 28 do
        out[i] = arr[(i - 1 + n) % 28 + 1]
    end
    return out
end

local function substitute(bits48)
    local out = {}
    for s = 1, 8 do
        local o = (s - 1) * 6
        local b1, b2, b3, b4, b5, b6 =
            bits48[o + 1], bits48[o + 2], bits48[o + 3], bits48[o + 4], bits48[o + 5], bits48[o + 6]
        local row = b1 * 2 + b6
        local col = ((b2 * 2 + b3) * 2 + b4) * 2 + b5
        local v = SBOX[s][row * 16 + col + 1]
        out[#out + 1] = rshift(v, 3) % 2
        out[#out + 1] = rshift(v, 2) % 2
        out[#out + 1] = rshift(v, 1) % 2
        out[#out + 1] = v % 2
    end
    return out
end

local function subkeys(key_bits)
    local k = permute(key_bits, PC1)
    local keys = {}
    for round = 1, 16 do
        local c, d = {}, {}
        for i = 1, 28 do c[i] = k[i] end
        for i = 1, 28 do d[i] = k[28 + i] end
        c = rotl28(c, SHIFTS[round])
        d = rotl28(d, SHIFTS[round])
        for i = 1, 28 do k[i] = c[i] end
        for i = 1, 28 do k[28 + i] = d[i] end
        keys[round] = permute(k, PC2)
    end
    return keys
end

--[[--
Encrypts one 8-byte block under an 8-byte key (DES-ECB, no IV).
--- @tparam string key8
--- @tparam string block8
--- @treturn string ciphertext (8 bytes)
]]
function Des.ecb_encrypt_block(key8, block8)
    assert(#key8 == 8, "DES key must be 8 bytes")
    assert(#block8 == 8, "DES block must be 8 bytes")
    local keys = subkeys(bytes_to_bits(key8))
    local bits = permute(bytes_to_bits(block8), IP)
    local l, r = {}, {}
    for i = 1, 32 do l[i] = bits[i] end
    for i = 1, 32 do r[i] = bits[32 + i] end
    for round = 1, 16 do
        local e = permute(r, E)
        xor_into(e, keys[round])
        local f = permute(substitute(e), P)
        local newr = xor_into(l, f)
        l = r
        r = newr
    end
    local pre = {}
    for i = 1, 32 do pre[i] = r[i] end
    for i = 1, 32 do pre[32 + i] = l[i] end
    return bits_to_bytes(permute(pre, FP), 8)
end

return Des
