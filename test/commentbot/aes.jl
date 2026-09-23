using Registrator.CommentBot: encrypt_metadata, decrypt_metadata

@testset "PR metadata encryption" begin
    key = "0123456789abcdef"

    # Ciphertexts produced by the previous MbedTLS-based implementation,
    # `encrypt(MbedTLS.CIPHER_AES_128_CBC, key, msg, key)`. Metadata in
    # already-open registry PRs must keep decrypting.
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
    end

    @test_throws ArgumentError encrypt_metadata("short", "x")
    @test_throws ArgumentError decrypt_metadata("0123456789abcdef0", hex2bytes(last(vectors[1])))
    # Wrong key fails the padding check rather than returning garbage.
    @test_throws ErrorException decrypt_metadata("fedcba9876543210", hex2bytes(last(vectors[2])))
end
