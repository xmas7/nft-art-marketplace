/*
  MUSEE Protocol
*/

// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./mixins/OZ/ERC721Upgradeable.sol";

import "./mixins/MuseeTreasuryNode.sol";
import "./mixins/NFT721Core.sol";
import "./mixins/NFT721Market.sol";
import "./mixins/NFT721Creator.sol";
import "./mixins/NFT721Metadata.sol";
import "./mixins/NFT721Mint.sol";
import "./mixins/NFT721ProxyCall.sol";
import "./mixins/ERC165UpgradeableGap.sol";

/**
 * @title Musee NFTs implemented using the ERC-721 standard.
 */
contract MUSEENFT721 is
  Initializable,
  MuseeTreasuryNode,
  ERC165UpgradeableGap,
  ERC165,
  ERC721Upgradeable,
  NFT721Core,
  NFT721ProxyCall,
  NFT721Creator,
  NFT721Market,
  NFT721Metadata,
  NFT721Mint
{
  constructor(address payable treasury)
    MuseeTreasuryNode(treasury) // solhint-disable-next-line no-empty-blocks
  {}

  /**
   * @notice Called once to configure the contract after the initial deployment.
   * @dev This farms the initialize call out to inherited contracts as needed.
   */
  function initialize() external initializer {
    ERC721Upgradeable.__ERC721_init();
    NFT721Mint._initializeNFT721Mint();
  }

  /**
   * @notice Allows a Musee admin to update NFT config variables.
   * @dev This must be called right after the initial call to `initialize`.
   */
  function adminUpdateConfig(
    address _nftMarket,
    string calldata baseURI,
    address proxyCallContract
  ) external onlyMuseeAdmin {
    _updateNFTMarket(_nftMarket);
    _updateBaseURI(baseURI);
    _updateProxyCall(proxyCallContract);
  }

  /**
   * @dev This is a no-op, just an explicit override to address compile errors due to inheritance.
   */
  function _burn(uint256 tokenId) internal override(ERC721Upgradeable, NFT721Creator, NFT721Metadata, NFT721Mint) {
    super._burn(tokenId);
  }

  function supportsInterface(bytes4 interfaceId)
    public
    view
    override(ERC165, NFT721Mint, ERC721Upgradeable, NFT721Creator, NFT721Market)
    returns (bool)
  {
    return super.supportsInterface(interfaceId);
  }
}

/***********************************
*   _burn and _transfer needed     *
*   _burn implmeneted here         *
*   _tansfer is at main contract   *
************************************/