# Titan Locker release status — 5 November 2026

## Robinhood Chain (4663)

The regular `TitanLockerManagerV2_2` is deployed at
[`0x5fa3f3Ca0c497b22ccd360aAe8423738D1825Fe9`](https://robinhoodchain.blockscout.com/address/0x5fa3f3Ca0c497b22ccd360aAe8423738D1825Fe9).
Deployment transaction:
[`0xa92a4346d81a43f95418d480a24ec26b501537fbd1febfa7088620a9ca81a2b7`](https://robinhoodchain.blockscout.com/tx/0xa92a4346d81a43f95418d480a24ec26b501537fbd1febfa7088620a9ca81a2b7).
The 23,404-byte on-chain runtime matches the compiled release artifact exactly after
linking `Util` at `0xFBfa1ce526f98deC2251D44d1DaF7c599223aFe6`.
Runtime hash: `0xacb5a9c6d9bf89969a11091b31ae80415b4a5f5b7e8ffc1b179f35d0ea2b9e83`.

The owner and fee receiver are both
`0x5C773302FBEED11fA59a6939f0354678738B02DB`. The manager has lock creation
enabled, a 0.025 ETH flat fee, and a 300 bps token fee. The following position
managers were checked against live code and allowlisted: Uniswap V3/V4,
SushiSwap V3/V4 CL, and PancakeSwap V3/Infinity CL. The four SushiSwap/PancakeSwap
integrations also passed the local Robinhood fork custody, fee-claim, and
maturity-withdrawal tests before release.

The Robinhood contract is live, but the Titan app and public documentation must
be switched to this new address before app users create V2.2 locks. The older V1
and V2.1 managers still have lock creation enabled on-chain. Their existing locks
remain at their original immutable addresses. Explorer source verification and
a real production lock cycle against V2.2 have not yet been completed; the
bytecode comparison and local fork tests are the verification completed here.

## Kinetiq Elysium (99901)

The regular manager is deployed on Elysium at
`0x713E56CeE7060F01F710bF26Aff988264dcfb311` and `Util` is deployed at
`0x772279251b563028a32cD1505e3F2f8485C746D9`. These addresses coincide with
older Robinhood addresses because the same wallet used the same creation nonces;
the deployments are on separate chains and contain different code. The Elysium
manager's 23,404-byte runtime matches its linked release artifact exactly
(hash `0xeb3de44c35d8052c5de107355cf6d825d2b6a5cfb6ae6c927ee5f06630ee4fcc`).

The manager owner and fee receiver are both
`0x5C773302FBEED11fA59a6939f0354678738B02DB`. Creation is enabled with a
1 HYPE flat fee or 500 bps token fee. All five corrected deployment and
configuration steps have successful parent and child receipts:

| Step | HyperEVM Inbox transaction | Elysium transaction |
|---|---|---|
| Util | `0x494d02bdcbb7d42f77461493a86773713afa31797261ea2b210cceb24ec1a2e8` | `0xff71c4836ebf0f4027e54ceff260c82182a1395abee1368c6de67588f030accf` |
| Manager | `0x449b55386af48b3f8ad1848fd4744d09893e88d2833f8d272bb836af058eff7e` | `0x3084a4ba97b13e91762ea510543180d216e32091dc44a68f9a3030a82c9e30ea` |
| Disable creation | `0x301780b98a688eb3a5cd283a8f7431fcf1231431e689548422af8fb52319f298` | `0x57539e648bbc239460099ce5403f0ea80f74ee75429c46eca64791311b10fc75` |
| Set native fee | `0x96be7e5baba49138a91bf85829776926ae500a584a419bec4492cce9fb6bedc7` | `0x53c64719adfdd81e893d6aea28c2e7c94b91fe6f1515bd381632bbc09c52809f` |
| Enable creation | `0x1b7f319ebba318abefe9121ed664e4d9165fb33d45fc39bd9a3269ffc407f789` | `0x04d75d76efb385da56011c4d5ffd359ce74ab793589a61d2ac8f1df818d07101` |

The first Inbox attempt, parent transaction
[`0x114e9e216a9e386890250df4c1f47ceb9a944f130bf8275623bdb5a114856ba7`](https://hyperevmscan.io/tx/0x114e9e216a9e386890250df4c1f47ceb9a944f130bf8275623bdb5a114856ba7),
was consumed without execution because our script omitted Nitro's `0x04`
signed-message prefix. It did not use a child nonce or deploy code. The script
was fixed and tested before the successful retry. The local gitignored state
file records the attempt and all successful hashes.

The user subsequently supplied Elysium's Uniswap V3 Positions NFT
`0xF025e0Fe9E331A0eF05c2ad3C4E9C64b625cda6f` and V4 Position Manager
`0x1d1C51b9d07fD27d36412A2b66CC23D19Eb3E518`. Before allowlisting, their
runtime hashes, ERC-721 interfaces, NFT symbols, and linked V3 factory/V4
PoolManager were checked on chain. A fixed-block Elysium fork test using real
positions (block 701402, Cancun EVM) passed custody, fee collection, early
withdrawal rejection, and maturity withdrawal for both managers. The user-supplied
routers, quoters, PoolManager, and bridge contracts were not allowlisted.

Both owner transactions were posted through the official HyperEVM Inbox and
confirmed on Elysium. The final on-chain mapping reads `UNIV3`/allowed for the V3
Positions NFT and `UNIV4`/allowed for the V4 Position Manager:

| Manager | HyperEVM Inbox transaction | Elysium transaction |
|---|---|---|
| Uniswap V3 | [`0xf55c…b65e`](https://hyperevmscan.io/tx/0xf55c1418ffa16ab17f13b1343acf7412ef7811eaeb68469b41176565e664b65e) | `0xfc966d2aa5e2138426f7425e0ccfc3937e99fea6971d2527f8c68d76c38b2fc7` |
| Uniswap V4 | [`0xd19d…559d`](https://hyperevmscan.io/tx/0xd19d0f8a98a9706b406ccaea5fd89f89770c4b4e45d4c2e61152dff5d717559d) | `0x66199997b0fc5110f8738f3dc43c405e474c3c6e5dd91092a1454000a3eda66b` |

The Titan app still requires Elysium integration, and a real production lock and
withdrawal cycle against this manager has not yet been completed.

No finite audit or test suite can establish that a contract has zero bugs. This
release status records the checks performed and the remaining deployment gaps.
