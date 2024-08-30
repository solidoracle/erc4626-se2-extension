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
        ERC4626(_UNDERLYING, "Vault", "VLT")
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
        // Store the strategy as trusted.
        getStrategyData[_strategy].trusted = true;
        getStrategyData[_strategy].weight = _weight;
        strategies.push(_strategy);
    }

    /**
     * @inheritdoc ERC4626
     */
    function afterDeposit(uint256 assets, uint256) internal override nonReentrant {
    }
    

    
    function beforeWithdraw(uint256 assets, uint256) internal override {
    }


    /*///////////////////////////////////////////////////////////////
                        REDEEM LOGIC
    //////////////////////////////////////////////////////////////*/

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        assets = previewRedeem(shares);
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
}
