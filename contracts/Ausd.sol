// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract AusdToken is ERC20, ERC20Burnable, ERC20Permit {
    error NotMinter();
    error ZeroAddress();

    address public minter;             // 当前主合约地址（可更换）

    event MinterChanged(address indexed oldMinter, address indexed newMinter);

    constructor(
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_) // EIP-2612
    {
        minter = msg.sender; // 初始 minter 即部署者
        emit MinterChanged(address(0), msg.sender);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice 当前 minter 可更新新的 minter 地址
    function setMinter(address newMinter) external {
        if (msg.sender != minter) revert NotMinter();
        if (newMinter == address(0)) revert ZeroAddress();
        emit MinterChanged(minter, newMinter);
        minter = newMinter;
    }

    /// @notice 仅当前 minter 可铸造
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }
}
