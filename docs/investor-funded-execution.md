# Investor-funded execution

Each investment request can have one `InvestmentExecutionAccount`. The request and
its assets remain in `InvestmentEscrow`; shares still belong to the investor. The
execution account holds no settlement tokens and cannot approve or transfer the
investment. Its only actions are `executeFill` and `executeIntegrate` for that
request.

The investor creates the account through `InvestmentExecutionFactory`, funds its
own EntryPoint deposit in the native currency, and consents to an execution
operator and a fixed policy. This uses the pinned ERC-4337 EntryPoint v0.9.0,
without a paymaster or a common fee pool. The factory authenticates the vault and
its escrow binding before creating the account.

## Consent and limits

The policy bounds the gas price, maximum cost of one attempt, lifetime attempt
count, expiration, and minimum useful purchase size. Initial funding must cover
the product of maximum attempts and maximum cost per attempt. This conservative
bound also prevents a direct third-party EntryPoint donation from expanding the
investor's authorized lifetime fee expenditure.

The actual charge can be lower than the reserved maximum. The estimate shown in
the client is a hypothetical execution cost, not a completion guarantee. A small
budget, adverse market conditions, insufficient liquidity, expiration, or the
attempt limit can leave investment assets pending. More funding never resets the
lifetime attempt limit or renews an expired authorization.

The execution operator signs the exact UserOperation hash from the authenticated
EntryPoint, including its account, nonce, calldata, and gas fields. The account
checks the EIP-191 signature of that hash. It rejects arbitrary calls, other
recipients, deployment code, paymasters, and excessive gas dimensions, including
`preVerificationGas`. An owner transition changes the nonce policy epoch so old
signed operations cannot be revived after a withdrawal or restart.

## Failed attempts and recovery

Before signing or submitting, the local executor simulates the escrow action.
An impossible purchase ceiling causes waiting without an on-chain transaction.
Simulation does not guarantee future inclusion conditions.

Account validation consumes one lifetime attempt and pauses execution **before**
the inner action. Useful successful progress re-arms the account. An inner revert
or out-of-gas leaves it paused; the charge and consumed attempt persist. Restart
requires a fresh owner transaction, and cannot reset the counter. This prevents
automatic paid retry loops. It does not promise that an authorized operator can
never make a bad attempt: that risk is bounded by the consented policy.

The owner can withdraw the unused EntryPoint deposit through `withdrawBudget`,
independently of the market, oracle, executor, bundler, and request status. That
withdrawal pauses automation and invalidates outstanding operations. It does not
replace escrow `stop` or token `claim`; those remain separate owner recovery paths.

## Accounting and payer boundary

For each included operation, use EntryPoint `UserOperationEvent`, identified by
account, user operation hash, and nonce. Its `success` and `actualGasCost` describe
the action and its charge. A successful outer transaction may contain a failed,
paid UserOperation. Do not assign the entire outer transaction gas to one request,
or infer costs from funding minus remaining balance: unsolicited deposits can
change that balance.

The protocol does not advance, replenish, or guarantee the execution budget. The
bundler submits the outer transaction and receives the EntryPoint charge. A fully
reverted outer bundle remains the bundler's risk; it cannot be reimbursed by a
payment that itself reverted. A production bundler must therefore be independent
and must not be financed or guaranteed by protocol funds. This implementation
does not establish that commercial or operational arrangement.

## Local verification infrastructure

`investor-executor.py` is an Anvil-only scheduler. Its dedicated unlocked operator
account signs bounded operations; it never broadcasts ordinary transactions or
falls back to the legacy sponsor. The app and its API contain no operator key or
signing endpoint. Existing unbudgeted requests wait for explicit owner funding.

`local-bundler.py` is a separate laboratory adapter using a different unlocked
Anvil account and the real pinned EntryPoint. It is not a production bundler and
does not claim full public-mempool/ERC-7562 compliance. Both services use explicit
loopback ports and durable state; uncertain sends and reorgs halt rather than
blindly resubmitting. Remote wallets, signer custody, network support, and a remote
bundler still require qualification before any real-funds deployment.

The old `sponsor-daemon.py` remains a historical, explicitly invoked local test
harness. It is not the default runtime for investor-funded automation and must not
be run as a fallback for a missing personal budget.
