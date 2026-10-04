// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Test double for the USDC ERC-20 interface: 6 decimals, a blocklist that
/// reverts like Arc's, and a revert on transfers to the zero address.
contract MockUSDC {
    string public constant name = "USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocklisted;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function setBlocklisted(address who, bool on) external {
        blocklisted[who] = on;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ERC20: insufficient allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(to != address(0), "Zero address not allowed");
        require(!blocklisted[from] && !blocklisted[to], "Blocklisted address");
        require(balanceOf[from] >= amount, "ERC20: transfer amount exceeds balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice A hostile token: while armed, every transfer calls back into the vault.
contract ReentrantToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    address public vault;
    bytes public attack;
    bool public armed;
    bytes public lastResult;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(address vault_, bytes calldata attack_) external {
        vault = vault_;
        attack = attack_;
        armed = true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = vault.call(attack);
            lastResult = ret;
            // propagate the vault's refusal so the test can see it
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice A token whose transfers report failure instead of reverting.
contract FalseReturnToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice A token with the wrong number of decimals.
contract EighteenDecimalsToken {
    uint8 public constant decimals = 18;
}
