import Foundation

/// Mercedes W205 ESP205 (Electronic Stability Program / Dynamic Select controller)
/// SecurityAccess key generator — level 11 (coding).
///
/// Algorithm recovered bit-exact from the ECU's own seed→key DLL
/// `ESP205_12_32_03.dll` (carved from the decrypted SMR-D, ESP167.sec2.bin; the same
/// keygen core mbito references as ESP205_/ESP213_/ESP167_ ESP205_12_32_03.dll).
/// Verified: K constant across all test seeds; the DLL only accepts access level 0x0B.
///
/// Same family algorithm as EPS205 steering (ANSI-C LCG + XOR K), different K.
///   C   = 0x41C64E6D   // LCG multiplier 1103515245
///   inc = 0x3039       // 12345  -> one rand() step
///   A = (C * BE32(seed[0..3]) + inc) mod 2^32
///   B = (C * BE32(seed[4..7]) + inc) mod 2^32
///   key32 = A ^ B ^ K
///   key   = key32 as 4 big-endian bytes
enum ESP205 {

    /// Level-11 coding constant for the ESP205 family (Dynamic Select coding).
    /// Lifted from ESP205_12_32_03.dll. (ESP213 non-AMG shares this; ESP213_AMG differs = 0xC2B93178.)
    static let K_level11: UInt32 = 0xD45D233F

    /// Access level: UDS 27 0B (request seed) / 27 0C (send key).
    static let accessLevel: UInt8 = 0x0B

    static func key(fromSeed seed: [UInt8], k: UInt32 = K_level11) -> [UInt8] {
        precondition(seed.count == 8, "ESP205 seed must be 8 bytes")
        let C: UInt32 = 0x41C64E6D, inc: UInt32 = 0x3039
        func be32(_ b: ArraySlice<UInt8>) -> UInt32 { b.reduce(0) { ($0 << 8) | UInt32($1) } }
        let a = C &* be32(seed[0..<4]) &+ inc
        let b = C &* be32(seed[4..<8]) &+ inc
        let key32 = a ^ b ^ k
        return [UInt8(key32 >> 24 & 0xFF), UInt8(key32 >> 16 & 0xFF),
                UInt8(key32 >>  8 & 0xFF), UInt8(key32       & 0xFF)]
    }

    /// If you ever sniff one real seed→key pair, this recovers the exact K (zero guessing).
    static func recoverK(seed: [UInt8], observedKey: [UInt8]) -> UInt32 {
        let C: UInt32 = 0x41C64E6D, inc: UInt32 = 0x3039
        func be32(_ b: ArraySlice<UInt8>) -> UInt32 { b.reduce(0) { ($0 << 8) | UInt32($1) } }
        let a = C &* be32(seed[0..<4]) &+ inc
        let b = C &* be32(seed[4..<8]) &+ inc
        return be32(observedKey[0..<4]) ^ a ^ b
    }
}

/// Dynamic Select "Last Mode" coding field — extracted from ESP205.CBF with a full Caesar
/// parser (jglim/CaesarSuite). Domain VCD_MB_Funktionen, read RVC_MB_Funktionen_Read /
/// write WVC_MB_Funktionen_Write, 81-byte dump (= mbito DID 22 2201 / 2E 2201).
///   Fragment "Fahrprogramme Last-Mode": ByteBitPos 616 => byte 77, bit 0; BitLength 32.
///   => occupies bytes 77..80 (the last 4 bytes of the block). Byte-aligned, no bit masking.
///   OFF "Kein Last-Mode"  = 00 00 00 00   (also the factory default — verified)
///   ON  "Last-Mode 4h"    = 55 54 01 55
enum DynamicSelectLastMode {
    static let readBlock:  [UInt8] = [0x22, 0x22, 0x01]      // -> 62 2201 + 81 bytes
    static let writeBlock: [UInt8] = [0x2E, 0x22, 0x01]      // prefix; append 81 bytes
    static let fieldOffset = 77                               // bytes 77..80
    static let valueOff: [UInt8] = [0x00, 0x00, 0x00, 0x00]  // Kein Last-Mode
    static let valueOn:  [UInt8] = [0x55, 0x54, 0x01, 0x55]  // Last-Mode 4h

    /// Read-modify-write: flip ONLY bytes 77..80, leave the rest of the block untouched.
    static func apply(block: [UInt8], enable: Bool) -> [UInt8] {
        precondition(block.count == 81, "coding block must be 81 bytes")
        var out = block
        let v = enable ? valueOn : valueOff
        for i in 0..<4 { out[fieldOffset + i] = v[i] }
        return out
    }
}

/*
 Full on-car sequence (UDS, tester→ECU):
   10 03                        // extended session
   27 0B                        // request seed   -> 67 0B <8 seed bytes>
   27 0C <4 key>                // key = ESP205.key(fromSeed:)  -> 67 0C unlocked
   22 2201                      // read -> 62 2201 + 81 coding bytes
   block = DynamicSelectLastMode.apply(block:, enable: true)   // set bytes 77..80 = 55 54 01 55
   2E 2201 <81 bytes>           // write
   11 03                        // soft reset
 Read-modify-write only; never blind-write the whole block.
*/
