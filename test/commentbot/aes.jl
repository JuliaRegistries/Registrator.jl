using Registrator.CommentBot: encrypt_metadata, decrypt_metadata, check_metadata_key,
    metadata_from_pr_body, OpenSSLError, JSON

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
    # Non-`String` key and data types are accepted (strings via `codeunits`,
    # non-`Vector` byte containers by copying into a `Vector{UInt8}`).
    @test encrypt_metadata(SubString(key * "!", 1, 16), meta) == encrypt_metadata(key, meta)
    @test encrypt_metadata(key, Test.GenericString(meta)) == encrypt_metadata(key, meta)
    @test decrypt_metadata(key, view(encrypt_metadata(key, meta), :)) == codeunits(meta)

    @test_throws ArgumentError encrypt_metadata("short", "x")
    @test_throws ArgumentError check_metadata_key("short")
    @test_throws ArgumentError check_metadata_key(nothing)
    @test check_metadata_key(key) === key
    @test_throws ArgumentError decrypt_metadata("0123456789abcdef0", hex2bytes(last(vectors[1])))
    # For these inputs a wrong key or truncated data fails the padding check
    # (a wrong key does so in ~255/256 cases, not always), and leaves no error
    # state behind for the next call.
    @test_throws OpenSSLError decrypt_metadata("fedcba9876543210", hex2bytes(last(vectors[2])))
    @test_throws OpenSSLError decrypt_metadata(key, hex2bytes(last(vectors[3]))[1:end-1])
    @test String(decrypt_metadata(key, hex2bytes(last(vectors[2])))) == "a"
end

@testset "metadata extraction from PR body" begin
    key = "0123456789abcdef"
    meta = Dict("request_type" => "issue", "pkg_repo_name" => "Foo/Bar.jl",
                "trigger_id" => 7, "tree_sha" => "abc", "version" => "0.1.0", "subdir" => "")
    enc_meta = "<!-- " * bytes2hex(encrypt_metadata(key, JSON.json(meta))) * " -->"

    # Plain body, as generated without release notes.
    body = "- Registering package: Bar\n- Version: v0.1.0\n" * enc_meta
    @test metadata_from_pr_body(body, key) == meta

    # With release notes the body has other HTML comments *before* the metadata
    # (this is the shape `pull_request_contents` produces).
    _, body = Registrator.pull_request_contents(;
        registration_type="New package", package="Bar", repo="https://github.com/Foo/Bar.jl",
        user="@u", version=v"0.1.0", commit="abc", release_notes="## Notes\n<!-- deadbeef -->\nhi",
        meta=enc_meta)
    @test occursin("<!-- BEGIN RELEASE NOTES -->", body)
    @test metadata_from_pr_body(body, key) == meta

    # A valid ciphertext copied from another PR into the (user-supplied) release
    # notes must not shadow the bot's own metadata, which always comes last.
    other = merge(meta, Dict("pkg_repo_name" => "Evil/Other.jl", "version" => "9.9.9"))
    other_enc = "<!-- " * bytes2hex(encrypt_metadata(key, JSON.json(other))) * " -->"
    _, body = Registrator.pull_request_contents(;
        registration_type="New package", package="Bar", repo="https://github.com/Foo/Bar.jl",
        user="@u", version=v"0.1.0", commit="abc", release_notes="notes\n" * other_enc,
        meta=enc_meta)
    @test metadata_from_pr_body(body, key) == meta

    # Decrypts and parses as JSON, but not to the shape `handle_approval` needs.
    scalar_enc = "<!-- " * bytes2hex(encrypt_metadata(key, "42")) * " -->"
    partial_enc = "<!-- " * bytes2hex(encrypt_metadata(key, """{"version":"1.0.0"}""")) * " -->"
    @test metadata_from_pr_body(scalar_enc, key) === nothing
    @test metadata_from_pr_body(partial_enc, key) === nothing
    @test metadata_from_pr_body(scalar_enc * "\n" * enc_meta, key) == meta

    # Missing body, missing comment, non-hex comment, wrong key.
    @test metadata_from_pr_body(nothing, key) === nothing
    @test metadata_from_pr_body("no comment here", key) === nothing
    @test metadata_from_pr_body("<!-- not hex -->", key) === nothing
    @test metadata_from_pr_body(body, "fedcba9876543210") === nothing
end
