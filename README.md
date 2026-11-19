# dotBots contracts

Source code of the dotBots smart contracts on BNB Smart Chain (chain id 56). One fully on-chain pixel bot per .ai Agent ID.

The files in this repo are byte-identical to the source verified on BscScan and Sourcify.

## Contracts

| Contract | Address | Source |
|---|---|---|
| dotBots (ERC-721) | 0x4123F0f5ca048780C0c91aBC0c7ac12c77a0bF69 | src/DotBots.sol |
| dotBots Market v2 | 0x8F9ca488C7684CDc96D8499ca73479Dd72EA9Ac3 | contracts/DotBotsMarketV2.sol |

- Verified: https://bscscan.com/address/0x4123F0f5ca048780C0c91aBC0c7ac12c77a0bF69#code
- Verified: https://bscscan.com/address/0x8F9ca488C7684CDc96D8499ca73479Dd72EA9Ac3#code
- Compiler: solc v0.8.37+commit.f401782d, optimizer on, 200 runs.
- Agent ID registry read by dotBots: 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F (view calls only).

## Supply

- Max supply 2,222: 2,122 public + 100 team reserve (constants).
- One bot per .ai Agent ID. The bot carries its Agent ID name. Art and metadata are generated on-chain.
- Mint and fusion can only be called by a wallet (no contracts).

## Owner and permissions

Owner of both contracts: Safe multisig 0xA9c76FeEcdA249BbE14d3a330a3739821f69d910 (2 of 3 signers). Ownership changes use a two-step transfer.

Safe multisig (the owner):

- Safe v1.4.1 at 0xA9c76FeEcdA249BbE14d3a330a3739821f69d910 on BNB Smart Chain.
- 3 signers, 2 signatures needed for every owner action. No single key can act alone.
- No Safe modules and no transaction guard are enabled, so nothing can bypass the 2 of 3 rule.
- Every Safe transaction and its signatures are public on chain.

dotBots:

| Function | Who | What it can do |
|---|---|---|
| setMintOpen | Owner | Open or close minting |
| setFusionOpen | Owner | Open or close fusion |
| setPrices | Owner | Set mint and fusion prices in USD; each price must be above 0 and at most $10 (constant) |
| teamMint | Owner | Mint from the 100-bot team reserve only; the reserve is fully used |
| assignGift | Owner | Assign an unnamed team bot to an Agent ID holder, or cancel it; the holder claims it with claimGift |
| setTreasury | Owner | Change the treasury address (also the royalty receiver) |
| transferOwnership / renounceOwnership | Owner | Move or give up ownership |
| withdraw | Anyone | Sends withdrawable funds to the treasury only |

- Royalty (ERC-2981): 5%, receiver = treasury.
- No pause, no upgrade, no metadata or art setter, no way to move holders' bots.

Market v2:

| Function | Who | What it can do |
|---|---|---|
| pause / unpause | Owner | Stop new listings, price changes, sales and offers; cancel, refunds and withdraw always work |
| setFee | Owner | Market fee, at most 5% (constant) |
| setFeeRecipient | Owner | Change the fee receiver |
| returnUnlisted | Owner | Send out a dotBot that reached the market by plain transfer (never listed), to an address the owner sets; listed bots cannot be touched |
| returnForeignNft | Owner | Send out another collection's NFT that reached the market by mistake, to an address the owner sets |

- The owner can never move a listed bot or touch BNB held for buyers and sellers. No proxy.
- renounceOwnership is disabled on Market v2.

## Payments

Mint payments are split by fixed constants in the contract source, which no one can change after deployment. dotBots pays no yield, dividend or return of any kind. Nothing here is investment advice.

How each mint payment is divided is written in src/DotBots.sol; this README does not restate it. No yield and no return is promised to anyone.

The official dotBots site always mints with referrer = 0x0, so it does not use the referral path in the contract. The site has no screen for claim() or claimReferral(), and dotBots does not promote either.

## Risk warning

NFTs and crypto are risky. Prices can go to zero. Every transaction is signed in your own wallet; check it before you confirm. dotBots never asks for your seed phrase, private key or a QR pairing.

dotBots is an independent project built on BNB Chain. It is not run or endorsed by Binance or BNB Chain.
