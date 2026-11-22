// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VestingVault — token vesting with cliff, linear unlock and revocation
/// @notice One vault holds tokens for many beneficiaries. The owner (e.g. the project team)
///         creates schedules; beneficiaries (team, investors, advisors) receive tokens over time.
contract VestingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //  PROVIDED PART (identical to the student starter file)
    // ============================================================
    struct Schedule {
        address beneficiary;
        uint256 total;      // total tokens promised
        uint256 released;   // tokens already paid out
        uint64 start;       // unix time when vesting starts
        uint64 cliff;       // seconds after `start` before ANY token vests
        uint64 duration;    // seconds after `start` when 100% is vested
        uint64 revokedAt;   // 0 while not revoked
        bool revocable;
        bool revoked;
    }

    IERC20 public immutable token;
    uint256 public scheduleCount;                       // ids start from 1
    uint256 public totalAllocated;                      // tokens promised to beneficiaries and not yet paid out
    mapping(uint256 => Schedule) public schedules;
    mapping(address => uint256[]) private _schedulesOf;

    event ScheduleCreated(uint256 indexed id, address indexed beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration, bool revocable);
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event Revoked(uint256 indexed id, uint256 returnedToOwner);
    event ScheduleTransferred(uint256 indexed id, address indexed from, address indexed to);

    constructor(IERC20 token_) Ownable(msg.sender) {
        require(address(token_) != address(0), "zero token");
        token = token_;
    }

    // ============================================================
    //  IMPLEMENTATION
    // ============================================================

    /// @notice Emitted when the owner withdraws tokens that are not promised to anybody.
    event UnallocatedWithdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroDuration();
    error CliffExceedsDuration();
    error InsufficientUnallocated(uint256 available, uint256 requested);
    error UnknownSchedule(uint256 id);
    error NothingToRelease();
    error NotRevocable();
    error AlreadyRevoked();
    error NothingToWithdraw();
    error NotBeneficiary();

    // ------------------------------------------------------------
    // STEP 1 — create a schedule
    // ------------------------------------------------------------

    /// @notice Creates a new vesting schedule backed by tokens already held by the vault.
    /// @dev The vault must hold at least `amount` tokens that are not promised to other schedules.
    /// @param beneficiary Address that will receive the vested tokens.
    /// @param amount Total number of tokens (in token base units) to vest.
    /// @param start Unix timestamp when vesting starts. May be in the past (retroactive vesting).
    /// @param cliff Seconds after `start` during which nothing vests. Must be <= `duration`.
    /// @param duration Seconds after `start` when 100% is vested. Must be > 0.
    /// @param revocable Whether the owner may later revoke the unvested part.
    /// @return id The id of the new schedule (ids start from 1).
    function createSchedule(
        address beneficiary,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    ) external onlyOwner returns (uint256 id) {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (duration == 0) revert ZeroDuration();
        if (cliff > duration) revert CliffExceedsDuration();

        uint256 available = _unallocated();
        if (available < amount) revert InsufficientUnallocated(available, amount);

        id = ++scheduleCount;
        schedules[id] = Schedule({
            beneficiary: beneficiary,
            total: amount,
            released: 0,
            start: start,
            cliff: cliff,
            duration: duration,
            revokedAt: 0,
            revocable: revocable,
            revoked: false
        });
        _schedulesOf[beneficiary].push(id);
        totalAllocated += amount;

        emit ScheduleCreated(id, beneficiary, amount, start, cliff, duration, revocable);
    }

    // ------------------------------------------------------------
    // STEP 2 — the vesting formula
    // ------------------------------------------------------------

    /// @notice Amount vested (earned) so far by schedule `id`, including tokens already released.
    /// @dev Frozen at `revokedAt` once the schedule is revoked. Reverts for an unknown id.
    /// @param id Schedule id.
    /// @return The vested amount in token base units.
    function vestedAmount(uint256 id) public view returns (uint256) {
        return _vested(_get(id));
    }

    /// @notice Amount the beneficiary of schedule `id` can claim right now (`vested - released`).
    /// @param id Schedule id.
    /// @return The releasable amount in token base units.
    function releasable(uint256 id) public view returns (uint256) {
        Schedule storage s = _get(id);
        return _vested(s) - s.released;
    }

    // ------------------------------------------------------------
    // STEP 3 — release
    // ------------------------------------------------------------

    /// @notice Pays out everything currently releasable for schedule `id`.
    /// @dev Anyone may call it (e.g. a keeper bot); tokens always go to the beneficiary.
    ///      Checks → Effects → Interactions plus `nonReentrant`.
    /// @param id Schedule id.
    function release(uint256 id) external nonReentrant {
        Schedule storage s = _get(id);
        uint256 amount = _vested(s) - s.released;
        if (amount == 0) revert NothingToRelease();

        // Effects
        s.released += amount;
        totalAllocated -= amount;
        address beneficiary = s.beneficiary;
        emit Released(id, beneficiary, amount);

        // Interaction
        token.safeTransfer(beneficiary, amount);
    }

    // ------------------------------------------------------------
    // STEP 4 — revoke
    // ------------------------------------------------------------

    /// @notice Revokes schedule `id`: the unvested part goes back to the owner, the vested part
    ///         stays claimable by the beneficiary, and vesting is frozen at the current time.
    /// @dev Only for revocable, not-yet-revoked schedules. Revoking a fully vested schedule returns 0.
    /// @param id Schedule id.
    function revoke(uint256 id) external onlyOwner nonReentrant {
        Schedule storage s = _get(id);
        if (!s.revocable) revert NotRevocable();
        if (s.revoked) revert AlreadyRevoked();

        uint256 unvested = s.total - _vested(s);

        // Effects
        s.revoked = true;
        s.revokedAt = uint64(block.timestamp);
        totalAllocated -= unvested;
        emit Revoked(id, unvested);

        // Interaction
        if (unvested > 0) token.safeTransfer(owner(), unvested);
    }

    // ------------------------------------------------------------
    // STEP 5 — housekeeping
    // ------------------------------------------------------------

    /// @notice Sends every token not promised to a schedule (`balance - totalAllocated`) to `to`.
    /// @dev Used to rescue tokens sent to the vault by mistake. Never touches promised tokens.
    /// @param to Recipient of the surplus.
    /// @return amount The amount withdrawn.
    function withdrawUnallocated(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = _unallocated();
        if (amount == 0) revert NothingToWithdraw();
        emit UnallocatedWithdrawn(to, amount);
        token.safeTransfer(to, amount);
    }

    /// @notice Ids of the schedules currently owned by `beneficiary`.
    /// @param beneficiary Address to look up.
    /// @return The list of schedule ids.
    function schedulesOf(address beneficiary) external view returns (uint256[] memory) {
        return _schedulesOf[beneficiary];
    }

    /// @notice Tokens held by the vault that are not promised to any schedule.
    /// @return The unallocated balance.
    function unallocated() external view returns (uint256) {
        return _unallocated();
    }

    // ------------------------------------------------------------
    // BONUS — transfer a schedule to another address
    // ------------------------------------------------------------

    /// @notice Moves schedule `id` to a new beneficiary (e.g. a new wallet). The released amount is kept.
    /// @dev Only the current beneficiary may call it.
    /// @param id Schedule id.
    /// @param newBeneficiary The new beneficiary, must not be the zero address.
    function transferSchedule(uint256 id, address newBeneficiary) external {
        Schedule storage s = _get(id);
        address from = s.beneficiary;
        if (msg.sender != from) revert NotBeneficiary();
        if (newBeneficiary == address(0)) revert ZeroAddress();

        _removeId(from, id);
        s.beneficiary = newBeneficiary;
        _schedulesOf[newBeneficiary].push(id);

        emit ScheduleTransferred(id, from, newBeneficiary);
    }

    // ------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------

    function _get(uint256 id) internal view returns (Schedule storage s) {
        s = schedules[id];
        if (s.beneficiary == address(0)) revert UnknownSchedule(id);
    }

    function _vested(Schedule storage s) internal view returns (uint256) {
        uint256 t = s.revoked ? uint256(s.revokedAt) : block.timestamp;
        uint256 start = s.start;
        if (t < start + s.cliff) return 0;
        if (t >= start + s.duration) return s.total;
        // multiply before dividing; mulDiv is overflow-safe for any `total`
        return Math.mulDiv(s.total, t - start, s.duration);
    }

    function _unallocated() internal view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        return balance > totalAllocated ? balance - totalAllocated : 0;
    }

    function _removeId(address owner_, uint256 id) internal {
        uint256[] storage ids = _schedulesOf[owner_];
        uint256 len = ids.length;
        for (uint256 i; i < len; ++i) {
            if (ids[i] == id) {
                ids[i] = ids[len - 1];
                ids.pop();
                return;
            }
        }
    }
}
