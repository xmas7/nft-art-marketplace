// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./Constants.sol";
import "./MuseeTreasuryNode.sol";
import "./SendValueWithFallbackWithdraw.sol";

/**
 * @title A mixin to distribute funds when an NFT is sold.
 */
abstract contract NFTMarketFees is Constants, Initializable, MuseeTreasuryNode, SendValueWithFallbackWithdraw {
  /**
   * @dev Removing old unused variables in an upgrade safe way. Was:
   * uint256 private _primaryMuseeFeeBasisPoints;
   * uint256 private _secondaryMuseeFeeBasisPoints;
   * uint256 private _secondaryCreatorFeeBasisPoints;
   * mapping(address => mapping(uint256 => bool)) private _nftContractToTokenIdToFirstSaleCompleted;
   */
  uint256[4] private __gap_was_fees;

  /// @notice The royalties sent to creator recipients on secondary sales.
  uint256 private constant CREATOR_ROYALTY_DENOMINATOR = BASIS_POINTS / 1000; // 10%
  /// @notice The fee collected by Musee for sales facilitated by this market contract.
  uint256 private constant MUSEE_FEE_DENOMINATOR = BASIS_POINTS / 500; // 5%
  /// @notice Musee NFT collection address
  address private immutable MUSEE_NFT_CONTRACT;

  /**
   * @notice Configures the musee collection address
   * @param museeNftContract The Musee Collection Address
   */
  constructor(address museeNftContract) {
    MUSEE_NFT_CONTRACT = museeNftContract;
  }

  /**
   * @notice Distributes funds to musee, creator recipients, and NFT owner after a sale.
   */
  // solhint-disable-next-line code-complexity
  function _distributeFunds(
    address nftContract,
    uint256 tokenId,
    address payable seller,
    uint256 price
  )
    internal
    returns (
      uint256 museeFee,
      uint256 creatorFee,
      uint256 ownerRev
    )
  {
    address payable[] memory creatorRecipients;
    uint256[] memory creatorShares;

    address payable ownerRevTo;
    (museeFee, creatorRecipients, creatorShares, creatorFee, ownerRevTo, ownerRev) = _getFees(
      nftContract,
      tokenId,
      seller,
      price
    );

    _sendValueWithFallbackWithdraw(getMuseeTreasury(), museeFee, SEND_VALUE_GAS_LIMIT_SINGLE_RECIPIENT);

    if (creatorFee != 0) {
      if (creatorRecipients.length > 1) {
        uint256 maxCreatorIndex = creatorRecipients.length;
        unchecked {
          // maxCreatorIndex cannot underflow due to the if above
          --maxCreatorIndex;
        }

        if (maxCreatorIndex > MAX_ROYALTY_RECIPIENTS_INDEX) {
          maxCreatorIndex = MAX_ROYALTY_RECIPIENTS_INDEX;
        }

        // Determine the total shares defined so it can be leveraged to distribute below
        uint256 totalShares;
        unchecked {
          // The array length cannot overflow 256 bits.
          for (uint256 i = 0; i <= maxCreatorIndex; ++i) {
            if (creatorShares[i] > BASIS_POINTS) {
              // If the numbers are >100% we ignore the fee recipients and pay just the first instead
              maxCreatorIndex = 0;
              break;
            }
            // The check above ensures totalShares wont overflow.
            totalShares += creatorShares[i];
          }
        }
        if (totalShares == 0) {
          maxCreatorIndex = 0;
        }

        // Send payouts to each additional recipient if more than 1 was defined
        uint256 totalRoyaltiesDistributed;
        for (uint256 i = 1; i <= maxCreatorIndex; ) {
          uint256 royalty = (creatorFee * creatorShares[i]) / totalShares;
          totalRoyaltiesDistributed += royalty;
          _sendValueWithFallbackWithdraw(creatorRecipients[i], royalty, SEND_VALUE_GAS_LIMIT_MULTIPLE_RECIPIENTS);
          unchecked {
            ++i;
          }
        }

        // Send the remainder to the 1st creator, rounding in their favor
        _sendValueWithFallbackWithdraw(
          creatorRecipients[0],
          creatorFee - totalRoyaltiesDistributed,
          SEND_VALUE_GAS_LIMIT_MULTIPLE_RECIPIENTS
        );
      } else {
        _sendValueWithFallbackWithdraw(creatorRecipients[0], creatorFee, SEND_VALUE_GAS_LIMIT_MULTIPLE_RECIPIENTS);
      }
    }
    _sendValueWithFallbackWithdraw(ownerRevTo, ownerRev, SEND_VALUE_GAS_LIMIT_SINGLE_RECIPIENT);
  }

  /**
   * @notice Returns how funds will be distributed for a sale at the given price point.
   * @param nftContract The address of the NFT contract.
   * @param tokenId The id of the NFT.
   * @param price The sale price to calculate the fees for.
   * @return museeFee How much will be sent to the Musee treasury.
   * @return creatorRev How much will be sent across all the `creatorRecipients` defined.
   * @return creatorRecipients The addresses of the recipients to receive a portion of the creator fee.
   * @return creatorShares The percentage of the creator fee to be distributed to each `creatorRecipient`.
   * If there is only one `creatorRecipient`, this may be an empty array.
   * Otherwise `creatorShares.length` == `creatorRecipients.length`.
   * @return ownerRev How much will be sent to the owner/seller of the NFT.
   * If the NFT is being sold by the creator, this may be 0 and the full revenue will appear as `creatorRev`.
   * @return owner The address of the owner of the NFT.
   * If `ownerRev` is 0, this may be `address(0)`.
   */
  function getFeesAndRecipients(
    address nftContract,
    uint256 tokenId,
    uint256 price
  )
    external
    view
    returns (
      uint256 museeFee,
      uint256 creatorRev,
      address payable[] memory creatorRecipients,
      uint256[] memory creatorShares,
      uint256 ownerRev,
      address payable owner
    )
  {
    address payable seller = _getSellerFor(nftContract, tokenId);
    (museeFee, creatorRecipients, creatorShares, creatorRev, owner, ownerRev) = _getFees(
      nftContract,
      tokenId,
      seller,
      price
    );
  }

  /**
   * @notice Calculates how funds should be distributed for the given sale details.
   * @dev When the NFT is being sold by the `tokenCreator`, all the seller revenue will
   * be split with the royalty recipients defined for that NFT.
   */
  function _getFees(
    address nftContract,
    uint256 tokenId,
    address payable seller,
    uint256 price
  )
    private
    view
    returns (
      uint256 museeFee,
      address payable[] memory creatorRecipients,
      uint256[] memory creatorShares,
      uint256 creatorRev,
      address payable ownerRevTo,
      uint256 ownerRev
    )
  {
    bool isCreator = false;
    // lookup for tokenCreator
    try ITokenCreator(nftContract).tokenCreator{ gas: READ_ONLY_GAS_LIMIT }(tokenId) returns (
      address payable _creator
    ) {
      isCreator = _creator == seller;
    } catch // solhint-disable-next-line no-empty-blocks
    {
      // Fall through
    }

    (creatorRecipients, creatorShares) = _getCreatorPaymentInfo(nftContract, tokenId);

    // Calculate the Musee fee
    unchecked {
      // SafeMath is not required when dividing by a non-zero constant.
      uint256 nftBalance = IERC721(MUSEE_NFT_CONTRACT).balanceOf(seller);
      if (nftBalance != 0) {
        museeFee = 0;
      } else {
        museeFee = price / MUSEE_FEE_DENOMINATOR;
      }
    }

    if (creatorRecipients.length != 0) {
      if (isCreator || (creatorRecipients.length == 1 && seller == creatorRecipients[0])) {
        // When sold by the creator, all revenue is split if applicable.
        unchecked {
          // museeFee is always < price.
          creatorRev = price - museeFee;
        }
      } else {
        // Rounding favors the owner first, then creator, and musee last.
        unchecked {
          // SafeMath is not required when dividing by a non-zero constant.
          creatorRev = price / CREATOR_ROYALTY_DENOMINATOR;
        }
        ownerRevTo = seller;
        ownerRev = price - museeFee - creatorRev;
      }
    } else {
      // No royalty recipients found.
      ownerRevTo = seller;
      unchecked {
        // museeFee is always < price.
        ownerRev = price - museeFee;
      }
    }
  }

  /**
   * @notice This empty reserved space is put in place to allow future versions to add new
   * variables without shifting down storage in the inheritance chain.
   * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
   */
  uint256[1000] private __gap;
}
