// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

//LZ
import "tapioca-sdk/dist/contracts/libraries/LzLib.sol";

//TAPIOCA
import {IUSDOBase} from "tapioca-periph/contracts/interfaces/IUSDO.sol";
import "tapioca-periph/contracts/interfaces/ISwapper.sol";
import "tapioca-periph/contracts/interfaces/ITapiocaOFT.sol";
import "tapioca-periph/contracts/interfaces/ISingularity.sol";

import "./USDOCommon.sol";

contract USDOLeverageDestinationModule is USDOCommon {
    using SafeERC20 for IERC20;

    constructor(
        address _lzEndpoint,
        IYieldBoxBase _yieldBox,
        ICluster _cluster
    ) BaseUSDOStorage(_lzEndpoint, _yieldBox, _cluster) {}

    /// @dev destination call for USDOLeverageModule.sendForLeverage
    function leverageUp(
        address module,
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) public {
        if (msg.sender != address(this)) revert SenderNotAuthorized();
        if (_moduleAddresses[Module.LeverageDestination] != module)
            revert NotValid();

        (
            ,
            uint64 amountSD,
            IUSDOBase.ILeverageSwapData memory swapData,
            IUSDOBase.ILeverageExternalContractsData memory externalData,
            IUSDOBase.ILeverageLZData memory lzData,
            address leverageFor,
            uint256 airdropAmount
        ) = abi.decode(
                _payload,
                (
                    uint16,
                    uint64,
                    IUSDOBase.ILeverageSwapData,
                    IUSDOBase.ILeverageExternalContractsData,
                    IUSDOBase.ILeverageLZData,
                    address,
                    uint256
                )
            );
        uint256 amount = _sd2ld(amountSD);
        uint256 balanceBefore = balanceOf(address(this));
        _checkCredited(_srcChainId, _srcAddress, _nonce, amount);
        uint256 balanceAfter = balanceOf(address(this));
        (bool success, bytes memory reason) = module.delegatecall(
            abi.encodeWithSelector(
                this.leverageUpInternal.selector,
                amount,
                swapData,
                externalData,
                lzData,
                leverageFor,
                airdropAmount
            )
        );
        if (!success) {
            if (balanceAfter - balanceBefore >= amount) {
                IERC20(address(this)).safeTransfer(leverageFor, amount);
            }
            _storeFailedMessage(
                _srcChainId,
                _srcAddress,
                _nonce,
                _payload,
                reason
            );
            emit CallFailedBytes(_srcChainId, _payload, reason);
        }
        emit ReceiveFromChain(_srcChainId, leverageFor, amount);
    }

    function _checkCredited(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        uint256 amount
    ) private {
        bool credited = creditedPackets[_srcChainId][_srcAddress][_nonce];
        if (!credited) {
            _creditTo(_srcChainId, address(this), amount);
            creditedPackets[_srcChainId][_srcAddress][_nonce] = true;
        }
    }

    function leverageUpInternal(
        uint256 amount,
        IUSDOBase.ILeverageSwapData memory swapData,
        IUSDOBase.ILeverageExternalContractsData memory externalData,
        IUSDOBase.ILeverageLZData memory lzData,
        address leverageFor,
        uint256 airdropAmount
    ) public payable {
        if (msg.sender != address(this)) revert SenderNotAuthorized();

        //swap from USDO
        if (externalData.swapper != address(0)) {
            if (!cluster.isWhitelisted(0, externalData.swapper))
                revert NotAuthorized(externalData.swapper);
        }
        if (!cluster.isWhitelisted(0, externalData.tOft))
            revert NotAuthorized(externalData.tOft);
        if (!cluster.isWhitelisted(0, externalData.magnetar))
            revert NotAuthorized(externalData.magnetar);
        if (!cluster.isWhitelisted(0, externalData.srcMarket))
            revert NotAuthorized(externalData.srcMarket);

        _approve(address(this), externalData.swapper, amount);
        ISwapper.SwapData memory _swapperData = ISwapper(externalData.swapper)
            .buildSwapData(address(this), swapData.tokenOut, amount, 0);
        (uint256 amountOut, ) = ISwapper(externalData.swapper).swap(
            _swapperData,
            swapData.amountOutMin,
            address(this),
            swapData.data
        );
        //wrap into tOFT
        if (swapData.tokenOut != address(0)) {
            //skip approval for native
            IERC20(swapData.tokenOut).approve(externalData.tOft, 0);
            IERC20(swapData.tokenOut).approve(externalData.tOft, amountOut);
        }
        ITapiocaOFTBase(externalData.tOft).wrap{
            value: swapData.tokenOut == address(0) ? amountOut : 0
        }(address(this), address(this), amountOut);
        //send to YB & deposit
        ICommonData.IApproval[] memory approvals;
        ITapiocaOFT(externalData.tOft).sendToYBAndBorrow{value: airdropAmount}(
            address(this),
            leverageFor,
            lzData.lzSrcChainId,
            lzData.srcAirdropAdapterParam,
            ITapiocaOFT.IBorrowParams({
                amount: amountOut,
                borrowAmount: 0,
                marketHelper: externalData.magnetar,
                market: externalData.srcMarket
            }),
            ICommonData.IWithdrawParams({
                withdraw: false,
                withdrawLzFeeAmount: 0,
                withdrawOnOtherChain: false,
                withdrawLzChainId: 0,
                withdrawAdapterParams: "0x",
                unwrap: false
            }),
            ICommonData.ISendOptions({
                extraGasLimit: lzData.srcExtraGasLimit,
                zroPaymentAddress: lzData.zroPaymentAddress
            }),
            approvals, // Empty array
            approvals // Empty array
        );
    }
}
