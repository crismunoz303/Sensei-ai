import Foundation

let job = StratumJob(
    jobId: "1db7",
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
    extraNonce1: "",
    extraNonce2Size: 4,
    difficulty: 32,
    extraNonce2Counter: 0
)

precondition(work.extraNonce2 == "00000000")
precondition(work.headerPrefix.count == 76)

let expectedNonce: UInt32 = 0x482601c0
let digest = SHA256Core.doubleHash(
    StratumWorkBuilder.header(work, nonce: expectedNonce)
)
let numeric = StratumWorkBuilder.numericHashValue(digest)

precondition(
    numeric <= work.shareTarget,
    "Known Stratum test nonce did not satisfy difficulty-32 share target"
)

print("Known Stratum SHA-256d share vector passed")
