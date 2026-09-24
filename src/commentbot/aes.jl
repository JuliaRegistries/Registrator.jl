# Minimal AES-128-CBC via libcrypto from OpenSSL_jll.
#
# Used to encrypt the registration metadata embedded in registry PR bodies.
# The format is unchanged from the previous MbedTLS-based implementation:
# `CONFIG["enc_key"]` is used as both the key and the IV, with PKCS#7 padding,
# so metadata in PRs opened before this change still decrypts.
# OpenSSL_jll is already part of the dependency tree through HTTP.jl (via
# Reseau on 2.x, OpenSSL.jl on 1.x).

import OpenSSL_jll: libcrypto

const AES_128_KEY_LEN = 16
const AES_BLOCK_LEN = 16

struct OpenSSLError <: Exception
    context::String
    msg::String
end

Base.showerror(io::IO, e::OpenSSLError) = print(io, "OpenSSLError in ", e.context, ": ", e.msg)

# libcrypto keeps a per-thread error queue. Every entry point below clears it
# first, so that an error left behind by some other libcrypto user (e.g. the
# HTTP.jl TLS backend, LibGit2 or libcurl) is not reported as ours.
_clear_openssl_errors() = @ccall libcrypto.ERR_clear_error()::Cvoid

function _throw_openssl_error(context::AbstractString)
    code = @ccall libcrypto.ERR_get_error()::Culong
    msg = if code == 0
        "unknown error"
    else
        buf = Vector{UInt8}(undef, 256)
        @ccall libcrypto.ERR_error_string_n(code::Culong, buf::Ptr{UInt8}, length(buf)::Csize_t)::Cvoid
        GC.@preserve buf unsafe_string(pointer(buf))
    end
    _clear_openssl_errors()
    throw(OpenSSLError(String(context), msg))
end

# Inputs are only read, never mutated, so a `Vector{UInt8}` is passed through as
# is and a `String`/`SubString{String}` is viewed through `codeunits` (zero-copy,
# ccall-convertible). Other string and byte-container types are copied into a
# `Vector{UInt8}`, since `codeunits` of an arbitrary `AbstractString` has no
# `pointer` and would fail inside the ccall.
_bytes(x::Union{String,SubString{String}}) = codeunits(x)
_bytes(x::AbstractString) = Vector{UInt8}(codeunits(x))
_bytes(x::Vector{UInt8}) = x
_bytes(x::AbstractVector{UInt8}) = Vector{UInt8}(x)

"""
    check_metadata_key(key)

Throw an `ArgumentError` unless `key` is a string or byte vector of exactly
`AES_128_KEY_LEN` bytes. Used both when the key is configured and on every
encrypt/decrypt call.
"""
function check_metadata_key(key)
    key === nothing &&
        throw(ArgumentError("commentbot.enc_key is not set; it must be a $AES_128_KEY_LEN-byte string"))
    key isa Union{AbstractString,AbstractVector{UInt8}} ||
        throw(ArgumentError("commentbot.enc_key must be a $AES_128_KEY_LEN-byte string, got $(typeof(key))"))
    n = length(_bytes(key))
    n == AES_128_KEY_LEN ||
        throw(ArgumentError("commentbot.enc_key must be $AES_128_KEY_LEN bytes, got $n"))
    key
end

# The 16-byte `key` doubles as the CBC IV (see the header comment); a valid
# AES-128 key is by construction a valid IV, so no separate IV check is needed.
function _aes_128_cbc(encrypt::Bool, key, data)
    key_b = _bytes(check_metadata_key(key))
    data_b = _bytes(data)
    # `EVP_CipherUpdate` takes the input length as a C `int`.
    length(data_b) <= typemax(Cint) ||
        throw(ArgumentError("input too large: $(length(data_b)) bytes"))

    enc = Cint(encrypt)
    _clear_openssl_errors()
    ctx = C_NULL
    try
        ctx = @ccall libcrypto.EVP_CIPHER_CTX_new()::Ptr{Cvoid}
        ctx == C_NULL && _throw_openssl_error("EVP_CIPHER_CTX_new")
        cipher = @ccall libcrypto.EVP_aes_128_cbc()::Ptr{Cvoid}
        cipher == C_NULL && _throw_openssl_error("EVP_aes_128_cbc")

        rc = @ccall libcrypto.EVP_CipherInit_ex(
            ctx::Ptr{Cvoid}, cipher::Ptr{Cvoid}, C_NULL::Ptr{Cvoid},
            key_b::Ptr{UInt8}, key_b::Ptr{UInt8}, enc::Cint)::Cint
        rc == 1 || _throw_openssl_error("EVP_CipherInit_ex")

        # CBC output is at most one block longer than the input.
        out = Vector{UInt8}(undef, length(data_b) + AES_BLOCK_LEN)
        outl = Ref{Cint}(0)
        rc = @ccall libcrypto.EVP_CipherUpdate(
            ctx::Ptr{Cvoid}, out::Ptr{UInt8}, outl::Ref{Cint},
            data_b::Ptr{UInt8}, length(data_b)::Cint)::Cint
        rc == 1 || _throw_openssl_error("EVP_CipherUpdate")
        n = Int(outl[])

        rc = GC.@preserve out @ccall libcrypto.EVP_CipherFinal_ex(
            ctx::Ptr{Cvoid}, pointer(out, n + 1)::Ptr{UInt8}, outl::Ref{Cint})::Cint
        # On decryption this is where a wrong key or corrupted data usually
        # shows up, as a padding check failure.
        rc == 1 || _throw_openssl_error("EVP_CipherFinal_ex")
        resize!(out, n + Int(outl[]))
        return out
    finally
        ctx != C_NULL && @ccall libcrypto.EVP_CIPHER_CTX_free(ctx::Ptr{Cvoid})::Cvoid
    end
end

"""
    encrypt_metadata(key, msg) -> Vector{UInt8}

Encrypt `msg` (a `String` or byte vector) with AES-128-CBC and PKCS#7 padding,
using the 16-byte `key` as both key and IV.
"""
encrypt_metadata(key, msg) = _aes_128_cbc(true, key, msg)

"""
    decrypt_metadata(key, data) -> Vector{UInt8}

Inverse of `encrypt_metadata`. Throws an `OpenSSLError` if the PKCS#7 padding
check fails, which is the usual outcome for data that was not encrypted with
`key`. There is no authentication, so a wrong key can occasionally (roughly 1
in 256) yield garbage bytes instead of an error; callers must validate the
result.
"""
decrypt_metadata(key, data) = _aes_128_cbc(false, key, data)
