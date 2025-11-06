// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract Usdt is ERC20, ERC20Burnable, ERC20Permit {
    error NotDeployer();
    error MinterAlreadySet();
    error ZeroAddress();
    error NotMinter();

    address public immutable deployer; // 部署者，仅用于设置一次 minter
    address public minter;             // 主合约地址
    bool    public minterSet;

    event MinterSet(address indexed minter);

    /**
     * @param name_   代币名
     * @param symbol_ 代币符号
     */
    constructor(
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_) // EIP-2612
    {
        deployer = msg.sender;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice 仅部署者可调用一次：将主合约地址设为唯一铸造者
    function setMinterOnce(address minter_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (minterSet) revert MinterAlreadySet();
        if (minter_ == address(0)) revert ZeroAddress();
        minter = minter_;
        minterSet = true;
        emit MinterSet(minter_);
    }

    /// @notice 仅主合约（minter）可铸造
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }
}
