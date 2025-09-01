#Rehypothecation Hook 🔄💧
Overview

The Rehypothecation Hook is a Uniswap v4 hook that optimizes idle LP capital.
When an LP’s position is out-of-range, the hook automatically deposits liquidity into Aave to earn lending yield.
When the position becomes in-range again, the hook withdraws from Aave to make liquidity available for swaps.

👉 This creates dual yield opportunities for LPs:

Swap fees (when in-range)

Lending interest (when out-of-range)

✨ Features

🟢 Automatic capital optimization: liquidity never sits idle

🔄 Dynamic rebalancing: funds flow between Uniswap & Aave depending on tick

🛡️ Fallbacks & buffers: small % of liquidity always stays in Uniswap for sudden swaps

📊 Extendable architecture: easy to plug in other lending protocols (Compound, Morpho, etc.)

📂 Project Structure
rehypothecation-hook/
├── foundry.toml
├── lib/                     # dependencies (Uniswap v4, Aave)
├── contracts/
│   ├── hooks/
│   │   └── RehypothecationHook.sol   # main hook contract
│   ├── interfaces/
│   │   └── IAave.sol                 # minimal Aave interface
│   └── utils/                        # optional helpers
├── script/
│   └── DeployRehypothecationHook.s.sol  # deploy script
├── test/
│   ├── RehypothecationHook.t.sol     # unit tests
│   └── Integration.t.sol             # integration scenario tests

⚙️ Setup
1. Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

2. Clone Repo
git clone https://github.com/your-username/rehypothecation-hook.git
cd rehypothecation-hook

3. Install Dependencies
forge install uniswap/v4-core --no-commit
forge install uniswap/v4-periphery --no-commit
forge install aave/protocol-v2 --no-commit

4. Build
forge build

🧪 Testing

Run all tests:

forge test -vvvv


Start a local chain:

anvil


Deploy locally:

forge script script/DeployRehypothecationHook.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

🚀 Demo Flow

LP provides liquidity in Uniswap pool

Price moves out of range → hook deposits liquidity into Aave

Price moves back in range → hook withdraws from Aave for swaps

LP earns fees + lending yield automatically

📌 Roadmap

 Add Compound / Morpho integration as alternative to Aave

 Add mock contracts for local testing without mainnet dependencies

 Build dashboard frontend to visualize LP capital flow

 Deploy to testnet for live demo

📜 License

MIT

🔥 This project was built during a hackathon to explore capital-efficient LP strategies on Uniswap v4.