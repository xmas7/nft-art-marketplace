/*
  MUSEE Protocol
*/

// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./mixins/Constants.sol";
import "./mixins/MuseeTreasuryNode.sol";
import "./mixins/NFTMarketAuction.sol";
import "./mixins/NFTMarketBuyPrice.sol";
import "./mixins/NFTMarketCore.sol";
import "./mixins/NFTMarketCreators.sol";
import "./mixins/NFTMarketFees.sol";
import "./mixins/NFTMarketOffer.sol";
import "./mixins/NFTMarketPrivateSale.sol";
import "./mixins/NFTMarketReserveAuction.sol";
import "./mixins/SendValueWithFallbackWithdraw.sol";

/**
 * @title A market for NFTs on Musee.
 * @notice The Musee marketplace is a contract which allows traders to buy and sell NFTs.
 * It supports buying and selling via auctions, private sales, buy price, and offers.
 * @dev All sales in the Musee market will pay the creator 10% royalties on secondary sales. This is not specific
 * to NFTs minted on Musee, it should work for any NFT. If royalty information was not defined when the NFT was
 * originally deployed, it may be added using the [Royalty Registry](https://royaltyregistry.xyz/) which will be
 * respected by our market contract.
 */
contract MUSEENFTMarket is
  Constants,
  Initializable,
  MuseeTreasuryNode,
  NFTMarketCore,
  ReentrancyGuardUpgradeable,
  NFTMarketCreators,
  SendValueWithFallbackWithdraw,
  NFTMarketFees,
  NFTMarketAuction,
  NFTMarketReserveAuction,
  NFTMarketPrivateSale,
  NFTMarketBuyPrice,
  NFTMarketOffer
{
  /**
   * @notice Set immutable variables for the implementation contract.
   * @dev Using immutable instead of constants allows us to use different values on testnet.
   * @param treasury The Musee Treasury contract address.
   * @param meth The METH ERC-20 token contract address.
   * @param royaltyRegistry The Royalty Registry contract address.
   * @param duration The duration of the auction in seconds.
   * @param marketProxyAddress The address of the proxy fronting this contract.
   */
  constructor(
    address payable treasury,
    address meth,
    address royaltyRegistry,
    uint256 duration,
    address marketProxyAddress,
    address museeNftContract
  )
    MuseeTreasuryNode(treasury)
    NFTMarketCore(meth)
    NFTMarketCreators(royaltyRegistry)
    NFTMarketReserveAuction(duration)
    NFTMarketPrivateSale(marketProxyAddress) // solhint-disable-next-line no-empty-blocks
    NFTMarketFees(museeNftContract)
  {}
  
  /**
   * @inheritdoc NFTMarketCore
   * @dev This is a no-op function required to avoid compile errors.
   */
  function _transferFromEscrow(
    address nftContract,
    uint256 tokenId,
    address recipient,
    address authorizeSeller
  ) internal override(NFTMarketCore, NFTMarketReserveAuction, NFTMarketBuyPrice) {
    super._transferFromEscrow(nftContract, tokenId, recipient, authorizeSeller);
  }
  /**
   * @notice Called once to configure the contract after the initial proxy deployment.
   * @dev This farms the initialize call out to inherited contracts as needed to initialize mutable variables.
   */
  function initialize() external initializer {
    NFTMarketAuction._initializeNFTMarketAuction();
  }

  /**
   * @inheritdoc NFTMarketCore
   * @dev This is a no-op function required to avoid compile errors.
   */
  function _beforeAuctionStarted(address nftContract, uint256 tokenId)
    internal
    override(NFTMarketCore, NFTMarketBuyPrice, NFTMarketOffer)
  {
    super._beforeAuctionStarted(nftContract, tokenId);
  }

  /**
   * @inheritdoc NFTMarketCore
   * @dev This is a no-op function required to avoid compile errors.
   */
  function _transferFromEscrow(
    address nftContract,
    uint256 tokenId,
    address recipient,
    address authorizeSeller
  ) internal override(NFTMarketCore, NFTMarketReserveAuction, NFTMarketBuyPrice) {
    super._transferFromEscrow(nftContract, tokenId, recipient, authorizeSeller);
  }

  /**
   * @inheritdoc NFTMarketCore
   * @dev This is a no-op function required to avoid compile errors.
   */
  function _transferFromEscrowIfAvailable(
    address nftContract,
    uint256 tokenId,
    address recipient
  ) internal override(NFTMarketCore, NFTMarketReserveAuction, NFTMarketBuyPrice) {
    super._transferFromEscrowIfAvailable(nftContract, tokenId, recipient);
  }
  function initialize() external initializer {
    NFTMarketAuction._initializeNFTMarketAuction();
  }
  /**
   * @inheritdoc NFTMarketCore
   * @dev This is a no-op function required to avoid compile errors.
   */
  function _transferToEscrow(address nftContract, uint256 tokenId)
    internal
    override(NFTMarketCore, NFTMarketReserveAuction, NFTMarketBuyPrice)
  {
    super._transferToEscrow(nftContract, tokenId);
  }

  /**
   * @inheritdoc NFTMarketCore
   * @dev This is a no-op function required to avoid compile errors.
   */
  function _getSellerFor(address nftContract, uint256 tokenId)
    internal
    view
    override(NFTMarketCore, NFTMarketReserveAuction, NFTMarketBuyPrice)
    returns (address payable seller)
  {
    seller = super._getSellerFor(nftContract, tokenId);
  }
}
