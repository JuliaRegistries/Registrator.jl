using Registrator.CommentBot: encrypt_metadata, decrypt_metadata, OpenSSLError

@testset "PR metadata encryption" begin
    key = "0123456789abcdef"

    # Ciphertexts produced independently by the previous MbedTLS-based
    # implementation, `encrypt(MbedTLS.CIPHER_AES_128_CBC, key, msg, key)`, and by
    #   printf %s "$msg" | openssl enc -aes-128-cbc -K $hexkey -iv $hexkey
    # which agree byte for byte. Metadata in already-open registry PRs must keep
    # decrypting.
    vectors = [
        "" => "ed47fee0545c3fa7dd070d44b86e98d9",
        "a" => "4694c9b4c3f491d04428ebd697e40581",
        "exactly16bytes!!" => "cbbd6157f4ba7d2bedc56ad9a5efdd8a93a11420ecfd8b8def7eaeaa387a9525",
        """{"request_type":"approve","version":"1.2.3"}""" =>
            "210267e026d1d9f4114738b74438162baafe36ddf5c23372f1ef311366a8034f016bfa9a994f1da33a8c80d781151952",
    ]
    for (msg, hex) in vectors
        @test bytes2hex(encrypt_metadata(key, msg)) == hex
        @test String(decrypt_metadata(key, hex2bytes(hex))) == msg
        # Byte-vector input works the same as a String.
        @test bytes2hex(encrypt_metadata(key, Vector{UInt8}(codeunits(msg)))) == hex
    end

    # Round trip through the JSON shape the comment bot actually embeds.
    meta = """{"pkg_repo_name":"Foo/Bar.jl","version":"0.1.0","subdir":"","tree_sha":"abc"}"""
    @test String(decrypt_metadata(key, encrypt_metadata(key, meta))) == meta
    # Non-`String` key and data types go through the same zero-copy path.
    @test encrypt_metadata(SubString(key * "!", 1, 16), meta) == encrypt_metadata(key, meta)
    @test decrypt_metadata(key, view(encrypt_metadata(key, meta), :)) == codeunits(meta)

    @test_throws ArgumentError encrypt_metadata("short", "x")
    @test_throws ArgumentError decrypt_metadata("0123456789abcdef0", hex2bytes(last(vectors[1])))
    # For these inputs a wrong key or truncated data fails the padding check
    # (a wrong key does so in ~255/256 cases, not always), and leaves no error
    # state behind for the next call.
    @test_throws OpenSSLError decrypt_metadata("fedcba9876543210", hex2bytes(last(vectors[2])))
    @test_throws OpenSSLError decrypt_metadata(key, hex2bytes(last(vectors[3]))[1:end-1])
    @test String(decrypt_metadata(key, hex2bytes(last(vectors[2])))) == "a"
end
