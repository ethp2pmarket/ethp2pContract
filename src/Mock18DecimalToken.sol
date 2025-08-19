// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Mock18DecimalToken
 * @notice Mock ERC20 token with 18 decimals for testing
 */
contract Mock18DecimalToken is ERC20, Ownable {
    constructor(address owner) ERC20("Mock18Token", "M18T") Ownable(owner) {}

    /**
     * @dev Returns the number of decimals used
     * @return Number of decimals
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @notice Mint tokens to an address - only callable by owner
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint (in token's smallest unit)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from an address - only callable by owner
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn (in token's smallest unit)
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
