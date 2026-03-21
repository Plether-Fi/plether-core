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

const smClasses = `
    classDef state fill:#dbeafe,stroke:#2563eb,color:#1e40af,stroke-width:2px
    classDef process fill:#f1f5f9,stroke:#475569,color:#1e293b,stroke-width:2px
    classDef success fill:#dcfce7,stroke:#16a34a,color:#166534,stroke-width:2px
    classDef softfail fill:#fef3c7,stroke:#d97706,color:#92400e,stroke-width:1.5px
    classDef hardfail fill:#fee2e2,stroke:#dc2626,color:#991b1b,stroke-width:2px
    classDef note fill:#fafafa,stroke:#d4d4d4,color:#737373,stroke-width:0.75px
    classDef action fill:#e0f2fe,stroke:#0284c7,color:#0c4a6e,stroke-width:1.5px`;

const orderLifecycle = `graph TD
    U([Trader]) -->|commitOrder| P([Pending])
    P -->|expires| F1([Failed: Expired])
    P -->|FIFO head + keeper execute| O{Oracle Policy}
    O -->|frozen market| R1([Revert: Wait])
    O -->|MEV or stale keeper input| R2([Revert: Retry])
    O -->|valid price| S{Slippage / Engine}
    S -->|invalid or engine reject| F2([Failed])
    S -->|success| E([Executed])
    F1 --> D[Delete Order and Advance Queue]
    F2 --> D
    E --> D

    class U state
    class P action
    class O,S process
    class E success
    class F1,F2 softfail
    class R1,R2 hardfail
    class D note
${smClasses}`;

const positionLifecycle = `graph TD
    NONE([No Position]) -->|processOrder · isClose=false| OPEN([Active Position])
    OPEN -->|Full close · size → 0| CLOSED([Closed])
    OPEN -->|equity < MMR · keeper triggers| LIQ([Liquidated])

    NONE -.- ND>IMR ≥ 150% MMR · min notional for keeper bounty]
    OPEN -.- OD>While active: increase (same side) or partial close (dust guard) · each settles funding + VPI]
    CLOSED -.- CD>PnL settled · position struct deleted]
    LIQ -.- LD>Margin seized · bounty paid · FAD: elevated MMR on weekends]

    class NONE state
    class OPEN action
    class CLOSED success
    class LIQ hardfail
    class ND,OD,CD,LD note
${smClasses}`;

const trancheWaterfall = `graph TD
    T[Reconcile · before every deposit/withdrawal] --> A[Accrue Senior Yield · time-based APY]
    A --> D{Surplus or Deficit?}

    D -->|distributable > claimedEquity| R1[1 · Restore Senior Principal to HWM]
    R1 --> R2[2 · Pay Accrued Senior Yield]
    R2 --> R3[3 · Junior Receives Surplus]

    D -->|distributable < claimedEquity| L1[1 · Junior Absorbs First Loss]
    L1 -->|Junior wiped| L2[2 · Senior Absorbs Last Loss]

    T -.- TD>distributable = USDC balance − pending fees − unrealized trader gains]
    R3 -.- RD>Senior protected: principal and yield paid before junior sees revenue]
    L2 -.- LD>Junior subordinated: fully wiped before senior takes any impairment]

    class T action
    class A,D process
    class R1,R2,R3 success
    class L1,L2 softfail
    class TD,RD,LD note
${smClasses}`;

const perpsReservationLifecycle = `graph TD
    NONE([No Reservation]) -->|OrderRouter commit open| FULL([Active: Full Amount])

    FULL -->|full execution or settlement| CONSUMED([Consumed])
    CONSUMED --> END([Closed and Not Refundable])

    FULL -->|partial terminal consumption| PARTIAL([Active: Partial Amount])
    PARTIAL -->|more terminal consumption| PARTIAL
    PARTIAL -->|remaining amount consumed| CONSUMED2([Consumed])
    CONSUMED2 --> END2([Closed and Not Refundable])

    FULL -->|expiry or valid refund| RELEASED([Released])
    RELEASED --> FREE([Free Settlement Restored])

    PARTIAL -->|release unused remainder| RELEASED2([Released])
    RELEASED2 --> FREE2([Free Settlement Restored])

    class NONE state
    class FULL,PARTIAL action
    class CONSUMED,CONSUMED2 success
    class RELEASED,RELEASED2 softfail
    class END,END2,FREE,FREE2 note
${smClasses}`;

const perpsOracleRegimes = `graph TD
    N([Normal]) -->|Fri 19:00 UTC or admin runway| F([FAD Close-Only])
    F -->|Fri 22:00 UTC or admin holiday| Z([Frozen Oracle])
    Z -->|Sun 21:00 UTC or holiday end| N

    N --> N1[opens allowed]
    N1 --> N2[staleness: normal]
    N2 --> N3[MEV checks on]
    N3 --> N4[maint margin]

    F --> F1[close-only]
    F1 --> F2[staleness: normal]
    F2 --> F3[MEV checks on]
    F3 --> F4[fad margin]

    Z --> Z1[close-only]
    Z1 --> Z2[staleness: fadMaxStaleness]
    Z2 --> Z3[MEV bypassed]
    Z3 --> Z4[fad margin]

    class N,F,Z state
    class N1,N2,N3,N4,F1,F2,F3,F4,Z1,Z2,Z3,Z4 action
${smClasses}`;

const perpsLpWithdrawalAvailability = `graph TD
    U([LP Holder]) -->|maxWithdraw / maxRedeem| G1{Past deposit cooldown?}
    G1 -->|No| B1([Blocked: cooldown])
    G1 -->|Yes| G2{degradedMode off?}
    G2 -->|No| B2([Blocked: degraded mode])
    G2 -->|Yes| G3{Fresh mark required and available?}
    G3 -->|No| B3([Blocked: stale mark])
    G3 -->|Yes| SNAP[Build withdrawal snapshot]
    SNAP --> RES[Reserved USDC]
    RES --> RES2[max liability + funding reserve + deferred liabilities + protocol fees]
    RES2 --> FREE[Free USDC]
    FREE --> FREE2[net physical assets minus reserved USDC]
    FREE2 --> CAP[Cap by tranche priority]
    CAP --> CAP2[senior first, junior subordinated]
    CAP2 --> OUT([Withdrawable Amount])

    class U state
    class SNAP,RES,RES2,FREE,FREE2,CAP,CAP2 action
    class OUT success
    class B1,B2,B3 hardfail
${smClasses}`;

const perpsInternalArchitecture = `graph TD
    U([Trader / LP / Keeper]) -->|Deposit or withdraw trader cash| MC[MarginClearinghouse]
    MC -->|Reserve committed margin + seize execution bounty| OR[OrderRouter]
    OR -->|Validated order intent| EN[CfdEngine]
    EN -->|Settle, seize, classify liabilities| MC
    EN -->|Account protocol, revenue, recap inflows| HP[HousePool]
    HP -->|Mint / burn shares| TV[TrancheVaults]
    HP -->|Queue unpaid trader payouts + liquidation bounties| DF[Deferred Claim Queue]
    HP -->|Segregate non-LP fees| PF(Protocol Fees)
    HP -->|Hold exceptional ownership gap| UA(Unassigned / Excess Assets)

    MC -.- MCN>Trader domain: free settlement, live position margin, committed order margin]
    OR -.- ORN>Queue domain: router-custodied execution-bounty escrow]
    EN -.- ENN>Ledger domain: close, liquidation, solvency, withdrawal accounting]
    HP -.- HPN>Pool domain: accounted assets, tranche waterfall, fee segregation]

    class U user
    class MC,OR,EN,HP,TV contract
    class PF,UA token
    class DF external
    class MCN,ORN,ENN,HPN desc
${classes}`;

mkdirSync(outDir, { recursive: true });

const [svg1, svg2, svg3, svg4, svg5, svg6, svg7, svg8, svg9, svg10, svg11, svg12, svg13, svg14, svg15, svg16, svg17, svg18] = await Promise.all([
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
  renderMermaid(orderLifecycle, theme),
  renderMermaid(positionLifecycle, theme),
  renderMermaid(trancheWaterfall, theme),
  renderMermaid(perpsReservationLifecycle, theme),
  renderMermaid(perpsOracleRegimes, theme),
  renderMermaid(perpsLpWithdrawalAvailability, theme),
  renderMermaid(perpsInternalArchitecture, theme),
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
writeFileSync(`${outDir}/perps-order-lifecycle.svg`, svg12);
writeFileSync(`${outDir}/perps-position-lifecycle.svg`, svg13);
writeFileSync(`${outDir}/perps-tranche-waterfall.svg`, svg14);
writeFileSync(`${outDir}/perps-reservation-lifecycle.svg`, svg15);
writeFileSync(`${outDir}/perps-oracle-regimes.svg`, svg16);
writeFileSync(`${outDir}/perps-lp-withdrawal-availability.svg`, svg17);
writeFileSync(`${outDir}/perps-internal-architecture-map.svg`, svg18);

console.log('Rendered: how-it-works, token-flow, bear-leverage, bull-leverage, staking, burn, flywheel, invar-deposit, invar-lp-deposit, invar-lp-withdraw, invar-withdraw, perps-order-lifecycle, perps-position-lifecycle, perps-tranche-waterfall, perps-reservation-lifecycle, perps-oracle-regimes, perps-lp-withdrawal-availability, perps-internal-architecture-map');
