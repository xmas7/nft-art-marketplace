// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/IAdminRole.sol";
import "../interfaces/IOperatorRole.sol";

error MuseeTreasuryNode_Address_Is_Not_A_Contract();
error MuseeTreasuryNode_Caller_Not_Admin();
error MuseeTreasuryNode_Caller_Not_Operator();

/**
 * @title A mixin that stores a reference to the Musee treasury contract.
 * @notice The treasury collects fees and defines admin/operator roles.
 */
abstract contract MuseeTreasuryNode is Initializable {
  using AddressUpgradeable for address payable;

  /// @dev This value was replaced with an immutable version.
  address payable private __gap_was_treasury;

  /// @notice The address of the treasury contract.
  address payable private immutable treasury;

  /// @notice Requires the caller is a Musee admin.
  modifier onlyMuseeAdmin() {
    if (!IAdminRole(treasury).isAdmin(msg.sender)) {
      revert MuseeTreasuryNode_Caller_Not_Admin();
    }
    _;
  }

  /// @notice Requires the caller is a Musee operator.
  modifier onlyMuseeOperator() {
    if (!IOperatorRole(treasury).isOperator(msg.sender)) {
      revert MuseeTreasuryNode_Caller_Not_Operator();
    }
    _;
  }

  /**
   * @notice Set immutable variables for the implementation contract.
   * @dev Assigns the treasury contract address.
   */
  constructor(address payable _treasury) {
    if (!_treasury.isContract()) {
      revert MuseeTreasuryNode_Address_Is_Not_A_Contract();
    }
    treasury = _treasury;
  }

  /**
   * @notice Gets the Musee treasury contract.
   * @dev This call is used in the royalty registry contract.
   * @return treasuryAddress The address of the Musee treasury contract.
   */
  function getMuseeTreasury() public view returns (address payable treasuryAddress) {
    return treasury;
  }

  /**
   * @notice This empty reserved space is put in place to allow future versions to add new
   * variables without shifting down storage in the inheritance chain.
   * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
   */
  uint256[2000] private __gap;
}
