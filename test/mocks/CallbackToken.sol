// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VestingVault} from "../../src/VestingVault.sol";

interface ITokenReceiver {
    function tokensReceived(address from, uint256 amount) external;
}

/// @notice ERC-777-style token: after every transfer it calls `tokensReceived` on hooked recipients.
contract CallbackToken is ERC20 {
    mapping(address => bool) public hooked;

    constructor() ERC20("Callback Token", "CBT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHooked(address account, bool on) external {
        hooked[account] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && hooked[to]) {
            ITokenReceiver(to).tokensReceived(from, value);
        }
    }
}

/// @notice Malicious beneficiary that re-enters `release` while receiving tokens.
contract ReentrantBeneficiary is ITokenReceiver {
    VestingVault public immutable vault;
    uint256 public id;
    uint256 public attempts;
    bool public reentrySucceeded;

    constructor(VestingVault vault_) {
        vault = vault_;
    }

    function setId(uint256 id_) external {
        id = id_;
    }

    function tokensReceived(address, uint256) external {
        if (attempts < 3) {
            attempts++;
            try vault.release(id) {
                reentrySucceeded = true;
            } catch {}
        }
    }
}
