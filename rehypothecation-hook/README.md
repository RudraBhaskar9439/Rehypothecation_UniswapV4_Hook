# FlexiPool Hook 🔄💧

## Overview

The FlexiPool Hook is a Uniswap v4 hook that **automatically optimizes idle LP capital**.  
When an LP’s position is **out-of-range**, the hook deposits liquidity into Aave to earn lending yield.  
When the position becomes **in-range again**, the hook withdraws from Aave and makes liquidity available for swaps.

👉 **Dual yield for LPs:**  
- **Swap fees** (when in-range)  
- **Lending interest** (when out-of-range)

---

## ✨ Features

- 🟢 **Automatic capital optimization:** Idle liquidity is always productive.
- 🔄 **Dynamic rebalancing:** Funds flow between Uniswap & Aave based on tick range.
- 🛡️ **Fallbacks & buffers:** A small % of liquidity always stays in Uniswap for instant swaps.
- 📊 **Extendable architecture:** Easily plug in other lending protocols (Compound, Morpho, etc.).
- 🔒 **Privacy-preserving:** Uses Fhenix for encrypted tick storage and event logging.
- 🧪 **Comprehensive testing:** Forked Sepolia support, coverage reporting, and modular test suite.

---

## 📂 Project Structure

```
rehypothecation-hook/
├── foundry.toml
├── lib/                         # dependencies (Uniswap v4, Aave, Fhenix)
├── src/
│   ├── hooks/
│   │   └── RehypothecationHooks.sol      # main hook contract
│   ├── interfaces/
│   │   ├── IAave.sol                    # minimal Aave interface
│   │   ├── ILiquidityOrchestrator.sol   # orchestrator interface
│   │   └── IPool.sol                    # pool contract interface
│   ├── utils/
│   │   └── Constant.sol                 # helper constants
│   └── LiquidityOrchestrator.sol        # orchestrator contract
├── script/
│   └── DeployRehypothecationHook.s.sol  # deploy script
├── test/
│   ├── RehypothecationHookstest.t.sol   # unit tests
│   └── Integration.t.sol                # integration scenario tests
```

---

## ⚙️ Setup

1. **Install Foundry**
    ```
    curl -L https://foundry.paradigm.xyz | bash
    foundryup
    ```

2. **Install Dependencies**
    ```
    forge install uniswap/v4-core
    forge install uniswap/v4-periphery
    forge install aave/protocol-v2
    forge install fhenixprotocol/cofhe-contracts
    ```

3. **Build**
    ```
    forge build
    ```

---

## 🧪 Testing

- **Run all tests:**
    ```
    forge test -vvvv --fork-url https://ethereum-sepolia-rpc.publicnode.com
    ```

- **See coverage:**
    ```
    forge coverage --report summary
    ```
    For HTML report:
    ```
    forge coverage --report lcov && genhtml lcov.info --output-directory coverage
    ```

- **Start a local chain:**
    ```
    anvil
    ```

- **Deploy locally:**
    ```
    forge script script/DeployRehypothecationHook.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
    ```

---

## 🚀 Demo Flow

1. LP provides liquidity in Uniswap pool.
2. Price moves out of range → hook deposits liquidity into Aave.
3. Price moves back in range → hook withdraws from Aave for swaps.
4. LP earns swap fees + lending yield automatically.

---

## 📌 Roadmap

- Add Compound / Morpho integration as alternatives to Aave.
- Add mock contracts for local testing without mainnet dependencies.
- Build dashboard frontend to visualize LP capital flow.
- Deploy to testnet for live demo.
- Extend privacy features and analytics.

---

## 📜 License

MIT

---

🔥 **Hackathon Project:**  
Exploring capital-efficient, privacy-preserving LP strategies on Uniswap v4 using hooks and cross-protocol integrations.
