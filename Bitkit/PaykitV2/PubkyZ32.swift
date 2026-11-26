#if DEBUG
    import Foundation

    /// Demo: z-base-32 text for 32-byte Pubky identities.
    ///
    /// Paykit v0.2 passes identities as 32 raw bytes, while Bitkit, the Homeserver paths and the logs use the
    /// 52-character z-base-32 text. Bits are read most significant first, as Pubky does.
    enum PubkyZ32 {
        private static let alphabet = Array("ybndrfg8ejkmcpqxot1uwisza345h769")
        private static let values: [Character: UInt8] = {
            var values: [Character: UInt8] = [:]
            for (index, character) in alphabet.enumerated() {
                values[character] = UInt8(index)
            }
            return values
        }()

        static func encode(_ bytes: Data) -> String {
            var output = ""
            var buffer: UInt32 = 0
            var bits = 0
            for byte in bytes {
                buffer = (buffer << 8) | UInt32(byte)
                bits += 8
                while bits >= 5 {
                    bits -= 5
                    output.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
                }
            }
            if bits > 0 {
                output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
            }
            return output
        }

        /// Decode a 32-byte identity. Accepts an optional `pubky` or `pk:` prefix. Nil for anything else.
        static func decodeIdentity(_ text: String) -> Data? {
            var body = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for prefix in ["pk:", "pubky"] where body.hasPrefix(prefix) {
                body.removeFirst(prefix.count)
            }
            guard body.count == 52 else { return nil }

            var output = Data()
            var buffer: UInt32 = 0
            var bits = 0
            for character in body {
                guard let value = values[character] else { return nil }
                buffer = (buffer << 5) | UInt32(value)
                bits += 5
                if bits >= 8 {
                    bits -= 8
                    output.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
                }
            }
            return output.count == 32 ? output : nil
        }
    }
#endif
