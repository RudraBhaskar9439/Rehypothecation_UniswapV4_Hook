In IAave.sol

function getReserveNormalizedIncome(address asset)

This function is the key to understanding how user deposits grow in value.

What it is: The "Normalized Income" is a cumulative index that tracks the total interest earned by the liquidity suppliers of a specific asset since the inception of that reserve pool.

How it works:

When a reserve for an asset is created, this index starts at a value of 1 (represented in high precision as 1×10^27, a unit called a "RAY").

As time passes and borrowers pay interest on their loans, this interest accrues to the liquidity providers.

The protocol continuously updates this index to reflect the newly accrued interest. Therefore, this index only ever increases or stays the same.

Primary Use: This index is used to determine the value of a user's aTokens. When you deposit an asset like DAI into Aave, you receive a corresponding amount of aTokens (e.g., aDAI). Your aToken balance represents your principal deposit plus all the interest you have earned. The getReserveNormalizedIncome index is the engine that drives the increase in your aToken balance over time.

Of course. Both of these functions are crucial to how Aave calculates and distributes interest to its liquidity providers (depositors).


function getReserveNormalizedIncome(address asset)
This function is the key to understanding how user deposits grow in value.

What it is: The "Normalized Income" is a cumulative index that tracks the total interest earned by the liquidity suppliers of a specific asset since the inception of that reserve pool.

How it works:

When a reserve for an asset is created, this index starts at a value of 1 (represented in high precision as 1×10^27, a unit called a "RAY").

As time passes and borrowers pay interest on their loans, this interest accrues to the liquidity providers.

The protocol continuously updates this index to reflect the newly accrued interest. Therefore, this index only ever increases or stays the same.

Primary Use: This index is used to determine the value of a user's aTokens. When you deposit an asset like DAI into Aave, you receive a corresponding amount of aTokens (e.g., aDAI). Your aToken balance represents your principal deposit plus all the interest you have earned. The getReserveNormalizedIncome index is the engine that drives the increase in your aToken balance over time.


In the world of Aave, the terms are used in slightly different contexts:

liquidityIndex: This is the technical name of the variable stored in the smart contract. A developer interacting directly with the core protocol might think in these terms.

normalizedIncome: This is the mathematical concept used in Aave's whitepaper and documentation to explain how interest accrues. A developer focused on the financial logic might think in these terms.

By providing both function names, the developer makes their interface easier to use for everyone. It allows other programmers to use the term they are most familiar with, making their own code more readable. It's like having a function that can be called getColor() or getColour() to accommodate different spellings.

