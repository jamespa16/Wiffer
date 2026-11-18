func chachaTests(_ t: Tests) {
    t.section("ChaCha20 (RFC 8439)")
    var k: [UInt8] = []
    for i in 0..<32 { k.append(UInt8(i)) }
    t.equal(hex(ChaCha20.block(key: k, nonce: unhex("000000090000004a00000000"), counter: 1)),
            "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e",
            "2.3.2 block")
    let sunscreen = ascii("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.")
    let ct = ChaCha20.xor(key: k, nonce: unhex("000000000000004a00000000"), counter: 1, sunscreen)
    t.equal(hex(ct), "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d",
            "2.4.2 encrypt")
    t.equal(ChaCha20.xor(key: k, nonce: unhex("000000000000004a00000000"), counter: 1, ct), sunscreen, "2.4.2 decrypt")

    t.section("Poly1305 (RFC 8439)")
    t.equal(hex(Poly1305.mac(key: unhex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"),
                             message: ascii("Cryptographic Forum Research Group"))),
            "a8061dc1305136c6c22b8baf0c0127a9", "2.5.2")
    // Appendix A.3 edge cases (carries through 2^130 - 5).
    let r2 = unhex("0200000000000000000000000000000000000000000000000000000000000000")
    t.equal(hex(Poly1305.mac(key: r2, message: [UInt8](repeating: 0xff, count: 16))),
            "03000000000000000000000000000000", "A.3 #5")
    t.equal(hex(Poly1305.mac(key: unhex("02000000000000000000000000000000ffffffffffffffffffffffffffffffff"),
                             message: unhex("02000000000000000000000000000000"))),
            "03000000000000000000000000000000", "A.3 #6")
    let r1 = unhex("0100000000000000000000000000000000000000000000000000000000000000")
    t.equal(hex(Poly1305.mac(key: r1, message: unhex("fffffffffffffffffffffffffffffffff0ffffffffffffffffffffffffffffff11000000000000000000000000000000"))),
            "05000000000000000000000000000000", "A.3 #7")
    t.equal(hex(Poly1305.mac(key: r2, message: unhex("fdffffffffffffffffffffffffffffff"))),
            "faffffffffffffffffffffffffffffff", "A.3 #9")
    t.equal(hex(Poly1305.mac(key: r1, message: unhex("e33594d7505e43b900000000000000003394d7505e4379cd01000000000000000000000000000000000000000000000001000000000000000000000000000000"))),
            "1cca6b28afa1bc860200000000000000", "3-block carries (vs Python cryptography)")
    var inc = Poly1305(key: unhex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"))
    for b in ascii("Cryptographic Forum Research Group") { inc.update([b]) }
    t.equal(hex(inc.finalize()), "a8061dc1305136c6c22b8baf0c0127a9", "byte-at-a-time")

    t.section("ChaCha20-Poly1305 (RFC 8439 2.8.2)")
    var k2: [UInt8] = []
    for i in 0..<32 { k2.append(UInt8(0x80 + i)) }
    let aead = ChaCha20Poly1305(key: k2)!
    let nonce = unhex("070000004041424344454647"), aad = unhex("50515253c0c1c2c3c4c5c6c7")
    let sealed = aead.seal(nonce: nonce, aad: aad, plaintext: sunscreen)
    t.equal(hex(sealed), "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116"
            + "1ae10b594f09e26a7e902ecbd0600691", "seal")
    t.equal(aead.open(nonce: nonce, aad: aad, ciphertextAndTag: sealed) ?? [], sunscreen, "open")
    aeadNegative(t, "chacha", sealed, aad) { aead.open(nonce: nonce, aad: $1, ciphertextAndTag: $0) }
    t.check(ChaCha20Poly1305(key: [0]) == nil, "bad key size")
    t.check(aead.open(nonce: [1, 2, 3], aad: aad, ciphertextAndTag: sealed) == nil, "bad nonce size")
}
