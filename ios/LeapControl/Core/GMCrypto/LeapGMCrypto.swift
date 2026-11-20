import Foundation

enum LeapGMCrypto {
    struct Agreement: Sendable {
        let publicKey: Data
        let sharedKey: Data
    }

    static func sm2KAP(
        certificatePEM: String,
        privateKey: Data?,
        peerPublicKeyX963: Data? = nil
    ) throws -> Agreement {
        if let privateKey, privateKey.count != 32 {
            throw LeapBLEProtocolError.cryptoFailure("SM2 临时私钥不是 32 字节")
        }

        var publicKey = Data(count: 65)
        var sharedKey = Data(count: 32)
        let status: Int32
        if let peerPublicKeyX963 {
            guard peerPublicKeyX963.count == 65, peerPublicKeyX963.first == 0x04 else {
                throw LeapBLEProtocolError.invalidCertificate("SM2 公钥不是 65 字节未压缩公钥")
            }
            status = invokeKAP(
                peerMaterial: peerPublicKeyX963,
                privateKey: privateKey,
                publicKey: &publicKey,
                sharedKey: &sharedKey,
                certificate: false
            )
        } else {
            let certificateDER = try decodeCertificate(certificatePEM)
            status = invokeKAP(
                peerMaterial: certificateDER,
                privateKey: privateKey,
                publicKey: &publicKey,
                sharedKey: &sharedKey,
                certificate: true
            )
        }
        guard status == LeapGMCryptoSuccess else {
            throw LeapBLEProtocolError.cryptoFailure("SM2 KAP 返回 \(status)")
        }
        return Agreement(publicKey: publicKey, sharedKey: sharedKey)
    }

    static func sm3(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw LeapBLEProtocolError.cryptoFailure("SM3 输入为空")
        }
        var digest = Data(count: 32)
        let status = digest.withUnsafeMutableBytes { digestBuffer in
            data.withUnsafeBytes { inputBuffer in
                LeapGMSM3(
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress,
                    data.count,
                    digestBuffer.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        guard status == LeapGMCryptoSuccess else {
            throw LeapBLEProtocolError.cryptoFailure("SM3 返回 \(status)")
        }
        return digest
    }

    static func sm4Encrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try sm4(data, key: key, iv: iv, encrypting: true)
    }

    static func sm4Decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try sm4(data, key: key, iv: iv, encrypting: false)
    }

    private static func decodeCertificate(_ value: String) throws -> Data {
        let lines = value.split(whereSeparator: \.isNewline)
        let encoded: String
        if lines.contains(where: { $0.contains("BEGIN CERTIFICATE") }) {
            encoded = lines
                .filter { !$0.hasPrefix("-----") }
                .joined()
        } else {
            encoded = value
        }
        guard let der = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              !der.isEmpty else {
            throw LeapBLEProtocolError.invalidCertificate("SM2 X.509 证书不是有效 PEM/Base64")
        }
        return der
    }

    private static func invokeKAP(
        peerMaterial: Data,
        privateKey: Data?,
        publicKey: inout Data,
        sharedKey: inout Data,
        certificate: Bool
    ) -> Int32 {
        func invoke(privateKeyBuffer: UnsafeRawBufferPointer?) -> Int32 {
            peerMaterial.withUnsafeBytes { peerBuffer in
                publicKey.withUnsafeMutableBytes { publicBuffer in
                    sharedKey.withUnsafeMutableBytes { sharedBuffer in
                        let peer = peerBuffer.bindMemory(to: UInt8.self).baseAddress
                        let privateBytes = privateKeyBuffer?
                            .bindMemory(to: UInt8.self).baseAddress
                        let outputPublic = publicBuffer
                            .bindMemory(to: UInt8.self).baseAddress
                        let outputShared = sharedBuffer
                            .bindMemory(to: UInt8.self).baseAddress
                        if certificate {
                            return LeapGMSM2KAPFromCertificate(
                                peer,
                                peerMaterial.count,
                                privateBytes,
                                privateKeyBuffer?.count ?? 0,
                                outputPublic,
                                outputShared
                            )
                        }
                        return LeapGMSM2KAPFromPublicKey(
                            peer,
                            peerMaterial.count,
                            privateBytes,
                            privateKeyBuffer?.count ?? 0,
                            outputPublic,
                            outputShared
                        )
                    }
                }
            }
        }

        if let privateKey {
            return privateKey.withUnsafeBytes { invoke(privateKeyBuffer: $0) }
        }
        return invoke(privateKeyBuffer: nil)
    }

    private static func sm4(
        _ data: Data,
        key: Data,
        iv: Data,
        encrypting: Bool
    ) throws -> Data {
        guard !data.isEmpty, key.count == 16, iv.count == 16 else {
            throw LeapBLEProtocolError.cryptoFailure("SM4 输入或 key/iv 长度无效")
        }
        var output = Data(count: data.count + (encrypting ? 16 : 0))
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        let input = inputBuffer.bindMemory(to: UInt8.self).baseAddress
                        let keyBytes = keyBuffer.bindMemory(to: UInt8.self).baseAddress
                        let ivBytes = ivBuffer.bindMemory(to: UInt8.self).baseAddress
                        let outputBytes = outputBuffer.bindMemory(to: UInt8.self).baseAddress
                        if encrypting {
                            return LeapGMSM4CBCPKCS7Encrypt(
                                input, data.count,
                                keyBytes, ivBytes,
                                outputBytes, outputCapacity,
                                &outputLength
                            )
                        }
                        return LeapGMSM4CBCPKCS7Decrypt(
                            input, data.count,
                            keyBytes, ivBytes,
                            outputBytes, outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == LeapGMCryptoSuccess else {
            throw LeapBLEProtocolError.cryptoFailure("SM4-CBC 返回 \(status)")
        }
        return output.prefix(outputLength)
    }
}
