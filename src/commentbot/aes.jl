# AES-128-CBC with PKCS#7 padding over OpenSSL's libcrypto EVP interface.
#
# The registration metadata embedded in registry PR bodies is encrypted with
# `CONFIG["enc_key"]` used as both the key and the IV. That format is kept
# as-is so PRs opened before this change can still be approved.

import OpenSSL_jll: libcrypto

const AES_128_KEY_LEN = 16
const AES_BLOCK_LEN = 16

function openssl_error(what::AbstractString)
    code = ccall((:ERR_get_error, libcrypto), Culong, ())
    ccall((:ERR_clear_error, libcrypto), Cvoid, ())
    if code == 0
        return ErrorException("$what failed")
    end
    buf = zeros(UInt8, 256)
    ccall((:ERR_error_string_n, libcrypto), Cvoid,
          (Culong, Ptr{UInt8}, Csize_t), code, buf, length(buf))
    ErrorException("$what failed: $(unsafe_string(pointer(buf)))")
end

function aes_128_cbc(encrypt::Bool, key, iv, data)
    key_b = Vector{UInt8}(codeunits(key))
    iv_b = Vector{UInt8}(codeunits(iv))
    data_b = data isa AbstractString ? Vector{UInt8}(codeunits(data)) : Vector{UInt8}(data)
    length(key_b) == AES_128_KEY_LEN ||
        throw(ArgumentError("AES-128 key must be $AES_128_KEY_LEN bytes, got $(length(key_b))"))
    length(iv_b) == AES_BLOCK_LEN ||
        throw(ArgumentError("AES IV must be $AES_BLOCK_LEN bytes, got $(length(iv_b))"))

    ccall((:ERR_clear_error, libcrypto), Cvoid, ())
    ctx = ccall((:EVP_CIPHER_CTX_new, libcrypto), Ptr{Cvoid}, ())
    ctx == C_NULL && throw(openssl_error("EVP_CIPHER_CTX_new"))
    try
        cipher = ccall((:EVP_aes_128_cbc, libcrypto), Ptr{Cvoid}, ())
        op = encrypt ? "EVP_Encrypt" : "EVP_Decrypt"

        ok = if encrypt
            ccall((:EVP_EncryptInit_ex, libcrypto), Cint,
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}),
                  ctx, cipher, C_NULL, key_b, iv_b)
        else
            ccall((:EVP_DecryptInit_ex, libcrypto), Cint,
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}),
                  ctx, cipher, C_NULL, key_b, iv_b)
        end
        ok == 1 || throw(openssl_error("$(op)Init_ex"))

        out = Vector{UInt8}(undef, length(data_b) + AES_BLOCK_LEN)
        outl = Ref{Cint}(0)
        ok = if encrypt
            ccall((:EVP_EncryptUpdate, libcrypto), Cint,
                  (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}, Ptr{UInt8}, Cint),
                  ctx, out, outl, data_b, length(data_b))
        else
            ccall((:EVP_DecryptUpdate, libcrypto), Cint,
                  (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}, Ptr{UInt8}, Cint),
                  ctx, out, outl, data_b, length(data_b))
        end
        ok == 1 || throw(openssl_error("$(op)Update"))
        n = Int(outl[])

        GC.@preserve out begin
            ok = if encrypt
                ccall((:EVP_EncryptFinal_ex, libcrypto), Cint,
                      (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}),
                      ctx, pointer(out, n + 1), outl)
            else
                ccall((:EVP_DecryptFinal_ex, libcrypto), Cint,
                      (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}),
                      ctx, pointer(out, n + 1), outl)
            end
        end
        ok == 1 || throw(openssl_error("$(op)Final_ex"))
        resize!(out, n + Int(outl[]))
    finally
        ccall((:EVP_CIPHER_CTX_free, libcrypto), Cvoid, (Ptr{Cvoid},), ctx)
    end
end

"""
    encrypt_metadata(key, msg) -> Vector{UInt8}

Encrypt `msg` with AES-128-CBC, using the 16-byte `key` as both key and IV.
"""
encrypt_metadata(key, msg) = aes_128_cbc(true, key, key, msg)

"""
    decrypt_metadata(key, data) -> Vector{UInt8}

Inverse of `encrypt_metadata`.
"""
decrypt_metadata(key, data) = aes_128_cbc(false, key, key, data)
