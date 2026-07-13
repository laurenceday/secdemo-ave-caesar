// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "../../src/ISealedEntityCredential.sol";
import {IAaveV4HubLike} from "../../src/AaveV4SpokeTrigger.sol";

/// @notice Minimal registry mock: setters for everything the consumers read.
contract MockSealedRegistry is ISealedEntityCredentialRegistry {
    mapping(address => bytes32) internal _credentialOf;
    mapping(bytes32 => CredentialView) internal _views;

    // -------- test setters --------
    function setWallet(address wallet, bytes32 id) external {
        _credentialOf[wallet] = id;
    }

    function setCredential(
        bytes32 id,
        bytes32 schemaProfile,
        address attestor,
        uint64 issuedAt,
        uint64 expiresAt,
        bool revoked,
        address[] memory triggers,
        bytes32[] memory triggerClasses
    ) external {
        CredentialView storage v = _views[id];
        v.schemaProfile = schemaProfile;
        v.attestor = attestor;
        v.issuedAt = issuedAt;
        v.expiresAt = expiresAt;
        v.revoked = revoked;
        v.triggers = triggers;
        v.triggerClasses = triggerClasses;
    }

    function setRevoked(bytes32 id, bool r) external {
        _views[id].revoked = r;
    }

    // -------- interface --------
    function credentialOf(address wallet) external view returns (bytes32) {
        return _credentialOf[wallet];
    }

    function getCredential(bytes32 id) external view returns (CredentialView memory) {
        return _views[id];
    }

    function boundTriggerOfClass(bytes32 id, bytes32 klass)
        external
        view
        returns (bool bound, address trigger)
    {
        CredentialView storage v = _views[id];
        for (uint256 i; i < v.triggerClasses.length; ++i) {
            if (v.triggerClasses[i] == klass) return (true, v.triggers[i]);
        }
        return (false, address(0));
    }

    // -------- unused in tests --------
    function register(
        bytes calldata,
        SealedTier[] calldata,
        address[] calldata,
        bytes32[] calldata,
        bytes calldata,
        bytes calldata
    ) external pure returns (bytes32) {
        revert("unimplemented");
    }

    function bindWallet(bytes32, address, bytes calldata) external pure {
        revert("unimplemented");
    }

    function unbindWallet(bytes32, address, bytes calldata) external pure {
        revert("unimplemented");
    }

    function publicField(bytes32, bytes32) external pure returns (bytes memory) {
        return "";
    }

    function revealField(bytes32, uint8, bytes32, bytes calldata, bytes32, bytes32[] calldata)
        external
        pure
    {
        revert("unimplemented");
    }
}

/// @notice Latch-flag trigger mock with a settable class (for wrong-class
///         provider tests).
contract MockLatchTrigger is IDisclosureTrigger {
    bytes32 public immutable klass;
    mapping(bytes32 => bool) public triggerableFlag;
    mapping(bytes32 => uint64) internal _at;

    constructor(bytes32 _klass) {
        klass = _klass;
    }

    function setTriggerable(bytes32 id, bool f) external {
        triggerableFlag[id] = f;
    }

    function latch(bytes32 id) external {
        require(triggerableFlag[id], "not triggerable");
        _at[id] = uint64(block.timestamp);
    }

    function isTriggered(bytes32 id) external view returns (bool) {
        return _at[id] != 0;
    }

    function isTriggerable(bytes32 id) external view returns (bool) {
        return triggerableFlag[id] && _at[id] == 0;
    }

    function triggeredAt(bytes32 id) external view returns (uint64) {
        return _at[id];
    }

    function triggerClass() external view returns (bytes32) {
        return klass;
    }
}

/// @notice Aave V4 Hub mock: the two views the trigger consumes, plus the
///         ways the real state moves — spokes report liquidation write-offs
///         (deficit up), the role-gated eliminate path covers them (deficit
///         down), and governance updates spoke config (drawCap/active).
contract MockAaveV4Hub {
    mapping(uint256 => mapping(address => uint256)) public deficitRay;
    mapping(uint256 => mapping(address => IAaveV4HubLike.SpokeConfig)) internal _configs;

    // -------- test setters mirroring real state transitions --------
    function reportDeficit(uint256 assetId, address spoke, uint256 amountRay) external {
        deficitRay[assetId][spoke] += amountRay;
    }

    function eliminateDeficit(uint256 assetId, address spoke, uint256 amountRay) external {
        deficitRay[assetId][spoke] -= amountRay;
    }

    function setSpokeConfig(
        uint256 assetId,
        address spoke,
        uint40 addCap,
        uint40 drawCap,
        bool active
    ) external {
        _configs[assetId][spoke] = IAaveV4HubLike.SpokeConfig({
            addCap: addCap,
            drawCap: drawCap,
            riskPremiumThreshold: 0,
            active: active,
            halted: false
        });
    }

    // -------- trigger-consumed views --------
    function getSpokeDeficitRay(uint256 assetId, address spoke) external view returns (uint256) {
        return deficitRay[assetId][spoke];
    }

    function getSpokeConfig(uint256 assetId, address spoke)
        external
        view
        returns (IAaveV4HubLike.SpokeConfig memory)
    {
        return _configs[assetId][spoke];
    }
}

/// @notice Minimal ERC20 for the allocator demo.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
