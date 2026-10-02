import Foundation

let job = StratumJob(
    jobId: "reference",
    prevHash: "0b29bfff96c5dc08ee65e63d7b7bab431745b089ff0cf95b49a1631e1d2f9f31",
    coinbase1: "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff2503777d07062f503253482f0405b8c75208",
    coinbase2: "0b2f436f696e48756e74722f0000000001603f352a010000001976a914c633315d376c20a973a758f7422d67f7bfed9c5888ac00000000",
    merkleBranches: [
        "f0dbca1ee1a9f6388d07d97c1ab0de0e41acdf2edac4b95780ba0a1ec14103b3",
        "8e43fd2988ac40c5d97702b7e5ccdf5b06d58f0e0d323f74dd5082232c1aedf7",
        "1177601320ac928b8c145d771dae78a3901a089fa4aca8def01cbff747355818",
        "9f64f3b0d9edddb14be6f71c3ac2e80455916e207ffc003316c6a515452aa7b4",
        "2d0b54af60fad4ae59ec02031f661d026f2bb95e2eeb1e6657a35036c017c595"
    ],
    version: "00000002",
    nbits: "1b148272",
    ntime: "52c7b81a",
    cleanJobs: true,
    generation: 1
)

let work = try StratumWorkBuilder.prepare(
    job: job,
    extraNonce1: "f800880e",
    extraNonce2Size: 4,
    difficulty: 32,
    extraNonce2Counter: 0
)

let expectedPrefix =
    "02000000ffbf290b08dcc5963de665ee43ab7b7b89b045175bf90cff1e63a149319f2f1d5cc58f5e84aafc740d521b92a7bf72f4e56c4cc3ad1c2159f1d094f97ac34eee1ab8c7527282141b"

precondition(work.headerPrefix.count == 76)
precondition(HexCodec.hex(work.headerPrefix) == expectedPrefix)
precondition(work.extraNonce2 == "00000000")

let nonceZeroHash = SHA256Core.doubleHash(
    StratumWorkBuilder.header(work, nonce: 0)
)

precondition(
    HexCodec.hex(nonceZeroHash) ==
    "a773c6eb6d0d818adb674e4036f59ad5942a4f7d102a9ede4b74a080d3e66a94"
)

precondition(
    HexCodec.hex(Array(nonceZeroHash.reversed())) ==
    "946ae6d380a0744bde9e2a107d4f2a94d59af536404e67db8a810d6debc673a7"
)

print("Stratum header construction reference passed")
