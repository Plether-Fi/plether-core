import { renderMermaid, THEMES } from 'beautiful-mermaid';
import { writeFileSync, mkdirSync } from 'fs';

const theme = { ...THEMES['github-light'], line: '#9ca3af', accent: '#6b7280' };
const outDir = 'assets/diagrams';

const classes = `
    classDef user fill:#dbeafe,stroke:#2563eb,color:#1e40af,stroke-width:2px
    classDef contract fill:#f1f5f9,stroke:#475569,color:#1e293b,stroke-width:2px
    classDef token fill:#dcfce7,stroke:#16a34a,color:#166534,stroke-width:1.5px
    classDef external fill:#fef9c3,stroke:#ca8a04,color:#713f12,stroke-width:1.5px
    classDef desc fill:#fafafa,stroke:#d4d4d4,color:#737373,stroke-width:0.75px
    classDef buffer fill:#e0f2fe,stroke:#0284c7,color:#0c4a6e,stroke-width:1.5px`;

const howItWorks = `graph TD
    U([💳 User]) -->|Deposit USDC| B[SyntheticSplitter]
    B --> C(plDXY-BEAR)
    B --> D(plDXY-BULL)
    C -.- E>gains when USD weakens]
    D -.- F>gains when USD strengthens]

    class U user
    class B contract
    class C,D token
    class E,F desc
${classes}`;

const tokenFlow = `graph TD
    U([💳 User]) -->|Deposit ⇄ Redeem USDC| SP[SyntheticSplitter]
    CL{{Chainlink}} -->|5 Price Feeds| SP
    PY{{Pyth Network}} -->|SEK/USD Feed| SP
    SP --> BEAR(plDXY-BEAR)
    SP --> BULL(plDXY-BULL)
    BEAR -->|Trade| CU{{Curve AMM · USDC/BEAR}}
    BULL -->|Trade via ZapRouter| CU
    SP -->|90% USDC Reserves| MA[MorphoAdapter]
    MA -->|Yield| MO{{Morpho Blue}}

    class U user
    class SP,MA contract
    class BEAR,BULL token
    class CL,PY,CU,MO external
${classes}`;

const bearLeverage = `graph TD
    U([💳 User]) -->|USDC Principal| LR[LeverageRouter]
    LR -->|Swap USDC → BEAR on Curve| BEAR(plDXY-BEAR)
    BEAR -->|Stake| SB(splDXY-BEAR)
    SB -->|Deposit Collateral| MO{{Morpho Blue}}
    LR -.- FL>Flash Loan: borrow USDC from Morpho · repaid same tx]
    MO -.- POS>Position: borrow USDC against collateral · ongoing debt]

    class U user
    class LR contract
    class BEAR,SB token
    class MO external
    class FL,POS desc
${classes}`;

const bullLeverage = `graph TD
    U([💳 User]) -->|USDC Principal| BLR[BullLeverageRouter]
    BLR -->|Mint BEAR + BULL| SP[SyntheticSplitter]
    SP -->|Sell BEAR → USDC on Curve · Keep BULL| BULL(plDXY-BULL)
    BULL -->|Stake| SBU(splDXY-BULL)
    SBU -->|Deposit Collateral| MO{{Morpho Blue}}
    BLR -.- FL>Flash Loan: borrow USDC from Morpho · repaid same tx]
    MO -.- POS>Position: borrow USDC against collateral · ongoing debt]

    class U user
    class BLR,SP contract
    class BULL,SBU token
    class MO external
    class FL,POS desc
${classes}`;

const staking = `graph TD
    U([💳 User]) -->|Deposit USDC| SP[SyntheticSplitter]
    SP --> BEAR(plDXY-BEAR)
    SP -->|USDC Yield| RD[RewardDistributor]
    SP --> BULL(plDXY-BULL)
    BEAR -->|Stake ⇄ Unstake| SB(splDXY-BEAR)
    BULL -->|Stake ⇄ Unstake| SBU(splDXY-BULL)
    RD -->|Rewards| SB
    RD -->|Rewards| SBU

    class U user
    class SP,RD contract
    class BEAR,BULL,SB,SBU token
${classes}`;

const burn = `graph TD
    U([💳 User]) -->|Burn BEAR + BULL| SP[SyntheticSplitter]
    MA[MorphoAdapter] -->|Withdraw if buffer insufficient| SP
    SP -->|USDC at $2.00 CAP rate| USDC(USDC)

    class U user
    class SP,MA contract
    class USDC token
${classes}`;

const flywheel = `graph TD
    OR[BasketOracle] -->|Theoretical Price| RD[RewardDistributor]
    SP[SyntheticSplitter] -->|USDC Yield| RD
    CU{{Curve AMM}} -->|Spot EMA| RD
    RD -.- BAL>Rebalancer · larger share to undervalued token · higher yield → more stakers → price corrects]
    BAL -->|Buy spot + donate| SB(splDXY-BEAR)
    BAL -->|Buy spot + donate| SBU(splDXY-BULL)

    class SP,RD,OR contract
    class CU external
    class SB,SBU token
    class BAL desc
${classes}`;

const invarDeposit = `sequenceDiagram
    actor K as Keeper
    actor U as User
    box rgba(241,245,249,0.4) Protocol
        participant IC as InvarCoin Vault
        participant BUF as USDC Buffer (2%)
    end
    box rgba(254,249,195,0.4) External
        participant CU as Curve USDC/BEAR
    end

    U->>IC: USDC
    IC->>U: INVAR shares
    IC->>BUF: USDC held locally

    Note over BUF: Buffer sits until keeper deploys

    K->>IC: deployToCurve
    IC->>BUF: Keep 2%, release excess
    BUF->>CU: Excess USDC
    CU-->>IC: LP tokens (earns trading fees)
`;

const invarLpDeposit = `graph TD
    U([User]) -->|USDC + BEAR · receive INVAR| IC[InvarCoin Vault]
    IC -->|Both tokens deposited directly| CU{{Curve USDC/BEAR Pool}}
    CU -.- D1>Shares priced with pessimistic LP valuation]

    class U user
    class IC contract
    class CU external
    class D1 desc
${classes}`;

const invarLpWithdraw = `graph TD
    U([User]) -->|INVAR shares · receive USDC + BEAR| IC[InvarCoin Vault]
    IC -->|Burn LP (balanced exit)| CU{{Curve USDC/BEAR Pool}}
    CU -.- D1>Works even when contract is paused]

    class U user
    class IC contract
    class CU external
    class D1 desc
${classes}`;

const invarWithdraw = `sequenceDiagram
    actor K as Keeper
    actor U as User
    box rgba(241,245,249,0.4) Protocol
        participant IC as InvarCoin Vault
        participant BUF as USDC Buffer (2%)
    end
    box rgba(254,249,195,0.4) External
        participant CU as Curve USDC/BEAR
    end

    U->>IC: INVAR shares (burned)
    BUF-->>IC: Pro-rata USDC
    IC->>CU: Burn pro-rata LP (single-sided)
    CU-->>IC: USDC from LP
    IC->>U: Total USDC

    K->>IC: replenishBuffer
    IC->>BUF: Buffer < 2%? Restore target
    IC->>CU: Burn LP (single-sided)
    CU-->>BUF: USDC replenishment
`;

mkdirSync(outDir, { recursive: true });

const [svg1, svg2, svg3, svg4, svg5, svg6, svg7, svg8, svg9, svg10, svg11] = await Promise.all([
  renderMermaid(howItWorks, theme),
  renderMermaid(tokenFlow, theme),
  renderMermaid(bearLeverage, theme),
  renderMermaid(bullLeverage, theme),
  renderMermaid(staking, theme),
  renderMermaid(burn, theme),
  renderMermaid(flywheel, theme),
  renderMermaid(invarDeposit, theme),
  renderMermaid(invarLpDeposit, theme),
  renderMermaid(invarLpWithdraw, theme),
  renderMermaid(invarWithdraw, theme),
]);

writeFileSync(`${outDir}/how-it-works.svg`, svg1);
writeFileSync(`${outDir}/token-flow.svg`, svg2);
writeFileSync(`${outDir}/bear-leverage.svg`, svg3);
writeFileSync(`${outDir}/bull-leverage.svg`, svg4);
writeFileSync(`${outDir}/staking.svg`, svg5);
writeFileSync(`${outDir}/burn.svg`, svg6);
writeFileSync(`${outDir}/flywheel.svg`, svg7);
writeFileSync(`${outDir}/invar-deposit.svg`, svg8);
writeFileSync(`${outDir}/invar-lp-deposit.svg`, svg9);
writeFileSync(`${outDir}/invar-lp-withdraw.svg`, svg10);
writeFileSync(`${outDir}/invar-withdraw.svg`, svg11);

console.log('Rendered: how-it-works, token-flow, bear-leverage, bull-leverage, staking, burn, flywheel, invar-deposit, invar-lp-deposit, invar-lp-withdraw, invar-withdraw');
