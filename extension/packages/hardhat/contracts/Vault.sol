//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import { SafeTransferLib, ERC4626, ERC20 } from "solmate/src/mixins/ERC4626.sol";
import "solmate/src/auth/Owned.sol";
import "solmate/src/utils/FixedPointMathLib.sol";
import "solmate/src/utils/ReentrancyGuard.sol";
import "solmate/src/utils/SafeCastLib.sol";
import "solmate/src/tokens/WETH.sol";
import "./Interfaces/aave/IPool.sol";
import "./Interfaces/aave/IRewardsController.sol";
import "./Interfaces/IWMATIC.sol";
import {Strategy, ERC20Strategy, ETHStrategy} from "./Interfaces/Strategy.sol";

/**
 * @author @solidoracle
 *
 * An ERC4626 multistrategy yield vault                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       
 **/

contract Vault is ERC4626, Owned, ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;    
    using SafeCastLib for uint256;
    uint256 internal immutable BASE_UNIT;
    uint256 public totalHoldings;
    uint256 public strategyBalance; // used in harvest, but not set in deposit or deducted from withdraw
    ERC20 public immutable UNDERLYING;
    uint256 public feePercent;
    uint256 public lastEpocProfitAccruedBeforeFees;

    bool public leverageStakingYieldToggle;
    uint8 public borrowPercentage;

    constructor(
        ERC20 _UNDERLYING,
        address _owner
    )
        ERC4626(_UNDERLYING, "MantleVault", "MVT")
        Owned(_owner)
    {
        // implicitly inherited from ERC20, which is passed as an argument to the ERC4626 constructor. 
        BASE_UNIT = 10**_UNDERLYING.decimals();
        UNDERLYING = _UNDERLYING;
    }


    /*///////////////////////////////////////////////////////////////
                        STRATEGY STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The total amount of underlying tokens held in strategies at the time of the last harvest.
    /// @dev Includes maxLockedProfit, must be correctly subtracted to compute available/free holdings.
    uint256 public totalStrategyHoldings;

    /// @dev Packed struct of strategy data.
    /// @param trusted Whether the strategy is trusted.
    /// @param balance The amount of underlying tokens held in the strategy.
    struct StrategyData {
        // Used to determine if the Vault will operate on a strategy.
        bool trusted;
        // Used to determine profit and loss during harvests of the strategy. ** might need to change this to the actual live balance
        uint248 balance;
        // weight of the strategy in the vault
        uint8 weight;
    }

    /// @notice Maps strategies to data the Vault holds on them.
    mapping(Strategy => StrategyData) public getStrategyData;

    Strategy[] public strategies;

    /*///////////////////////////////////////////////////////////////
                    WITHDRAWAL STACK STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice An ordered array of strategies representing the withdrawal stack.
    /// @dev The stack is processed in descending order, meaning the last index will be withdrawn from first.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are filtered out when encountered at
    /// withdrawal time, not validated upfront, meaning the stack may not reflect the "true" set used for withdrawals.
    Strategy[] public withdrawalStack;

    /// @notice Gets the full withdrawal stack.
    /// @return An ordered array of strategies representing the withdrawal stack.
    /// @dev This is provided because Solidity converts public arrays into index getters,
    /// but we need a way to allow external contracts and users to access the whole array.
    function getWithdrawalStack() external view returns (Strategy[] memory) {
        return withdrawalStack;
    }

    /*///////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/


    function addTrustedStrategy(Strategy _strategy, uint8 _weight) external onlyOwner {
        // Ensure the strategy accepts the correct underlying token.
        // If the strategy accepts ETH the Vault should accept WETH, it'll handle wrapping when necessary.
        // require(
        //     strategy.isCEther() ? underlyingIsWETH : ERC20Strategy(address(strategy)).underlying() == UNDERLYING,
        //     "WRONG_UNDERLYING"
        // );

        // require weight is between 0 and 100

        // Store the strategy as trusted.
        getStrategyData[_strategy].trusted = true;
        getStrategyData[_strategy].weight = _weight;
        strategies.push(_strategy);

        // check that strategies add up to 100
    }

    /**
     * @inheritdoc ERC4626
     */
    function afterDeposit(uint256 assets, uint256) internal override nonReentrant {
        // // deposit assets to Aave
        // ERC20(asset).approve(aave, assets);
        // // we are not considering the float here -- we are depositing everything
        // IPool(aave).supply(address(asset), assets, address(this), 0);
        // // Increase totalHoldings to account for the deposit.
        // totalHoldings += assets;

        // for each trusted strategy, allocate the funds according to the weight
        for (uint256 i = 0; i < strategies.length; i++) {

            Strategy strategy = strategies[i];
            StrategyData storage data = getStrategyData[strategy];
            if (data.trusted) {

                //depositIntoStrategy
                uint256 strategyAmount = assets.mulDivDown(data.weight, 100); // need more precision here
                // deposit assets to strategy

                ERC20(asset).approve(address(strategy), strategyAmount);
                ERC20(asset).transfer(address(strategy), strategyAmount);
                strategy.deposit(strategyAmount);

                // Increase totalStrategyHoldings to account for the deposit.
                // TOTAL STRATEGY HOLDINGS != TOTAL HOLDINGS
                totalStrategyHoldings += strategyAmount;
            }
        }
    }
    

    
    function beforeWithdraw(uint256 assets, uint256) internal override {
        // Retrieve underlying tokens from strategy/float.
        retrieveUnderlying(assets);
    }

    /// @dev Retrieves a specific amount of underlying tokens held in the strategy and/or float.
    /// @dev Only withdraws from strategies if needed and maintains the target float percentage if possible.
    /// @param underlyingAmount The amount of underlying tokens to retrieve.
    function retrieveUnderlying(uint256 underlyingAmount) internal {
        totalStrategyHoldings = totalAssets();

        pullFromStrategy(underlyingAmount);
    }

    /*///////////////////////////////////////////////////////////////
                        STRATEGY WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function pullFromStrategy(uint256 underlyingAmount) public {
        // IPool(aave).withdraw(address(asset), underlyingAmount, address(this));

        // for each trusted strategy, allocate the funds according to the weight
        for (uint256 i = 0; i < strategies.length; i++) {

            Strategy strategy = strategies[i];
            StrategyData storage data = getStrategyData[strategy];
            if (data.trusted) {

                //withdrawFromStrategy
                uint256 withdrawAmount = underlyingAmount.mulDivDown(data.weight, 100); // need more precision here

   
                strategy.redeemUnderlying(withdrawAmount);


                totalStrategyHoldings -= withdrawAmount;
            }
        }
        // unchecked {
        //     totalHoldings -= underlyingAmount;
        // }
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        asset.safeTransfer(receiver, assets);
    }

    /*///////////////////////////////////////////////////////////////
                        VAULT ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    // THIS DETERMINES IF YOU HARVEST WHEN WITHDRAWING
    /// @notice Calculates the total amount of underlying tokens the Vault holds.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the Vault holds.
    function totalAssets() public view override returns (uint256) {
        uint256 totalUnderlyingHeld;

        for (uint256 i = 0; i < strategies.length; i++) {
            Strategy strategy = strategies[i];
            StrategyData storage data = getStrategyData[strategy];

            if (data.trusted) {
                uint256 strategyBalance = strategy.strategyBalance(); 
                totalUnderlyingHeld += strategyBalance;
            }
        }
        return totalUnderlyingHeld;
    }

    function totalFloat() public view returns (uint256) {
        return UNDERLYING.balanceOf(address(this));
    }
    
    /*///////////////////////////////////////////////////////////////
                             HARVEST LOGIC
    //////////////////////////////////////////////////////////////*/

    // I think we should harvest the equity
    // as the increase in debt is something that needs to be repayed by the user, and we should not charge fees on that
    function harvest() external onlyOwner {
        // Used to store the total profit accrued by the aave strategy.
        uint256 totalProfitAccrued;

        // Get the strategy's previous and current balance.
        uint256 balanceLastHarvest = totalHoldings;
        uint balanceThisHarvest = totalAssets();

        unchecked {
            // Update the total profit accrued while counting losses as zero profit.
            totalProfitAccrued += balanceThisHarvest > balanceLastHarvest
                ? balanceThisHarvest - balanceLastHarvest // Profits since last harvest.
                : 0; // If the strategy registered a net loss we don't have any new profit.

            
        }

        // Compute fees as the fee percent multiplied by the profit.
        uint256 feesAccrued = totalProfitAccrued.mulDivDown(feePercent, 1e18);
    
        // If we accrued any fees, mint an equivalent amount of rvTokens.
        _mint(address(this), feesAccrued.mulDivDown(BASE_UNIT, convertToAssets(BASE_UNIT)));
    
        lastEpocProfitAccruedBeforeFees = totalProfitAccrued - feesAccrued; // used to check the yield in tests

        // Set total holdings to our new total.
        totalHoldings += totalProfitAccrued - feesAccrued;
    }

    /*///////////////////////////////////////////////////////////////
                             FEE & REWARD CLAIM LOGIC
    //////////////////////////////////////////////////////////////*/

    function claimFees(uint256 amount) external onlyOwner {
        // Transfer the provided amount of rvTokens to the caller.
        asset.safeTransfer(msg.sender, amount);
    }

    /// @notice Emitted when the fee percentage is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newFeePercent The new fee percentage.
    event FeePercentUpdated(address indexed user, uint256 newFeePercent);

    /// @notice Sets a new fee percentage.
    /// @param newFeePercent The new fee percentage.
    function setFeePercent(uint256 newFeePercent) external onlyOwner {
        // A fee percentage over 100% doesn't make sense.
        require(newFeePercent <= 1e18, "FEE_TOO_HIGH");

        // Update the fee percentage.
        feePercent = newFeePercent;

        emit FeePercentUpdated(msg.sender, newFeePercent);
    }

    /*///////////////////////////////////////////////////////////////
                          RECIEVE ETHER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Required for the Vault to receive unwrapped ETH.
    receive() external payable {
        // Convert the MATIC to WMATIC
        // WMATIC(payable(address(asset))).deposit{value: msg.value}();

        // Deposit the WMATIC to the Vault
        // this.deposit(msg.value, msg.sender);
     }

}
