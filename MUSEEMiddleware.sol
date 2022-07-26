/*
  MUSEE Protocol
*/

// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./MUSEENFTMarket.sol";
import "./PercentSplitETH.sol";
import "./CollectionContract.sol";
import "./mixins/Constants.sol";
import "./METH.sol";
import "./interfaces/ens/IENS.sol";
import "./interfaces/ens/IPublicResolver.sol";
import "./interfaces/ens/IReverseRegistrar.sol";

error MUSEEMiddleware_Contract_Is_Not_ERC721();
error MUSEEMiddleware_No_Royalty_Recipients_Defined();
error MUSEEMiddleware_Royalty_Recipient_Address_0();
error MUSEEMiddleware_Royalty_Recipient_Not_Receivable(address recipient);

/**
 * @title Convenience methods to ease integration with other contracts.
 * @notice This will aggregate calls and format the output per the needs of our frontend or other consumers.
 */
contract MUSEEMiddleware is Constants {
  using AddressUpgradeable for address;
  using AddressUpgradeable for address payable;
  using Strings for uint256;
  using ERC165Checker for address;

  struct Fee {
    uint256 percentInBasisPoints;
    uint256 amountInWei;
  }
  struct FeeWithRecipient {
    uint256 percentInBasisPoints;
    uint256 amountInWei;
    address payable recipient;
  }
  struct RevSplit {
    uint256 relativePercentInBasisPoints;
    uint256 absolutePercentInBasisPoints;
    uint256 amountInWei;
    address payable recipient;
  }

  MUSEENFTMarket private immutable market;
  METH private immutable meth;
  IENS private immutable ens;

  constructor(
    address payable _market,
    address payable _meth,
    address _ens
  ) {
    market = MUSEENFTMarket(_market);
    meth = METH(_meth);
    ens = IENS(_ens);
  }

  // solhint-disable-next-line code-complexity
  function getFees(
    address nftContract,
    uint256 tokenId,
    uint256 price
  )
    public
    view
    returns (
      FeeWithRecipient memory musee,
      Fee memory creator,
      FeeWithRecipient memory owner,
      RevSplit[] memory creatorRevSplit
    )
  {
    musee.recipient = market.getMuseeTreasury();
    address payable[] memory creatorRecipients;
    uint256[] memory creatorShares;
    uint256 creatorRev;
    {
      address payable ownerAddress;
      uint256 museeFee;
      uint256 ownerRev;
      (museeFee, creatorRev, creatorRecipients, creatorShares, ownerRev, ownerAddress) = market
        .getFeesAndRecipients(nftContract, tokenId, price);
      musee.amountInWei = museeFee;
      creator.amountInWei = creatorRev;
      owner.amountInWei = ownerRev;
      owner.recipient = ownerAddress;
      if (creatorShares.length == 0) {
        creatorShares = new uint256[](creatorRecipients.length);
        if (creatorShares.length == 1) {
          creatorShares[0] = BASIS_POINTS;
        }
      }
    }
    uint256 creatorRevBP;
    {
      uint256 museeFeeBP;
      uint256 ownerRevBP;
      (museeFeeBP, creatorRevBP, , , ownerRevBP, ) = market.getFeesAndRecipients(
        nftContract,
        tokenId,
        BASIS_POINTS
      );
      musee.percentInBasisPoints = museeFeeBP;
      creator.percentInBasisPoints = creatorRevBP;
      owner.percentInBasisPoints = ownerRevBP;
    }

    // Normalize shares to 10%
    {
      uint256 totalShares = 0;
      for (uint256 i = 0; i < creatorShares.length; ++i) {
        // TODO handle ignore if > 100% (like the market would)
        totalShares += creatorShares[i];
      }

      for (uint256 i = 0; i < creatorShares.length; ++i) {
        creatorShares[i] = (BASIS_POINTS * creatorShares[i]) / totalShares;
      }
    }

    // Count creators and split recipients
    {
      uint256 creatorCount = creatorRecipients.length;
      for (uint256 i = 0; i < creatorRecipients.length; ++i) {
        // Check if the address is a percent split
        if (address(creatorRecipients[i]).isContract()) {
          try PercentSplitETH(creatorRecipients[i]).getShareLength{ gas: READ_ONLY_GAS_LIMIT }() returns (
            uint256 recipientCount
          ) {
            creatorCount += recipientCount - 1;
          } catch // solhint-disable-next-line no-empty-blocks
          {
            // Not a Musee percent split
          }
        }
      }
      creatorRevSplit = new RevSplit[](creatorCount);
    }

    // Populate rev splits, including any percent splits
    uint256 revSplitIndex = 0;
    for (uint256 i = 0; i < creatorRecipients.length; ++i) {
      if (address(creatorRecipients[i]).isContract()) {
        try PercentSplitETH(creatorRecipients[i]).getShareLength{ gas: READ_ONLY_GAS_LIMIT }() returns (
          uint256 recipientCount
        ) {
          uint256 totalSplitShares;
          for (uint256 splitIndex = 0; splitIndex < recipientCount; ++splitIndex) {
            uint256 share = PercentSplitETH(creatorRecipients[i]).getPercentInBasisPointsByIndex(splitIndex);
            totalSplitShares += share;
          }
          for (uint256 splitIndex = 0; splitIndex < recipientCount; ++splitIndex) {
            uint256 splitShare = (PercentSplitETH(creatorRecipients[i]).getPercentInBasisPointsByIndex(splitIndex) *
              BASIS_POINTS) / totalSplitShares;
            splitShare = (splitShare * creatorShares[i]) / BASIS_POINTS;
            creatorRevSplit[revSplitIndex++] = _calcRevSplit(
              price,
              splitShare,
              creatorRevBP,
              PercentSplitETH(creatorRecipients[i]).getShareRecipientByIndex(splitIndex)
            );
          }
          continue;
        } catch // solhint-disable-next-line no-empty-blocks
        {
          // Not a Musee percent split
        }
      }
      {
        creatorRevSplit[revSplitIndex++] = _calcRevSplit(price, creatorShares[i], creatorRevBP, creatorRecipients[i]);
      }
    }

    // Bubble the creator to the first position in `creatorRevSplit`
    {
      address creatorAddress;
      try ITokenCreator(nftContract).tokenCreator{ gas: READ_ONLY_GAS_LIMIT }(tokenId) returns (
        address payable _creator
      ) {
        creatorAddress = _creator;
      } catch // solhint-disable-next-line no-empty-blocks
      {
        // Fall through
      }

      // 7th priority: owner from contract or override
      try IOwnable(nftContract).owner{ gas: READ_ONLY_GAS_LIMIT }() returns (address _owner) {
        if (_owner != address(0)) {
          creatorAddress = _owner;
        }
      } catch // solhint-disable-next-line no-empty-blocks
      {
        // Fall through
      }
      if (creatorAddress != address(0)) {
        for (uint256 i = 1; i < creatorRevSplit.length; ++i) {
          if (creatorRevSplit[i].recipient == creatorAddress) {
            (creatorRevSplit[i], creatorRevSplit[0]) = (creatorRevSplit[0], creatorRevSplit[i]);
            break;
          }
        }
      }
    }
  }

  /**
   * @notice Checks an NFT to confirm it will function correctly with our marketplace.
   * @dev This should be called with as `call` to simulate the tx; never `sendTransaction`.
   */
  function probeNFT(address nftContract, uint256 tokenId) external payable {
    if (!nftContract.supportsInterface(type(IERC721).interfaceId)) {
      revert MUSEEMiddleware_Contract_Is_Not_ERC721();
    }
    (, , , RevSplit[] memory creatorRevSplit) = getFees(nftContract, tokenId, BASIS_POINTS);
    if (creatorRevSplit.length == 0) {
      revert MUSEEMiddleware_No_Royalty_Recipients_Defined();
    }
    for (uint256 i = 0; i < creatorRevSplit.length; ++i) {
      address recipient = creatorRevSplit[i].recipient;
      if (recipient == address(0)) {
        revert MUSEEMiddleware_Royalty_Recipient_Address_0();
      }
      // Sending > 1 to help confirm when the recipient is a contract forwarding to other addresses
      // solhint-disable-next-line avoid-low-level-calls
      (bool success, ) = recipient.call{ value: 10, gas: SEND_VALUE_GAS_LIMIT_MULTIPLE_RECIPIENTS }("");
      if (!success) {
        revert MUSEEMiddleware_Royalty_Recipient_Not_Receivable(recipient);
      }
    }
  }

  function getAccountInfo(address account)
    external
    view
    returns (
      uint256 ethBalance,
      uint256 availableMethBalance,
      uint256 lockedMethBalance,
      string memory ensName
    )
  {
    ethBalance = account.balance;
    availableMethBalance = meth.balanceOf(account);
    lockedMethBalance = meth.totalBalanceOf(account) - availableMethBalance;

    // Lookup ENS name, if one was registered
    ensName = _getENSName(account);
  }

  /**
   * @notice Retrieves details related to the NFT in the MUSEE Market.
   * @param nftContract The address of the contract for the NFT
   * @param tokenId The id for the NFT in the contract.
   */
  function getNFTDetails(address nftContract, uint256 tokenId)
    public
    view
    returns (
      address owner,
      bool isInEscrow,
      address auctionBidder,
      uint256 auctionEndTime,
      uint256 auctionPrice,
      uint256 auctionId,
      uint256 buyPrice,
      uint256 offerAmount,
      address offerBuyer,
      uint256 offerExpiration
    )
  {
    (owner, buyPrice) = market.getBuyPrice(nftContract, tokenId);
    (offerBuyer, offerExpiration, offerAmount) = market.getOffer(nftContract, tokenId);
    auctionId = market.getReserveAuctionIdFor(nftContract, tokenId);
    if (auctionId != 0) {
      NFTMarketReserveAuction.ReserveAuction memory auction = market.getReserveAuction(auctionId);
      auctionEndTime = auction.endTime;
      auctionPrice = auction.amount;
      auctionBidder = auction.bidder;
      owner = auction.seller;
    }

    if (owner == address(0)) {
      owner = payable(IERC721(nftContract).ownerOf(tokenId));
      isInEscrow = false;
    } else {
      isInEscrow = true;
    }
  }

  // solhint-disable-next-line code-complexity
  function getNFTDetailString(address nftContract, uint256 tokenId) external view returns (string memory details) {
    (
      address owner,
      bool isInEscrow,
      address auctionBidder,
      uint256 auctionEndTime,
      uint256 auctionPrice,
      uint256 auctionId,
      uint256 buyPrice,
      uint256 offerAmount,
      address offerBuyer,
      uint256 offerExpiration
    ) = getNFTDetails(nftContract, tokenId);
    details = _getAddressAndName(owner);
    if (isInEscrow) {
      if (auctionEndTime > 0) {
        if (auctionEndTime >= block.timestamp) {
          // Active auction
          details = string.concat(
            details,
            " has it in active auction going for ",
            _getETHString(auctionPrice),
            ", bid from ",
            _getAddressAndName(auctionBidder),
            " and ends in ",
            _getDeltaTimeString(auctionEndTime - block.timestamp),
            " [auctionId: ",
            auctionId.toString(),
            "]"
          );
        } else {
          // Auction ended, pending finalization
          details = string.concat(
            details,
            " sold it in auction for ",
            _getETHString(auctionPrice),
            " to ",
            _getAddressAndName(auctionBidder),
            " ",
            _getDeltaTimeString(block.timestamp - auctionEndTime),
            " ago [pending settlement / auctionId: ",
            auctionId.toString(),
            "]"
          );
        }
      } else {
        // Buy now and/or reserve price
        details = string.concat(details, " listed for ");
        if (buyPrice < type(uint256).max) {
          details = string.concat(details, "buy now at ", _getETHString(buyPrice));
        }
        if (buyPrice < type(uint256).max && auctionPrice > 0) {
          details = string.concat(details, " or ");
        }
        if (auctionPrice > 0) {
          details = string.concat(
            details,
            "reserve price of ",
            _getETHString(auctionPrice),
            " [auctionId: ",
            auctionId.toString(),
            "]"
          );
        }
      }

      if (offerAmount > 0) {
        // With an offer too
        details = string.concat(
          details,
          " with an offer of ",
          _getOfferString(offerAmount, offerBuyer, offerExpiration)
        );
      }
    } else if (offerAmount > 0) {
      // Just an offer
      details = string.concat(details, " has an offer for ", _getOfferString(offerAmount, offerBuyer, offerExpiration));
    } else {
      // Nothing
      details = string.concat(details, " has not listed nor gotten an offer");
    }
    
    // Populate rev splits, including any percent splits
    uint256 revSplitIndex = 0;
    for (uint256 i = 0; i < creatorRecipients.length; ++i) {
      if (address(creatorRecipients[i]).isContract()) {
        try PercentSplitETH(creatorRecipients[i]).getShareLength{ gas: READ_ONLY_GAS_LIMIT }() returns (
          uint256 recipientCount
        ) {
          uint256 totalSplitShares;
          for (uint256 splitIndex = 0; splitIndex < recipientCount; ++splitIndex) {
            uint256 share = PercentSplitETH(creatorRecipients[i]).getPercentInBasisPointsByIndex(splitIndex);
            totalSplitShares += share;
          }
          for (uint256 splitIndex = 0; splitIndex < recipientCount; ++splitIndex) {
            uint256 splitShare = (PercentSplitETH(creatorRecipients[i]).getPercentInBasisPointsByIndex(splitIndex) *
              BASIS_POINTS) / totalSplitShares;
            splitShare = (splitShare * creatorShares[i]) / BASIS_POINTS;
            creatorRevSplit[revSplitIndex++] = _calcRevSplit(
              price,
              splitShare,
              creatorRevBP,
              PercentSplitETH(creatorRecipients[i]).getShareRecipientByIndex(splitIndex)
            );
          }
          continue;
        } catch // solhint-disable-next-line no-empty-blocks
        {
          // Not a Musee percent split
        }
      }
      {
        creatorRevSplit[revSplitIndex++] = _calcRevSplit(price, creatorShares[i], creatorRevBP, creatorRecipients[i]);
      }
    }
  }

  function _calcRevSplit(
    uint256 price,
    uint256 share,
    uint256 creatorRevBP,
    address payable recipient
  ) private pure returns (RevSplit memory) {
    uint256 absoluteShare = (share * creatorRevBP) / BASIS_POINTS;
    uint256 amount = (absoluteShare * price) / BASIS_POINTS;
    return RevSplit(share, absoluteShare, amount, recipient);
  }

  function _getAddressAndName(address account) private view returns (string memory name) {
    string memory ensName = _getENSName(account);
    if (bytes(ensName).length > 0) {
      name = string.concat(_toAsciiString(account), " (", ensName, ")");
    } else {
      name = _toAsciiString(account);
    }
  }

  // solhint-disable-next-line code-complexity
  function _getDeltaTimeString(uint256 timeRemaining) private pure returns (string memory delta) {
    uint256 secondsRemaining = timeRemaining;
    // Days
    if (timeRemaining >= 1 days) {
      uint256 day = secondsRemaining / (1 days);
      if (day == 1) {
        delta = "1 day";
      } else {
        delta = string.concat(day.toString(), " days");
      }
      secondsRemaining -= day * 1 days;
      if (secondsRemaining == 0) {
        return delta;
      } else {
        delta = string.concat(delta, " ");
      }
    }
    // Hours
    if (timeRemaining >= 1 hours) {
      uint256 hrs = secondsRemaining / (1 hours);
      if (hrs == 1) {
        delta = string.concat(delta, "1 hour");
      } else {
        delta = string.concat(delta, hrs.toString(), " hours");
      }
      secondsRemaining -= hrs * 1 hours;
      if (secondsRemaining == 0) {
        return delta;
      } else {
        delta = string.concat(delta, " ");
      }
    }
    // Minutes
    if (timeRemaining >= 1 minutes) {
      uint256 mins = secondsRemaining / (1 minutes);
      if (mins == 1) {
        delta = string.concat(delta, "1 min");
      } else {
        delta = string.concat(delta, mins.toString(), " mins");
      }
      secondsRemaining -= mins * 1 minutes;
      if (secondsRemaining == 0) {
        return delta;
      } else {
        delta = string.concat(delta, " ");
      }
    }
    // Seconds
    if (secondsRemaining == 1) {
      delta = string.concat(delta, "1 sec");
    } else {
      delta = string.concat(delta, secondsRemaining.toString(), " secs");
    }
  }

  // solhint-disable-next-line code-complexity
  function _getETHString(uint256 amount) private pure returns (string memory eth) {
    string memory amountString = amount.toString();
    uint256 printedCount = 0;
    if (bytes(amountString).length > 18) {
      for (uint256 i = 0; i < bytes(amountString).length - 18; ++i) {
        bytes memory byteArray = new bytes(1);
        byteArray[0] = bytes(amountString)[i];
        eth = string.concat(eth, string(byteArray));
        printedCount++;
      }
    } else {
      eth = "0";
    }
    uint256 endingZeros = 0;
    for (uint256 i = bytes(amountString).length - 1; i > 0; --i) {
      if (bytes(amountString)[i] == bytes("0")[0]) {
        ++endingZeros;
      } else {
        break;
      }
    }
    if (endingZeros < 18) {
      eth = string.concat(eth, ".");

      if (bytes(amountString).length < 18) {
        // add leading zeros
        for (uint256 i = 0; i < 18 - bytes(amountString).length; ++i) {
          eth = string.concat(eth, "0");
        }
      }
      for (; printedCount < bytes(amountString).length - endingZeros; ++printedCount) {
        bytes memory byteArray = new bytes(1);
        byteArray[0] = bytes(amountString)[printedCount];
        eth = string.concat(eth, string(byteArray));
      }
    }

    eth = string.concat(eth, " ETH");
  }

  function _getENSName(address account) private view returns (string memory ensName) {
    IReverseRegistrar reverseRegistrar = IReverseRegistrar(
      ens.owner(
        keccak256(
          abi.encodePacked(keccak256(abi.encodePacked(abi.encode(bytes32(0)), keccak256("reverse"))), keccak256("addr"))
        )
      )
    );
    bytes32 node = reverseRegistrar.node(account);
    if (node != bytes32(0)) {
      IPublicResolver resolver = IPublicResolver(ens.resolver(node));

      // The standard call style is reverting when no results are found
      (bool success, bytes memory data) = address(resolver).staticcall(abi.encodeWithSignature("name(bytes32)", node));

      if (success && data.length > 0) {
        ensName = resolver.name(node);

        // TODO this only works for .eth names, subdomains and others will be ignored
        bytes32 nameNode = keccak256(
          abi.encodePacked(
            keccak256(abi.encodePacked(bytes32(0), keccak256("eth"))),
            keccak256(_substring(ensName, 0, bytes(ensName).length - 4))
          )
        );

        // Validate ownership
        address owner = ens.owner(nameNode);
        if (owner != account) {
          // Invalid reverse registration
          ensName = "";
        }
      }
    }
  }

  function _getOfferString(
    uint256 amount,
    address buyer,
    uint256 expiration
  ) private view returns (string memory offer) {
    offer = string.concat(
      _getETHString(amount),
      " from ",
      _getAddressAndName(buyer),
      " that expires in ",
      _getDeltaTimeString(expiration - block.timestamp)
    );
  }

  function _substring(
    string memory str,
    uint256 startIndex,
    uint256 endIndex
  ) private pure returns (bytes memory result) {
    bytes memory strBytes = bytes(str);
    result = new bytes(endIndex - startIndex);
    for (uint256 i = startIndex; i < endIndex; ++i) {
      result[i - startIndex] = strBytes[i];
    }
  }

  /**
   * @notice Converts an address into a string.
   * @dev From https://ethereum.stackexchange.com/questions/8346/convert-address-to-string
   */
  function _toAsciiString(address x) private pure returns (string memory) {
    unchecked {
      bytes memory s = new bytes(42);
      s[0] = "0";
      s[1] = "x";
      for (uint256 i = 0; i < 20; ++i) {
        bytes1 b = bytes1(uint8(uint256(uint160(x)) / (2**(8 * (19 - i)))));
        bytes1 hi = bytes1(uint8(b) / 16);
        bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
        s[2 * i + 2] = _char(hi);
        s[2 * i + 3] = _char(lo);
      }
      return string(s);
    }
  }

  /**
   * @notice Converts a byte to a UTF-8 character.
   */
  function _char(bytes1 b) private pure returns (bytes1 c) {
    unchecked {
      if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
      else return bytes1(uint8(b) + 0x57);
    }
  }
}
