import { renderMermaid, THEMES } from 'beautiful-mermaid';
import { writeFileSync, mkdirSync } from 'fs';

const theme = { ...THEMES['github-light'], line: '#9ca3af', accent: '#6b7280' };
const outDir = 'assets/diagrams';

const classes = `
    classDef user fill:#dbeafe,stroke:#2563eb,color:#1e40af,stroke-width:2px
    classDef contract fill:#f1f5f9,stroke:#475569,color:#1e293b,stroke-width:2px
    classDef token fill:#dcfce7,stroke:#16a34a,color:#166534,stroke-width:1.5px
    classDef external fill:#fef9c3,stroke:#ca8a04,color:#713f12,stroke-width:1.5px
    classDef desc fill:#fafafa,stroke:#d4d4d4,color:#737373,stroke-width:0.75px`;

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

mkdirSync(outDir, { recursive: true });

const [svg1, svg2, svg3, svg4, svg5, svg6, svg7] = await Promise.all([
  renderMermaid(howItWorks, theme),
  renderMermaid(tokenFlow, theme),
  renderMermaid(bearLeverage, theme),
  renderMermaid(bullLeverage, theme),
  renderMermaid(staking, theme),
  renderMermaid(burn, theme),
  renderMermaid(flywheel, theme),
]);

writeFileSync(`${outDir}/how-it-works.svg`, svg1);
writeFileSync(`${outDir}/token-flow.svg`, svg2);
writeFileSync(`${outDir}/bear-leverage.svg`, svg3);
writeFileSync(`${outDir}/bull-leverage.svg`, svg4);
writeFileSync(`${outDir}/staking.svg`, svg5);
writeFileSync(`${outDir}/burn.svg`, svg6);
writeFileSync(`${outDir}/flywheel.svg`, svg7);

console.log('Rendered: how-it-works, token-flow, bear-leverage, bull-leverage, staking, burn, flywheel');
