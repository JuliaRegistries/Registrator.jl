# Minimal AES-128-CBC via libcrypto from OpenSSL_jll.
#
# Used to encrypt the registration metadata embedded in registry PR bodies.
# The format is unchanged from the previous MbedTLS-based implementation:
# `CONFIG["enc_key"]` is used as both the key and the IV, with PKCS#7 padding,
# so metadata in PRs opened before this change still decrypts.
# OpenSSL_jll is already part of the dependency tree through HTTP.jl.

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
# HTTP.jl TLS backend) is not reported as ours.
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

_bytes(x::AbstractString) = Vector{UInt8}(codeunits(x))
_bytes(x::AbstractVector{UInt8}) = Vector{UInt8}(x)

function _aes_128_cbc(encrypt::Bool, key, iv, data)
    key_b, iv_b, data_b = _bytes(key), _bytes(iv), _bytes(data)
    length(key_b) == AES_128_KEY_LEN ||
        throw(ArgumentError("AES-128 key must be $AES_128_KEY_LEN bytes, got $(length(key_b))"))
    length(iv_b) == AES_BLOCK_LEN ||
        throw(ArgumentError("AES IV must be $AES_BLOCK_LEN bytes, got $(length(iv_b))"))

    op = encrypt ? "EVP_Encrypt" : "EVP_Decrypt"
    _clear_openssl_errors()
    ctx = C_NULL
    try
        ctx = @ccall libcrypto.EVP_CIPHER_CTX_new()::Ptr{Cvoid}
        ctx == C_NULL && _throw_openssl_error("EVP_CIPHER_CTX_new")
        cipher = @ccall libcrypto.EVP_aes_128_cbc()::Ptr{Cvoid}
        cipher == C_NULL && _throw_openssl_error("EVP_aes_128_cbc")

        # `@ccall` needs the literal symbol, hence the branches.
        rc = if encrypt
            @ccall libcrypto.EVP_EncryptInit_ex(
                ctx::Ptr{Cvoid}, cipher::Ptr{Cvoid}, C_NULL::Ptr{Cvoid}, key_b::Ptr{UInt8}, iv_b::Ptr{UInt8})::Cint
        else
            @ccall libcrypto.EVP_DecryptInit_ex(
                ctx::Ptr{Cvoid}, cipher::Ptr{Cvoid}, C_NULL::Ptr{Cvoid}, key_b::Ptr{UInt8}, iv_b::Ptr{UInt8})::Cint
        end
        rc == 1 || _throw_openssl_error("$(op)Init_ex")

        # CBC output is at most one block longer than the input.
        out = Vector{UInt8}(undef, length(data_b) + AES_BLOCK_LEN)
        outl = Ref{Cint}(0)
        rc = if encrypt
            @ccall libcrypto.EVP_EncryptUpdate(
                ctx::Ptr{Cvoid}, out::Ptr{UInt8}, outl::Ref{Cint}, data_b::Ptr{UInt8}, length(data_b)::Cint)::Cint
        else
            @ccall libcrypto.EVP_DecryptUpdate(
                ctx::Ptr{Cvoid}, out::Ptr{UInt8}, outl::Ref{Cint}, data_b::Ptr{UInt8}, length(data_b)::Cint)::Cint
        end
        rc == 1 || _throw_openssl_error("$(op)Update")
        n = Int(outl[])

        rc = GC.@preserve out begin
            tail = pointer(out, n + 1)
            if encrypt
                @ccall libcrypto.EVP_EncryptFinal_ex(ctx::Ptr{Cvoid}, tail::Ptr{UInt8}, outl::Ref{Cint})::Cint
            else
                @ccall libcrypto.EVP_DecryptFinal_ex(ctx::Ptr{Cvoid}, tail::Ptr{UInt8}, outl::Ref{Cint})::Cint
            end
        end
        # On decryption this is where a wrong key or corrupted data shows up,
        # as a padding check failure.
        rc == 1 || _throw_openssl_error("$(op)Final_ex")
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
encrypt_metadata(key, msg) = _aes_128_cbc(true, key, key, msg)

"""
    decrypt_metadata(key, data) -> Vector{UInt8}

Inverse of `encrypt_metadata`. Throws an `OpenSSLError` if `data` was not
encrypted with `key`.
"""
decrypt_metadata(key, data) = _aes_128_cbc(false, key, key, data)
