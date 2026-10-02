# Lucky Miner v0.1

Native iPhone Bitcoin lottery-miner project for private sideloading.

Implemented in v0.1:
- real double-SHA256 work over 80-byte Bitcoin-style headers
- measured hash rate, total hashes, best leading-zero-bit score, and worker count
- Eco, Balanced, and Max CPU modes
- iOS thermal, battery, and Low Power Mode monitoring
- automatic thermal throttling and critical-temperature stop
- Stratum V1 TCP subscribe/authorize handshake
- configurable pool host, port, and username
- unsigned IPA GitHub Actions build

v0.1 does not yet process mining.notify into live pool work or call mining.submit. Those are the next milestone; accepted shares and BTC earnings are not simulated.
