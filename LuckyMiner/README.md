# Lucky Miner v0.1

Native iOS lottery-miner project intended for private sideloading.

## v0.1 implemented
- Real SHA-256d (double SHA-256) hashing via CryptoKit.
- Bitcoin-style 80-byte block-header hashing with little-endian nonce.
- Known-vector SHA-256d startup self-test.
- Eco / Balanced / Max CPU modes.
- Live H/s, total hashes, best leading-zero-bit result, session time.
- iOS thermal state and battery monitoring.
- Automatic thermal throttling policy and critical-temperature stop.
- Truthful UI: v0.1 is local hashing only and does not claim pool earnings.

## Next milestone
Stratum V1 client integration, payout-address settings, real mining.notify job construction, share-target validation, accepted/rejected share tracking, reconnect/backoff, and pool best-difficulty accounting.

## Build
The GitHub workflow creates an unsigned IPA. The IPA is intended to be signed externally before installation.
